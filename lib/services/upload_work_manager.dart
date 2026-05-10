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

// ── How many times WorkManager retries a single chunk before marking failed ──
const _kMaxWmRetries = 5;

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

      // Reset stuck 'uploading' rows → 'pending', keeping progress + session URL.
      // Session validity is checked per-chunk below before reusing.
      await db.resetStuckUploadingKeepProgress();

      bool anyUploaded = false;

      while (true) {
        final pending = await db.getPending();
        if (pending.isEmpty) break;

        final row            = pending.first;
        final chunkId        = row['chunk_id']            as String;
        final filePath       = row['local_file_path']     as String;
        final fileName       = row['file_name']           as String;
        final sessionId      = row['session_id']          as String;
        final startSec       = row['start_sec']           as int;
        final endSec         = row['end_sec']             as int;
        final sessionDateMs  = row['session_date_ms']     as int;
        final sessionStartMs = row['session_start_ms']    as int;
        final bytesAlready   = row['bytes_uploaded']      as int?  ?? 0;
        final savedUrl       = row['upload_session_url']  as String?;
        final savedExpiryMs  = row['upload_session_expiry'] as int?;

        // ── Resolve folder path ──────────────────────────────────────────
        final onedrive     = OneDriveService();
        final userFolder   = await UserService().getDisplayName();
        final sessionDate  = DateTime.fromMillisecondsSinceEpoch(sessionDateMs);
        final sessionStart = DateTime.fromMillisecondsSinceEpoch(sessionStartMs);
        final dateFolder   = DateFormat('dd-MM-yyyy').format(sessionDate);
        final datePart     = DateFormat('yyyyMMdd').format(sessionDate);
        final timePart     = DateFormat('HHmmss').format(sessionStart);
        final sessionFolder = '${sessionId}_${datePart}_$timePart';
        final folderPath    = 'OTN Recorder/$dateFolder/$userFolder/$sessionFolder';

        // ── File missing locally ─────────────────────────────────────────
        if (!File(filePath).existsSync()) {
          debugPrint('=== WorkManager: file missing $filePath');
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
          // ── Already on OneDrive? ───────────────────────────────────────
          final alreadyDone = await onedrive.fileExistsAndComplete(
              folderPath: folderPath, fileName: fileName);
          if (alreadyDone) {
            debugPrint('=== WorkManager: $fileName already on OD');
            await db.markDone(chunkId);
            anyUploaded = true;
            final sessionDone = await db.isSessionFullyDone(sessionId);
            if (sessionDone) {
              await _writeFirestore(row, sessionId, dateFolder, userFolder,
                  sessionFolder, startSec, endSec, sessionStartMs);
            }
            continue;
          }

          // ── Decide whether to resume or start fresh ────────────────────
          // Resume only if:
          //   1. We have a saved session URL
          //   2. That URL has NOT expired (expiry stored in DB, 10-min buffer)
          //   3. We have bytes already uploaded (something to resume)
          String? resumeUrl;
          if (savedUrl != null &&
              savedUrl.isNotEmpty &&
              bytesAlready > 0 &&
              savedExpiryMs != null) {
            final stillValid = DateTime.now().millisecondsSinceEpoch <
                savedExpiryMs - 600000; // 10-min safety buffer
            if (stillValid) {
              resumeUrl = savedUrl;
              debugPrint('=== WorkManager: resuming $fileName from $bytesAlready bytes');
            } else {
              // Session expired — clear it, start fresh from byte 0
              debugPrint('=== WorkManager: session expired for $fileName — fresh upload');
              await db.clearUploadSession(chunkId);
            }
          }

          // ── Upload ────────────────────────────────────────────────────
          await onedrive.uploadFileInSession(
            filePath:          filePath,
            fileName:          fileName,
            dateFolder:        dateFolder,
            userFolder:        userFolder,
            sessionFolder:     sessionFolder,
            rootFolder:        'OTN Recorder',
            existingUploadUrl: resumeUrl,
            onProgress: (p) async {
              final fileSize = File(filePath).existsSync()
                  ? File(filePath).lengthSync() : 0;
              if (fileSize > 0) {
                await db.updateProgress(chunkId,
                    bytesUploaded: (fileSize * p).round());
              }
            },
            // Save the session URL + expiry the first time OneDrive returns it.
            // onedrive_service passes it back via onSessionCreated callback.
            onSessionCreated: (url) async {
              final expiry = DateTime.now().add(const Duration(hours: 23));
              await db.saveUploadSession(chunkId, url, expiry);
              debugPrint('=== WorkManager: saved session URL for $fileName (expires ${expiry.toIso8601String()})');
            },
            onStatus: (_) {},
          );

          // ── Verify ────────────────────────────────────────────────────
          final verified = await onedrive.fileExistsAndComplete(
              folderPath: folderPath, fileName: fileName);

          if (verified) {
            await db.markDone(chunkId);
            anyUploaded = true;
            debugPrint('=== WorkManager: $fileName done ✓');
            final sessionDone = await db.isSessionFullyDone(sessionId);
            if (sessionDone) {
              debugPrint('=== WorkManager: session $sessionId complete');
              await _writeFirestore(row, sessionId, dateFolder, userFolder,
                  sessionFolder, startSec, endSec, sessionStartMs);
            }
          } else {
            await db.incrementRetry(chunkId);
            final retries = (row['retry_count'] as int) + 1;
            if (retries >= _kMaxWmRetries) {
              await db.markFailed(chunkId);
            } else {
              // Clear expired/broken session before next attempt
              await db.clearUploadSession(chunkId);
              await db.updateStatus(chunkId, 'pending');
            }
          }
        } catch (e) {
          debugPrint('=== WorkManager upload error: $e');
          await db.incrementRetry(chunkId);
          final retries = (row['retry_count'] as int) + 1;
          if (retries >= _kMaxWmRetries) {
            await db.markFailed(chunkId);
          } else {
            // Clear broken session so next attempt starts fresh if needed
            await db.clearUploadSession(chunkId);
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
    final db         = UploadQueueDb.instance;
    final allChunks  = await db.getSessionChunks(sessionId);
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

    await FirestoreCacheService().markSessionSynced(sessionId);
    debugPrint('=== WorkManager: session $sessionId → synced ✓');

    final dateFmt = DateFormat('dd-MM-yyyy')
        .format(DateTime.fromMillisecondsSinceEpoch(
            row['session_date_ms'] as int));
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

  // KEEP policy: if a job is already queued, don't replace it.
  // This prevents duplicate jobs when enqueue() fires multiple times rapidly
  // (e.g. recording stops and all chunks enqueue within 1 second).
  // A separate scheduleUploadForced() uses REPLACE for network-reconnect events.
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
      backoffPolicyDelay: const Duration(minutes: 2),
      initialDelay: Duration.zero,
    );
    debugPrint('=== WorkManager: upload job scheduled (KEEP)');
  }

  /// Called when network reconnects — replaces any stale queued job with
  /// a fresh one so upload starts immediately on the new connection.
  static Future<void> scheduleUploadForced() async {
    await Workmanager().registerOneOffTask(
      kUploadTaskUnique,
      kUploadTaskName,
      existingWorkPolicy: ExistingWorkPolicy.replace,
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresDeviceIdle: false,
      ),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 2),
      initialDelay: Duration.zero,
    );
    debugPrint('=== WorkManager: upload job scheduled (REPLACE — network reconnect)');
  }

  static Future<void> cancel() async {
    await Workmanager().cancelByUniqueName(kUploadTaskUnique);
  }
}