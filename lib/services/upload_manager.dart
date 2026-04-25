import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'onedrive_service.dart';
import 'session_store.dart';
import 'user_service.dart'; // ← replaces user_names.dart

/// Manages the upload of all parts of one session to OneDrive.
/// - Resolves user display name via [UserService] (Firebase-based)
/// - Builds folder path ONCE using session START time → all parts in ONE folder
/// - Supports pause / resume / cancel
/// - Retries each part up to 4 times before marking pending
/// - Deletes local file after each successful part upload
class UploadManager {
  final SessionModel session;
  final void Function(double progress, int part, int total)? onProgress;
  final void Function(String status)? onStatusChange;

  bool _isPaused = false;
  bool _isCancelled = false;

  bool get isPaused => _isPaused;

  UploadManager({
    required this.session,
    this.onProgress,
    this.onStatusChange,
  });

  void pause() => _isPaused = true;
  void resume() => _isPaused = false;
  void cancel() => _isCancelled = true;

  Future<void> start() async {
    final store = await SessionStore.load();
    session.status = 'uploading';
    await store.updateSession(session);
    onStatusChange?.call('uploading');

    // ── Resolve user name from Firebase (cached) ──────────────────────────
    // No static map / user_names.dart needed here.
    final userFullName = await UserService().getDisplayName();

    // ── Build folder path ONCE using session START time ───────────────────
    // All parts share the same folderPath → land in ONE OneDrive folder.
    // Format: OTN Recorder/DD-MM-YYYY/UserFullName/SessionID_Date_StartTime
    final folderPath = OneDriveService.buildSessionFolderPath(
      dateFolder: session.dateFolder,         // DD-MM-YYYY
      userFullName: userFullName,             // from Firebase, not static map
      sessionId: session.sessionId,           // e.g. 9NE5B0
      sessionDate: session.sessionDate,       // YYYYMMDD
      sessionStartTime: session.startTime,    // HHmmss — START only, never stop
    );
    // ─────────────────────────────────────────────────────────────────────

    for (int i = session.uploadedBlocks.length;
        i < session.localChunkPaths.length;
        i++) {
      if (_isCancelled) break;

      await _waitForReady();
      if (_isCancelled) break;

      final file = File(session.localChunkPaths[i]);
      final partName = i < session.partNames.length
          ? session.partNames[i]
          : _defaultPartName(i);

      if (!await file.exists()) {
        // Already uploaded + deleted locally, or lost — skip
        session.uploadedBlocks = List.generate(i + 1, (i) => i);
        await store.updateSession(session);
        continue;
      }

      bool partDone = false;
      for (int attempt = 0; attempt < 4 && !partDone; attempt++) {
        try {
          final uploadUrl = await OneDriveService.createUploadSession(
            folderPath: folderPath, // same folder for EVERY part
            fileName: partName,
          );

          await OneDriveService.uploadFileInChunks(
            uploadUrl: uploadUrl,
            file: file,
            onProgress: (chunkProg) {
              final overall =
                  (i + chunkProg) / session.localChunkPaths.length;
              onProgress?.call(
                  overall, i + 1, session.localChunkPaths.length);
            },
          );

          // Delete local file after successful upload
          await file.delete();

          session.uploadedBlocks = List.generate(i + 1, (i) => i);
          await store.updateSession(session);
          partDone = true;
        } catch (_) {
          if (attempt < 3) {
            await Future.delayed(
                Duration(seconds: (attempt + 1) * 5));
          } else {
            // All 4 attempts failed → mark pending and stop
            session.status = 'pending';
            await store.updateSession(session);
            onStatusChange?.call('pending');
            return;
          }
        }
      }
    }

    if (!_isCancelled) {
      session.status = 'synced';
      await store.updateSession(session);
      onStatusChange?.call('synced');
    }
  }

  Future<void> _waitForReady() async {
    while (_isPaused && !_isCancelled) {
      await Future.delayed(const Duration(seconds: 2));
    }
    var result = await Connectivity().checkConnectivity();
    while (result.contains(ConnectivityResult.none) && !_isCancelled) {
      await Future.delayed(const Duration(seconds: 5));
      result = await Connectivity().checkConnectivity();
    }
  }

  String _defaultPartName(int index) =>
      '${session.sessionId}_part${(index + 1).toString().padLeft(2, '0')}.mp4';
}