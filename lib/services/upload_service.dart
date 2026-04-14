import 'dart:io';
import 'package:dio/dio.dart';
import 'package:intl/intl.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'user_service.dart';

enum UploadBlockResult { success, failed, cancelled }

typedef ProgressCallback = void Function(int blockIndex, int totalBlocks, double blockProgress);
typedef StatusCallback   = void Function(String status);

class UploadService {
  static const String _backendUrl = 'https://otn-upload-backend.onrender.com';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 60),
    receiveTimeout: const Duration(minutes: 30), // large merged file needs time
    sendTimeout:    const Duration(minutes: 30),
  ));

  bool _cancelled = false;
  bool _paused    = false;

  void pause()  => _paused = true;
  void resume() => _paused = false;
  void cancel() => _cancelled = true;
  bool get isPaused    => _paused;
  bool get isCancelled => _cancelled;

  Future<List<int>> uploadSession({
    required String sessionId,
    required List<String> chunkPaths,
    required DateTime sessionTime,
    required List<int> alreadyUploaded,
    required ProgressCallback onProgress,
    required StatusCallback onStatus,
  }) async {
    _cancelled = false;
    _paused    = false;

    final dateFolder = DateFormat('dd-MM-yyyy').format(sessionTime);
    final userFolder = await UserService().getDisplayName();

    // ── Single chunk — upload directly, no merge needed ──────────────────
    if (chunkPaths.length == 1) {
      final file = File(chunkPaths[0]);
      if (!await file.exists()) {
        onStatus('File not found');
        return alreadyUploaded;
      }

      // Clean filename: remove block suffix for single-block sessions
      final rawName   = chunkPaths[0].split('/').last;
      final cleanName = rawName.replaceAll(RegExp(r'_block01of01\.mp4$'), '.mp4');

      onStatus('Uploading...');
      final result = await _uploadSingleFile(
        filePath:   chunkPaths[0],
        fileName:   cleanName,
        dateFolder: dateFolder,
        userFolder: userFolder,
        onProgress: (p) => onProgress(1, 1, p),
      );

      if (result == UploadBlockResult.success) {
        onStatus('Upload complete ✓');
        try { await file.delete(); } catch (_) {}
        return [0];
      } else {
        onStatus('Upload failed — tap retry');
        return alreadyUploaded;
      }
    }

    // ── Multiple chunks — merge on phone first, then upload ───────────────
    onStatus('Preparing: merging ${chunkPaths.length} chunks on device...');
    onProgress(0, 1, 0.0);

    // Check all chunks exist
    for (int i = 0; i < chunkPaths.length; i++) {
      if (!await File(chunkPaths[i]).exists()) {
        onStatus('Chunk ${i + 1} file missing — cannot merge');
        return alreadyUploaded;
      }
    }

    // Build merged output path next to the first chunk
    final firstChunk  = chunkPaths[0];
    final dir         = firstChunk.substring(0, firstChunk.lastIndexOf('/'));
    final rawName     = firstChunk.split('/').last;
    // Remove block suffix: uid_20260414_110000_block01of04.mp4 → uid_20260414_110000.mp4
    final mergedName  = rawName.replaceAll(RegExp(r'_block\d+of\d+\.mp4$'), '.mp4');
    final mergedPath  = '$dir/$mergedName';

    onStatus('Merging chunks on device (lossless)...');

    final mergeSuccess = await _mergeChunksOnDevice(
      chunkPaths:  chunkPaths,
      outputPath:  mergedPath,
      onStatus:    onStatus,
    );

    if (!mergeSuccess) {
      onStatus('Merge failed — trying individual upload as fallback');
      // Fallback: upload chunks individually if merge fails
      return await _uploadChunksIndividually(
        chunkPaths:      chunkPaths,
        dateFolder:      dateFolder,
        userFolder:      userFolder,
        alreadyUploaded: alreadyUploaded,
        onProgress:      onProgress,
        onStatus:        onStatus,
      );
    }

    final mergedFile = File(mergedPath);
    final mergedSize = await mergedFile.length();
    onStatus('Merge done (${(mergedSize / 1024 / 1024).toStringAsFixed(0)}MB) — uploading...');
    onProgress(0, 1, 0.05);

    // Pause/cancel check before upload
    while (_paused && !_cancelled) {
      onStatus('Paused — tap Resume to continue');
      await Future.delayed(const Duration(seconds: 2));
    }
    if (_cancelled) {
      try { await mergedFile.delete(); } catch (_) {}
      return alreadyUploaded;
    }

    // Upload the single merged file
    final result = await _uploadSingleFile(
      filePath:   mergedPath,
      fileName:   mergedName,
      dateFolder: dateFolder,
      userFolder: userFolder,
      onProgress: (p) => onProgress(1, 1, 0.05 + p * 0.95),
    );

    if (result == UploadBlockResult.success) {
      onStatus('Upload complete — single file in OneDrive ✓');
      // Delete merged file
      try { await mergedFile.delete(); } catch (_) {}
      // Delete all original chunks
      for (final path in chunkPaths) {
        try { await File(path).delete(); } catch (_) {}
      }
      // Return all indices as uploaded
      return List.generate(chunkPaths.length, (i) => i);
    } else {
      onStatus('Upload failed — tap retry');
      // Keep chunks, delete failed merged file
      try { await mergedFile.delete(); } catch (_) {}
      return alreadyUploaded;
    }
  }

  // ── FFmpeg merge on device ────────────────────────────────────────────────
  Future<bool> _mergeChunksOnDevice({
    required List<String> chunkPaths,
    required String outputPath,
    required StatusCallback onStatus,
  }) async {
    try {
      // Delete any previous failed merge attempt
      final out = File(outputPath);
      if (await out.exists()) await out.delete();

      // Build FFmpeg concat command
      // -f concat -safe 0 = use a text list of files
      // -c copy            = lossless, no re-encode (very fast)
      // -movflags faststart = web-friendly MP4
      final inputList = chunkPaths.map((p) => '-i "$p"').join(' ');
      final filterComplex = chunkPaths.asMap().entries
          .map((e) => '[${e.key}:v][${e.key}:a]')
          .join('') +
          'concat=n=${chunkPaths.length}:v=1:a=0[outv]';

      // Use concat demuxer (fastest and most reliable for same-format files)
      // Write a temp file list
      final listPath = '${outputPath}.concat.txt';
      final listContent = chunkPaths.map((p) => "file '$p'").join('\n');
      await File(listPath).writeAsString(listContent);

      final cmd = '-f concat -safe 0 -i "$listPath" -c copy -movflags +faststart "$outputPath"';
      print('=== Merging ${chunkPaths.length} chunks → $outputPath');

      final session = await FFmpegKit.execute(cmd);
      final rc      = await session.getReturnCode();

      // Clean up list file
      try { await File(listPath).delete(); } catch (_) {}

      if (ReturnCode.isSuccess(rc)) {
        final size = await File(outputPath).length();
        print('=== Merge success: ${(size/1024/1024).toStringAsFixed(1)}MB');
        return true;
      } else {
        final logs = await session.getAllLogsAsString();
        print('=== Merge failed: $logs');
        return false;
      }
    } catch (e) {
      print('=== Merge exception: $e');
      return false;
    }
  }

  // ── Upload a single file (streaming, handles any size) ────────────────────
  Future<UploadBlockResult> _uploadSingleFile({
    required String filePath,
    required String fileName,
    required String dateFolder,
    required String userFolder,
    required void Function(double) onProgress,
  }) async {
    try {
      final fileSize = await File(filePath).length();
      print('=== Uploading: $fileName (${(fileSize/1024/1024).toStringAsFixed(1)}MB)');

      final formData = FormData.fromMap({
        'dateFolder':  dateFolder,
        'userFolder':  userFolder,
        'fileName':    fileName,
        'totalBlocks': '1',       // always 1 — already merged
        'blockIndex':  '1',
        'video': await MultipartFile.fromFile(filePath, filename: fileName),
      });

      final response = await _dio.post(
        '$_backendUrl/upload',
        data: formData,
        onSendProgress: (sent, total) {
          if (total > 0) onProgress(sent / total);
        },
        options: Options(
          validateStatus: (s) => s != null && s < 600,
          headers: {'Accept': 'application/json'},
        ),
      );

      if (response.statusCode == 200 && response.data['success'] == true) {
        print('=== Upload success: ${response.data['path']}');
        return UploadBlockResult.success;
      }
      print('=== Upload failed: ${response.statusCode} ${response.data}');
      return UploadBlockResult.failed;

    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return UploadBlockResult.cancelled;
      print('=== DioException: ${e.type} ${e.message}');
      return UploadBlockResult.failed;
    } catch (e) {
      print('=== Upload exception: $e');
      return UploadBlockResult.failed;
    }
  }

  // ── Fallback: upload chunks individually if merge fails ───────────────────
  Future<List<int>> _uploadChunksIndividually({
    required List<String> chunkPaths,
    required String dateFolder,
    required String userFolder,
    required List<int> alreadyUploaded,
    required ProgressCallback onProgress,
    required StatusCallback onStatus,
  }) async {
    final uploaded = List<int>.from(alreadyUploaded);
    for (int i = 0; i < chunkPaths.length; i++) {
      if (uploaded.contains(i)) continue;
      if (_cancelled) break;

      final file = File(chunkPaths[i]);
      if (!await file.exists()) { uploaded.add(i); continue; }

      onStatus('Fallback: uploading chunk ${i + 1} of ${chunkPaths.length}...');
      final result = await _uploadSingleFile(
        filePath:   chunkPaths[i],
        fileName:   chunkPaths[i].split('/').last,
        dateFolder: dateFolder,
        userFolder: userFolder,
        onProgress: (p) => onProgress(i + 1, chunkPaths.length, p),
      );
      if (result == UploadBlockResult.success) {
        uploaded.add(i);
        try { await file.delete(); } catch (_) {}
      }
    }
    return uploaded;
  }

  Future<bool> isBackendReachable() async {
    try {
      final res = await _dio.get('$_backendUrl/health',
          options: Options(receiveTimeout: const Duration(seconds: 30)));
      return res.statusCode == 200;
    } catch (_) { return false; }
  }
}