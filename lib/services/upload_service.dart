import 'dart:io';
import 'package:dio/dio.dart';
import 'package:intl/intl.dart';
import 'user_service.dart';

enum UploadBlockResult { success, failed, cancelled }

typedef ProgressCallback = void Function(int blockIndex, int totalBlocks, double blockProgress);
typedef StatusCallback   = void Function(String status);

class UploadService {
  static const String _backendUrl = 'https://video-recorder-app-d7zk.onrender.com';

  // ── Longer timeouts — video files are large ──────────────────────────────
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 60),  // Render cold start can take 30s
    receiveTimeout: const Duration(minutes: 15),  // Large files need time
    sendTimeout:    const Duration(minutes: 15),
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
    print('=== UploadService: uploading to $dateFolder/$userFolder');

    final List<int> uploaded = List.from(alreadyUploaded);
    final int total = chunkPaths.length;

    for (int i = 0; i < total; i++) {
      if (_cancelled) break;
      if (uploaded.contains(i)) {
        onProgress(i + 1, total, 1.0);
        continue;
      }

      while (_paused && !_cancelled) {
        onStatus('Paused — tap Resume to continue');
        await Future.delayed(const Duration(seconds: 2));
      }
      if (_cancelled) break;

      final filePath = chunkPaths[i];
      final file = File(filePath);
      if (!await file.exists()) {
        onStatus('Block ${i + 1} file not found — skipping');
        uploaded.add(i); // mark done so we don't retry
        continue;
      }

      final fileName = filePath.split('/').last;
      onStatus('Uploading block ${i + 1} of $total...');

      // Retry up to 3 times per block
      UploadBlockResult result = UploadBlockResult.failed;
      for (int attempt = 1; attempt <= 3; attempt++) {
        if (_cancelled) break;
        if (attempt > 1) {
          onStatus('Retrying block ${i + 1} (attempt $attempt)...');
          await Future.delayed(Duration(seconds: attempt * 2));
        }
        result = await _uploadBlock(
          filePath: filePath, fileName: fileName,
          dateFolder: dateFolder, userFolder: userFolder,
          onProgress: (p) => onProgress(i + 1, total, p),
        );
        if (result == UploadBlockResult.success) break;
      }

      if (result == UploadBlockResult.success) {
        uploaded.add(i);
        onProgress(i + 1, total, 1.0);
        // Delete local file after confirmed upload
        try {
          await file.delete();
          print('=== Deleted local: $fileName');
        } catch (e) {
          print('=== Could not delete local: $e');
        }
      } else if (result == UploadBlockResult.failed) {
        onStatus('Block ${i + 1} failed after 3 attempts');
      }
    }
    return uploaded;
  }

  Future<UploadBlockResult> _uploadBlock({
    required String filePath,
    required String fileName,
    required String dateFolder,
    required String userFolder,
    required void Function(double) onProgress,
  }) async {
    try {
      final file = File(filePath);
      final fileSize = await file.length();
      print('=== Uploading: $fileName (${(fileSize/1024/1024).toStringAsFixed(1)}MB)');

      final formData = FormData.fromMap({
        'dateFolder': dateFolder,
        'userFolder': userFolder,
        'fileName':   fileName,
        'video': await MultipartFile.fromFile(filePath, filename: fileName),
      });

      final response = await _dio.post(
        '$_backendUrl/upload',
        data: formData,
        onSendProgress: (sent, total) {
          if (total > 0) {
            final progress = sent / total;
            onProgress(progress);
            if (sent % (5 * 1024 * 1024) < 65536) { // log every ~5MB
              print('=== Upload progress: ${(progress * 100).toStringAsFixed(0)}%');
            }
          }
        },
        options: Options(
          // Explicitly allow both WiFi and mobile data (Dio uses system default,
          // which already allows both — this just makes it explicit)
          headers: { 'Accept': 'application/json' },
          validateStatus: (status) => status != null && status < 600,
        ),
      );

      if (response.statusCode == 200 && response.data['success'] == true) {
        print('=== Block upload success: ${response.data['path']}');
        return UploadBlockResult.success;
      } else {
        print('=== Block upload failed: status=${response.statusCode} body=${response.data}');
        return UploadBlockResult.failed;
      }

    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return UploadBlockResult.cancelled;
      print('=== DioException: type=${e.type} msg=${e.message}');
      if (e.response != null) print('=== Response: ${e.response?.statusCode} ${e.response?.data}');
      return UploadBlockResult.failed;
    } catch (e) {
      print('=== Upload unexpected error: $e');
      return UploadBlockResult.failed;
    }
  }

  Future<bool> isBackendReachable() async {
    try {
      final res = await _dio.get('$_backendUrl/health',
          options: Options(receiveTimeout: const Duration(seconds: 30)));
      return res.statusCode == 200;
    } catch (e) {
      print('=== Backend unreachable: $e');
      return false;
    }
  }
}