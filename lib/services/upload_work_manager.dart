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

const kUploadTaskUnique = 'otn_upload_worker';
const kUploadTaskName   = 'otn_chunk_upload';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    debugPrint('=== WorkManager task: $taskName');
    try {
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

      // CRITICAL: Do NOT reset bytes_uploaded on stuck rows.
      // Just change status back to pending so upload resumes from saved offset.
      await db.resetStuckUploadingKeepProgress();

      bool anyUploaded = false;
      while (true) {
        final pending = await db.getPending();
        if (pending.isEmpty) break;

        final row        = pending.first;
        final chunkId    = row['chunk_id']       as String;
        final filePath   = row['local_file_path'] as String;
        final fileName   = row['file_name']       as String;
        final sessionId  = row['session_id']      as String;
        final partNum    = row['part_number']      as int;
        final startSec   = row['start_sec']        as int;
        final endSec     = row['end_sec']          as int;
        final sessionDateMs  = row['session_date_ms']  as int;
        final sessionStartMs = row['session_start_ms'] as int;
        final bytesAlready   = row['bytes_uploaded']   as int? ?? 0;
        final savedUrl       = row['upload_session_url'] as String?;

        if (!File(filePath).existsSync()) {
          debugPrint('=== WorkManager: file missing $filePath');
          // Check OneDrive before giving up
          final onedrive   = OneDriveService();
          final userFolder = await UserService().getDisplayName();
          final sessionDate = DateTime.fromMillisecondsSinceEpoch(sessionDateMs);
          final sessionStart = DateTime.fromMillisecondsSinceEpoch(sessionStartMs);
          final dateFolder  = DateFormat('dd-MM-yyyy').format(sessionDate);
          final datePart    = DateFormat('yyyyMMdd').format(sessionDate);
          final timePart    = DateFormat('HHmmss').format(sessionStart);
          final sessionFolder = '${sessionId}_${datePart}_$timePart';
          final folderPath    = 'OTN Recorder/$dateFolder/$userFolder/$sessionFolder';
          final already = await onedrive.fileExistsAndComplete(
              folderPath: folderPath, fileName: fileName)
              .catchError((_) => false);
          if (already) {
            await db.markDone(chunkId);
            anyUploaded = true;
            final sessionDone = await db.isSessionFullyDone(sessionId);
            if (sessionDone) {
              await _writeFirestore(row, sessionId, dateFolder, userFolder,
                  sessionFolder, startSec, endSec, sessionStartMs);
            }
          } else {
            await db.markFailed(chunkId);
          }
          continue;
        }

        await db.updateStatus(chunkId, 'uploading');

        try {
          final onedrive   = OneDriveService();
          final userFolder = await UserService().getDisplayName();
          final sessionDate = DateTime.fromMillisecondsSinceEpoch(sessionDateMs);
          final sessionStart = DateTime.fromMillisecondsSinceEpoch(sessionStartMs);
          final dateFolder  = DateFormat('dd-MM-yyyy').format(sessionDate);
          final datePart    = DateFormat('yyyyMMdd').format(sessionDate);
          final timePart    = DateFormat('HHmmss').format(sessionStart);
          final sessionFolder = '${sessionId}_${datePart}_$timePart';
          final folderPath    = 'OTN Recorder/$dateFolder/$userFolder/$sessionFolder';

          // Check if already on OneDrive
          final alreadyDone = await onedrive.fileExistsAndComplete(
              folderPath: folderPath, fileName: fileName);
          if (alreadyDone) {
            debugPrint('=== WorkManager: $fileName already on OD');
            await db.markDone(chunkId);
            // File kept locally — user deletes manually from history screen
            anyUploaded = true;
            await _writeFirestore(row, sessionId, dateFolder, userFolder,
                sessionFolder, startSec, endSec, sessionStartMs);
            continue;
          }

          // Upload — resume from saved byte offset if available
          await onedrive.uploadFileInSession(
            filePath:          filePath,
            fileName:          fileName,
            dateFolder:        dateFolder,
            userFolder:        userFolder,
            sessionFolder:     sessionFolder,
            rootFolder:        'OTN Recorder',
            existingUploadUrl: savedUrl,
            onProgress: (p) async {
              final fileSize = File(filePath).existsSync()
                  ? File(filePath).lengthSync() : 0;
              if (fileSize > 0) {
                await db.updateProgress(chunkId,
                    bytesUploaded: (fileSize * p).round());
              }
            },
            onStatus: (_) {},
          );

          final verified = await onedrive.fileExistsAndComplete(
              folderPath: folderPath, fileName: fileName);

          if (verified) {
            await db.markDone(chunkId);
            // File kept locally — user deletes manually
            anyUploaded = true;
            debugPrint('=== WorkManager: $fileName done ✓');
            // Session-wise: only write Firestore when ALL chunks of session done
            final sessionDone = await db.isSessionFullyDone(sessionId);
            if (sessionDone) {
              debugPrint('=== WorkManager: session $sessionId complete');
              await _writeFirestore(row, sessionId, dateFolder, userFolder,
                  sessionFolder, startSec, endSec, sessionStartMs);
            }
          } else {
            await db.incrementRetry(chunkId);
            final retries = (row['retry_count'] as int) + 1;
            if (retries >= 5) {
              await db.markFailed(chunkId);
            } else {
              await db.updateStatus(chunkId, 'pending');
            }
          }
        } catch (e) {
          debugPrint('=== WorkManager upload error: $e');
          // Save the upload session URL for resume if available
          await db.incrementRetry(chunkId);
          final retries = (row['retry_count'] as int) + 1;
          if (retries >= 5) {
            await db.markFailed(chunkId);
          } else {
            await db.updateStatus(chunkId, 'pending');
          }
        }
      }

      debugPrint('=== WorkManager task complete. anyUploaded=$anyUploaded');
      return true;
    } catch (e) {
      debugPrint('=== WorkManager fatal error: $e');
      return false;
    }
  });
}

Future<void> _writeFirestore(
  Map<String, dynamic> row,
  String sessionId,
  String dateFolder,
  String userFolder,
  String sessionFolder,
  int startSec,
  int endSec,
  int sessionStartMs,
) async {
  try {
    // Get ALL done chunks for this session from DB for accurate totals
    final db       = UploadQueueDb.instance;
    final allChunks = await db.getSessionChunks(sessionId);
    final doneChunks = allChunks
        .where((r) => (r['status'] as String?) == 'done')
        .toList();

    int totalSecs = 0;
    final parts   = <int>[];
    for (final c in doneChunks) {
      final s = (c['start_sec'] as int? ?? 0);
      final e = (c['end_sec']   as int? ?? 0);
      totalSecs += (e - s).clamp(0, 7200);
      parts.add(c['part_number'] as int? ?? 1);
    }

    await FirestoreCacheService().writeFullSession(
      sessionId:      sessionId,
      dateFolder:     dateFolder,
      userFolder:     userFolder,
      sessionFolder:  sessionFolder,
      sessionStartMs: sessionStartMs,
      chunksUploaded: doneChunks.length,
      totalSecs:      totalSecs,
      parts:          parts..sort(),
    );

    // writeFullSession uses merge:false — status is already 'synced' in that call
    // But call markSessionSynced explicitly as a safety net
    await FirestoreCacheService().markSessionSynced(sessionId);
    debugPrint('=== WorkManager: session $sessionId → synced ✓');

    final dateFmt = DateFormat('dd-MM-yyyy')
        .format(DateTime.fromMillisecondsSinceEpoch(
            row['session_date_ms'] as int));
    debugPrint('=== WorkManager: running attendance sync for $dateFmt');
    await AttendanceAutoSync().buildAndUploadNow(dateFmt);
    debugPrint('=== WorkManager: attendance sync complete for $dateFmt');
  } catch (e) {
    debugPrint('=== WorkManager Firestore/attendance error (non-fatal): $e');
  }
}

class UploadWorkManager {
  static Future<void> initialize() async {
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: false,
    );
    debugPrint('=== WorkManager initialized');
  }

  /// Schedule upload — use REPLACE policy so new network availability
  /// always triggers a fresh run, not just keep the old queued one.
  static Future<void> scheduleUpload() async {
    await Workmanager().registerOneOffTask(
      kUploadTaskUnique,
      kUploadTaskName,
      // REPLACE: ensures a new task is created when network comes back online
      // KEEP would silently ignore the new schedule if one is already pending
      existingWorkPolicy: ExistingWorkPolicy.replace,
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresDeviceIdle: false,
      ),
      backoffPolicy: BackoffPolicy.linear,
      initialDelay: Duration.zero,
    );
    debugPrint('=== WorkManager: upload job scheduled');
  }

  static Future<void> cancel() async {
    await Workmanager().cancelByUniqueName(kUploadTaskUnique);
  }
}