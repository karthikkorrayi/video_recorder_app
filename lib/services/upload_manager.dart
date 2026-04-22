import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'onedrive_service.dart';
import 'session_store.dart';
import 'user_service.dart';
import '../models/session_model.dart';

// ── UploadState — emitted via stream so UploadProgressScreen rebuilds ────────

class UploadState {
  final int         totalBlocks;
  final List<int>   uploadedBlocks;
  final double      overallProgress;  // 0.0–1.0
  final double      blockProgress;    // 0.0–1.0 for current part
  final String      statusText;
  final bool        isComplete;
  final bool        isError;

  const UploadState({
    required this.totalBlocks,
    required this.uploadedBlocks,
    this.overallProgress = 0.0,
    this.blockProgress   = 0.0,
    this.statusText      = '',
    this.isComplete      = false,
    this.isError         = false,
  });

  UploadState copyWith({
    double? overallProgress,
    double? blockProgress,
    String? statusText,
    bool?   isComplete,
    bool?   isError,
    List<int>? uploadedBlocks,
  }) => UploadState(
    totalBlocks:     totalBlocks,
    uploadedBlocks:  uploadedBlocks ?? this.uploadedBlocks,
    overallProgress: overallProgress ?? this.overallProgress,
    blockProgress:   blockProgress   ?? this.blockProgress,
    statusText:      statusText      ?? this.statusText,
    isComplete:      isComplete      ?? this.isComplete,
    isError:         isError         ?? this.isError,
  );
}

// ── UploadManager — singleton, survives navigation ───────────────────────────

class UploadManager {
  static final UploadManager _i = UploadManager._();
  factory UploadManager() => _i;
  UploadManager._();

  final _ctrl = StreamController<UploadState>.broadcast();

  /// UI subscribes to this for live progress updates.
  Stream<UploadState> get stream => _ctrl.stream;

  UploadState _state = const UploadState(
    totalBlocks: 0, uploadedBlocks: [], statusText: 'Idle');

  /// Last known state — used by UploadProgressScreen on initState.
  UploadState get current => _state;

  bool _running   = false;
  bool _isPaused  = false;
  bool _cancelled = false;

  /// Whether an upload is currently active.
  bool get isRunning => _running;
  bool get isPaused  => _isPaused;

  void pause()  => _isPaused = true;
  void resume() => _isPaused = false;
  void cancel() { _cancelled = true; _isPaused = false; }

  void _emit(UploadState s) {
    _state = s;
    _ctrl.add(s);
  }

  /// Start uploading [session]. [store] is used to persist status changes.
  Future<void> start(SessionModel session, SessionStore store) async {
    if (_running) return; // already uploading — don't double-start
    _running   = true;
    _cancelled = false;
    _isPaused  = false;

    _emit(UploadState(
      totalBlocks:    session.blockCount,
      uploadedBlocks: List.from(session.uploadedBlocks),
      statusText:     'Starting upload...',
    ));

    try {
      // Resolve user full name via Firebase (cached after first call)
      final userFullName = await UserService().getDisplayName();

      // Build OneDrive folder path ONCE — uses session START time so all
      // parts land in the same folder regardless of when they finish uploading
      final folderPath = OneDriveService.buildSessionFolderPath(
        dateFolder:       session.dateFolder.isNotEmpty
            ? session.dateFolder
            : _fmtDateFolder(session.recordedAt),
        userFullName:     userFullName,
        sessionId:        session.id.length >= 6
            ? session.id.substring(0, 6).toUpperCase()
            : session.id.toUpperCase(),
        sessionDate:      session.sessionDate.isNotEmpty
            ? session.sessionDate
            : _fmtDate(session.recordedAt),
        sessionStartTime: session.startTime.isNotEmpty
            ? session.startTime
            : _fmtTime(session.recordedAt),
      );

      final paths = session.localChunkPaths;
      final done  = List<int>.from(session.uploadedBlocks);

      for (int i = 0; i < paths.length; i++) {
        if (_cancelled) break;
        if (done.contains(i)) continue; // already uploaded

        await _waitForReady();
        if (_cancelled) break;

        final file     = File(paths[i]);
        final partName = i < session.partNames.length
            ? session.partNames[i]
            : '${session.id}_part${(i+1).toString().padLeft(2,'0')}.mp4';

        _emit(_state.copyWith(
          statusText:  'Uploading part ${i+1} of ${paths.length}...',
          blockProgress: 0.0,
        ));

        if (!await file.exists()) {
          // Already deleted (uploaded before) — count as done
          done.add(i);
          _emitProgress(done, paths.length);
          continue;
        }

        bool partDone = false;
        for (int attempt = 0; attempt < 4 && !partDone; attempt++) {
          try {
            final uploadUrl = await OneDriveService.createUploadSession(
              folderPath: folderPath,
              fileName:   partName,
            );

            await OneDriveService.uploadFileInChunks(
              uploadUrl:  uploadUrl,
              file:       file,
              onProgress: (p) {
                final overall = (i + p) / paths.length;
                _emit(_state.copyWith(
                  blockProgress:   p,
                  overallProgress: overall,
                  statusText: 'Part ${i+1}/${paths.length} — '
                      '${(p*100).toStringAsFixed(0)}%',
                ));
              },
            );

            await file.delete();
            done.add(i);
            session.uploadedBlocks = List.from(done);
            await store.save(session);
            _emitProgress(done, paths.length);
            partDone = true;

          } catch (_) {
            if (attempt < 3) {
              await Future.delayed(Duration(seconds: (attempt + 1) * 5));
            } else {
              // All retries exhausted
              session.status = 'pending';
              await store.save(session);
              _emit(_state.copyWith(
                statusText: 'Upload failed after retries. Tap retry.',
                isError:    true,
              ));
              _running = false;
              return;
            }
          }
        }
      }

      if (!_cancelled) {
        session.status = 'synced';
        await store.save(session);
        _emit(_state.copyWith(
          overallProgress: 1.0,
          blockProgress:   1.0,
          statusText:      'Upload complete ✓',
          isComplete:      true,
        ));
      }

    } catch (e) {
      session.status = 'pending';
      await store.save(session);
      _emit(_state.copyWith(
        statusText: 'Error: $e',
        isError:    true,
      ));
    } finally {
      _running = false;
    }
  }

  void _emitProgress(List<int> done, int total) {
    _emit(_state.copyWith(
      uploadedBlocks:  List.from(done),
      overallProgress: total > 0 ? done.length / total : 0,
    ));
  }

  Future<void> _waitForReady() async {
    while (_isPaused && !_cancelled) {
      await Future.delayed(const Duration(seconds: 2));
    }
    var result = await Connectivity().checkConnectivity();
    while (result == ConnectivityResult.none && !_cancelled) {
      _emit(_state.copyWith(statusText: 'Waiting for network...'));
      await Future.delayed(const Duration(seconds: 5));
      result = await Connectivity().checkConnectivity();
    }
  }

  // ── Date formatters ───────────────────────────────────────────────────────
  static String _fmtDateFolder(DateTime t) =>
      '${t.day.toString().padLeft(2,'0')}-'
      '${t.month.toString().padLeft(2,'0')}-${t.year}';

  static String _fmtDate(DateTime t) =>
      '${t.year}${t.month.toString().padLeft(2,'0')}'
      '${t.day.toString().padLeft(2,'0')}';

  static String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2,'0')}'
      '${t.minute.toString().padLeft(2,'0')}'
      '${t.second.toString().padLeft(2,'0')}';
}