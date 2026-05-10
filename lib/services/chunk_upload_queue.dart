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
  String?        lastUploadUrl;

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
    this.lastUploadUrl,
  });

  int get durationSecs => (endSec - startSec).clamp(0, 7200);
  int get startMin     => startSec ~/ 60;
  int get endMin       => (endSec + 59) ~/ 60;

  String get cloudFileName {
    final n        = partNumber.toString().padLeft(2, '0');
    final date     = DateFormat('yyyyMMdd').format(sessionDate);
    // Chunk actual start/end as absolute timestamps
    final chunkStart = sessionStartTime.add(Duration(seconds: startSec));
    final chunkEnd   = sessionStartTime.add(Duration(seconds: endSec));
    final sFmt = DateFormat('HHmmss').format(chunkStart);
    final eFmt = DateFormat('HHmmss').format(chunkEnd);
    final dur  = (endSec - startSec).clamp(0, 7200);
    // Format: SESSIONID_YYYYMMDD_PNN_SHHMMSS_EHHMMSS_DURs.mp4
    // e.g.    AOO7BQ_20260508_P01_S103045_E103210_165s.mp4
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
  int         retryCount; // Issue 1: track retries
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
/// Signals caller to skip its own Firestore write — prevents double-write.
class _AlreadyDone implements Exception {}

// ─── ChunkUploadQueue ─────────────────────────────────────────────────────────
class ChunkUploadQueue {
  static final ChunkUploadQueue _i = ChunkUploadQueue._();
  factory ChunkUploadQueue() => _i;
  ChunkUploadQueue._();

  static const _rootFolder    = 'OTN Recorder';
  static const _wifiPrefKey   = 'upload_wifi_only';
  static const _meteredPrefKey = 'upload_allow_metered';
  static const _backupDirName  = 'otn_backup';
  static const _chunkDirName   = 'otn_upload_chunks';
  static const _retentionDays  = 7;
  static const _maxRetries     = 1; // Issue 1: retry once, then hold ALL

  final _onedrive = OneDriveService();
  final _states   = <String, ChunkState>{};
  final _queue    = <PendingChunk>[];

  bool _running       = false;
  bool _hasNetwork    = true;
  bool _isWifi        = true;
  bool _cellularOk    = false;
  bool _wifiPreferred = true;
  bool _allowMetered  = false;

  // Real-time upload speed tracking
  int    _speedWindowBytes = 0;   // bytes sent in current 1s window
  int    _speedWindowStart = 0;  // window start timestamp (ms)
  double _currentSpeedBps  = 0; // smoothed speed in bytes/sec

  // Issue 1: global hold — when true, ALL uploads stop until user taps Retry
  bool _globalHold    = false;

  final _ctrl = StreamController<List<ChunkState>>.broadcast();
  Stream<List<ChunkState>> get stream => _ctrl.stream;

  List<ChunkState> get current => _states.values
      .where((s) => s.status != ChunkStatus.done).toList()
      ..sort((a, b) {
        final sid = a.chunk.sessionId.compareTo(b.chunk.sessionId);
        return sid != 0 ? sid : a.chunk.partNumber.compareTo(b.chunk.partNumber);
      });

  List<ChunkState> get all => _states.values.toList();
  Timer? _persistDebounce;

  void _emit() {
    _ctrl.add(current);
    _persistDebounced();
    _updateForegroundService(); // update notification with latest state
  }

  /// Sync WorkManager upload progress from SQLite into UI state every 2s.
  /// WorkManager runs in a separate isolate — this bridges the gap.
  Future<void> _syncProgressFromDb() async {
    if (_states.isEmpty) return;
    try {
      // Check ALL queue rows (including done) so we can clean up WM-finished chunks
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
          debugPrint('=== Queue: DB sync: ${state.chunk.cloudFileName} done by WM');
          // Mark as done in UI — keep tile visible until whole session finishes
          state.status   = ChunkStatus.done;
          state.progress = 1.0;
          state.message  = 'Done ✓';
          // File kept — no auto-delete
          // Only write Firestore + clear session UI when ALL chunks are done
          final sessionDone = await UploadQueueDb.instance
              .isSessionFullyDone(state.chunk.sessionId)
              .timeout(const Duration(seconds: 5), onTimeout: () => false);
          if (sessionDone) {
            debugPrint('=== Queue: session ${state.chunk.sessionId} fully done (WM sync)');
            _writeChunkToFirestore(state.chunk).ignore();
            // Remove all chunks of this session from UI at once
            final sid = state.chunk.sessionId;
            _states.removeWhere((_, s) => s.chunk.sessionId == sid);
            _queue.removeWhere((c) => c.sessionId == sid);
          }
          changed = true;
        } else if (dbStatus == 'uploading' && bytesUp > 0 && fileSize > 0) {
          // WorkManager actively uploading — show live progress in UI
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

  void _persistDebounced() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(seconds: 2), _persistToDisk);
  }

  void _persistToDisk() {
    // SQLite is updated in-place per operation — nothing to batch write here.
    // This is kept as a no-op so call sites don't need to change.
  }

  // ── Metrics ──────────────────────────────────────────────────────────────
  int  get pendingCount   => _states.values.where((s) => s.status == ChunkStatus.queued).length;
  int  get uploadingCount => _states.values.where((s) => s.status == ChunkStatus.uploading).length;
  int  get failedCount    => _states.values.where((s) => s.status == ChunkStatus.failed).length;
  bool get isUploading    => _states.values.any((s) => s.status == ChunkStatus.uploading);
  bool get isWifi         => _isWifi;
  bool get isGlobalHold   => _globalHold;

  /// Session IDs currently in the pending/uploading queue — used to hide from Uploaded Sessions
  Set<String> get pendingSessionIds =>
      _states.values.map((s) => s.chunk.sessionId).toSet();

  /// Live upload speed in KB/s or MB/s (bytes-based, accurate)
  String get uploadSpeedLabel {
    // Show speed if actively uploading in main queue
    if (isUploading) {
      if (_currentSpeedBps <= 0) return 'Starting...';
      if (_currentSpeedBps >= 1024 * 1024) {
        return '${(_currentSpeedBps / 1024 / 1024).toStringAsFixed(1)} MB/s';
      }
      if (_currentSpeedBps >= 1024) {
        return '${(_currentSpeedBps / 1024).toStringAsFixed(0)} KB/s';
      }
      return '${_currentSpeedBps.toStringAsFixed(0)} B/s';
    }
    // _running = true but no state marked uploading = WM running in background
    if (_running) return 'Uploading...';
    return 'Idle';
  }
  int  get pendingSecs    => _states.values
      .where((s) => s.status != ChunkStatus.done)
      .fold(0, (sum, s) {
        if (s.status == ChunkStatus.uploading) {
          // For uploading chunks, subtract already-uploaded portion
          final remaining = (s.chunk.durationSecs * (1.0 - s.progress)).round();
          return sum + remaining;
        }
        return sum + s.chunk.durationSecs;
      });

  /// Number of unique sessions with any pending/uploading/failed chunks.
  int get pendingSessionCount => _states.values
      .where((s) => s.status != ChunkStatus.done)
      .map((s) => s.chunk.sessionId)
      .toSet()
      .length;

  /// Total seconds actively uploading right now (for real-time progress).
  int get uploadingProgressSecs => _states.values
      .where((s) => s.status == ChunkStatus.uploading)
      .fold(0, (sum, s) =>
          sum + (s.chunk.durationSecs * s.progress.clamp(0.0, 1.0)).round());

  // ── Session grouping for Issue 3 ─────────────────────────────────────────
  /// Groups current non-done chunks by sessionId, sorted by session then part.
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

  // ── Backup helpers ────────────────────────────────────────────────────────
  // CRITICAL: Use Android/media persistent path — NOT getTemporaryDirectory().
  // Temp/cache is wiped by Android overnight or on low storage.
  // Android/media/<pkg>/ is persistent and survives until app uninstall.
  static const _persistentBase = '/storage/emulated/0/Android/media/com.otn.videorecorder/OTN';

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

  static Future<String> _ensureBackup(String filePath) async {
    // The structured backup path IS the file path — camera_screen already
    // moved the chunk to the structured folder before enqueue.
    // This method is kept for recovery path compatibility only.
    return filePath;
  }

  // ── Verified delete — only removes local file after OneDrive confirms ─────
  // Called after fileExistsAndComplete() returns true.
  static Future<void> _deleteFiles(PendingChunk chunk) async {
    // filePath and backupPath are the same structured path — delete once
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
        // Non-fatal: file stays as backup, user can manually remove
      }
    }
  }

  // ── Prefs ─────────────────────────────────────────────────────────────────
  Future<void> _loadPrefs() async {
    final prefs    = await SharedPreferences.getInstance();
    _wifiPreferred = prefs.getBool(_wifiPrefKey) ?? true;
    _allowMetered  = prefs.getBool(_meteredPrefKey) ?? false;
    // Fix: after loading prefs, attempt upload if conditions now met
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

  // ── Network monitor ───────────────────────────────────────────────────────
  void startNetworkMonitor({BuildContext? context}) {
    _loadPrefs(); // async — prefs available shortly after
    // Poll SQLite every 2s to sync WorkManager upload progress into UI
    // WorkManager runs in a separate isolate — progress only visible via DB
    Timer.periodic(const Duration(seconds: 2), (_) => _syncProgressFromDb());
    Connectivity().onConnectivityChanged.listen((results) async {
      final wasWifi = _isWifi;
      final result  = results.isNotEmpty ? results.first : ConnectivityResult.none;
      _isWifi     = result == ConnectivityResult.wifi || result == ConnectivityResult.ethernet;
      _hasNetwork = result != ConnectivityResult.none;

      if (!_hasNetwork) {
        // Network lost — pause and notify user
        _updateAllQueued('Waiting for network...');
        _emit();
        return;
      }

      // Network came back — show alert if on cellular and toggle is off
      if (!_isWifi && !_allowMetered) {
        // Show snackbar alert — do NOT auto-upload on cellular without consent
        _emit(); // update UI to show network state
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
        return; // Do NOT start upload — wait for user to enable toggle
      }

      // WiFi connected or cellular is allowed — resume/start uploads
      if (wasWifi == false && _isWifi) {
        debugPrint('=== Queue: WiFi reconnected — resuming uploads');
      }
      // Watchdog: if _running is stuck (upload threw before finally ran),
      // give it 3s then force-clear so uploads can resume
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
      _emit();
    });
  }

  bool get _canUpload =>
      _hasNetwork && (_isWifi || _allowMetered) && !_globalHold;

  // ── Issue 1: Metered Connection Dialog (matches screenshot style) ──────────
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
              // Wi-Fi icon in blue circle
              Container(
                width: 64, height: 64,
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.wifi, color: Colors.blue, size: 32),
              ),
              const SizedBox(height: 16),

              // Title
              const Text('Metered Connection Uploads',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),

              // Description
              const Text(
                'By default, uploads only happen on Wi-Fi. '
                'If Wi-Fi is unavailable, you can allow uploads '
                'on cellular or metered connections.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 16),

              // Warning box
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

              // Toggle row
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Row(children: [
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Allow metered connections',
                          style: TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14)),
                      const SizedBox(height: 2),
                      Text('Upload on cellular and metered Wi-Fi',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey[600])),
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

              // Done button
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
      // result ignored — use toggle
      if (_canUpload) _processNext();
      _emit();
    }
  }

  // Called from history_screen "No Wi-Fi" tap
  Future<void> approveCellular(BuildContext context) async {
    await showMeteredConnectionDialog(context);
  }

  void _updateAllQueued(String msg) {
    for (final s in _states.values) {
      if (s.status == ChunkStatus.queued) s.message = msg;
    }
  }

  // ── Stale file cleanup — NEVER deletes failed chunks ─────────────────────
  // Failed chunks stay on disk permanently as manual recovery backups.
  // The user can copy them via Files app if upload never completes.
  // Only removes done queue entries from memory — file itself was already
  // deleted by _deleteFiles() right after OneDrive confirmation.
  Future<void> cleanStaleFiles() async {
    final staleKeys = <String>[];

    for (final entry in _states.entries) {
      final s = entry.value;
      // Only evict DONE entries from memory after retention window.
      // FAILED entries stay in queue so user can see them and retry.
      // Done entries have no timestamp — evict from memory after retention window
      // using chunk enqueue time approximated by sessionDate.
      // File is already deleted from disk at this point (deleted on OD confirm).
      if (s.status == ChunkStatus.done) {
        final sessionAge = DateTime.now().difference(s.chunk.sessionDate);
        if (sessionAge.inDays >= _retentionDays) staleKeys.add(entry.key);
      }
    }

    for (final k in staleKeys) {
      // Done entries: file already deleted after OneDrive confirm.
      // Just evict from in-memory queue.
      _states.remove(k);
      _queue.removeWhere((c) => c.filePath == k);
    }
    if (staleKeys.isNotEmpty) _emit();

    // Do NOT scan or delete from the structured backup folder.
    // That folder is the user's manual recovery backup.
    // Files there are ONLY deleted via _deleteFiles() after OneDrive confirms.
    debugPrint('=== cleanStaleFiles: evicted ${staleKeys.length} done entries from memory');
  }

  // ── Enqueue ───────────────────────────────────────────────────────────────
  Future<void> enqueue(PendingChunk chunk) async {
    debugPrint('=== Queue: enqueue ${chunk.cloudFileName}');
    if (!File(chunk.backupPath).existsSync()) {
      await _ensureBackup(chunk.filePath);
    }
    _states[chunk.filePath] = ChunkState(chunk);
    _queue.add(chunk);

    // Write to SQLite immediately — survives app kill
    await UploadQueueDb.instance.insertChunk({
      'chunk_id':          chunk.filePath, // unique per chunk
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

    // Schedule WorkManager job — Android manages it even if app dies
    await UploadWorkManager.scheduleUpload();

    _emit();
    if (_canUpload) _processNext();
  }

  // ── Issue 1: Process — retry once, then global hold ───────────────────────
  Future<void> _processNext() async {
    if (_running) return;
    if (!_canUpload) return;
    if (_globalHold) return;

    // Only pick genuinely queued chunks (not failed — those need user action)
    PendingChunk? next;
    try {
      next = _queue.firstWhere(
          (c) => _states[c.filePath]?.status == ChunkStatus.queued);
    } catch (_) { return; }

    _running = true;
    // Fix: always wrap in try/finally so _running is ALWAYS cleared,
    // even if an unexpected exception escapes the inner catch blocks
    try {
    // Race guard: check SQLite status before starting upload.
    // WorkManager may already be uploading or have finished this chunk.
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
          // WorkManager is actively uploading — yield and keep polling until done
          debugPrint('=== Queue: ${next.cloudFileName} WM uploading — waiting for WM to finish');
          _running = false;
          // Poll every 5s until WM finishes (status changes from 'uploading')
          for (var i = 0; i < 60; i++) { // max 5 minutes wait
            await Future.delayed(const Duration(seconds: 5));
            try {
              final fp = next?.filePath;
              if (fp == null) break;
              final r = await UploadQueueDb.instance.db.then(
                  (db) => db.query('upload_queue',
                      where: 'chunk_id = ?', whereArgs: [fp], limit: 1));
              if (r.isEmpty) break; // row gone = done
              final s = r.first['status'] as String? ?? '';
              if (s == 'done' || s == 'failed') break; // WM finished
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
    // Start foreground service so upload continues in background
    final pendingTotal = _states.length;
    UploadForegroundService.start(
      progressText: 'Uploading Part ${next.partNumber} of ${next.sessionId}',
      chunksText:   '$pendingTotal chunk${pendingTotal == 1 ? '' : 's'} pending',
    ).ignore();

    bool uploadSuccess = false;

    // ── Issue 1: attempt up to (1 + _maxRetries) times ─────────────────────
    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        if (attempt > 0) {
          state.message = 'Retrying ($attempt/$_maxRetries)...';
          _emit();
          await Future.delayed(const Duration(seconds: 5));
          if (!_canUpload) break; // network may have died during delay
        }

        await _uploadChunk(next, state);

        // Verify on OneDrive
        final userFolder = await UserService().getDisplayName();
        final dateFolder = DateFormat('dd-MM-yyyy').format(next.sessionDate);
        final folderPath = '$_rootFolder/$dateFolder/$userFolder/${next.sessionFolderName}';
        state.message = 'Verifying...';
        _emit();

        final verified = await _onedrive.fileExistsAndComplete(
            folderPath: folderPath, fileName: next.cloudFileName);

        if (verified) {
          uploadSuccess = true;
          break; // success — exit retry loop
        } else {
          // Not on OneDrive yet — treat as soft failure
          next.lastUploadUrl = null;
          throw Exception('File not confirmed on OneDrive after upload');
        }
      } catch (e) {
        if (e is _AlreadyDone) {
          // WorkManager already handled this — skip Firestore write, treat as success
          uploadSuccess = true;
          break;
        }
        debugPrint('=== Queue attempt $attempt failed: $e');
        next.lastUploadUrl = null; // always clear stale URL
        if (attempt < _maxRetries) {
          // Will retry — continue loop
          continue;
        }
        // Exhausted retries — fall through to failure handling
      }
    }

    if (uploadSuccess) {
      // Mark SQLite done
      await UploadQueueDb.instance.markDone(next.filePath);
      _currentSpeedBps = 0; _speedWindowBytes = 0; _speedWindowStart = 0;

      // ── KEEP chunk in _states as done — tile stays visible with ✓ ──────
      // Only remove when the WHOLE session is confirmed done.
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
      _emit(); // re-render — chunk tile turns green with ✓

      debugPrint('=== Queue: ${next.cloudFileName} done ✓');

      // Check if WM already wrote Firestore for this session
      bool wmAlreadyWrote = false;
      try {
        final col = FirestoreCacheService().sessionsCollection;
        if (col != null) {
          final doc = await col.doc(next.sessionId).get();
          wmAlreadyWrote = doc.exists &&
              (doc.data()?['status'] as String?) == 'synced';
        }
      } catch (_) {}

      // Session-wise: check if ALL chunks are now done
      final sessionDone = await UploadQueueDb.instance
          .isSessionFullyDone(next.sessionId)
          .timeout(const Duration(seconds: 5), onTimeout: () => false);

      if (sessionDone) {
        // Write Firestore once — this makes session appear in Uploaded Sessions
        if (!wmAlreadyWrote) {
          debugPrint('=== Queue: session ${next.sessionId} all done → Firestore');
          await _writeChunkToFirestore(next);
        }
        // NOW remove ALL chunks of this session from UI
        final sid = next.sessionId;
        _states.removeWhere((_, s) => s.chunk.sessionId == sid);
        _queue.removeWhere((c) => c.sessionId == sid);
        _emit(); // session disappears from Pending, appears in Uploaded
        debugPrint('=== Queue: session $sid cleared from Pending Uploads');
      } else {
        debugPrint('=== Queue: chunk ${next.partNumber} done — '
            'session ${next.sessionId} still has more chunks');
      }

      _running = false;
      if (_states.values.every((s) =>
          s.status == ChunkStatus.done || s.status == ChunkStatus.failed)) {
        UploadForegroundService.stop().ignore();
      }
      if (_canUpload) _processNext();
      return;

    } else {
      // ── Issue 1: Failure after retries — GLOBAL HOLD ─────────────────
      // All other chunks stop. User must tap Retry All.
      state.status   = ChunkStatus.failed;
      state.progress = 0.0;
      state.failedAt = DateTime.now();
      state.message  = 'Failed after ${_maxRetries + 1} attempt(s)';
      _globalHold = true; // STOP everything

      // Mark all other queued chunks as "on hold"
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

      // _running cleared in finally
    }
    } finally {
      // Fix: ALWAYS clear _running, no matter what happens
      _running = false;
    }
  }

  Future<void> _writeChunkToFirestore(PendingChunk chunk) async {
    try {
      final userFolder = await UserService().getDisplayName();
      final dateFolder = DateFormat('dd-MM-yyyy').format(chunk.sessionDate);

      // Count only rows with status='done' in SQLite for accurate totals.
      // Failed/pending chunks are NOT counted — they may retry and upload later.
      final allRows  = await UploadQueueDb.instance.db.then((db) =>
          db.query('upload_queue',
              where: 'session_id = ?', whereArgs: [chunk.sessionId]));
      final doneRows = allRows
          .where((r) => (r['status'] as String?) == 'done')
          .toList();

      if (doneRows.isEmpty) return; // nothing to write yet

      int totalSecs  = 0;
      final parts    = <int>[];
      for (final r in doneRows) {
        final s = r['start_sec'] as int? ?? 0;
        final e = r['end_sec']   as int? ?? 0;
        totalSecs += (e - s).clamp(0, 7200);
        parts.add(r['part_number'] as int? ?? 1);
      }
      parts.sort();

      // Check if ALL chunks of this session are done
      final allDone = allRows.length == doneRows.length &&
          allRows.isNotEmpty;

      // Use merge:true so we only update the fields we know —
      // avoids overwriting data from a concurrent WM write
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
        // 'uploading' = some chunks still pending; 'synced' = all done
        'status':         allDone ? 'synced' : 'uploading',
        'updatedAt':      FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      debugPrint('=== Firestore: \${chunk.sessionId} updated — '
          '\${doneRows.length}/\${allRows.length} chunks, '
          '\${totalSecs}s, status=\${allDone ? "synced" : "uploading"}');

      AttendanceAutoSync().scheduleUpdate(dateFolder);
    } catch (e, st) {
      debugPrint('=== Firestore write error (non-fatal): \$e');
      debugPrint('=== Firestore write stacktrace: \$st');
    }
  }

  Future<void> _uploadChunk(PendingChunk chunk, ChunkState state) async {
    final userFolder    = await UserService().getDisplayName();
    final dateFolder    = DateFormat('dd-MM-yyyy').format(chunk.sessionDate);
    final sessionFolder = chunk.sessionFolderName;
    final folderPath    = '$_rootFolder/$dateFolder/$userFolder/$sessionFolder';

    if (!chunk.hasAnyFile) {
      // File missing locally — but WorkManager may have already uploaded it.
      // Check OneDrive before declaring permanent failure.
      debugPrint('=== Queue: ${chunk.cloudFileName} file missing — checking OneDrive...');
      try {
        final alreadyOnOD = await OneDriveService().fileExistsAndComplete(
          folderPath: folderPath,
          fileName:   chunk.cloudFileName,
        ).timeout(const Duration(seconds: 15), onTimeout: () => false);
        if (alreadyOnOD) {
          // WorkManager uploaded it — write Firestore once then throw special
          // exception so caller skips its own _writeChunkToFirestore call
          debugPrint('=== Queue: ${chunk.cloudFileName} found on OneDrive — marking done (WM)');
          await UploadQueueDb.instance.markDone(chunk.filePath);
          // Keep chunk tile as done (green ✓), only clear session when all done
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
        if (e is _AlreadyDone) rethrow; // must propagate up to processNext
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

    await _onedrive.uploadFileInSession(
      filePath:          chunk.bestFilePath,
      fileName:          chunk.cloudFileName,
      dateFolder:        dateFolder,
      userFolder:        userFolder,
      sessionFolder:     sessionFolder,
      rootFolder:        _rootFolder,
      existingUploadUrl: chunk.lastUploadUrl,
      onProgress: (p) {
        state.progress = p;
        state.message  = 'Uploading ${(p * 100).toStringAsFixed(0)}%';
        // 1-second windowed speed measurement
        // onProgress fires per 256KB slice — accumulate bytes in 1s buckets
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
            if (elapsed >= 300 && deltaB > 0) { // 300ms window
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

  /// Issue 1: Manual retry — clears global hold, re-queues ALL failed chunks
  void retryFailed() {
    _globalHold = false; // release the hold
    _running    = false; // Fix: force-clear stuck _running from previous attempt
    for (final s in _states.values) {
      if (s.status == ChunkStatus.failed) {
        if (s.chunk.hasAnyFile) {
          s.status     = ChunkStatus.queued;
          s.progress   = 0.0;
          s.message    = 'Retrying...';
          s.failedAt   = null;
          s.retryCount = 0;
          s.chunk.lastUploadUrl = null;
        } else {
          // File missing — WorkManager may have already uploaded.
          // _uploadChunk will verify OneDrive before declaring permanent failure.
          // Re-queue it so _uploadChunk can do the OD check.
          s.status     = ChunkStatus.queued;
          s.progress   = 0.0;
          s.message    = 'Checking OneDrive...';
          s.failedAt   = null;
          s.retryCount = 0;
        }
      }
      // Also unblock chunks that were on hold
      if (s.status == ChunkStatus.queued &&
          s.message == 'On hold — waiting for failed chunk') {
        s.message = 'Queued';
      }
    }
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
    // Single chunk retry also releases global hold
    _globalHold           = false;
    _running              = false; // Fix: force-clear stuck _running
    s.status              = ChunkStatus.queued;
    s.progress            = 0.0;
    s.message             = 'Retrying...';
    s.retryCount          = 0;
    s.failedAt            = null;
    chunk.lastUploadUrl   = null;
    // Unblock other held chunks
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

  // ── abandonChunk — removes from queue but KEEPS local file ─────────────
  // The structured backup file is kept on disk for manual recovery.
  // User can copy it via Files app. File is not deleted here.
  void abandonChunk(String filePath) {
    // Remove from in-memory queue
    _states.remove(filePath);
    _queue.removeWhere((c) => c.filePath == filePath);

    // CRITICAL: Mark as failed in SQLite so it doesn't reappear on app restart
    // Without this, _recoverFromPersistence loads it back on next launch
    UploadQueueDb.instance.markFailed(filePath).ignore();
    debugPrint('=== Queue: abandoned $filePath — marked failed in DB');

    // If we just deleted the failed chunk, release hold so others can proceed
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
  // ── Recovery from SQLite (replaces JSON persistence) ─────────────────────
  Future<void> _recoverFromPersistence() async {
    try {
      await UploadQueueDb.instance.resetStuckUploadingKeepProgress();
      final rows = await UploadQueueDb.instance.getPending();
      debugPrint('=== SQLite recovery: ${rows.length} pending chunks');

      for (final row in rows) {
        var filePath = row['local_file_path'] as String? ?? '';
        if (filePath.isEmpty) continue;
        if (_states.containsKey(filePath)) continue;

        // If primary path is missing, search alternate storage locations
        if (!File(filePath).existsSync()) {
          final fileName = filePath.split('/').last;
          // Search all known base paths for this file
          final searchPaths = [
            // Android/data path
            '/storage/emulated/0/Android/data/com.otn.videorecorder/files',
            // Android/media path
            '/storage/emulated/0/Android/media/com.otn.videorecorder/OTN/recordings',
            // App documents
            (await getApplicationDocumentsDirectory()).path,
          ];

          String? foundPath;
          for (final basePath in searchPaths) {
            // Walk directories looking for this filename
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
            // Update DB with correct path
            await UploadQueueDb.instance.updateFilePath(
                row['chunk_id'] as String, foundPath);
            filePath = foundPath;
          } else {
            debugPrint('=== SQLite recovery: file not found anywhere — $filePath');
            // File missing locally — check OneDrive before giving up
            // WorkManager will handle OD check on next run
            // Keep as pending so WM can verify and mark done if on OD
            await UploadQueueDb.instance.updateStatus(
                row['chunk_id'] as String, 'pending');
            // Add to UI as 'missing file' state for visibility
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

  Future<void> recoverFromCache() async {
    // Step 1: Restore from SQLite (most reliable — survives app clear)
    await _recoverFromPersistence();

    // Step 2: Scan ALL local recording directories for orphaned mp4 files
    // that are NOT in SQLite (e.g. recorded offline then app was force-closed
    // before enqueue completed, or DB was corrupted).
    //
    // Scans the ACTUAL backup location used by camera_screen:
    //   Android/data/<pkg>/files/OTN/recordings/DD-MM-YYYY/user/sessionFolder/
    // Also scans legacy paths for backward compat.
    final scanRoots = <String>[
      '/storage/emulated/0/Android/data/com.otn.videorecorder/files/OTN/recordings',
      '/storage/emulated/0/Android/media/com.otn.videorecorder/OTN/recordings',
      '/storage/emulated/0/Android/media/com.otn.videorecorder/OTN/otn_backup',
      '/storage/emulated/0/Android/media/com.otn.videorecorder/OTN/otn_chunks',
    ];

    // Collect all mp4 files across all roots, keyed by filename
    final allFiles = <String, String>{}; // filename → full path
    for (final root in scanRoots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      try {
        for (final entity in dir.listSync(recursive: true).whereType<File>()) {
          if (!entity.path.endsWith('.mp4')) continue;
          final name = entity.path.split('/').last;
          // Prefer Android/data path over legacy paths
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

    // Build set of filenames already tracked in memory (from Step 1)
    final trackedNames = _states.values
        .map((s) => s.chunk.cloudFileName)
        .toSet();

    // Also build set of filenames already in SQLite (any status) to avoid
    // creating duplicate entries for chunks already tracked but not yet recovered
    final dbRows    = await UploadQueueDb.instance.getAllChunks();
    final dbFileNames = dbRows
        .map((r) => (r['file_name'] as String? ?? ''))
        .where((n) => n.isNotEmpty)
        .toSet();

    // Filename parsers — support both formats
    // Cloud filename NEW: SESSIONID_DATE_PNN_SHHMMSS_EHHMMSS_DURs.mp4
    final namePatternNew = RegExp(
        r'^([A-Z0-9]{6,7})_([0-9]{8})_P([0-9]{2})_S([0-9]{6})_E([0-9]{6})_([0-9]+)s\.mp4\$');
    // Cloud filename OLD: SESSIONID_DATE_TIME_NNMM-MM.mp4
    final namePatternOld = RegExp(
        r'^([A-Z0-9]{6,7})_([0-9]{8})_([0-9]{6})_([0-9]{2})([0-9]{2})-([0-9]{2})\.mp4\$');
    // LOCAL backup filename: SESSIONID_DATE_TIME_partNN.mp4 (generated by camera_screen)
    final namePatternLocal = RegExp(
        r'^([A-Z0-9]{6,7})_([0-9]{8})_([0-9]{6})_part([0-9]{2})\.mp4\$');

    int recovered = 0;
    for (final entry in allFiles.entries) {
      final name     = entry.key;
      final fullPath = entry.value;

      // Skip if already tracked in memory or in SQLite
      if (trackedNames.contains(name)) continue;
      if (dbFileNames.contains(name))  continue;

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
        // Local backup: SESSIONID_DATE_TIME_partNN.mp4
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
        endSec   = 0; // unknown from filename — will use DB startSec/endSec if in DB
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
        backupPath:       fullPath, // already in structured backup location
        sessionId:        sessionId,
        userId:           '',
        partNumber:       partNum,
        sessionDate:      dt,
        sessionStartTime: st,
        sessionEndTime:   st,
        startSec:         startSec,
        endSec:           endSec,
      );

      // Add to SQLite so it persists across future app clears
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
        'onedrive_path':     '${sessionId}_${mNew != null ? mNew.group(2)! : mOld!.group(2)!}_${st.hour.toString().padLeft(2,'0')}${st.minute.toString().padLeft(2,'0')}${st.second.toString().padLeft(2,'0')}',
        'status':            'pending',
        'retry_count':       0,
        'bytes_uploaded':    0,
        'upload_session_url': null,
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

  /// Called from history_screen when the persistent toggle changes
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