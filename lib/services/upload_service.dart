import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'user_service.dart';
import 'notification_service.dart';
import 'onedrive_service.dart';

typedef ProgressCallback        = void Function(int blockIndex, int totalBlocks, double blockProgress);
typedef StatusCallback          = void Function(String status);
typedef OverallProgressCallback = void Function(double percent);

class UploadService {
  static const String _rootFolder = 'OTN Recorder';

  // ── Compression settings ──────────────────────────────────────────────────
  // H.265 (HEVC) at 4Mbps gives excellent quality for meeting recordings
  // while reducing 2.74GB files to ~550MB — 5x smaller, same visual quality.
  // CRF 28 = good quality. Lower = better quality, larger file.
  static const int    _targetBitrate = 4000; // kbps
  // libx264 is always available in ffmpeg_kit_flutter_new full-gpl
  // Gives ~3x file reduction vs raw (2.74GB → ~900MB) vs libx265 5x
  // but libx265 fails on Vivo I2217 hardware encoder
  static const String _videoCodec    = 'libx264';
  static const int    _crf           = 28;

  final _notif    = NotificationService();
  final _onedrive = OneDriveService();

  bool _cancelled = false;
  bool _paused    = false;

  void pause()  => _paused = true;
  void resume() => _paused = false;
  void cancel() => _cancelled = true;

  Future<List<int>> uploadSession({
    required String sessionId,
    required List<String> chunkPaths,
    required DateTime sessionTime,
    required List<int> alreadyUploaded,
    required ProgressCallback onProgress,
    required StatusCallback onStatus,
    OverallProgressCallback? onOverallProgress,
  }) async {
    _cancelled = false;
    _paused    = false;

    final localFile = chunkPaths.first;
    final localF    = File(localFile);

    if (!await localF.exists()) {
      onStatus('Recording file not found');
      return alreadyUploaded;
    }

    final originalSizeMB = await localF.length() / 1024 / 1024;
    final dateFolder     = DateFormat('dd-MM-yyyy').format(sessionTime);
    final userFolder     = await UserService().getDisplayName();
    final fileName       = localFile.split('/').last;

    // ── Step 1: Compress before upload ────────────────────────────────────
    // Only compress if file is >200MB (small test recordings skip compression)
    String uploadPath   = localFile;
    String uploadName   = fileName;
    bool   compressed   = false;
    File?  compressedFile;

    if (originalSizeMB > 100) { // compress anything over 100MB
      onStatus('Compressing video for faster upload...');
      onOverallProgress?.call(0.01);

      final result = await _compress(
        inputPath:  localFile,
        onProgress: (p) {
          onStatus('Compressing ${(p * 100).toStringAsFixed(0)}%... '
              '(reduces file size ~3x for faster upload)');
          onOverallProgress?.call(0.01 + p * 0.19); // 1–20% = compression
        },
      );

      if (result != null) {
        compressedFile  = File(result);
        final newSizeMB = await compressedFile.length() / 1024 / 1024;
        uploadPath      = result;
        uploadName      = fileName.replaceAll('.mp4', '_compressed.mp4');
        compressed      = true;
        onStatus('Compressed: ${originalSizeMB.toStringAsFixed(0)}MB → '
            '${newSizeMB.toStringAsFixed(0)}MB');
        debugPrint('=== Compressed ${originalSizeMB.toStringAsFixed(0)}MB → '
            '${newSizeMB.toStringAsFixed(0)}MB');
      } else {
        // Compression failed — upload original
        onStatus('Compression skipped, uploading original...');
        debugPrint('=== Compression failed, uploading original');
      }
    }

    final uploadSizeMB = (await File(uploadPath).length() / 1024 / 1024)
        .toStringAsFixed(1);
    onStatus('Uploading $uploadSizeMB MB...');
    onOverallProgress?.call(0.20);
    onProgress(1, 1, 0.0);

    // ── Step 2: Upload ────────────────────────────────────────────────────
    bool success = false;
    for (int attempt = 1; attempt <= 3; attempt++) {
      if (_cancelled) break;
      if (attempt > 1) {
        onStatus('Retry attempt $attempt of 3...');
        await Future.delayed(Duration(seconds: attempt * 5));
      }

      while (_paused && !_cancelled) {
        onStatus('Paused — tap Resume to continue');
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (_cancelled) break;

      try {
        await _onedrive.uploadFile(
          filePath:    uploadPath,
          fileName:    uploadName,
          dateFolder:  dateFolder,
          userFolder:  userFolder,
          rootFolder:  _rootFolder,
          isPaused:    () => _paused,
          isCancelled: () => _cancelled,
          onProgress: (p) {
            onProgress(1, 1, p);
            final overall = 0.20 + p * 0.78; // 20–98%
            onOverallProgress?.call(overall.clamp(0.0, 0.98));
            _notif.showUploadProgress(
                block: 1, total: 1, percentDone: (overall * 100).round());
          },
          onStatus: onStatus,
        );
        success = true;
        break;
      } catch (e) {
        debugPrint('=== Upload attempt $attempt failed: $e');
        onStatus(attempt < 3
            ? 'Upload failed, retrying...'
            : 'Upload failed after 3 attempts');
      }
    }

    // ── Cleanup compressed file ───────────────────────────────────────────
    if (compressed && compressedFile != null) {
      try { await compressedFile.delete(); } catch (_) {}
    }

    if (!success) {
      _notif.showUploadFailed('Upload failed — tap retry');
      return alreadyUploaded;
    }

    onStatus('Upload complete ✓');
    onOverallProgress?.call(1.0);
    onProgress(1, 1, 1.0);
    _notif.showUploadComplete(1);

    // Delete local original after confirmed upload
    try { await localF.delete(); } catch (_) {}

    return [0];
  }

  // ── H.265 compression ─────────────────────────────────────────────────────
  // Input:  original 1080p H.264 at 20Mbps (~2.74GB/20min)
  // Output: 1080p H.265 at 4Mbps  (~550MB/20min) — 5x smaller, same quality
  // Time:   ~3-5 min on phone CPU (runs in background, non-blocking)
  Future<String?> _compress({
    required String inputPath,
    required void Function(double) onProgress,
  }) async {
    try {
      final tmpDir  = await getTemporaryDirectory();
      final outPath = '${tmpDir.path}/otn_upload_compressed_'
          '${DateTime.now().millisecondsSinceEpoch}.mp4';

      // Get duration for progress calculation
      double durationSec = 0;
      try {
        final probe   = await FFmpegKit.execute('-i "$inputPath" -f null -');
        final logs    = await probe.getAllLogsAsString() ?? '';
        final match   = RegExp(r'Duration:\s*(\d+):(\d+):(\d+\.?\d*)')
            .firstMatch(logs);
        if (match != null) {
          durationSec = int.parse(match.group(1)!) * 3600.0
              + int.parse(match.group(2)!) * 60.0
              + double.parse(match.group(3)!);
        }
      } catch (_) {}

      // H.265 compression command
      // -vcodec libx265  = H.265 encoder (5x more efficient than H.264)
      // -crf 28          = quality level (18=lossless, 28=good, 51=worst)
      // -preset fast     = encoding speed vs compression ratio
      // -acodec aac      = audio stays as AAC
      // -movflags +faststart = playable immediately without full download
      // -crf 28: quality level (18=near-lossless, 28=good, 35=acceptable)
      // -preset veryfast: fastest encoding, slightly larger than 'fast' but much quicker
      // No -b:v: let CRF control bitrate (more consistent quality)
      // -tune fastdecode: optimise for playback on mobile
      final cmd = '-i "$inputPath" '
          '-vcodec $_videoCodec '
          '-crf $_crf '
          '-preset veryfast '
          '-tune fastdecode '
          '-acodec aac '
          '-b:a 128k '
          '-movflags +faststart '
          '-threads 0 '
          '-y "$outPath"';

      debugPrint('=== Compressing: ${cmd.substring(0, 60)}...');

      // Run with progress tracking via log callback
      double lastProgress = 0;
      final session = await FFmpegKit.executeAsync(
        cmd,
        null, // completion callback
        null, // log callback
        (statistics) {
          if (durationSec > 0 && statistics.getTime() > 0) {
            final p = (statistics.getTime() / 1000 / durationSec).clamp(0.0, 0.99);
            if (p > lastProgress + 0.02) {
              lastProgress = p;
              onProgress(p);
            }
          }
        },
      );

      final rc = await session.getReturnCode();
      if (!ReturnCode.isSuccess(rc)) {
        final logs = await session.getAllLogsAsString();
        debugPrint('=== Compression failed: ${logs?.substring(0, 200)}');
        return null;
      }

      final outFile = File(outPath);
      if (!await outFile.exists() || await outFile.length() < 1024) {
        return null;
      }

      onProgress(1.0);
      return outPath;
    } catch (e) {
      debugPrint('=== Compression exception: $e');
      return null;
    }
  }
}