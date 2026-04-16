import 'dart:io';
import 'package:intl/intl.dart';
import 'user_service.dart';
import 'notification_service.dart';
import 'onedrive_service.dart';

typedef ProgressCallback        = void Function(int blockIndex, int totalBlocks, double blockProgress);
typedef StatusCallback          = void Function(String status);
typedef OverallProgressCallback = void Function(double percent);

class UploadService {
  static const String _rootFolder = 'OTN Recorder';

  final _notif    = NotificationService();
  final _onedrive = OneDriveService();

  bool _cancelled = false;
  bool _paused    = false;

  void pause()  => _paused = true;
  void resume() => _paused = false;
  void cancel() => _cancelled = true;
  bool get isPaused    => _paused;
  bool get isCancelled => _cancelled;

  Future<List<int>> uploadSession({
    required String sessionId,
    required List<String> chunkPaths,   // always 1 local file
    required DateTime sessionTime,
    required List<int> alreadyUploaded,
    required ProgressCallback onProgress,
    required StatusCallback onStatus,
    OverallProgressCallback? onOverallProgress,
  }) async {
    _cancelled = false;
    _paused    = false;

    final localFile  = chunkPaths.first;
    final localF     = File(localFile);

    if (!await localF.exists()) {
      onStatus('Recording file not found');
      return alreadyUploaded;
    }

    final fileSizeMB = (await localF.length() / 1024 / 1024).toStringAsFixed(1);
    final dateFolder = DateFormat('dd-MM-yyyy').format(sessionTime);
    final userFolder = await UserService().getDisplayName();

    // Clean filename — single file, no part suffix
    final fileName = localFile.split('/').last;

    print('=== UploadService: uploading $fileName ($fileSizeMB MB) → cloud');
    onStatus('Starting upload ($fileSizeMB MB)...');
    onOverallProgress?.call(0.02);
    onProgress(1, 1, 0.0);

    // ── Upload directly — Graph API handles 10MB network slices internally ──
    // No file splitting needed. Stable for any file size. One file in cloud.
    bool success = false;
    for (int attempt = 1; attempt <= 3; attempt++) {
      if (_cancelled) break;

      if (attempt > 1) {
        onStatus('Retry attempt $attempt of 3...');
        await Future.delayed(Duration(seconds: attempt * 4));
      }

      if (_paused) {
        onStatus('Paused — tap Resume to continue');
        while (_paused && !_cancelled) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      if (_cancelled) break;

      try {
        await _onedrive.uploadFile(
          filePath:    localFile,
          fileName:    fileName,
          dateFolder:  dateFolder,
          userFolder:  userFolder,
          rootFolder:  _rootFolder,
          isPaused:    () => _paused,
          isCancelled: () => _cancelled,
          onProgress: (p) {
            onProgress(1, 1, p);
            // 2% prep + 96% upload + 2% wrap-up
            final overall = 0.02 + p * 0.96;
            onOverallProgress?.call(overall.clamp(0.0, 0.98));
            _notif.showUploadProgress(
              block: 1, total: 1,
              percentDone: (overall * 100).round());
          },
          onStatus: onStatus,
        );
        success = true;
        break;
      } catch (e) {
        print('=== Upload attempt $attempt failed: $e');
        if (attempt < 3) {
          onStatus('Upload failed, retrying... ($e)');
        } else {
          onStatus('Upload failed after 3 attempts: $e');
        }
      }
    }

    if (!success) {
      _notif.showUploadFailed('Upload failed — tap retry');
      return alreadyUploaded;
    }

    // ── Success ───────────────────────────────────────────────────────────────
    onStatus('Upload complete ✓  File saved to cloud storage');
    onOverallProgress?.call(1.0);
    onProgress(1, 1, 1.0);
    _notif.showUploadComplete(1);

    // Delete local file after confirmed upload
    try { await localF.delete(); } catch (_) {}

    return [0]; // mark block 0 as uploaded
  }
}