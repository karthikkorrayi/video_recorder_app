import 'dart:io';
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

  /// Fires background processing and returns immediately.
  /// Uses Future.microtask so it doesn't block the UI thread.
  /// FFmpegKit uses platform channels so it must stay on the main Dart isolate,
  /// but we use async/await so the camera's MediaRecorder is never contended.
  String startBackgroundProcessing({
    required String rawVideoPath,
    required DateTime sessionTime,
  }) {
    final sessionId = '${DateTime.now().millisecondsSinceEpoch}';
    // Schedule processing to start after current frame renders
    Future.microtask(() => _runProcessing(
      rawVideoPath: rawVideoPath,
      sessionTime: sessionTime,
      sessionId: sessionId,
    ));
    return sessionId;
  }

  Future<void> _runProcessing({
    required String rawVideoPath,
    required DateTime sessionTime,
    required String sessionId,
  }) async {
    final manager = ProcessingManager();
    final user = FirebaseAuth.instance.currentUser!;
    final userId = user.uid;
    final userEmail = user.email ?? userId;

    try {
      manager.update(sessionId, ProcessingStatus(
        sessionId: sessionId,
        state: ProcessingState.analysing,
        message: 'Analysing video...',
        progress: 0.05,
      ));

      // Probe duration — awaited, yields to event loop between calls
      final durationSecs = await _probeDuration(rawVideoPath);
      final totalBlocks = (durationSecs / _blockSecs).ceil().clamp(1, 999);

      final dir = await _storage.sessionDir(sessionTime, userEmail);
      final savedPaths = <String>[];

      for (int i = 0; i < totalBlocks; i++) {
        final blockNum = i + 1;
        final startSec = i * _blockSecs;

        final fileName = _storage.blockFileName(
          userId: userId,
          sessionTime: sessionTime,
          blockIndex: blockNum,
          totalBlocks: totalBlocks,
        );
        final outputPath = '${dir.path}/$fileName';

        manager.update(sessionId, ProcessingStatus(
          sessionId: sessionId,
          state: ProcessingState.processing,
          message: 'Processing block $blockNum of $totalBlocks...',
          progress: 0.1 + (i / totalBlocks) * 0.85,
          currentBlock: blockNum,
          totalBlocks: totalBlocks,
        ));

        // Landscape output: keep original ratio, scale to 720p, 30fps, no audio
        // Each FFmpegKit.execute call yields to the event loop when awaited —
        // the camera can still write its recording during these yields.
        final cmd = '-i "$rawVideoPath" '
            '-ss $startSec '
            '-t $_blockSecs '
            '-vf "scale=-2:720,fps=30" '
            '-an '
            '-c:v libx264 '
            '-crf 26 '
            '-preset ultrafast '   // fastest preset = least CPU contention
            '-movflags +faststart '
            '"$outputPath"';

        final session = await FFmpegKit.execute(cmd);
        final rc = await session.getReturnCode();

        if (!ReturnCode.isSuccess(rc)) {
          final logs = await session.getAllLogsAsString();
          throw Exception('Block $blockNum failed: $logs');
        }

        savedPaths.add(outputPath);
        print('=== Processor [$sessionId]: block $blockNum done → $outputPath');
      }

      // Write .dur sidecar (actual duration for display)
      if (savedPaths.isNotEmpty) {
        final sidecar = savedPaths.first.replaceAll(RegExp(r'\.mp4$'), '.dur');
        await File(sidecar).writeAsString('$durationSecs');
      }

      // Update attendance
      await _attendance.recordSession(durationSecs);

      // Delete raw file to free storage
      try { await File(rawVideoPath).delete(); } catch (_) {}

      manager.update(sessionId, ProcessingStatus(
        sessionId: sessionId,
        state: ProcessingState.done,
        message: 'Saved ${savedPaths.length} block${savedPaths.length == 1 ? '' : 's'}',
        progress: 1.0,
        currentBlock: savedPaths.length,
        totalBlocks: totalBlocks,
      ));

    } catch (e) {
      print('=== Processor [$sessionId]: ERROR: $e');
      manager.update(sessionId, ProcessingStatus(
        sessionId: sessionId,
        state: ProcessingState.error,
        message: 'Failed: $e',
        progress: 0,
      ));
    }
  }

  Future<int> _probeDuration(String path) async {
    try {
      final s = await FFprobeKit.getMediaInformation(path);
      final info = s.getMediaInformation();
      if (info != null) {
        final d = double.tryParse(info.getDuration() ?? '');
        if (d != null && d > 0) return d.ceil();
      }
    } catch (e) { print('=== Processor: probe error: $e'); }
    return 60;
  }

  Future<int> getDuration(String path) => _probeDuration(path);
}