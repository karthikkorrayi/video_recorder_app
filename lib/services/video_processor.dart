import 'dart:io';
import 'dart:isolate';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'local_video_storage.dart';
import 'attendance_service.dart';
import 'processing_manager.dart';

class VideoProcessor {
  static const int _blockSecs = 120;

  final _storage = LocalVideoStorage();
  final _attendance = AttendanceService();

  /// Kick off processing in a Dart Isolate so FFmpeg never touches
  /// the camera's I/O thread. Returns sessionId immediately.
  String startBackgroundProcessing({
    required String rawVideoPath,
    required DateTime sessionTime,
  }) {
    final sessionId = '${DateTime.now().millisecondsSinceEpoch}';
    // True background — Dart Isolate = separate OS thread
    _runInIsolate(rawVideoPath: rawVideoPath,
        sessionTime: sessionTime, sessionId: sessionId);
    return sessionId;
  }

  // ─── Isolate entry ────────────────────────────────────────────────────────

  /// Spawns an isolate. The isolate sends back progress events via SendPort.
  Future<void> _runInIsolate({
    required String rawVideoPath,
    required DateTime sessionTime,
    required String sessionId,
  }) async {
    final receivePort = ReceivePort();

    // We can't pass complex objects (like FirebaseAuth) into an isolate,
    // so get user info on the main thread first.
    final user = FirebaseAuth.instance.currentUser!;
    final userId = user.uid;
    final userEmail = user.email ?? userId;

    // Resolve output directory on main thread (uses plugins)
    final dir = await _storage.sessionDir(sessionTime, userEmail);

    // Build all filenames ahead of time — we'll figure out totalBlocks after
    // probing inside the isolate, but we pass the config.
    final config = _IsolateConfig(
      rawVideoPath: rawVideoPath,
      outputDir: dir.path,
      userId: userId,
      sessionTime: sessionTime,
      blockSecs: _blockSecs,
      sessionId: sessionId,
      sendPort: receivePort.sendPort,
    );

    // Listen for progress events from the isolate
    receivePort.listen((msg) {
      if (msg is _ProgressEvent) {
        ProcessingManager().update(sessionId, ProcessingStatus(
          sessionId: sessionId,
          state: msg.state,
          message: msg.message,
          progress: msg.progress,
          currentBlock: msg.currentBlock,
          totalBlocks: msg.totalBlocks,
        ));
      } else if (msg is _DoneEvent) {
        receivePort.close();
        // Back on main thread: update attendance + sidecar
        _onIsolateDone(msg, sessionId);
      } else if (msg is _ErrorEvent) {
        receivePort.close();
        ProcessingManager().update(sessionId, ProcessingStatus(
          sessionId: sessionId,
          state: ProcessingState.error,
          message: 'Failed: ${msg.error}',
          progress: 0,
        ));
      }
    });

    await Isolate.spawn(_isolateMain, config);
  }

  /// Called back on the main isolate after processing completes.
  Future<void> _onIsolateDone(_DoneEvent event, String sessionId) async {
    try {
      // Write .dur sidecar with actual duration (for correct duration display)
      if (event.savedPaths.isNotEmpty) {
        final sidecar = event.savedPaths.first
            .replaceAll(RegExp(r'\.mp4$'), '.dur');
        await File(sidecar).writeAsString('${event.durationSecs}');
      }
      // Update attendance log
      await _attendance.recordSession(event.durationSecs);
      // Delete raw file to free space
      try { await File(event.rawVideoPath).delete(); } catch (_) {}

      ProcessingManager().update(sessionId, ProcessingStatus(
        sessionId: sessionId,
        state: ProcessingState.done,
        message: 'Saved ${event.savedPaths.length} block${event.savedPaths.length == 1 ? '' : 's'}',
        progress: 1.0,
        currentBlock: event.savedPaths.length,
        totalBlocks: event.savedPaths.length,
      ));
    } catch (e) {
      print('=== Processor: _onIsolateDone error: $e');
    }
  }

  // ─── Isolate body (runs on separate OS thread) ────────────────────────────

  /// This runs in a separate Dart Isolate — completely isolated from
  /// the camera's I/O. FFmpeg can take as long as it wants here without
  /// interfering with video recording.
  static Future<void> _isolateMain(_IsolateConfig cfg) async {
    void emit(_IsolateMessage msg) => cfg.sendPort.send(msg);

    try {
      emit(_ProgressEvent(
        state: ProcessingState.analysing,
        message: 'Analysing video...',
        progress: 0.05,
      ));

      // Probe duration
      final durationSecs = await _probeDuration(cfg.rawVideoPath);
      final totalBlocks = (durationSecs / cfg.blockSecs).ceil().clamp(1, 999);

      final savedPaths = <String>[];
      final dt = _fmtDateTime(cfg.sessionTime);
      final safeId = cfg.userId.length > 12
          ? cfg.userId.substring(0, 12) : cfg.userId;
      safeId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

      for (int i = 0; i < totalBlocks; i++) {
        final blockNum = i + 1;
        final startSec = i * cfg.blockSecs;

        // Build filename matching LocalVideoStorage.blockFileName
        final nn = blockNum.toString().padLeft(2, '0');
        final mm = totalBlocks.toString().padLeft(2, '0');
        final fileName = totalBlocks == 1
            ? '${safeId}_$dt.mp4'
            : '${safeId}_${dt}_block${nn}of${mm}.mp4';

        final outputPath = '${cfg.outputDir}/$fileName';

        emit(_ProgressEvent(
          state: ProcessingState.processing,
          message: 'Processing block $blockNum of $totalBlocks...',
          progress: 0.1 + (i / totalBlocks) * 0.85,
          currentBlock: blockNum,
          totalBlocks: totalBlocks,
        ));

        // Landscape output — keep original ratio, 720p height, 30fps, no audio
        final cmd = '-i "${cfg.rawVideoPath}" '
            '-ss $startSec '
            '-t ${cfg.blockSecs} '
            '-vf "scale=-2:720,fps=30" '
            '-an '
            '-c:v libx264 '
            '-crf 26 '
            '-preset fast '
            '-movflags +faststart '
            '"$outputPath"';

        final session = await FFmpegKit.execute(cmd);
        final rc = await session.getReturnCode();

        if (!ReturnCode.isSuccess(rc)) {
          final logs = await session.getAllLogsAsString();
          throw Exception('Block $blockNum failed: $logs');
        }

        savedPaths.add(outputPath);
      }

      emit(_DoneEvent(
        savedPaths: savedPaths,
        durationSecs: durationSecs,
        rawVideoPath: cfg.rawVideoPath,
      ));
    } catch (e) {
      emit(_ErrorEvent(error: e.toString()));
    }
  }

  static Future<int> _probeDuration(String path) async {
    try {
      final s = await FFprobeKit.getMediaInformation(path);
      final info = s.getMediaInformation();
      if (info != null) {
        final d = double.tryParse(info.getDuration() ?? '');
        if (d != null && d > 0) return d.ceil();
      }
    } catch (_) {}
    return 60;
  }

  static String _fmtDateTime(DateTime t) =>
      '${t.year}${_p(t.month)}${_p(t.day)}_${_p(t.hour)}${_p(t.minute)}${_p(t.second)}';

  static String _p(int n) => n.toString().padLeft(2, '0');

  /// Probe-only helper for the review screen to show duration before saving.
  Future<int> getDuration(String path) => _probeDuration(path);
}

// ─── Isolate message types ────────────────────────────────────────────────────

class _IsolateConfig {
  final String rawVideoPath;
  final String outputDir;
  final String userId;
  final DateTime sessionTime;
  final int blockSecs;
  final String sessionId;
  final SendPort sendPort;

  const _IsolateConfig({
    required this.rawVideoPath, required this.outputDir,
    required this.userId, required this.sessionTime,
    required this.blockSecs, required this.sessionId,
    required this.sendPort,
  });
}

abstract class _IsolateMessage {}

class _ProgressEvent extends _IsolateMessage {
  final ProcessingState state;
  final String message;
  final double progress;
  final int currentBlock;
  final int totalBlocks;
  _ProgressEvent({required this.state, required this.message,
      required this.progress, this.currentBlock = 0, this.totalBlocks = 0});
}

class _DoneEvent extends _IsolateMessage {
  final List<String> savedPaths;
  final int durationSecs;
  final String rawVideoPath;
  _DoneEvent({required this.savedPaths, required this.durationSecs,
      required this.rawVideoPath});
}

class _ErrorEvent extends _IsolateMessage {
  final String error;
  _ErrorEvent({required this.error});
}