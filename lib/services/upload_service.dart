import 'dart:io';
import 'package:dio/dio.dart';
import 'package:intl/intl.dart';
import 'user_service.dart';
import 'video_processor.dart';
import 'notification_service.dart';

enum UploadBlockResult { success, failed, cancelled }

typedef ProgressCallback = void Function(int blockIndex, int totalBlocks, double blockProgress);
typedef StatusCallback   = void Function(String status);
// NEW: overall percent callback for history screen inline progress
typedef OverallProgressCallback = void Function(double percent);

class UploadService {
  static const String _backendUrl = 'https://video-recorder-app-d7zk.onrender.com';

  final _notif = NotificationService();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 60),
    receiveTimeout: const Duration(minutes: 30),
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
    required List<String> chunkPaths, // single file path locally
    required DateTime sessionTime,
    required List<int> alreadyUploaded,
    required ProgressCallback onProgress,
    required StatusCallback onStatus,
    OverallProgressCallback? onOverallProgress,
  }) async {
    _cancelled = false;
    _paused    = false;

    final dateFolder = DateFormat('dd-MM-yyyy').format(sessionTime);
    final userFolder = await UserService().getDisplayName();
    final localFile  = chunkPaths.first; // always 1 file locally

    if (!await File(localFile).exists()) {
      onStatus('File not found');
      return alreadyUploaded;
    }

    // ── Step 1: Split local file into 5-min upload chunks ─────────────────
    onStatus('Preparing upload chunks...');
    onOverallProgress?.call(0.02);

    List<String> uploadChunks;
    try {
      uploadChunks = await VideoProcessor().splitForUpload(localFile, sessionTime);
    } catch (e) {
      onStatus('Split failed: $e');
      return alreadyUploaded;
    }

    if (uploadChunks.isEmpty) {
      onStatus('No chunks created');
      return alreadyUploaded;
    }

    final total       = uploadChunks.length;
    final sessionName = localFile.split('/').last.replaceAll('.mp4', '');

    print('=== UploadService: $total chunk(s) → $dateFolder/$userFolder');

    // ── Step 2: Upload each chunk ──────────────────────────────────────────
    int successCount = 0;

    for (int i = 0; i < total; i++) {
      if (_cancelled) break;

      while (_paused && !_cancelled) {
        onStatus('Paused — tap Resume to continue');
        await Future.delayed(const Duration(seconds: 2));
      }
      if (_cancelled) break;

      final chunkPath = uploadChunks[i];
      final chunkFile = File(chunkPath);
      if (!await chunkFile.exists()) { successCount++; continue; }

      final chunkName = chunkPath.split('/').last;
      onStatus('Uploading part ${i + 1} of $total...');

      // Overall progress: 5% prep + 90% upload + 5% merge
      final baseProgress = 0.05 + (i / total) * 0.90;
      onOverallProgress?.call(baseProgress);
      onProgress(i + 1, total, 0.0);

      // Retry up to 3 times
      UploadBlockResult result = UploadBlockResult.failed;
      for (int attempt = 1; attempt <= 3; attempt++) {
        if (_cancelled) break;
        if (attempt > 1) {
          onStatus('Retry part ${i + 1} (attempt $attempt)...');
          await Future.delayed(Duration(seconds: attempt * 3));
        }
        result = await _uploadChunk(
          filePath:    chunkPath,
          fileName:    chunkName,
          dateFolder:  dateFolder,
          userFolder:  userFolder,
          sessionName: sessionName,
          chunkIndex:  i + 1,
          totalChunks: total,
          onProgress: (p) {
            onProgress(i + 1, total, p);
            final overall = 0.05 + (i + p) / total * 0.90;
            onOverallProgress?.call(overall.clamp(0.0, 0.95));
            // Update notification
            _notif.showUploadProgress(
              block: i + 1, total: total,
              percentDone: (overall * 100).round());
          },
        );
        if (result == UploadBlockResult.success) break;
      }

      if (result == UploadBlockResult.success) {
        successCount++;
        onProgress(i + 1, total, 1.0);
        // Delete temp chunk (NOT the original local file yet)
        if (chunkPath != localFile) {
          try { await chunkFile.delete(); } catch (_) {}
        }
      } else {
        onStatus('Part ${i + 1} failed after 3 attempts');
      }
    }

    // ── Step 3: Check if all chunks uploaded ──────────────────────────────
    if (successCount < total) {
      onStatus('Upload incomplete — $successCount/$total parts uploaded');
      _notif.showUploadFailed('Upload incomplete');
      return alreadyUploaded;
    }

    // ── Step 4: Backend merge complete — delete original local file ────────
    onStatus('All parts uploaded — backend merging into single file...');
    onOverallProgress?.call(0.97);

    // Wait briefly for backend to finish merge
    await Future.delayed(const Duration(seconds: 3));

    onStatus('Upload complete ✓ Single file in OneDrive');
    onOverallProgress?.call(1.0);
    _notif.showUploadComplete(total);

    // Delete original local session file
    try { await File(localFile).delete(); } catch (_) {}

    // Return all indices as uploaded
    return List.generate(chunkPaths.length, (i) => i);
  }

  Future<UploadBlockResult> _uploadChunk({
    required String filePath,
    required String fileName,
    required String dateFolder,
    required String userFolder,
    required String sessionName,
    required int    chunkIndex,
    required int    totalChunks,
    required void Function(double) onProgress,
  }) async {
    try {
      final fileSize = await File(filePath).length();
      print('=== Chunk $chunkIndex/$totalChunks: $fileName (${(fileSize/1024/1024).toStringAsFixed(1)}MB)');

      final formData = FormData.fromMap({
        'dateFolder':   dateFolder,
        'userFolder':   userFolder,
        'fileName':     fileName,
        'sessionName':  sessionName, // used by backend to group chunks for merge
        'totalChunks':  totalChunks.toString(),
        'chunkIndex':   chunkIndex.toString(),
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
        return UploadBlockResult.success;
      }
      print('=== Chunk failed: ${response.statusCode} ${response.data}');
      return UploadBlockResult.failed;

    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return UploadBlockResult.cancelled;
      print('=== DioException: ${e.message}');
      return UploadBlockResult.failed;
    } catch (e) {
      print('=== Chunk exception: $e');
      return UploadBlockResult.failed;
    }
  }

  Future<bool> isBackendReachable() async {
    try {
      final res = await _dio.get('$_backendUrl/health',
          options: Options(receiveTimeout: const Duration(seconds: 30)));
      return res.statusCode == 200;
    } catch (_) { return false; }
  }
}