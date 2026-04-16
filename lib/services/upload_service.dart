import 'dart:io';
import 'package:intl/intl.dart';
import 'user_service.dart';
import 'video_processor.dart';
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
    required List<String> chunkPaths,   // single local file
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
    final localFile  = chunkPaths.first;

    if (!await File(localFile).exists()) {
      onStatus('Local file not found');
      return alreadyUploaded;
    }

    // ── Step 1: Split into 5-min upload chunks ────────────────────────────
    onStatus('Splitting into upload chunks...');
    onOverallProgress?.call(0.02);

    List<String> uploadChunks;
    try {
      uploadChunks = await VideoProcessor().splitForUpload(localFile, sessionTime);
    } catch (e) {
      onStatus('Split failed: $e');
      return alreadyUploaded;
    }

    if (uploadChunks.isEmpty) {
      onStatus('No chunks to upload');
      return alreadyUploaded;
    }

    final total       = uploadChunks.length;
    final sessionName = localFile.split('/').last.replaceAll('.mp4', '');
    print('=== UploadService: $total chunk(s) → direct to Cloud Storage');

    // ── Step 2: Upload each chunk directly phone → Cloud Storage ───────────────
    int successCount = 0;

    for (int i = 0; i < total; i++) {
      if (_cancelled) break;

      while (_paused && !_cancelled) {
        onStatus('Paused — tap Resume to continue');
        await Future.delayed(const Duration(seconds: 2));
      }
      if (_cancelled) break;

      final chunkPath = uploadChunks[i];
      if (!await File(chunkPath).exists()) { successCount++; continue; }

      // Chunk file name: sessionName_chunk01of04.mp4
      final chunkNum  = i + 1;

      // For single chunk, use clean name without suffix
      final uploadName = total == 1
          ? '$sessionName.mp4'
          : '${sessionName}_part${chunkNum.toString().padLeft(2,'0')}of'
            '${total.toString().padLeft(2,'0')}.mp4';

      onStatus(total > 1
          ? 'Uploading part $chunkNum of $total...'
          : 'Uploading...');

      final baseProgress = 0.05 + (i / total) * 0.90;
      onOverallProgress?.call(baseProgress);
      onProgress(chunkNum, total, 0.0);

      bool success = false;
      for (int attempt = 1; attempt <= 3; attempt++) {
        if (_cancelled) break;
        if (attempt > 1) {
          onStatus('Retry part $chunkNum (attempt $attempt)...');
          await Future.delayed(Duration(seconds: attempt * 3));
        }
        try {
          await _onedrive.uploadFile(
            filePath:    chunkPath,
            fileName:    uploadName,
            dateFolder:  dateFolder,
            userFolder:  userFolder,
            rootFolder:  _rootFolder,
            isPaused:    () => _paused,
            isCancelled: () => _cancelled,
            onProgress: (p) {
              onProgress(chunkNum, total, p);
              final overall = 0.05 + (i + p) / total * 0.90;
              onOverallProgress?.call(overall.clamp(0.0, 0.95));
              _notif.showUploadProgress(
                block: chunkNum, total: total,
                percentDone: (overall * 100).round());
            },
            onStatus: (s) => onStatus(s),
          );
          success = true;
          break;
        } catch (e) {
          print('=== Chunk $chunkNum attempt $attempt failed: $e');
          if (attempt == 3) onStatus('Part $chunkNum failed: $e');
        }
      }

      if (success) {
        successCount++;
        onProgress(chunkNum, total, 1.0);
        // Delete temp chunk (not the original file)
        if (chunkPath != localFile) {
          try { await File(chunkPath).delete(); } catch (_) {}
        }
      }
    }

    if (successCount < total) {
      onStatus('Incomplete — $successCount/$total parts uploaded');
      _notif.showUploadFailed('Upload incomplete');
      return alreadyUploaded;
    }

    // ── Step 3: All parts uploaded — delete local session file ────────────
    onStatus('Upload complete ✓ ${total > 1 ? "$total parts in Cloud Storage" : "File in Cloud Storage"}');
    onOverallProgress?.call(1.0);
    _notif.showUploadComplete(total);

    try { await File(localFile).delete(); } catch (_) {}

    return List.generate(chunkPaths.length, (i) => i);
  }
}