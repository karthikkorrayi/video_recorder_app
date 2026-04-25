import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'onedrive_service.dart';
import 'notification_service.dart';
import 'user_service.dart';
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
    final n    = partNumber.toString().padLeft(2,'0');
    final date = DateFormat('yyyyMMdd').format(sessionDate);
    final time = DateFormat('HHmmss').format(sessionStartTime);
    return '${sessionId}_${date}_${time}_${n}_'
        '${startMin.toString().padLeft(2,'0')}-${endMin.toString().padLeft(2,'0')}.mp4';
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
  bool _allowMetered  = false; // Issue 1: persisted metered toggle

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
  void _emit() => _ctrl.add(current);

  // ── Metrics ──────────────────────────────────────────────────────────────
  int  get pendingCount   => _states.values.where((s) => s.status == ChunkStatus.queued).length;
  int  get uploadingCount => _states.values.where((s) => s.status == ChunkStatus.uploading).length;
  int  get failedCount    => _states.values.where((s) => s.status == ChunkStatus.failed).length;
  bool get isUploading    => _states.values.any((s) => s.status == ChunkStatus.uploading);
  bool get isWifi         => _isWifi;
  bool get isGlobalHold   => _globalHold;
  int  get pendingSecs    => _states.values
      .where((s) => s.status == ChunkStatus.queued || s.status == ChunkStatus.failed)
      .fold(0, (sum, s) => sum + s.chunk.durationSecs);

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
  static Future<Directory> _backupDir() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/$_backupDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> _chunksDir() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/$_chunkDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<String> _ensureBackup(String filePath) async {
    final bdir       = await _backupDir();
    final fileName   = filePath.split('/').last;
    final backupPath = '${bdir.path}/$fileName';
    final backup     = File(backupPath);
    if (!await backup.exists()) {
      final original = File(filePath);
      if (await original.exists()) {
        await original.copy(backupPath);
        debugPrint('=== Backup created: $backupPath');
      }
    }
    return backupPath;
  }

  static Future<void> _deleteFiles(PendingChunk chunk) async {
    for (final path in [chunk.filePath, chunk.backupPath]) {
      try { await File(path).delete(); } catch (_) {}
    }
  }

  // ── Prefs ─────────────────────────────────────────────────────────────────
  Future<void> _loadPrefs() async {
    final prefs    = await SharedPreferences.getInstance();
    _wifiPreferred = prefs.getBool(_wifiPrefKey) ?? true;
    _allowMetered  = prefs.getBool(_meteredPrefKey) ?? false;
  }

  Future<void> _saveMeteredPref(bool value) async {
    _allowMetered = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_meteredPrefKey, value);
  }

  // ── Network monitor ───────────────────────────────────────────────────────
  void startNetworkMonitor({BuildContext? context}) {
    _loadPrefs();
    Connectivity().onConnectivityChanged.listen((results) async {
      final wasWifi = _isWifi;
      final result  = results.isNotEmpty ? results.first : ConnectivityResult.none;
      _isWifi     = result == ConnectivityResult.wifi || result == ConnectivityResult.ethernet;
      _hasNetwork = result != ConnectivityResult.none;

      if (!_hasNetwork) {
        _updateAllQueued('Waiting for network...');
        _emit();
        return;
      }
      if (wasWifi && !_isWifi && _wifiPreferred && !_allowMetered && isUploading) {
        _cellularOk = false;
        if (context != null && context.mounted) {
          await showMeteredConnectionDialog(context);
        }
      }
      if (_isWifi) _cellularOk = false;
      if (_canUpload) _processNext();
      _emit();
    });
  }

  bool get _canUpload =>
      _hasNetwork && (_isWifi || _cellularOk || _allowMetered) && !_globalHold;

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
      _cellularOk = result;
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

  // ── 7-day clean + recovery ────────────────────────────────────────────────
  Future<void> cleanStaleFiles() async {
    final cutoff = DateTime.now().subtract(const Duration(days: _retentionDays));
    final staleKeys = <String>[];
    for (final entry in _states.entries) {
      final s = entry.value;
      if (s.status == ChunkStatus.failed &&
          s.failedAt != null && s.failedAt!.isBefore(cutoff)) {
        staleKeys.add(entry.key);
      }
    }
    for (final k in staleKeys) {
      await _deleteFiles(_states[k]!.chunk);
      _states.remove(k);
      _queue.removeWhere((c) => c.filePath == k);
    }
    if (staleKeys.isNotEmpty) _emit();

    for (final dirName in [_backupDirName, _chunkDirName]) {
      try {
        final tmp = await getTemporaryDirectory();
        final dir = Directory('${tmp.path}/$dirName');
        if (!await dir.exists()) continue;
        for (final f in dir.listSync().whereType<File>()) {
          final mod = await f.lastModified();
          if (mod.isBefore(cutoff) && !_states.containsKey(f.path)) {
            await f.delete();
          }
        }
      } catch (_) {}
    }
  }

  // ── Enqueue ───────────────────────────────────────────────────────────────
  Future<void> enqueue(PendingChunk chunk) async {
    debugPrint('=== Queue: enqueue ${chunk.cloudFileName}');
    if (!File(chunk.backupPath).existsSync()) {
      await _ensureBackup(chunk.filePath);
    }
    _states[chunk.filePath] = ChunkState(chunk);
    _queue.add(chunk);
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
    final state = _states[next.filePath]!;
    state.status  = ChunkStatus.uploading;
    state.message = 'Starting...';
    _emit();

    bool uploadSuccess = false;

    // ── Issue 1: attempt up to (1 + _maxRetries) times ─────────────────────
    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        if (attempt > 0) {
          state.message = 'Retrying (${attempt}/${_maxRetries})...';
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
      // ── Success: delete files, remove from queue ──────────────────────
      await _deleteFiles(next);
      _states.remove(next.filePath);
      _queue.remove(next);
      _emit();
      debugPrint('=== Queue: ${next.cloudFileName} done ✓');
      _running = false;

      // Continue with next queued chunk
      if (_canUpload) _processNext();

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

      NotificationService().showUploadFailed(
          'Part ${next.partNumber} of ${next.sessionId} failed. '
          'Open app and tap Retry All to continue.');

      _running = false;
      // No _processNext() — global hold prevents further uploads
    }
  }

  Future<void> _uploadChunk(PendingChunk chunk, ChunkState state) async {
    if (!chunk.hasAnyFile) {
      throw _PermanentFailure('Both original and backup missing — re-record needed.');
    }
    final userFolder    = await UserService().getDisplayName();
    final dateFolder    = DateFormat('dd-MM-yyyy').format(chunk.sessionDate);
    final sessionFolder = chunk.sessionFolderName;
    final folderPath    = '$_rootFolder/$dateFolder/$userFolder/$sessionFolder';

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
        _emit();
      },
      onStatus: (s) { state.message = s; _emit(); },
    );
  }

  // ── Public controls ───────────────────────────────────────────────────────

  /// Issue 1: Manual retry — clears global hold, re-queues ALL failed chunks
  void retryFailed() {
    _globalHold = false; // release the hold
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
          s.message = 'File missing — re-record needed';
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

  void abandonChunk(String filePath) {
    final s = _states[filePath];
    if (s != null) _deleteFiles(s.chunk).ignore();
    _states.remove(filePath);
    _queue.removeWhere((c) => c.filePath == filePath);

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
  Future<void> recoverFromCache() async {
    await cleanStaleFiles();
    final bdir = await _backupDir();
    final cdir = await _chunksDir();

    final allFiles = <String, File>{};
    for (final dir in [cdir, bdir]) {
      if (!await dir.exists()) continue;
      for (final f in dir.listSync().whereType<File>()
          .where((f) => f.path.endsWith('.mp4'))) {
        final name = f.path.split('/').last;
        if (!allFiles.containsKey(name)) allFiles[name] = f;
      }
    }

    final namePattern = RegExp(
        r'^([A-Z0-9]{6})_(\d{8})_(\d{6})_(\d+)_(\d+)-(\d+)\.mp4');

    for (final entry in allFiles.entries) {
      final name = entry.key;
      final file = entry.value;
      if (_states.values.any((s) => s.chunk.cloudFileName == name)) continue;

      final m = namePattern.firstMatch(name);
      if (m == null) continue;

      final ds = m.group(2)!; final ts = m.group(3)!;
      final dt = DateTime(int.parse(ds.substring(0,4)),
          int.parse(ds.substring(4,6)), int.parse(ds.substring(6,8)));
      final st = DateTime(dt.year, dt.month, dt.day,
          int.parse(ts.substring(0,2)), int.parse(ts.substring(2,4)),
          int.parse(ts.substring(4,6)));

      final inChunks   = '${cdir.path}/$name';
      final backupPath = await _ensureBackup(
          File(inChunks).existsSync() ? inChunks : file.path);

      final chunk = PendingChunk(
        filePath:         inChunks,
        backupPath:       backupPath,
        sessionId:        m.group(1)!,
        userId:           '',
        partNumber:       int.parse(m.group(4)!),
        sessionDate:      dt,
        sessionStartTime: st,
        sessionEndTime:   st,
        startSec:         int.parse(m.group(5)!) * 60,
        endSec:           int.parse(m.group(6)!) * 60,
      );

      _states[chunk.filePath] = ChunkState(chunk);
      _queue.add(chunk);
      debugPrint('=== Queue: recovered ${chunk.cloudFileName}');
    }

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