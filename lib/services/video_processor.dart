import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'local_video_storage.dart';
import 'attendance_service.dart';

class VideoProcessor {
  static const int _blockSecs = 120; // 2 minutes

  final _storage = LocalVideoStorage();
  final _attendance = AttendanceService();

  /// Process raw video → split → save locally.
  /// Also writes .dur sidecar with real duration, and updates attendance log.
  Future<List<String>> processAndSaveLocally({
    required String rawVideoPath,
    required DateTime sessionTime,
    void Function(int current, int total, String message)? onProgress,
  }) async {
    final user = FirebaseAuth.instance.currentUser!;
    final userId = user.uid;
    final userEmail = user.email ?? userId;

    onProgress?.call(0, 1, 'Analysing video...');
    final durationSecs = await getDuration(rawVideoPath);
    final totalBlocks = (durationSecs / _blockSecs).ceil().clamp(1, 999);
    print('=== Processor: duration=${durationSecs}s  blocks=$totalBlocks');

    final dir = await _storage.sessionDir(sessionTime, userEmail);
    print('=== Processor: output dir = ${dir.path}');

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

      onProgress?.call(blockNum, totalBlocks + 1,
          'Processing block $blockNum of $totalBlocks...');

      // crop 9:16 → scale 1080×1920 → 30fps → no audio → H.264
      final cmd = '-i "$rawVideoPath" '
          '-ss $startSec '
          '-t $_blockSecs '
          '-vf "crop=ih*(9/16):ih,scale=1080:1920,fps=30" '
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
        throw Exception('FFmpeg block $blockNum failed: $logs');
      }
      print('=== Processor: block $blockNum saved → $outputPath');
      savedPaths.add(outputPath);
    }

    // Write .dur sidecar with actual duration next to block 1
    if (savedPaths.isNotEmpty) {
      final sidecar = savedPaths.first.replaceAll(RegExp(r'\.mp4$'), '.dur');
      await File(sidecar).writeAsString('$durationSecs');
      print('=== Processor: sidecar → $sidecar ($durationSecs s)');
    }

    // Update daily attendance log
    await _attendance.recordSession(durationSecs);

    onProgress?.call(totalBlocks + 1, totalBlocks + 1, 'Saved!');
    return savedPaths;
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