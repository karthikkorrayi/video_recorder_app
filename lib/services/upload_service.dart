import 'dart:io';
import 'package:dio/dio.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../config/user_names.dart';

/// Result of a single block upload attempt.
enum UploadBlockResult { success, failed, cancelled }

/// Callback types
typedef ProgressCallback = void Function(int blockIndex, int totalBlocks, double blockProgress);
typedef StatusCallback   = void Function(String status);

class UploadService {
  // ── CHANGE THIS to your Render.com URL after deploying ──────────────────
  static const String _backendUrl = 'https://otn-upload-backend.onrender.com';
  // ────────────────────────────────────────────────────────────────────────

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 10),
    sendTimeout:    const Duration(minutes: 10),
  ));

  bool _cancelled = false;
  bool _paused    = false;

  void pause()  => _paused = true;
  void resume() => _paused = false;
  void cancel() => _cancelled = true;

  bool get isPaused    => _paused;
  bool get isCancelled => _cancelled;

  /// Upload all blocks of a session to OneDrive.
  /// Returns the list of successfully uploaded block indices (0-based).
  Future<List<int>> uploadSession({
    required String sessionId,
    required List<String> chunkPaths,       // local file paths, in order
    required DateTime sessionTime,
    required List<int> alreadyUploaded,     // block indices already done
    required ProgressCallback onProgress,
    required StatusCallback onStatus,
  }) async {
    _cancelled = false;
    _paused    = false;

    final user  = FirebaseAuth.instance.currentUser!;
    final email = user.email ?? user.uid;

    // OneDrive folder names
    final dateFolder = DateFormat('dd-MM-yyyy').format(sessionTime);   // e.g. 08-04-2026
    final userFolder = getOneDriveFolderName(email);                   // e.g. G lavanya

    final List<int> uploaded = List.from(alreadyUploaded);
    final int total = chunkPaths.length;

    for (int i = 0; i < total; i++) {
      if (_cancelled) break;

      // Skip already uploaded blocks (resume support)
      if (uploaded.contains(i)) {
        onProgress(i + 1, total, 1.0);
        continue;
      }

      // Wait while paused
      while (_paused && !_cancelled) {
        onStatus('Paused — tap Resume to continue');
        await Future.delayed(const Duration(seconds: 2));
      }
      if (_cancelled) break;

      final filePath = chunkPaths[i];
      final file     = File(filePath);
      if (!await file.exists()) {
        onStatus('Block ${i + 1} file missing — skipping');
        continue;
      }

      final fileName = filePath.split('/').last;
      onStatus('Uploading block ${i + 1} of $total...');

      final result = await _uploadBlock(
        filePath:   filePath,
        fileName:   fileName,
        dateFolder: dateFolder,
        userFolder: userFolder,
        onProgress: (p) => onProgress(i + 1, total, p),
      );

      if (result == UploadBlockResult.success) {
        uploaded.add(i);
        onProgress(i + 1, total, 1.0);
      } else if (result == UploadBlockResult.failed) {
        onStatus('Block ${i + 1} failed — will retry on next upload attempt');
        // Continue with next block instead of stopping everything
      }
    }

    return uploaded;
  }

  /// Upload a single block file to the backend.
  Future<UploadBlockResult> _uploadBlock({
    required String filePath,
    required String fileName,
    required String dateFolder,
    required String userFolder,
    required void Function(double) onProgress,
  }) async {
    try {
      final formData = FormData.fromMap({
        'dateFolder': dateFolder,
        'userFolder': userFolder,
        'fileName':   fileName,
        'video': await MultipartFile.fromFile(filePath, filename: fileName),
      });

      await _dio.post(
        '$_backendUrl/upload',
        data: formData,
        onSendProgress: (sent, total) {
          if (total > 0) onProgress(sent / total);
        },
        options: Options(
          headers: {'Accept': 'application/json'},
        ),
      );

      return UploadBlockResult.success;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return UploadBlockResult.cancelled;
      print('Upload block error: ${e.message} — ${e.response?.data}');
      return UploadBlockResult.failed;
    } catch (e) {
      print('Upload block unexpected error: $e');
      return UploadBlockResult.failed;
    }
  }

  /// Quick health check — returns true if backend is reachable.
  Future<bool> isBackendReachable() async {
    try {
      final res = await _dio.get(
        '$_backendUrl/health',
        options: Options(receiveTimeout: const Duration(seconds: 10)),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}