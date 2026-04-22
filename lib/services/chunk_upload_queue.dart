import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'onedrive_service.dart';
import 'notification_service.dart';
import 'user_service.dart';
import 'package:intl/intl.dart';

/// A single chunk waiting to be uploaded.
class PendingChunk {
  final String   filePath;
  final String   sessionId;
  final String   userId;
  final int      partNumber;
  final DateTime sessionDate;
  final DateTime sessionStartTime;
  final DateTime sessionEndTime; // kept for camera_screen compatibility — NOT used in folder name
  final int      startSec;
  final int      endSec;

  PendingChunk({
    required this.filePath,
    required this.sessionId,
    required this.userId,
    required this.partNumber,
    required this.sessionDate,
    required this.sessionStartTime,
    required this.sessionEndTime,
    required this.startSec,
    required this.endSec,
  });

  static String _fmtSec(int secs) {
    final m = (secs ~/ 60).toString().padLeft(2, '0');
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m$s';
  }

  static String _fmtWall(DateTime dt) => DateFormat('HHmmss').format(dt);

  /// Filename: SESSIONID_YYYYMMDD_HHMMSS_partNN_MMSS-MMSS.mp4
  /// e.g. OSFZWS_20260422_043710_part01_0000-0200.mp4
  String get cloudFileName {
    final n    = partNumber.toString().padLeft(2, '0');
    final date = DateFormat('yyyyMMdd').format(sessionDate);
    final time = _fmtWall(sessionStartTime);
    return '${sessionId}_${date}_${time}_part${n}_${_fmtSec(startSec)}-${_fmtSec(endSec)}.mp4';
  }

  /// FIX: Session folder uses START TIME ONLY — no end time.
  /// All parts of same session share identical folder name → land in ONE folder.
  /// e.g. OSFZWS_20260422_043710  (not OSFZWS_20260422_043710_043944)
  String get sessionFolderName {
    final date  = DateFormat('yyyyMMdd').format(sessionDate);
    final start = _fmtWall(sessionStartTime);
    return '${sessionId}_${date}_$start';
  }
}

enum ChunkStatus { queued, uploading, done, failed }

class ChunkState {
  final PendingChunk chunk;
  ChunkStatus status;
  double      progress;
  String      message;

  ChunkState(this.chunk)
      : status   = ChunkStatus.queued,
        progress = 0.0,
        message  = 'Queued';
}

class _PermanentFailure implements Exception {
  final String message;
  const _PermanentFailure(this.message);
  @override String toString() => message;
}

/// Singleton queue — processes chunks one at a time, survives navigation.
class ChunkUploadQueue {
  static final ChunkUploadQueue _i = ChunkUploadQueue._();
  factory ChunkUploadQueue() => _i;
  ChunkUploadQueue._();

  static const String _rootFolder = 'OTN Recorder';

  final _onedrive = OneDriveService();
  final _states   = <String, ChunkState>{};
  final _queue    = <PendingChunk>[];
  bool  _running  = false;
  bool  _hasNetwork = true;

  final _ctrl = StreamController<List<ChunkState>>.broadcast();
  Stream<List<ChunkState>> get stream  => _ctrl.stream;

  /// Only non-done chunks shown in Pending panel.
  /// Completed chunks are erased from view automatically.
  List<ChunkState> get current => _states.values
      .where((s) => s.status != ChunkStatus.done)
      .toList()
      ..sort((a, b) => a.chunk.partNumber.compareTo(b.chunk.partNumber));

  /// All chunks including done — for metrics.
  List<ChunkState> get all => _states.values.toList();

  void _emit() => _ctrl.add(current);

  void enqueue(PendingChunk chunk) {
    debugPrint('=== Queue: enqueue ${chunk.cloudFileName}');
    final state = ChunkState(chunk);
    _states[chunk.filePath] = state;
    _queue.add(chunk);
    _emit();
    _processNext();
  }

  void startNetworkMonitor() {
    Connectivity().onConnectivityChanged.listen((results) {
      final has = results.any((r) => r != ConnectivityResult.none);
      if (has && !_hasNetwork) {
        debugPrint('=== Queue: network restored');
        _hasNetwork = true;
        _processNext();
      } else if (!has) {
        _hasNetwork = false;
        _updateAllQueued('Waiting for network...');
      }
    });
  }

  void _updateAllQueued(String message) {
    for (final s in _states.values) {
      if (s.status == ChunkStatus.queued) s.message = message;
    }
    _emit();
  }

  Future<void> _processNext() async {
    if (_running) return;
    if (!_hasNetwork) return;

    PendingChunk? next;
    try {
      next = _queue.firstWhere(
        (c) => _states[c.filePath]?.status == ChunkStatus.queued,
        orElse: () => _queue.firstWhere(
          (c) => _states[c.filePath]?.status == ChunkStatus.failed,
        ),
      );
    } catch (_) {
      return; // nothing to process
    }

    _running = true;
    final state = _states[next.filePath]!;
    state.status  = ChunkStatus.uploading;
    state.message = 'Starting...';
    _emit();

    try {
      await _uploadChunk(next, state);
      state.status   = ChunkStatus.done;
      state.progress = 1.0;
      state.message  = 'Synced ✓';

      // FIX: Erase completed chunk from display immediately
      _states.remove(next.filePath);
      _queue.remove(next);
      _emit();

      try { await File(next.filePath).delete(); } catch (_) {}
      debugPrint('=== Queue: ${next.cloudFileName} done ✓');

      // Auto-clear any remaining done states for this session
      _clearDoneForSession(next.sessionId);

    } catch (e) {
      debugPrint('=== Queue: ${next.cloudFileName} failed: $e');

      if (e is _PermanentFailure) {
        state.status  = ChunkStatus.failed;
        state.message = e.message;
        _states.remove(next.filePath);
        _queue.remove(next);
        _emit();
      } else {
        state.status  = ChunkStatus.failed;
        state.message = e.toString().length > 80
            ? '${e.toString().substring(0, 80)}...'
            : e.toString();
        _emit();

        NotificationService().showUploadFailed(
          'Part ${next.partNumber} of session ${next.sessionId} failed. Tap to retry.',
        );

        await Future.delayed(const Duration(seconds: 30));
        if (_states[next.filePath]?.status == ChunkStatus.failed) {
          state.status  = ChunkStatus.queued;
          state.message = 'Retrying...';
          _emit();
        }
      }
    } finally {
      _running = false;
    }

    final hasMore = _states.values.any(
        (s) => s.status == ChunkStatus.queued ||
               s.status == ChunkStatus.failed);
    if (hasMore) _processNext();
  }

  void _clearDoneForSession(String sessionId) {
    final doneKeys = _states.entries
        .where((e) =>
            e.value.chunk.sessionId == sessionId &&
            e.value.status == ChunkStatus.done)
        .map((e) => e.key)
        .toList();
    for (final k in doneKeys) {
      _states.remove(k);
      _queue.removeWhere((c) => c.filePath == k);
    }
    if (doneKeys.isNotEmpty) _emit();
  }

  Future<void> _uploadChunk(PendingChunk chunk, ChunkState state) async {
    final file = File(chunk.filePath);
    if (!await file.exists()) {
      throw _PermanentFailure('Cache file deleted — nothing to upload');
    }

    final userFolder    = await UserService().getDisplayName();
    final dateFolder    = DateFormat('dd-MM-yyyy').format(chunk.sessionDate);
    final sessionFolder = chunk.sessionFolderName; // START TIME ONLY

    await _onedrive.uploadFileInSession(
      filePath:      chunk.filePath,
      fileName:      chunk.cloudFileName,
      dateFolder:    dateFolder,
      userFolder:    userFolder,
      sessionFolder: sessionFolder,
      rootFolder:    _rootFolder,
      onProgress: (p) {
        state.progress = p;
        state.message  = 'Uploading ${(p * 100).toStringAsFixed(0)}%';
        _emit();
      },
      onStatus: (s) {
        state.message = s;
        _emit();
      },
    );
  }

  // ── Public controls ───────────────────────────────────────────────────────

  /// Called by camera_screen when a new session starts — clears done chunks
  /// so the badge resets to "0/N" for the new session.
  void clearCompleted() {
    _states.removeWhere((_, s) => s.status == ChunkStatus.done);
    _queue.removeWhere((c) => !_states.containsKey(c.filePath));
    _emit();
  }

    void retryFailed() {
    for (final s in _states.values) {
      if (s.status == ChunkStatus.failed) {
        s.status  = ChunkStatus.queued;
        s.message = 'Retrying...';
      }
    }
    _emit();
    _processNext();
  }

  void retryChunk(PendingChunk chunk) {
    final s = _states[chunk.filePath];
    if (s != null) {
      s.status  = ChunkStatus.queued;
      s.message = 'Retrying...';
      _emit();
      _processNext();
    }
  }

  void abandonChunk(String filePath) {
    _states.remove(filePath);
    _queue.removeWhere((c) => c.filePath == filePath);
    _emit();
  }

  bool isSessionComplete(String sessionId) => !_states.values
      .any((s) => s.chunk.sessionId == sessionId &&
                  s.status != ChunkStatus.done);

  // ── Metrics ───────────────────────────────────────────────────────────────
  int get pendingCount   => _states.values.where((s) => s.status == ChunkStatus.queued).length;
  int get uploadingCount => _states.values.where((s) => s.status == ChunkStatus.uploading).length;
  int get failedCount    => _states.values.where((s) => s.status == ChunkStatus.failed).length;
  int get doneCount      => all.where((s) => s.status == ChunkStatus.done).length;
  bool get isUploading   => _states.values.any((s) => s.status == ChunkStatus.uploading);

  // ── Recovery ──────────────────────────────────────────────────────────────
  Future<void> recoverFromCache() async {
    try {
      final tmpDir    = await getTemporaryDirectory();
      final chunksDir = Directory('${tmpDir.path}/otn_upload_chunks');
      if (!await chunksDir.exists()) return;

      final files = chunksDir.listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.mp4'))
          .toList();

      for (final f in files) {
        if (_states.containsKey(f.path)) continue;
        final name = f.path.split('/').last;
        final m = RegExp(
            r'^([A-Z0-9]{6})_(\d{8})_(\d{6})_part(\d+)_(\d{4})-(\d{4})')
            .firstMatch(name);
        if (m == null) continue;

        int toSec(String s) =>
            int.parse(s.substring(0, 2)) * 60 + int.parse(s.substring(2));

        final dateStr  = m.group(2)!;
        final timeStr  = m.group(3)!;
        final date = DateTime(
          int.parse(dateStr.substring(0, 4)),
          int.parse(dateStr.substring(4, 6)),
          int.parse(dateStr.substring(6, 8)),
        );
        final start = DateTime(date.year, date.month, date.day,
          int.parse(timeStr.substring(0, 2)),
          int.parse(timeStr.substring(2, 4)),
          int.parse(timeStr.substring(4, 6)),
        );

        enqueue(PendingChunk(
          filePath:         f.path,
          sessionId:        m.group(1)!,
          userId:           '',
          partNumber:       int.parse(m.group(4)!),
          sessionDate:      date,
          sessionStartTime: start,
          sessionEndTime:   start, // unknown from cache — use start as fallback
          startSec:         toSec(m.group(5)!),
          endSec:           toSec(m.group(6)!),
        ));
      }
    } catch (e) {
      debugPrint('=== recoverFromCache error: $e');
    }
  }
}