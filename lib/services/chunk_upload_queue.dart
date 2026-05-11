import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'onedrive_service.dart';
import 'upload_queue_db.dart';
import 'upload_work_manager.dart';
import 'attendance_auto_sync.dart';
import 'firestore_cache_service.dart';
import 'notification_service.dart';
import 'upload_foreground_service.dart';
import 'user_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;

// ─── Duration formatter ────────────────────────────────────────────────────────
String fmtDuration(int totalSecs) {
  if (totalSecs <= 0) return '0s';
  if (totalSecs < 60) return '${totalSecs}s';
  final mins = totalSecs ~/ 60;
  final secs = totalSecs % 60;
  if (mins < 60) return secs > 0 ? '${mins}m ${secs}s' : '${mins}m';
  final hrs = mins ~/ 60; final rem = mins % 60;
  return rem > 0 ? '${hrs}h ${rem}m' : '${hrs}h';
}

// ─── PendingChunk ─────────────────────────────────────────────────────────────
class PendingChunk {
  final String   filePath;
  final String   backupPath;
  final String   sessionId;
  final String   userId;
  final int      partNumber;
  final DateTime sessionDate;
  final DateTime sessionStartTime;
  final DateTime sessionEndTime;
  final int      startSec;
  final int      endSec;
  // No longer stored in-memory — session URL lives in SQLite only.
  // This prevents stale in-memory URLs from being reused after expiry.

  PendingChunk({
    required this.filePath,
    required this.backupPath,
    required this.sessionId,
    required this.userId,
    required this.partNumber,
    required this.sessionDate,
    required this.sessionStartTime,
    required this.sessionEndTime,
    required this.startSec,
    required this.endSec,
  });

  int get durationSecs {
    final raw = endSec - startSec;
    if (raw > 0) return raw.clamp(0, 7200);
    // Fallback: parse duration from the cloud filename suffix (_NNNs.mp4).
    // This covers recovered/orphaned chunks where startSec/endSec are both 0
    // because the filename could not be fully parsed at recovery time.
    final m = RegExp(r'_(\d+)s\.mp4$').firstMatch(cloudFileName);
    if (m != null) {
      final parsed = int.tryParse(m.group(1)!);
      if (parsed != null && parsed > 0) return parsed.clamp(0, 7200);
    }
    // Last resort: derive from actual file size (assume ~500KB/s for 1080p)
    try {
      final bytes = File(bestFilePath).lengthSync();
      if (bytes > 0) return (bytes / (500 * 1024)).round().clamp(1, 7200);
    } catch (_) {}
    return 0;
  }
  int get startMin     => startSec ~/ 60;
  int get endMin       => (endSec + 59) ~/ 60;

  String get cloudFileName {
    final n          = partNumber.toString().padLeft(2, '0');
    final date       = DateFormat('yyyyMMdd').format(sessionDate);
    final chunkStart = sessionStartTime.add(Duration(seconds: startSec));
    final chunkEnd   = sessionStartTime.add(Duration(seconds: endSec));
    final sFmt = DateFormat('HHmmss').format(chunkStart);
    final eFmt = DateFormat('HHmmss').format(chunkEnd);
    final dur  = (endSec - startSec).clamp(0, 7200);
    return '${sessionId}_${date}_P$n'
        '_S${sFmt}_E${eFmt}_${dur}s.mp4';
  }

  String get sessionFolderName {
    final date  = DateFormat('yyyyMMdd').format(sessionDate);
    final start = DateFormat('HHmmss').format(sessionStartTime);
    return '${sessionId}_${date}_$start';
  }

  bool get hasAnyFile =>
      File(filePath).existsSync() || File(backupPath).existsSync();

  String get bestFilePath =>
      File(filePath).existsSync() ? filePath : backupPath;
}

// ─── ChunkStatus ──────────────────────────────────────────────────────────────
enum ChunkStatus { queued, uploading, done, failed }

class ChunkState {
  final PendingChunk chunk;
  ChunkStatus status;
  double      progress;
  String      message;
  int         retryCount;
  DateTime?   failedAt;

  ChunkState(this.chunk)
      : status     = ChunkStatus.queued,
        progress   = 0.0,
        message    = 'Queued',
        retryCount = 0;
}

class _PermanentFailure implements Exception {
  final String message;
  const _PermanentFailure(this.message);
  @override String toString() => message;
}

/// Thrown when WorkManager already uploaded this chunk.
class _AlreadyDone implements Exception {}

// ─── ChunkUploadQueue ─────────────────────────────────────────────────────────
class ChunkUploadQueue {
  static final ChunkUploadQueue _i = ChunkUploadQueue._();
  factory ChunkUploadQueue() => _i;
  ChunkUploadQueue._();

  static const _rootFolder     = 'OTN Recorder';
  static const _wifiPrefKey    = 'upload_wifi_only';
  static const _meteredPrefKey = 'upload_allow_metered';
  static const _backupDirName  = 'otn_backup';
  static const _chunkDirName   = 'otn_upload_chunks';
  static const _retentionDays  = 7;
  static const _maxRetries     = 1;

  final _onedrive = OneDriveService();
  final _states   = <String, ChunkState>{};
  final _queue    = <PendingChunk>[];

  bool _running       = false;
  bool _hasNetwork    = true;
  bool _isWifi        = true;
  bool _cellularOk    = false;
  bool _wifiPreferred = true;
  bool _allowMetered  = false;
  bool _globalHold    = false;

  // Real-time upload speed tracking (upload-based, bytes per second)
  int    _speedWindowBytes = 0;
  int    _speedWindowStart = 0;
  double _currentSpeedBps  = 0;

  // Independent real-time network speed probe
  // Runs every 3s regardless of whether an upload is active.
  // Measures actual download throughput by fetching a small CDN payload.
  Timer?  _netProbeTimer;
  double  _netProbeBps   = 0;   // latest probe result in bytes/sec
  bool    _probeRunning  = false;

  final _ctrl = StreamController<List<ChunkState>>.broadcast();
  Stream<List<ChunkState>> get stream => _ctrl.stream;

  // ALL chunks (including done) — so done chunks stay visible in the UI
  // as green tiles until the ENTIRE session is confirmed and removed at once.
  // Previously filtered out done chunks which caused them to disappear mid-session.
  List<ChunkState> get current => _states.values.toList()
      ..sort((a, b) {
        final sid = a.chunk.sessionId.compareTo(b.chunk.sessionId);
        return sid != 0 ? sid : a.chunk.partNumber.compareTo(b.chunk.partNumber);
      });

  List<ChunkState> get all => _states.values.toList();
  Timer? _persistDebounce;

  // Debounced emit: batches rapid consecutive updates into a single UI rebuild.
  // Without this, operations like "mark 5 chunks done in quick succession"
  // trigger 5 separate StreamBuilder rebuilds causing visible jank.
  // The 16ms window (~1 frame at 60fps) coalesces same-frame updates.
  Timer? _emitDebounce;
  void _emit() {
    _emitDebounce?.cancel();
    _emitDebounce = Timer(const Duration(milliseconds: 16), () {
      if (!_ctrl.isClosed) {
        _ctrl.add(current);
        _updateForegroundService();
      }
    });
  }

  // Immediate emit — used only when UI correctness requires no delay
  // (e.g. after network state changes where the user is watching)
  void _emitNow() {
    _emitDebounce?.cancel();
    if (!_ctrl.isClosed) {
      _ctrl.add(current);
      _updateForegroundService();
    }
  }

  // ── DB → UI sync (WorkManager progress bridge) ────────────────────────────
  Future<void> _syncProgressFromDb() async {
    if (_states.isEmpty) return;
    try {
      final allRows = await UploadQueueDb.instance.db.then(
          (db) => db.query('upload_queue',
              columns: ['local_file_path', 'bytes_uploaded', 'file_size_bytes', 'status'],
              where: 'chunk_id IN (${_states.keys.map((_) => '?').join(',')})',
              whereArgs: _states.keys.toList()));

      bool changed = false;
      for (final row in allRows) {
        final filePath = row['local_file_path'] as String? ?? '';
        final bytesUp  = row['bytes_uploaded']  as int?    ?? 0;
        final fileSize = row['file_size_bytes']  as int?    ?? 0;
        final dbStatus = row['status']           as String? ?? '';
        if (filePath.isEmpty) continue;

        final state = _states[filePath];
        if (state == null) continue;

        if (dbStatus == 'done') {
          state.status   = ChunkStatus.done;
          state.progress = 1.0;
          state.message  = 'Done ✓';
          // Check session completion using _states (in-memory), NOT DB.
          // DB may be ahead of UI (WM wrote done before all states updated).
          // Only remove the session when every chunk in _states is done —
          // this ensures all tiles show green briefly before the session disappears.
          final sid = state.chunk.sessionId;
          final allInMemoryDone = _states.values
              .where((s) => s.chunk.sessionId == sid)
              .every((s) => s.status == ChunkStatus.done);
          if (allInMemoryDone) {
            _writeChunkToFirestore(state.chunk).ignore();
            // Delete local files + DB rows before removing from states
            final toDelete = _states.values
                .where((s) => s.chunk.sessionId == sid)
                .toList();
            for (final s in toDelete) {
              _deleteFiles(s.chunk).ignore();
              UploadQueueDb.instance.deleteChunk(s.chunk.filePath).ignore();
            }
            _states.removeWhere((_, s) => s.chunk.sessionId == sid);
            _queue.removeWhere((c) => c.sessionId == sid);
          }
          changed = true;
        } else if (dbStatus == 'uploading' && bytesUp > 0 && fileSize > 0) {
          final progress = (bytesUp / fileSize).clamp(0.0, 1.0);
          if ((progress - state.progress).abs() > 0.01) {
            state.status   = ChunkStatus.uploading;
            state.progress = progress;
            state.message  = 'Uploading ${(progress * 100).toInt()}%';
            changed = true;
          }
        }
      }
      if (changed) _ctrl.add(current);
    } catch (_) {}
  }

  void _updateForegroundService() {
    final uploading = _states.values
        .where((s) => s.status == ChunkStatus.uploading)
        .toList();
    if (uploading.isEmpty) return;
    final active  = uploading.first;
    final total   = _states.length;
    final pct     = (active.progress * 100).toStringAsFixed(0);
    final sid     = active.chunk.sessionId;
    final part    = active.chunk.partNumber;
    UploadForegroundService.update(
      progressText: 'Part $part: $pct% — $sid',
      chunksText:   '$total chunk${total == 1 ? '' : 's'} pending',
    ).ignore();
  }

  // ── Metrics ──────────────────────────────────────────────────────────────
  int  get pendingCount   => _states.values.where((s) => s.status == ChunkStatus.queued).length;
  int  get uploadingCount => _states.values.where((s) => s.status == ChunkStatus.uploading).length;
  int  get failedCount    => _states.values.where((s) => s.status == ChunkStatus.failed).length;
  bool get isUploading    => _states.values.any((s) => s.status == ChunkStatus.uploading);
  bool get isWifi         => _isWifi;
  bool get isGlobalHold   => _globalHold;

  // Sessions that are genuinely still in progress (not yet all-done).
  // Used by history_screen to gate Firestore 'synced' sessions from showing
  // in the Uploaded section while they're still in the Pending section.
  // Excludes sessions where every chunk is done — those are being cleaned up.
  Set<String> get pendingSessionIds => _states.values
      .where((s) => s.status != ChunkStatus.done)
      .map((s) => s.chunk.sessionId)
      .toSet();

  // Returns the best available speed reading at any moment:
  //   • While uploading: live measured upload throughput (byte-counted)
  //   • Between chunks / idle: last measured network probe speed
  // This means the widget ALWAYS shows a meaningful number — it is a
  // real-time network metric, not an "upload is happening" indicator.
  String get uploadSpeedLabel {
    // Prefer live upload measurement while actively uploading
    if (isUploading && _currentSpeedBps > 0) {
      return _formatBps(_currentSpeedBps);
    }
    // Use network probe speed (available even when idle)
    if (_netProbeBps > 0) return _formatBps(_netProbeBps);
    // Fallback labels
    if (!_hasNetwork) return 'No network';
    if (isUploading)  return 'Measuring...';
    return 'Measuring...';
  }

  static String _formatBps(double bps) {
    if (bps >= 1024 * 1024) return '${(bps / 1024 / 1024).toStringAsFixed(1)} MB/s';
    if (bps >= 1024)        return '${(bps / 1024).toStringAsFixed(0)} KB/s';
    return '${bps.toStringAsFixed(0)} B/s';
  }

  // Always true — speed widget shows network quality at all times
  bool get isShowingSpeed => _netProbeBps > 0 || isUploading;

  int get pendingSecs => _states.values
      .where((s) => s.status != ChunkStatus.done)
      .fold(0, (sum, s) {
        if (s.status == ChunkStatus.uploading) {
          final remaining = (s.chunk.durationSecs * (1.0 - s.progress)).round();
          return sum + remaining;
        }
        return sum + s.chunk.durationSecs;
      });

  int get pendingSessionCount => _states.values
      .where((s) => s.status != ChunkStatus.done)
      .map((s) => s.chunk.sessionId)
      .toSet()
      .length;

  int get uploadingProgressSecs => _states.values
      .where((s) => s.status == ChunkStatus.uploading)
      .fold(0, (sum, s) =>
          sum + (s.chunk.durationSecs * s.progress.clamp(0.0, 1.0)).round());

  Map<String, List<ChunkState>> get groupedBySesion {
    final map = <String, List<ChunkState>>{};
    for (final s in current) {
      map.putIfAbsent(s.chunk.sessionId, () => []).add(s);
    }
    for (final list in map.values) {
      list.sort((a, b) => a.chunk.partNumber.compareTo(b.chunk.partNumber));
    }
    return map;
  }

  // ── Persistent base path ──────────────────────────────────────────────────
  static const _persistentBase =
      '/storage/emulated/0/Android/media/com.otn.videorecorder/OTN';

  static Future<Directory> _backupDir() async {
    final dir = Directory('$_persistentBase/$_backupDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> _chunksDir() async {
    final dir = Directory('$_persistentBase/$_chunkDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<String> _ensureBackup(String filePath) async => filePath;

  static Future<void> _deleteFiles(PendingChunk chunk) async {
    final paths = {chunk.filePath, chunk.backupPath};
    for (final path in paths) {
      try {
        final f = File(path);
        if (await f.exists()) {
          await f.delete();
          debugPrint('=== LocalBackup: deleted confirmed chunk $path');
        }
      } catch (e) {
        debugPrint('=== LocalBackup: delete failed for $path — $e');
      }
    }
  }

  // ── Prefs ─────────────────────────────────────────────────────────────────
  Future<void> _loadPrefs() async {
    final prefs    = await SharedPreferences.getInstance();
    _wifiPreferred = prefs.getBool(_wifiPrefKey) ?? true;
    _allowMetered  = prefs.getBool(_meteredPrefKey) ?? false;
    if (_canUpload && _states.values.any(
        (s) => s.status == ChunkStatus.queued)) {
      _processNext();
    }
    _emit();
  }

  Future<void> _saveMeteredPref(bool value) async {
    _allowMetered = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_meteredPrefKey, value);
  }

  // ── Real-time network speed probe ────────────────────────────────────────
  // Fetches a ~100KB payload from Cloudflare's CDN every 3 seconds.
  // This is independent of upload state — gives a live network quality
  // reading even when no upload is happening.
  // Probe URL is intentionally a no-auth static asset so it works globally.
  static const _probeUrl =
      'https://speed.cloudflare.com/__down?bytes=102400'; // 100KB

  void _startNetProbe() {
    _netProbeTimer?.cancel();
    _netProbeTimer = Timer.periodic(const Duration(seconds: 3), (_) => _runProbe());
    _runProbe(); // run immediately on start
  }

  Future<void> _runProbe() async {
    if (_probeRunning || !_hasNetwork) return;
    _probeRunning = true;
    try {
      final start    = DateTime.now().millisecondsSinceEpoch;
      final response = await http.get(Uri.parse(_probeUrl))
          .timeout(const Duration(seconds: 6));
      final elapsed  = DateTime.now().millisecondsSinceEpoch - start;
      if (response.statusCode == 200 && elapsed > 0) {
        final bytes   = response.bodyBytes.length;
        final bps     = (bytes / elapsed) * 1000.0; // bytes per second
        // Exponential moving average: 30% new sample, 70% history
        // Prevents jittery readings from single-probe variance
        _netProbeBps = _netProbeBps == 0
            ? bps
            : _netProbeBps * 0.7 + bps * 0.3;
        _emit();
      }
    } catch (_) {
      // Probe failed (timeout/network) — keep last known value, don't reset
    } finally {
      _probeRunning = false;
    }
  }

  void _stopNetProbe() {
    _netProbeTimer?.cancel();
    _netProbeTimer = null;
  }

  // ── Network monitor ───────────────────────────────────────────────────────
  void startNetworkMonitor({BuildContext? context}) {
    _loadPrefs();
    // Poll SQLite every 2s to sync WorkManager upload progress into UI
    Timer.periodic(const Duration(seconds: 2), (_) => _syncProgressFromDb());
    // Start real-time network speed probe — runs independently of uploads
    _startNetProbe();

    Connectivity().onConnectivityChanged.listen((results) async {
      final wasWifi = _isWifi;
      final result  = results.isNotEmpty ? results.first : ConnectivityResult.none;
      _isWifi     = result == ConnectivityResult.wifi || result == ConnectivityResult.ethernet;
      _hasNetwork = result != ConnectivityResult.none;

      if (!_hasNetwork) {
        _updateAllQueued('Waiting for network...');
        _emitNow(); // immediate — user just saw network drop
        return;
      }

      if (!_isWifi && !_allowMetered) {
        _emit();
        if (context != null && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Row(children: [
              Icon(Icons.signal_cellular_alt, color: Colors.white, size: 16),
              SizedBox(width: 8),
              Expanded(child: Text(
                'Mobile network detected — enable "Allow cellular uploads" to upload')),
            ]),
            backgroundColor: Colors.orange[700],
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Enable',
              textColor: Colors.white,
              onPressed: () async {
                await _saveMeteredPref(true);
                if (_canUpload) _processNext();
                _emit();
              },
            ),
          ));
        }
        return;
      }

      if (wasWifi == false && _isWifi) {
        debugPrint('=== Queue: WiFi reconnected — forcing WM reschedule');
        // REPLACE so upload starts immediately on new connection
        await UploadWorkManager.scheduleUploadForced();
      }

      if (_running) {
        Future.delayed(const Duration(seconds: 3), () {
          if (_running && !isUploading) {
            debugPrint('=== Queue: watchdog cleared stuck _running');
            _running = false;
          }
          if (_canUpload) _processNext();
        });
      } else {
        if (_canUpload) _processNext();
      }
      _emitNow(); // immediate — user just reconnected
    });
  }

  bool get _canUpload =>
      _hasNetwork && (_isWifi || _allowMetered) && !_globalHold;

  // ── Metered connection dialog ─────────────────────────────────────────────
  Future<void> showMeteredConnectionDialog(BuildContext context) async {
    bool toggleValue = _allowMetered;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 64, height: 64,
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.wifi, color: Colors.blue, size: 32),
              ),
              const SizedBox(height: 16),
              const Text('Metered Connection Uploads',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              const Text(
                'By default, uploads only happen on Wi-Fi. '
                'If Wi-Fi is unavailable, you can allow uploads '
                'on cellular or metered connections.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Colors.orange, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(child: Text(
                    'Video uploads can be large and may use significant data. '
                    'Standard carrier rates apply on cellular. '
                    'Enable this if uploads aren\'t starting on your Wi-Fi.',
                    style: TextStyle(fontSize: 12, color: Colors.orange),
                  )),
                ]),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Row(children: [
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Allow metered connections',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      const SizedBox(height: 2),
                      Text('Upload on cellular and metered Wi-Fi',
                          style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                    ],
                  )),
                  Switch(
                    value: toggleValue,
                    onChanged: (v) => setState(() => toggleValue = v),
                    activeThumbColor: const Color(0xFF00C853),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, toggleValue),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Done',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15)),
                ),
              ),
            ]),
          ),
        ),
      ),
    );

    if (result != null) {
      await _saveMeteredPref(result);
      if (_canUpload) _processNext();
      _emit();
    }
  }

  Future<void> approveCellular(BuildContext context) async {
    await showMeteredConnectionDialog(context);
  }

  void _updateAllQueued(String msg) {
    for (final s in _states.values) {
      if (s.status == ChunkStatus.queued) s.message = msg;
    }
  }

  // ── Stale file cleanup ────────────────────────────────────────────────────
  Future<void> cleanStaleFiles() async {
    final staleKeys = <String>[];
    for (final entry in _states.entries) {
      final s = entry.value;
      if (s.status == ChunkStatus.done) {
        final sessionAge = DateTime.now().difference(s.chunk.sessionDate);
        if (sessionAge.inDays >= _retentionDays) staleKeys.add(entry.key);
      }
    }
    for (final k in staleKeys) {
      _states.remove(k);
      _queue.removeWhere((c) => c.filePath == k);
    }
    if (staleKeys.isNotEmpty) _emit();
    debugPrint('=== cleanStaleFiles: evicted ${staleKeys.length} done entries from memory');
  }

  // ── Enqueue ───────────────────────────────────────────────────────────────
  Future<void> enqueue(PendingChunk chunk) async {
    debugPrint('=== Queue: enqueue ${chunk.cloudFileName}');
    _states[chunk.filePath] = ChunkState(chunk);
    _queue.add(chunk);

    await UploadQueueDb.instance.insertChunk({
      'chunk_id':          chunk.filePath,
      'session_id':        chunk.sessionId,
      'local_file_path':   chunk.filePath,
      'onedrive_path':     chunk.sessionFolderName,
      'file_name':         chunk.cloudFileName,
      'file_size_bytes':   File(chunk.filePath).existsSync()
                               ? File(chunk.filePath).lengthSync() : 0,
      'bytes_uploaded':    0,
      'status':            'pending',
      'retry_count':       0,
      'part_number':       chunk.partNumber,
      'start_sec':         chunk.startSec,
      'end_sec':           chunk.endSec,
      'session_date_ms':   chunk.sessionDate.millisecondsSinceEpoch,
      'session_start_ms':  chunk.sessionStartTime.millisecondsSinceEpoch,
      'user_id':           chunk.userId,
    });

    // Use KEEP policy — avoid creating duplicate WM jobs when multiple
    // chunks enqueue in rapid succession after recording stops
    await UploadWorkManager.scheduleUpload();

    _emit();
    if (_canUpload) _processNext();
  }

  // ── Main upload loop ──────────────────────────────────────────────────────
  Future<void> _processNext() async {
    if (_running) return;
    if (!_canUpload) return;
    if (_globalHold) return;

    PendingChunk? next;
    try {
      next = _queue.firstWhere(
          (c) => _states[c.filePath]?.status == ChunkStatus.queued);
    } catch (_) { return; }

    _running = true;
    try {
      // Race guard: check DB status before starting
      try {
        final rows = await UploadQueueDb.instance.db.then(
            (db) => db.query('upload_queue',
                where: 'chunk_id = ?', whereArgs: [next!.filePath], limit: 1));
        if (rows.isNotEmpty) {
          final dbStatus = rows.first['status'] as String? ?? '';
          if (dbStatus == 'done') {
            debugPrint('=== Queue: ${next.cloudFileName} already done by WorkManager — skipping');
            _states.remove(next.filePath);
            _queue.remove(next);
            _emit();
            _running = false;
            if (_canUpload) _processNext();
            return;
          }
          if (dbStatus == 'uploading') {
            debugPrint('=== Queue: ${next.cloudFileName} WM uploading — yielding');
            _running = false;
            for (var i = 0; i < 60; i++) {
              await Future.delayed(const Duration(seconds: 5));
              try {
                final fp = next?.filePath;
                if (fp == null) break;
                final r = await UploadQueueDb.instance.db.then(
                    (db) => db.query('upload_queue',
                        where: 'chunk_id = ?', whereArgs: [fp], limit: 1));
                if (r.isEmpty) break;
                final s = r.first['status'] as String? ?? '';
                if (s == 'done' || s == 'failed') break;
                if (s != 'uploading') break;
              } catch (_) { break; }
            }
            if (_canUpload) _processNext();
            return;
          }
        }
      } catch (_) {}

      final state = _states[next.filePath]!;
      state.status  = ChunkStatus.uploading;
      state.message = 'Starting...';
      _emit();

      final pendingTotal = _states.length;
      UploadForegroundService.start(
        progressText: 'Uploading Part ${next.partNumber} of ${next.sessionId}',
        chunksText:   '$pendingTotal chunk${pendingTotal == 1 ? '' : 's'} pending',
      ).ignore();

      bool uploadSuccess = false;

      for (int attempt = 0; attempt <= _maxRetries; attempt++) {
        try {
          if (attempt > 0) {
            state.message = 'Retrying ($attempt/$_maxRetries)...';
            _emit();
            await Future.delayed(const Duration(seconds: 5));
            if (!_canUpload) break;
          }

          await _uploadChunk(next, state);

          final userFolder = await UserService().getDisplayName();
          final dateFolder = DateFormat('dd-MM-yyyy').format(next.sessionDate);
          final folderPath = '$_rootFolder/$dateFolder/$userFolder/${next.sessionFolderName}';
          state.message = 'Verifying...';
          _emit();

          final verified = await _onedrive.fileExistsAndComplete(
              folderPath: folderPath, fileName: next.cloudFileName);

          if (verified) {
            uploadSuccess = true;
            break;
          } else {
            // Clear stale session so next attempt starts fresh
            await UploadQueueDb.instance.clearUploadSession(next.filePath);
            throw Exception('File not confirmed on OneDrive after upload');
          }
        } catch (e) {
          if (e is _AlreadyDone) {
            uploadSuccess = true;
            break;
          }
          debugPrint('=== Queue attempt $attempt failed: $e');
          // Clear session URL — may have expired or be invalid
          await UploadQueueDb.instance.clearUploadSession(next.filePath);
          if (attempt < _maxRetries) continue;
        }
      }

      if (uploadSuccess) {
        await UploadQueueDb.instance.markDone(next.filePath);
        // Do NOT zero speed here — carry the last measured speed forward
        // so the UI shows the real measured speed between chunks instead
        // of flashing "Starting..." every time a chunk boundary is crossed.
        // Speed window is reset only when ALL uploads finish (see below).
        _speedWindowBytes = 0; _speedWindowStart = 0; // reset window only, keep _currentSpeedBps

        final doneState = _states[next.filePath];
        if (doneState != null) {
          doneState.status   = ChunkStatus.done;
          doneState.progress = 1.0;
          doneState.message  = 'Uploaded ✓';
        }
        if (_globalHold && _states.values.every(
            (s) => s.status != ChunkStatus.failed)) {
          _globalHold = false;
        }
        _emit();

        debugPrint('=== Queue: ${next.cloudFileName} done ✓');

        bool wmAlreadyWrote = false;
        try {
          final col = FirestoreCacheService().sessionsCollection;
          if (col != null) {
            final doc = await col.doc(next.sessionId).get();
            wmAlreadyWrote = doc.exists &&
                (doc.data()?['status'] as String?) == 'synced';
          }
        } catch (_) {}

        final sessionDone = await UploadQueueDb.instance
            .isSessionFullyDone(next.sessionId)
            .timeout(const Duration(seconds: 5), onTimeout: () => false);

        if (sessionDone) {
          if (!wmAlreadyWrote) {
            debugPrint('=== Queue: session ${next.sessionId} all done → Firestore');
            await _writeChunkToFirestore(next);
          }
          final sid = next.sessionId;
          // Delete local mp4s + DB rows — prevents ghost re-enqueue on next login
          final toDelete = _states.values
              .where((s) => s.chunk.sessionId == sid)
              .toList();
          for (final s in toDelete) {
            await _deleteFiles(s.chunk);
            await UploadQueueDb.instance.deleteChunk(s.chunk.filePath);
          }
          _states.removeWhere((_, s) => s.chunk.sessionId == sid);
          _queue.removeWhere((c) => c.sessionId == sid);
          _emit();
          debugPrint('=== Queue: session $sid cleaned + cleared from Pending Uploads');
        } else {
          debugPrint('=== Queue: chunk ${next.partNumber} done — '
              'session ${next.sessionId} still has more chunks');
        }

        _running = false;
        if (_states.values.every((s) =>
            s.status == ChunkStatus.done || s.status == ChunkStatus.failed)) {
          UploadForegroundService.stop().ignore();
          // All uploads done — zero upload-based speed so probe takes over
          _currentSpeedBps = 0; _speedWindowBytes = 0; _speedWindowStart = 0;
        }
        if (_canUpload) _processNext();
        return;
      } else {
        state.status   = ChunkStatus.failed;
        state.progress = 0.0;
        state.failedAt = DateTime.now();
        state.message  = 'Failed after ${_maxRetries + 1} attempt(s)';
        _globalHold = true;

        for (final s in _states.values) {
          if (s.status == ChunkStatus.queued) {
            s.message = 'On hold — waiting for failed chunk';
          }
        }
        _emit();

        UploadForegroundService.stop().ignore();
        NotificationService().showUploadFailed(
            'Part ${next.partNumber} of ${next.sessionId} failed. '
            'Open app and tap Retry All to continue.');
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _writeChunkToFirestore(PendingChunk chunk) async {
    try {
      final userFolder = await UserService().getDisplayName();
      final dateFolder = DateFormat('dd-MM-yyyy').format(chunk.sessionDate);

      final allRows  = await UploadQueueDb.instance.db.then((db) =>
          db.query('upload_queue',
              where: 'session_id = ?', whereArgs: [chunk.sessionId]));
      final doneRows = allRows
          .where((r) => (r['status'] as String?) == 'done')
          .toList();

      if (doneRows.isEmpty) return;

      int totalSecs  = 0;
      final parts    = <int>[];
      for (final r in doneRows) {
        final s = r['start_sec'] as int? ?? 0;
        final e = r['end_sec']   as int? ?? 0;
        totalSecs += (e - s).clamp(0, 7200);
        parts.add(r['part_number'] as int? ?? 1);
      }
      parts.sort();

      final allDone = allRows.length == doneRows.length && allRows.isNotEmpty;

      final col = FirestoreCacheService().sessionsCollection;
      if (col == null) return;
      await col.doc(chunk.sessionId).set({
        'sessionId':      chunk.sessionId,
        'dateFolder':     dateFolder,
        'userFolder':     userFolder,
        'sessionFolder':  chunk.sessionFolderName,
        'sessionStartMs': chunk.sessionStartTime.millisecondsSinceEpoch,
        'chunksUploaded': doneRows.length,
        'totalSecs':      totalSecs,
        'parts':          parts,
        'status':         allDone ? 'synced' : 'uploading',
        'updatedAt':      FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      debugPrint('=== Firestore: ${chunk.sessionId} updated — '
          '${doneRows.length}/${allRows.length} chunks, '
          '${totalSecs}s, status=${allDone ? "synced" : "uploading"}');

      AttendanceAutoSync().scheduleUpdate(dateFolder);
    } catch (e, st) {
      debugPrint('=== Firestore write error (non-fatal): $e');
      debugPrint('=== Firestore write stacktrace: $st');
    }
  }

  Future<void> _uploadChunk(PendingChunk chunk, ChunkState state) async {
    final userFolder    = await UserService().getDisplayName();
    final dateFolder    = DateFormat('dd-MM-yyyy').format(chunk.sessionDate);
    final sessionFolder = chunk.sessionFolderName;
    final folderPath    = '$_rootFolder/$dateFolder/$userFolder/$sessionFolder';

    if (!chunk.hasAnyFile) {
      debugPrint('=== Queue: ${chunk.cloudFileName} file missing — checking OneDrive...');
      try {
        final alreadyOnOD = await OneDriveService().fileExistsAndComplete(
          folderPath: folderPath,
          fileName:   chunk.cloudFileName,
        ).timeout(const Duration(seconds: 15), onTimeout: () => false);
        if (alreadyOnOD) {
          debugPrint('=== Queue: ${chunk.cloudFileName} found on OneDrive — marking done (WM)');
          await UploadQueueDb.instance.markDone(chunk.filePath);
          final alreadyState = _states[chunk.filePath];
          if (alreadyState != null) {
            alreadyState.status   = ChunkStatus.done;
            alreadyState.progress = 1.0;
            alreadyState.message  = 'Done ✓';
          }
          final sessionDone2 = await UploadQueueDb.instance
              .isSessionFullyDone(chunk.sessionId)
              .timeout(const Duration(seconds: 5), onTimeout: () => false);
          if (sessionDone2) _writeChunkToFirestore(chunk).ignore();
          throw _AlreadyDone();
        }
      } catch (e) {
        if (e is _AlreadyDone) rethrow;
        debugPrint('=== Queue: OD check failed: $e');
      }
      throw _PermanentFailure('Both original and backup missing — re-record needed.');
    }

    state.message = 'Checking...';
    _emit();

    if (await _onedrive.fileExistsAndComplete(
        folderPath: folderPath, fileName: chunk.cloudFileName)) {
      debugPrint('=== Queue: already on OneDrive — skip');
      return;
    }

    state.message = 'Uploading...';
    _emit();

    // ── Expiry-aware session URL retrieval ───────────────────────────────
    // Only reuse a saved session URL if it is still valid.
    // If expired or missing, pass null — OneDriveService creates a fresh session.
    String? resumeUrl;
    final hasValid = await UploadQueueDb.instance.hasValidSession(chunk.filePath);
    if (hasValid) {
      final rows = await UploadQueueDb.instance.db.then(
          (db) => db.query('upload_queue',
              columns: ['upload_session_url'],
              where: 'chunk_id = ?',
              whereArgs: [chunk.filePath],
              limit: 1));
      if (rows.isNotEmpty) {
        resumeUrl = rows.first['upload_session_url'] as String?;
        debugPrint('=== Queue: resuming ${chunk.cloudFileName} with saved session URL');
      }
    } else {
      debugPrint('=== Queue: no valid session for ${chunk.cloudFileName} — fresh start');
    }

    await _onedrive.uploadFileInSession(
      filePath:          chunk.bestFilePath,
      fileName:          chunk.cloudFileName,
      dateFolder:        dateFolder,
      userFolder:        userFolder,
      sessionFolder:     sessionFolder,
      rootFolder:        _rootFolder,
      existingUploadUrl: resumeUrl,
      // Save new session URL + expiry to DB as soon as OneDrive returns it
      onSessionCreated: (url) async {
        final expiry = DateTime.now().add(const Duration(hours: 23));
        await UploadQueueDb.instance.saveUploadSession(chunk.filePath, url, expiry);
        debugPrint('=== Queue: saved session URL for ${chunk.cloudFileName}');
      },
      onProgress: (p) {
        state.progress = p;
        state.message  = 'Uploading ${(p * 100).toStringAsFixed(0)}%';
        try {
          final fileSize  = File(chunk.bestFilePath).lengthSync();
          final bytesNow  = (fileSize * p).round();
          final nowMs     = DateTime.now().millisecondsSinceEpoch;
          if (_speedWindowStart == 0) {
            _speedWindowStart = nowMs;
            _speedWindowBytes = bytesNow;
          } else {
            final elapsed = nowMs - _speedWindowStart;
            final deltaB  = bytesNow - _speedWindowBytes;
            if (elapsed >= 300 && deltaB > 0) {
              final bps = (deltaB / elapsed) * 1000.0;
              _currentSpeedBps = _currentSpeedBps == 0
                  ? bps : _currentSpeedBps * 0.5 + bps * 0.5;
              _speedWindowStart = nowMs;
              _speedWindowBytes = bytesNow;
            }
          }
        } catch (_) {}
        _emit();
      },
      onStatus: (s) { state.message = s; _emit(); },
    );
  }

  // ── Public controls ───────────────────────────────────────────────────────
  void retryFailed() {
    _globalHold = false;
    _running    = false;
    for (final s in _states.values) {
      if (s.status == ChunkStatus.failed) {
        if (s.chunk.hasAnyFile) {
          s.status     = ChunkStatus.queued;
          s.progress   = 0.0;
          s.message    = 'Retrying...';
          s.failedAt   = null;
          s.retryCount = 0;
        } else {
          s.status     = ChunkStatus.queued;
          s.progress   = 0.0;
          s.message    = 'Checking OneDrive...';
          s.failedAt   = null;
          s.retryCount = 0;
        }
        // Clear DB session URL on retry — may have expired during failure window
        UploadQueueDb.instance.clearUploadSession(s.chunk.filePath).ignore();
      }
      if (s.status == ChunkStatus.queued &&
          s.message == 'On hold — waiting for failed chunk') {
        s.message = 'Queued';
      }
    }
    // Also reset in SQLite so WM can pick them up
    UploadQueueDb.instance.retryAllFailed().ignore();
    _emit();
    if (_canUpload) _processNext();
  }

  void retryChunk(PendingChunk chunk) {
    final s = _states[chunk.filePath];
    if (s == null) return;
    if (!chunk.hasAnyFile) {
      s.status  = ChunkStatus.failed;
      s.message = 'File missing — re-record needed';
      _emit();
      return;
    }
    _globalHold  = false;
    _running     = false;
    s.status     = ChunkStatus.queued;
    s.progress   = 0.0;
    s.message    = 'Retrying...';
    s.retryCount = 0;
    s.failedAt   = null;
    // Clear expired session URL
    UploadQueueDb.instance.clearUploadSession(chunk.filePath).ignore();
    for (final other in _states.values) {
      if (other.status == ChunkStatus.queued &&
          other.message == 'On hold — waiting for failed chunk') {
        other.message = 'Queued';
      }
    }
    _emit();
    if (_canUpload) _processNext();
  }

  void clearCompleted() {
    _states.removeWhere((_, s) => s.status == ChunkStatus.done);
    _queue.removeWhere((c) => !_states.containsKey(c.filePath));
    _emit();
  }

  void abandonChunk(String filePath) {
    _states.remove(filePath);
    _queue.removeWhere((c) => c.filePath == filePath);
    UploadQueueDb.instance.markFailed(filePath).ignore();
    debugPrint('=== Queue: abandoned $filePath — marked failed in DB');

    if (_globalHold && _states.values.none((s) => s.status == ChunkStatus.failed)) {
      _globalHold = false;
      for (final other in _states.values) {
        if (other.message == 'On hold — waiting for failed chunk') {
          other.message = 'Queued';
        }
      }
    }
    _emit();
    if (_canUpload && !_globalHold) _processNext();
  }

  bool isSessionComplete(String sessionId) => !_states.values
      .any((s) => s.chunk.sessionId == sessionId && s.status != ChunkStatus.done);

  // ── Recovery ──────────────────────────────────────────────────────────────
  Future<void> _recoverFromPersistence() async {
    try {
      await UploadQueueDb.instance.resetStuckUploadingKeepProgress();
      final rows = await UploadQueueDb.instance.getPending();
      debugPrint('=== SQLite recovery: ${rows.length} pending chunks');

      for (final row in rows) {
        var filePath = row['local_file_path'] as String? ?? '';
        if (filePath.isEmpty) continue;
        if (_states.containsKey(filePath)) continue;

        if (!File(filePath).existsSync()) {
          final fileName = filePath.split('/').last;
          final searchPaths = [
            '/storage/emulated/0/Android/data/com.otn.videorecorder/files',
            '/storage/emulated/0/Android/media/com.otn.videorecorder/OTN/recordings',
            (await getApplicationDocumentsDirectory()).path,
          ];

          String? foundPath;
          for (final basePath in searchPaths) {
            try {
              final baseDir = Directory(basePath);
              if (!baseDir.existsSync()) continue;
              await for (final entity in baseDir.list(recursive: true)) {
                if (entity is File && entity.path.endsWith(fileName)) {
                  foundPath = entity.path;
                  break;
                }
              }
              if (foundPath != null) break;
            } catch (_) {}
          }

          if (foundPath != null) {
            debugPrint('=== SQLite recovery: found at new path $foundPath');
            await UploadQueueDb.instance.updateFilePath(
                row['chunk_id'] as String, foundPath);
            filePath = foundPath;
          } else {
            debugPrint('=== SQLite recovery: file not found anywhere — $filePath');
            await UploadQueueDb.instance.updateStatus(
                row['chunk_id'] as String, 'pending');
            final sessionDateMs2  = (row['session_date_ms']  as int? ?? 0);
            final sessionStartMs2 = (row['session_start_ms'] as int? ?? 0);
            final sessionDate2    = DateTime.fromMillisecondsSinceEpoch(sessionDateMs2);
            final sessionStart2   = DateTime.fromMillisecondsSinceEpoch(sessionStartMs2);
            final lostChunk = PendingChunk(
              filePath:         filePath,
              backupPath:       filePath,
              sessionId:        row['session_id']  as String? ?? '',
              userId:           row['user_id']     as String? ?? '',
              partNumber:       row['part_number'] as int? ?? 1,
              sessionDate:      sessionDate2,
              sessionStartTime: sessionStart2,
              sessionEndTime:   sessionStart2,
              startSec:         row['start_sec'] as int? ?? 0,
              endSec:           row['end_sec']   as int? ?? 0,
            );
            final lostCs    = ChunkState(lostChunk);
            lostCs.status   = ChunkStatus.failed;
            lostCs.progress = 0.0;
            lostCs.message  = 'File missing — will verify on next sync';
            _states[lostChunk.filePath] = lostCs;
            _queue.add(lostChunk);
            continue;
          }
        }

        final sessionDateMs  = (row['session_date_ms']  as int? ?? 0);
        final sessionStartMs = (row['session_start_ms'] as int? ?? 0);
        final sessionDate    = DateTime.fromMillisecondsSinceEpoch(sessionDateMs);
        final sessionStart   = DateTime.fromMillisecondsSinceEpoch(sessionStartMs);

        final chunk = PendingChunk(
          filePath:         filePath,
          backupPath:       await _ensureBackup(filePath),
          sessionId:        row['session_id']  as String? ?? '',
          userId:           row['user_id']     as String? ?? '',
          partNumber:       row['part_number'] as int? ?? 1,
          sessionDate:      sessionDate,
          sessionStartTime: sessionStart,
          sessionEndTime:   sessionStart,
          startSec:         row['start_sec'] as int? ?? 0,
          endSec:           row['end_sec']   as int? ?? 0,
        );

        final cs    = ChunkState(chunk);
        cs.status   = ChunkStatus.queued;
        cs.progress = 0.0;
        cs.message  = 'Recovered — queued';
        _states[chunk.filePath] = cs;
        _queue.add(chunk);
        debugPrint('=== SQLite recovery: restored ${chunk.cloudFileName}');
      }
      if (_states.isNotEmpty) _emit();
    } catch (e) {
      debugPrint('=== _recoverFromPersistence error: $e');
    }
  }

  // ── Lightweight refresh: SQLite-only, no disk scan ──────────────────────
  // Called by the history screen refresh button. Runs in ~5ms vs recoverFromCache
  // which does a full filesystem scan (can take 200-500ms on large storage).
  // Only re-adds genuinely pending rows that aren't already tracked in _states.
  // Never touches done rows — they're cleaned up by the upload completion path.
  Future<void> recoverPendingOnly() async {
    try {
      await UploadQueueDb.instance.resetStuckUploadingKeepProgress();
      final rows = await UploadQueueDb.instance.getPending();
      bool added = false;
      for (final row in rows) {
        final filePath = row['local_file_path'] as String? ?? '';
        if (filePath.isEmpty) continue;
        if (_states.containsKey(filePath)) continue;
        if (!File(filePath).existsSync()) continue; // skip missing files silently
        final dt = DateTime.fromMillisecondsSinceEpoch(row['session_date_ms']  as int? ?? 0);
        final st = DateTime.fromMillisecondsSinceEpoch(row['session_start_ms'] as int? ?? 0);
        final chunk = PendingChunk(
          filePath:         filePath,
          backupPath:       filePath,
          sessionId:        row['session_id']  as String? ?? '',
          userId:           row['user_id']     as String? ?? '',
          partNumber:       row['part_number'] as int? ?? 1,
          sessionDate:      dt,
          sessionStartTime: st,
          sessionEndTime:   st,
          startSec:         row['start_sec'] as int? ?? 0,
          endSec:           row['end_sec']   as int? ?? 0,
        );
        final cs = ChunkState(chunk)
          ..status  = ChunkStatus.queued
          ..message = 'Recovered';
        _states[filePath] = cs;
        _queue.add(chunk);
        added = true;
      }
      if (added) { _emit(); if (_canUpload) _processNext(); }
    } catch (e) { debugPrint('=== recoverPendingOnly error: $e'); }
  }

  Future<void> recoverFromCache() async {
    // Purge stale done rows first — cleans up old app versions that didn't
    // call deleteChunk() at upload time. Runs fast (indexed status + updated_at).
    await UploadQueueDb.instance.purgeDoneRows(olderThanDays: 2);

    await _recoverFromPersistence();

    final scanRoots = <String>[
      '/storage/emulated/0/Android/data/com.otn.videorecorder/files/OTN/recordings',
      '/storage/emulated/0/Android/media/com.otn.videorecorder/OTN/recordings',
      '/storage/emulated/0/Android/media/com.otn.videorecorder/OTN/otn_backup',
      '/storage/emulated/0/Android/media/com.otn.videorecorder/OTN/otn_chunks',
    ];

    final allFiles = <String, String>{};
    for (final root in scanRoots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      try {
        for (final entity in dir.listSync(recursive: true).whereType<File>()) {
          if (!entity.path.endsWith('.mp4')) continue;
          final name = entity.path.split('/').last;
          if (!allFiles.containsKey(name) ||
              entity.path.contains('Android/data')) {
            allFiles[name] = entity.path;
          }
        }
      } catch (e) {
        debugPrint('=== recoverFromCache: scan error $root: $e');
      }
    }

    debugPrint('=== recoverFromCache: found ${allFiles.length} mp4 files on disk');

    final trackedPaths = _states.values
        .map((s) => s.chunk.filePath)
        .toSet();

    final dbRows = await UploadQueueDb.instance.getAllChunks();

    // Set 1: cloud filenames in DB (for new-format orphan check)
    final dbFileNames = dbRows
        .map((r) => (r['file_name'] as String? ?? ''))
        .where((n) => n.isNotEmpty)
        .toSet();

    // Set 2: local file paths of DONE rows — these were already uploaded.
    // Local filenames differ from cloud filenames, so dbFileNames never matches
    // what's on disk. This set checks by local path and base filename instead.
    final doneLocalPaths = dbRows
        .where((r) => (r['status'] as String?) == 'done')
        .map((r) => r['local_file_path'] as String? ?? '')
        .where((p) => p.isNotEmpty)
        .toSet();
    final doneLocalNames = doneLocalPaths
        .map((p) => p.split('/').last)
        .toSet();

    final namePatternNew = RegExp(
        r'^([A-Z0-9]{6,7})_([0-9]{8})_P([0-9]{2})_S([0-9]{6})_E([0-9]{6})_([0-9]+)s\.mp4$');
    final namePatternOld = RegExp(
        r'^([A-Z0-9]{6,7})_([0-9]{8})_([0-9]{6})_([0-9]{2})([0-9]{2})-([0-9]{2})\.mp4$');
    final namePatternLocal = RegExp(
        r'^([A-Z0-9]{6,7})_([0-9]{8})_([0-9]{6})_part([0-9]{2})\.mp4$');

    int recovered = 0;
    for (final entry in allFiles.entries) {
      final name     = entry.key;
      final fullPath = entry.value;

      if (trackedPaths.contains(fullPath)) continue;  // already tracked in memory
      if (dbFileNames.contains(name))       continue;  // has a DB row (any status)
      if (doneLocalPaths.contains(fullPath)) continue;  // local path is done in DB
      if (doneLocalNames.contains(name))    continue;  // base name is done in DB

      final mNew   = namePatternNew.firstMatch(name);
      final mOld   = mNew   == null ? namePatternOld.firstMatch(name)   : null;
      final mLocal = (mNew == null && mOld == null)
                   ? namePatternLocal.firstMatch(name) : null;
      if (mNew == null && mOld == null && mLocal == null) {
        debugPrint('=== recoverFromCache: unrecognized filename $name — skip');
        continue;
      }

      final String sessionId;
      final DateTime dt, st;
      final int partNum, startSec, endSec;

      if (mLocal != null) {
        sessionId = mLocal.group(1)!;
        final ds  = mLocal.group(2)!;
        final ts  = mLocal.group(3)!;
        dt = DateTime(int.parse(ds.substring(0,4)),
            int.parse(ds.substring(4,6)), int.parse(ds.substring(6,8)));
        st = DateTime(dt.year, dt.month, dt.day,
            int.parse(ts.substring(0,2)), int.parse(ts.substring(2,4)),
            int.parse(ts.substring(4,6)));
        partNum  = int.parse(mLocal.group(4)!);
        startSec = 0;
        endSec   = 0;
      } else if (mNew != null) {
        sessionId = mNew.group(1)!;
        final ds  = mNew.group(2)!;
        dt = DateTime(int.parse(ds.substring(0,4)),
            int.parse(ds.substring(4,6)), int.parse(ds.substring(6,8)));
        final sts = mNew.group(4)!;
        st = DateTime(dt.year, dt.month, dt.day,
            int.parse(sts.substring(0,2)), int.parse(sts.substring(2,4)),
            int.parse(sts.substring(4,6)));
        partNum  = int.parse(mNew.group(3)!);
        final ets = mNew.group(5)!;
        final edt = DateTime(dt.year, dt.month, dt.day,
            int.parse(ets.substring(0,2)), int.parse(ets.substring(2,4)),
            int.parse(ets.substring(4,6)));
        startSec = 0;
        endSec   = edt.difference(st).inSeconds.abs();
      } else {
        sessionId = mOld!.group(1)!;
        final ds  = mOld.group(2)!;
        final ts  = mOld.group(3)!;
        dt = DateTime(int.parse(ds.substring(0,4)),
            int.parse(ds.substring(4,6)), int.parse(ds.substring(6,8)));
        st = DateTime(dt.year, dt.month, dt.day,
            int.parse(ts.substring(0,2)), int.parse(ts.substring(2,4)),
            int.parse(ts.substring(4,6)));
        partNum  = int.parse(mOld.group(4)!);
        startSec = int.parse(mOld.group(5)!) * 60;
        endSec   = int.parse(mOld.group(6)!) * 60;
      }

      final chunk = PendingChunk(
        filePath:         fullPath,
        backupPath:       fullPath,
        sessionId:        sessionId,
        userId:           '',
        partNumber:       partNum,
        sessionDate:      dt,
        sessionStartTime: st,
        sessionEndTime:   st,
        startSec:         startSec,
        endSec:           endSec,
      );

      await UploadQueueDb.instance.insertChunk({
        'chunk_id':          fullPath,
        'local_file_path':   fullPath,
        'file_name':         name,
        'session_id':        sessionId,
        'user_id':           '',
        'part_number':       partNum,
        'session_date_ms':   dt.millisecondsSinceEpoch,
        'session_start_ms':  st.millisecondsSinceEpoch,
        'start_sec':         startSec,
        'end_sec':           endSec,
        'onedrive_path':     chunk.sessionFolderName,
        'status':            'pending',
        'retry_count':       0,
        'bytes_uploaded':    0,
      });

      _states[fullPath] = ChunkState(chunk);
      _queue.add(chunk);
      recovered++;
      debugPrint('=== recoverFromCache: rescued $name from $fullPath');
    }

    debugPrint('=== recoverFromCache: rescued $recovered orphaned chunks');
    if (_states.isNotEmpty) {
      _emit();
      if (_canUpload) _processNext();
    }
  }

  void setMeteredAllowed(bool value) {
    _allowMetered = value;
    _emit();
    if (_canUpload) _processNext();
  }
}

// ── Extension helper ──────────────────────────────────────────────────────────
extension _IterableExt<T> on Iterable<T> {
  bool none(bool Function(T) test) => !any(test);
}