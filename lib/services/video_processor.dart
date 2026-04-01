import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'local_video_storage.dart';
import 'attendance_service.dart';
import 'processing_manager.dart';

class VideoProcessor {
  static const int _blockSecs = 120; // 2 minutes per block

  final _storage = LocalVideoStorage();
  final _attendance = AttendanceService();

  /// Starts processing in the background immediately — does NOT await.
  /// Returns the sessionId so the dashboard can track it via ProcessingManager.
  String startBackgroundProcessing({
    required String rawVideoPath,
    required DateTime sessionTime,
  }) {
    final sessionId = '${DateTime.now().millisecondsSinceEpoch}';
    // Fire and forget — runs completely in background
    _processInBackground(
      rawVideoPath: rawVideoPath,
      sessionTime: sessionTime,
      sessionId: sessionId,
    );
    return sessionId;
  }

  Future<void> _processInBackground({
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

      final durationSecs = await getDuration(rawVideoPath);
      final totalBlocks = (durationSecs / _blockSecs).ceil().clamp(1, 999);

      final dir = await _storage.sessionDir(sessionTime, userEmail);
      print('=== Processor [$sessionId]: ${durationSecs}s → $totalBlocks blocks → ${dir.path}');

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

        // LANDSCAPE output — keep original aspect ratio, just set 30fps & mute audio.
        // We do NOT crop to 9:16. The recording is landscape and stays landscape.
        // scale=-2:720 ensures height=720 (even number) while keeping aspect ratio.
        final cmd = '-i "$rawVideoPath" '
            '-ss $startSec '
            '-t $_blockSecs '
            '-vf "scale=-2:720,fps=30" '  // keeps landscape ratio, 720p height
            '-an '                          // no audio
            '-c:v libx264 '
            '-crf 26 '
            '-preset fast '
            '-movflags +faststart '
            '"$outputPath"';

        print('=== Processor [$sessionId]: block $blockNum → $outputPath');

        final session = await FFmpegKit.execute(cmd);
        final rc = await session.getReturnCode();

        if (!ReturnCode.isSuccess(rc)) {
          final logs = await session.getAllLogsAsString();
          throw Exception('FFmpeg block $blockNum failed: $logs');
        }

        savedPaths.add(outputPath);
        print('=== Processor [$sessionId]: block $blockNum done');
      }

      // Write .dur sidecar with actual duration
      if (savedPaths.isNotEmpty) {
        final sidecar = savedPaths.first.replaceAll(RegExp(r'\.mp4$'), '.dur');
        await File(sidecar).writeAsString('$durationSecs');
      }

      // Update attendance
      await _attendance.recordSession(durationSecs);

      // Delete raw file to save space
      try { await File(rawVideoPath).delete(); } catch (_) {}

      manager.update(sessionId, ProcessingStatus(
        sessionId: sessionId,
        state: ProcessingState.done,
        message: 'Saved ${savedPaths.length} block${savedPaths.length == 1 ? '' : 's'}',
        progress: 1.0,
        currentBlock: savedPaths.length,
        totalBlocks: totalBlocks,
      ));

      print('=== Processor [$sessionId]: complete');
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

  Future<int> getDuration(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info != null) {
        final d = double.tryParse(info.getDuration() ?? '');
        if (d != null && d > 0) return d.ceil();
      }
    } catch (e) {
      print('=== Processor: getDuration error: $e');
    }
    return 60;
  }
}