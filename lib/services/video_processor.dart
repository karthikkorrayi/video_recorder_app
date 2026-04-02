import 'dart:io';
import 'package:video_compress/video_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'local_video_storage.dart';
import 'attendance_service.dart';
import 'processing_manager.dart';

class VideoProcessor {
  static const int _blockSecs = 120; // 2-minute blocks

  final _storage   = LocalVideoStorage();
  final _attendance = AttendanceService();

  /// Kick off processing in background (non-blocking).
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

      final durationSecs = await _getDuration(rawVideoPath);
      final totalBlocks = (durationSecs / _blockSecs).ceil().clamp(1, 999);
      print('=== Processor [$sessionId]: ${durationSecs}s → $totalBlocks blocks');

      // ── Step 2: Compress using native MediaCodec ──────────────────────────
      // video_compress uses Android MediaCodec — no FFmpeg needed
      // This handles: resolution scaling to 720p, codec compression
      // Audio is already disabled at recording time (enableAudio: false)
      manager.update(sessionId, ProcessingStatus(
        sessionId: sessionId, state: ProcessingState.processing,
        message: 'Compressing video...', progress: 0.15,
        currentBlock: 0, totalBlocks: totalBlocks,
      ));

      final info = await VideoCompress.compressVideo(
        rawVideoPath,
        quality: VideoQuality.MediumQuality, // 720p equivalent
        deleteOrigin: false,                 // we delete manually after
        includeAudio: false,                 // no audio (matches recording setting)
        frameRate: 30,
      );

      if (info == null || info.file == null) {
        throw Exception('Compression failed — output is null');
      }

      final compressedPath = info.file!.path;
      print('=== Processor [$sessionId]: compressed → $compressedPath');

      // ── Step 3: Split into 2-minute blocks ───────────────────────────────
      final dir = await _storage.sessionDir(sessionTime, userEmail);
      final savedPaths = <String>[];

      for (int i = 0; i < totalBlocks; i++) {
        final blockNum = i + 1;
        final progress = 0.2 + (i / totalBlocks) * 0.75;

        manager.update(sessionId, ProcessingStatus(
          sessionId: sessionId, state: ProcessingState.processing,
          message: 'Saving block $blockNum of $totalBlocks...',
          progress: progress, currentBlock: blockNum, totalBlocks: totalBlocks,
        ));

        final fileName = _storage.blockFileName(
          userId: userId, sessionTime: sessionTime,
          blockIndex: blockNum, totalBlocks: totalBlocks,
        );
        final outputPath = '${dir.path}/$fileName';

        // Trim block: copy the time-range bytes using video_compress trim
        // For single block (short video), just copy the compressed file
        if (totalBlocks == 1) {
          await File(compressedPath).copy(outputPath);
        } else {
          final startMs = i * _blockSecs * 1000;
          final endMs   = (i + 1) * _blockSecs * 1000;

          // video_compress trim — uses native MediaMuxer, very fast
          final trimmed = await VideoCompress.compressVideo(
            compressedPath,
            quality: VideoQuality.DefaultQuality, // no re-encode, just trim
            deleteOrigin: false,
            includeAudio: false,
            startTime: startMs ~/ 1000,   // seconds
            duration: _blockSecs,
          );

          if (trimmed?.file != null) {
            await trimmed!.file!.copy(outputPath);
            await trimmed.file!.delete();
          } else {
            // Fallback: copy the whole compressed if trim fails
            await File(compressedPath).copy(outputPath);
          }
        }

        savedPaths.add(outputPath);
        print('=== Processor [$sessionId]: block $blockNum → $outputPath');
      }

      // ── Step 4: Write sidecar + cleanup ──────────────────────────────────
      if (savedPaths.isNotEmpty) {
        final sidecar = savedPaths.first.replaceAll(RegExp(r'\.mp4$'), '.dur');
        await File(sidecar).writeAsString('$durationSecs');
      }

      // Cleanup temp files
      try { await File(rawVideoPath).delete(); } catch (_) {}
      try { await File(compressedPath).delete(); } catch (_) {}

      await _attendance.recordSession(durationSecs);

      manager.update(sessionId, ProcessingStatus(
        sessionId: sessionId, state: ProcessingState.done,
        message: 'Saved ${savedPaths.length} block${savedPaths.length == 1 ? '' : 's'}',
        progress: 1.0,
        currentBlock: savedPaths.length, totalBlocks: totalBlocks,
      ));

    } catch (e) {
      print('=== Processor [$sessionId]: ERROR: $e');
      manager.update(sessionId, ProcessingStatus(
        sessionId: sessionId, state: ProcessingState.error,
        message: 'Failed: $e', progress: 0,
      ));
    } finally {
      VideoCompress.cancelCompression();
    }
  }

  // ── Duration probe ────────────────────────────────────────────────────────

  Future<int> getDuration(String path) => _getDuration(path);

  static Future<int> _getDuration(String path) async {
    try {
      final info = await VideoCompress.getMediaInfo(path);
      final ms = info.duration;
      if (ms != null && ms > 0) return (ms / 1000).ceil();
    } catch (e) {
      print('=== Processor: getDuration error: $e');
    }
    return 60;
  }
}