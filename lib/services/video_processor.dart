import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'local_video_storage.dart';
import 'attendance_service.dart';
import 'processing_manager.dart';

class VideoProcessor {
  static const int blockSecs = 120;

  final _storage    = LocalVideoStorage();
  final _attendance = AttendanceService();

  String startBackgroundProcessing({
    required String rawVideoPath,
    required DateTime sessionTime,
  }) {
    final sessionId = '${DateTime.now().millisecondsSinceEpoch}';
    Future.microtask(() => _run(
      rawVideoPath: rawVideoPath,
      sessionTime: sessionTime,
      sessionId: sessionId,
    ));
    return sessionId;
  }

  Future<void> _run({
    required String rawVideoPath,
    required DateTime sessionTime,
    required String sessionId,
  }) async {
    final manager = ProcessingManager();
    final user = FirebaseAuth.instance.currentUser!;
    final userId = user.uid;
    final userEmail = user.email ?? userId;

    try {
      // ── Step 1: Get duration ─────────────────────────────────────────────
      manager.update(sessionId, ProcessingStatus(
        sessionId: sessionId, state: ProcessingState.analysing,
        message: 'Analysing video...', progress: 0.05,
      ));

      final durationSec = await _probeDurationSec(rawVideoPath);
      final totalBlocks = (durationSec / blockSecs).ceil().clamp(1, 999);
      print('=== Processor: ${durationSec}s → $totalBlocks block(s)');

      final dir        = await _storage.sessionDir(sessionTime, userEmail);
      final savedPaths = <String>[];

      for (int i = 0; i < totalBlocks; i++) {
        final blockNum  = i + 1;
        final startSec  = i * blockSecs;
        final remaining = durationSec - startSec;
        final blockDur  = remaining < blockSecs ? remaining : blockSecs.toDouble();

        manager.update(sessionId, ProcessingStatus(
          sessionId: sessionId, state: ProcessingState.processing,
          message: 'Saving block $blockNum of $totalBlocks...',
          progress: 0.1 + (i / totalBlocks) * 0.85,
          currentBlock: blockNum, totalBlocks: totalBlocks,
        ));

        final fileName   = _storage.blockFileName(
          userId: userId, sessionTime: sessionTime,
          blockIndex: blockNum, totalBlocks: totalBlocks,
        );
        final outputPath = '${dir.path}/$fileName';

        // -ss BEFORE -i = input seek (fast, frame-accurate for H.264)
        // -t            = number of seconds to copy from the seek point
        // -c copy       = no re-encode, instant split, zero quality loss
        // -avoid_negative_ts make_zero = fix timestamps in split files
        // -movflags +faststart = moov atom at front (fast playback start)
        final cmd =
            '-ss $startSec '
            '-i "$rawVideoPath" '
            '-t $blockDur '
            '-c copy '
            '-avoid_negative_ts make_zero '
            '-movflags +faststart '
            '"$outputPath"';

        print('=== Block $blockNum: ss=$startSec t=$blockDur → $outputPath');

        final session = await FFmpegKit.execute(cmd);
        final rc      = await session.getReturnCode();

        if (!ReturnCode.isSuccess(rc)) {
          final logs = await session.getAllLogsAsString();
          throw Exception('Block $blockNum failed:\n$logs');
        }

        final outFile = File(outputPath);
        if (!await outFile.exists() || await outFile.length() < 512) {
          throw Exception('Block $blockNum output missing or empty');
        }

        savedPaths.add(outputPath);
        final kb = (await outFile.length() / 1024).toStringAsFixed(0);
        print('=== Block $blockNum ✓  ${kb}KB');
      }

      if (savedPaths.isNotEmpty) {
        final sidecar = savedPaths.first.replaceAll(RegExp(r'\.mp4$'), '.dur');
        await File(sidecar).writeAsString('$durationSec');
      }

      try { await File(rawVideoPath).delete(); } catch (_) {}
      await _attendance.recordSession(durationSec.toInt());

      manager.update(sessionId, ProcessingStatus(
        sessionId: sessionId, state: ProcessingState.done,
        message: 'Saved ${savedPaths.length} block${savedPaths.length == 1 ? '' : 's'}',
        progress: 1.0, currentBlock: savedPaths.length, totalBlocks: totalBlocks,
      ));
      print('=== Processor ✓ complete');

    } catch (e) {
      print('=== Processor ERROR: $e');
      manager.update(sessionId, ProcessingStatus(
        sessionId: sessionId, state: ProcessingState.error,
        message: 'Failed: $e', progress: 0,
      ));
    }
  }

  static Future<double> _probeDurationSec(String path) async {
    try {
      final s    = await FFprobeKit.getMediaInformation(path);
      final info = s.getMediaInformation();
      if (info != null) {
        final d = double.tryParse(info.getDuration() ?? '');
        if (d != null && d > 0) { print('=== Probe: ${d}s'); return d; }
      }
    } catch (e) { print('=== Probe error: $e'); }
    return 60.0;
  }

  Future<int> getDuration(String path) async =>
      (await _probeDurationSec(path)).ceil();
}