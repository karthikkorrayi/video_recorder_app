import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';
import 'upload_queue_db.dart';
import 'onedrive_service.dart';
import 'firestore_cache_service.dart';
import 'attendance_auto_sync.dart';
import 'user_service.dart';
import 'package:intl/intl.dart';

// ─── Task name constants ──────────────────────────────────────────────────────
const kUploadTaskUnique = 'otn_upload_worker';
const kUploadTaskName   = 'otn_chunk_upload';

// ─── Top-level callback — MUST be top-level (not inside a class) ─────────────
// WorkManager calls this when it runs the task.
// This is invoked in a separate isolate, so we re-open the DB and services.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    debugPrint('=== WorkManager task: $taskName');

    try {
      // WorkManager runs in a separate Dart isolate — Firebase must be
      // re-initialized here with explicit options (no google-services.json in isolate).
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: const FirebaseOptions(
            apiKey:            'AIzaSyAU5jiCE8sCIMjm0ywBFnHupvOIAkCbMLM',
            appId:             '1:164325680744:android:4f0c0284c3a3db8e4f7ddd',
            messagingSenderId: '164325680744',
            projectId:         'videorecorderapp-305b8',
            storageBucket:     'videorecorderapp-305b8.firebasestorage.app',
          ),
        );
        debugPrint('=== WorkManager: Firebase initialized');
      }

      final db = UploadQueueDb.instance;

      // Reset any stuck 'uploading' rows from a previous killed run
      await db.resetStuckUploading();

      // Process ALL pending chunks one by one
      bool anyUploaded = false;
      while (true) {
        final pending = await db.getPending();
        if (pending.isEmpty) break;

        final row = pending.first;
        final chunkId   = row['chunk_id']   as String;
        final filePath  = row['local_file_path'] as String;
        final fileName  = row['file_name']  as String;
        final sessionId = row['session_id'] as String;
        final partNum   = row['part_number'] as int;
        final startSec  = row['start_sec']  as int;
        final endSec    = row['end_sec']    as int;
        final sessionDateMs  = row['session_date_ms']  as int;
        final sessionStartMs = row['session_start_ms'] as int;

        // File must exist — if missing, mark failed and skip
        if (!File(filePath).existsSync()) {
          debugPrint('=== WorkManager: file missing $filePath → failed');
          await db.markFailed(chunkId);
          continue;
        }

        await db.updateStatus(chunkId, 'uploading');

        try {
          final onedrive   = OneDriveService();
          final userFolder = await UserService().getDisplayName();
          final sessionDate = DateTime.fromMillisecondsSinceEpoch(sessionDateMs);
          final sessionStart = DateTime.fromMillisecondsSinceEpoch(sessionStartMs);
          final dateFolder  = DateFormat('dd-MM-yyyy').format(sessionDate);

          // Build session folder (start-time only — all parts in one folder)
          final datePart  = DateFormat('yyyyMMdd').format(sessionDate);
          final timePart  = DateFormat('HHmmss').format(sessionStart);
          final sessionFolder = '${sessionId}_${datePart}_$timePart';
          final folderPath    = 'OTN Recorder/$dateFolder/$userFolder/$sessionFolder';

          // Check if already on OneDrive (idempotent)
          final alreadyDone = await onedrive.fileExistsAndComplete(
              folderPath: folderPath, fileName: fileName);
          if (alreadyDone) {
            debugPrint('=== WorkManager: $fileName already on OD — marking done');
            await db.markDone(chunkId);
            await File(filePath).delete().catchError((_) {});
            anyUploaded = true;
            continue;
          }

          // Upload with progress tracked in DB
          await onedrive.uploadFileInSession(
            filePath:      filePath,
            fileName:      fileName,
            dateFolder:    dateFolder,
            userFolder:    userFolder,
            sessionFolder: sessionFolder,
            rootFolder:    'OTN Recorder',
            onProgress: (p) async {
              final fileSize = File(filePath).lengthSync();
              await db.updateProgress(chunkId,
                  bytesUploaded: (fileSize * p).round());
            },
            onStatus: (_) {},
          );

          // Verify on OneDrive
          final verified = await onedrive.fileExistsAndComplete(
              folderPath: folderPath, fileName: fileName);

          if (verified) {
            await db.markDone(chunkId);
            await File(filePath).delete().catchError((_) {});
            anyUploaded = true;
            debugPrint('=== WorkManager: $fileName done ✓');

            // Write to Firestore + trigger attendance Excel update
            try {
              final userFolder = await UserService().getDisplayName();
              final dateMs     = row['session_date_ms'] as int? ?? 0;
              final dateFmt    = DateFormat('dd-MM-yyyy')
                  .format(DateTime.fromMillisecondsSinceEpoch(dateMs));
              await FirestoreCacheService().recordChunkUploaded(
                sessionId:         sessionId,
                dateFolder:        dateFolder,
                userFolder:        userFolder,
                sessionFolder:     sessionFolder,
                chunkDurationSecs: endSec - startSec,
                chunkSizeBytes:    0,
                partNumber:        partNum,
                sessionStartMs:    sessionStartMs,
              );
              // Run attendance sync directly here (awaited) — NOT via debounce timer.
              // A debounce timer would fire after this isolate closes, causing network abort.
              debugPrint('=== WorkManager: running attendance sync for $dateFmt');
              await AttendanceAutoSync().buildAndUploadNow(dateFmt);
              debugPrint('=== WorkManager: attendance sync complete for $dateFmt');
            } catch (e) {
              debugPrint('=== WorkManager Firestore write error (non-fatal): $e');
            }
          } else {
            await db.incrementRetry(chunkId);
            final retryCount = (row['retry_count'] as int) + 1;
            if (retryCount >= 3) {
              await db.markFailed(chunkId);
              debugPrint('=== WorkManager: $fileName failed after 3 retries');
            } else {
              await db.updateStatus(chunkId, 'pending');
              debugPrint('=== WorkManager: $fileName not verified — retry $retryCount');
            }
          }
        } catch (e) {
          debugPrint('=== WorkManager upload error: $e');
          await db.incrementRetry(chunkId);
          final retryCount = (row['retry_count'] as int) + 1;
          if (retryCount >= 3) {
            await db.markFailed(chunkId);
          } else {
            await db.updateStatus(chunkId, 'pending');
          }
        }
      }

      debugPrint('=== WorkManager task complete. anyUploaded=$anyUploaded');
      return Future.value(true);
    } catch (e) {
      debugPrint('=== WorkManager fatal error: $e');
      return Future.value(false);
    }
  });
}

// ─── Helper to schedule the WorkManager job ───────────────────────────────────
class UploadWorkManager {
  /// Call once at app startup (main.dart)
  static Future<void> initialize() async {
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: false,
    );
    debugPrint('=== WorkManager initialized');
  }

  /// Schedule upload job — safe to call multiple times (unique task deduplicates)
  /// Called automatically after recording stops and chunks are queued in DB.
  static Future<void> scheduleUpload() async {
    await Workmanager().registerOneOffTask(
      kUploadTaskUnique,
      kUploadTaskName,
      existingWorkPolicy: ExistingWorkPolicy.keep,
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresDeviceIdle: false,
      ),
      backoffPolicy: BackoffPolicy.exponential,
      // 0.9.x uses Duration directly (no separate backoffPolicyDelay param)
      initialDelay: Duration.zero,
    );
    debugPrint('=== WorkManager: upload job scheduled');
  }

  /// Cancel any pending scheduled job
  static Future<void> cancel() async {
    await Workmanager().cancelByUniqueName(kUploadTaskUnique);
  }
}