import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'attendance_export_service.dart';
import 'package:intl/intl.dart';
import 'onedrive_service.dart';
import 'upload_queue_db.dart';
import 'user_service.dart';

/// Fast metadata cache backed by Firestore.
/// Written after each chunk upload. Backfilled from OneDrive on first open.
/// All date filters read from Firestore — no slow OneDrive listing needed.
class FirestoreCacheService {
  static final FirestoreCacheService _i = FirestoreCacheService._();
  factory FirestoreCacheService() => _i;
  FirestoreCacheService._();

  static const _sessionsPath = 'sessions';

  FirebaseFirestore get _db  => FirebaseFirestore.instance;
  String?           get _uid => FirebaseAuth.instance.currentUser?.uid;

  /// Public accessor for history screen direct queries
  CollectionReference<Map<String, dynamic>>? get sessionsCollection => _sessions;

  CollectionReference<Map<String, dynamic>>? get _sessions {
    final uid = _uid;
    if (uid == null) return null;
    return _db.collection('users').doc(uid).collection('sessions');
  }

  // ── Backfill from OneDrive ────────────────────────────────────────────────

  /// Called once on app open after login.
  /// Scans OneDrive, writes any missing sessions to Firestore.
  Future<void> backfillFromOneDrive() async {
    try {
      final col = _sessions;
      if (col == null) return;

      final userFolder = await UserService().getDisplayName();
      debugPrint('=== Firestore backfill: scanning OneDrive for $userFolder');

      // List all files from OneDrive
      final files = await OneDriveService().listUserFiles(
        rootFolder: 'OTN Recorder',
        userFolder: userFolder,
      ).timeout(const Duration(seconds: 60));

      if (files.isEmpty) {
        debugPrint('=== Firestore backfill: no files found on OneDrive');
        return;
      }

      debugPrint('=== Firestore backfill: found ${files.length} files');

      // Fix 1: Pre-load sessions that still have active (non-done) chunks in
      // the local SQLite queue. These are mid-upload sessions — we must NOT
      // mark them 'synced' even if some chunks are already on OneDrive.
      final activeRows = await UploadQueueDb.instance.getActive();
      final activeSessionIds = activeRows
          .map((r) => r['session_id'] as String? ?? '')
          .where((s) => s.isNotEmpty)
          .toSet();
      debugPrint('=== Firestore backfill: ${activeSessionIds.length} sessions '
          'still uploading — will stay as "uploading" in Firestore');

      // Group by sessionFolder
      final sessionMap = <String, List<Map<String, dynamic>>>{};
      for (final f in files) {
        final sf = f['sessionFolder'] as String? ?? '';
        if (sf.isEmpty) continue;
        sessionMap.putIfAbsent(sf, () => []).add(f);
      }

      // For each session, check if already in Firestore, write if not
      int written = 0;
      for (final entry in sessionMap.entries) {
        final sessionFolder = entry.key;
        final parts         = entry.value;

        // Extract sessionId from folder name: SESSIONID_YYYYMMDD_HHMMSS
        final segments = sessionFolder.split('_');
        if (segments.length < 3) continue;
        final sessionId  = segments[0];
        final dateStr    = segments[1]; // YYYYMMDD
        final timeStr    = segments[2]; // HHMMSS

        // Always compute accurate values from OneDrive file list
        final totalBytes   = parts.fold<int>(0,
            (s, p) => s + ((p['size'] as int?) ?? 0));
        final totalSecs    = parts.fold<int>(0,
            (s, p) => s + _parseFileSecs(p['name'] as String? ?? ''));
        final partNums     = parts.map((p) =>
            _parsePartNumber(p['name'] as String? ?? '')).toList()
            ..sort();

        // Check if doc already exists — always UPDATE with fresh OD data
        final existing = await col.doc(sessionId).get();
        // Fix 1: Only mark 'synced' if session has no active chunks in the
        // local upload queue. Mid-upload sessions stay 'uploading' so they
        // don't appear in the Uploaded section prematurely.
        final isStillUploading = activeSessionIds.contains(sessionId);
        final statusForExisting = isStillUploading ? 'uploading' : 'synced';

        if (existing.exists) {
          final data = existing.data()!;
          // Only overwrite with OD data if it has more/equal chunks than Firestore
          // This fixes: 2-chunk session shown as 1 chunk after partial upload
          final fsChunks = (data['chunksUploaded'] as num? ?? 0).toInt();
          if (parts.length >= fsChunks) {
            await col.doc(sessionId).update({
              'chunksUploaded': parts.length,
              'totalSecs':      totalSecs,
              'totalBytes':     totalBytes,
              'parts':          partNums,
              'status':         statusForExisting, // Fix 1
              'updatedAt':      FieldValue.serverTimestamp(),
              'backfilled':     true,
            });
          }
          continue;
        }
        // Also check by sessionFolder to avoid duplicates
        final byFolder = await col
            .where('sessionFolder', isEqualTo: sessionFolder)
            .limit(1)
            .get();
        if (byFolder.docs.isNotEmpty) {
          final existingDoc = byFolder.docs.first;
          final data = existingDoc.data();
          final fsChunks = (data['chunksUploaded'] as num? ?? 0).toInt();
          if (parts.length >= fsChunks) {
            await existingDoc.reference.update({
              'chunksUploaded': parts.length,
              'totalSecs':      totalSecs,
              'totalBytes':     totalBytes,
              'parts':          partNums,
              'status':         statusForExisting, // Fix 1
              'updatedAt':      FieldValue.serverTimestamp(),
              'backfilled':     true,
            });
          }
          continue;
        }

        // Parse date
        DateTime? sessionDate;
        try {
          sessionDate = DateTime(
            int.parse(dateStr.substring(0, 4)),
            int.parse(dateStr.substring(4, 6)),
            int.parse(dateStr.substring(6, 8)),
            int.parse(timeStr.substring(0, 2)),
            int.parse(timeStr.substring(2, 4)),
            int.parse(timeStr.substring(4, 6)),
          );
        } catch (_) { continue; }

        final dateFolder   = DateFormat('dd-MM-yyyy').format(sessionDate);

        await col.doc(sessionId).set({
          'sessionId':      sessionId,
          'dateFolder':     dateFolder,
          'userFolder':     userFolder,
          'sessionFolder':  sessionFolder,
          'sessionStartMs': sessionDate.millisecondsSinceEpoch,
          'chunksUploaded': parts.length,
          'totalSecs':      totalSecs,
          'totalBytes':     totalBytes,
          'parts':          partNums,
          // Fix 1: respect active upload queue — new docs from a partial
          // OneDrive scan must not be written as 'synced' yet.
          'status':         isStillUploading ? 'uploading' : 'synced',
          'updatedAt':      FieldValue.serverTimestamp(),
          'backfilled':     true,
        });
        written++;
      }

      debugPrint('=== Firestore backfill: wrote $written new sessions');
    } catch (e) {
      debugPrint('=== Firestore backfill error (non-fatal): $e');
    }
  }

  /// Write or overwrite a complete session document.
  /// Called when ALL chunks of a session are confirmed done.
  Future<void> writeFullSession({
    required String sessionId,
    required String dateFolder,
    required String userFolder,
    required String sessionFolder,
    required int    sessionStartMs,
    required int    chunksUploaded,
    required int    totalSecs,
    required List<int> parts,
  }) async {
    try {
      final col = _sessions;
      if (col == null) return;
      await col.doc(sessionId).set({
        'sessionId':      sessionId,
        'dateFolder':     dateFolder,
        'userFolder':     userFolder,
        'sessionFolder':  sessionFolder,
        'sessionStartMs': sessionStartMs,
        'chunksUploaded': chunksUploaded,
        'totalSecs':      totalSecs,
        'totalBytes':     0,
        'parts':          parts,
        'status':         'synced',
        'updatedAt':      FieldValue.serverTimestamp(),
      }, SetOptions(merge: false)); // overwrite fully for accuracy
      debugPrint('=== Firestore: full session written — $sessionId '
          '($chunksUploaded chunks, ${totalSecs}s)');
    } catch (e) {
      debugPrint('=== Firestore writeFullSession error: $e');
    }
  }

  /// Force full re-scan — called on manual refresh.
  /// Updates ALL sessions in Firestore with accurate chunk count + duration.
  Future<void> forceRefreshFromOneDrive() async {
    debugPrint('=== Firestore forceRefresh: starting full OD re-scan');
    // backfillFromOneDrive now always updates existing docs, so just call it
    await backfillFromOneDrive();
    debugPrint('=== Firestore forceRefresh: complete');
  }

  /// Parse duration seconds from OneDrive filename.
  /// Supports both formats:
  ///   NEW: AOO7BQ_20260508_P01_S103045_E103210_165s.mp4  → 165s (exact)
  ///   OLD: 3VCWW6_20260506_015642_0100-02.mp4            → (2-0)*60 = 120s
  static int _parseFileSecs(String name) {
    // NEW format: _DURs.mp4  e.g. _165s.mp4
    final mNew = RegExp(r'_(\d+)s\.mp4$').firstMatch(name);
    if (mNew != null) return int.parse(mNew.group(1)!);

    // OLD format v2: _NNMM-MM.mp4  e.g. _0100-02.mp4 → (02-00)*60
    final mOld = RegExp(r'_\d{2}(\d{2})-(\d{2})\.mp4$').firstMatch(name);
    if (mOld != null) {
      final s = int.parse(mOld.group(1)!);
      final e = int.parse(mOld.group(2)!);
      return (e - s).abs() * 60;
    }

    // OLD format v1: _MM-MM.mp4  e.g. _00-02.mp4 → (02-00)*60
    final mV1 = RegExp(r'_(\d{2})-(\d{2})\.mp4$').firstMatch(name);
    if (mV1 != null) {
      return (int.parse(mV1.group(2)!) - int.parse(mV1.group(1)!)).abs() * 60;
    }
    return 0;
  }

  /// Parse part number from OneDrive filename.
  /// Supports both formats:
  ///   NEW: AOO7BQ_20260508_P01_S103045_E103210_165s.mp4  → 1
  ///   OLD: 3VCWW6_20260506_015642_0100-02.mp4            → 1
  static int _parsePartNumber(String name) {
    // NEW format: _PNN_  e.g. _P01_
    final mNew = RegExp(r'_P(\d{2})_').firstMatch(name);
    if (mNew != null) return int.parse(mNew.group(1)!);

    // OLD format: _NNMM-MM.mp4  — NN is first 2 digits of the 4-digit block
    final mOld = RegExp(r'_(\d{2})\d{2}-\d{2}\.mp4$').firstMatch(name);
    if (mOld != null) return int.parse(mOld.group(1)!);

    return 1;
  }

  // ── Sync deletions — remove Firestore docs for sessions deleted from OD ──
  /// Diffs Firestore sessions vs OneDrive for the given date folders.
  /// Any session in Firestore that no longer exists on OneDrive is deleted.
  Future<void> syncDeletionsFromOneDrive({List<String>? dateFolders}) async {
    try {
      final col = _sessions;
      if (col == null) return;
      final userFolder = await UserService().getDisplayName();

      // Get all sessions from Firestore (limited to provided date folders or all)
      Query<Map<String, dynamic>> query = col;
      if (dateFolders != null && dateFolders.isNotEmpty) {
        query = col.where('dateFolder', whereIn: dateFolders.take(30).toList());
      }
      final firestoreDocs = await query.get();
      if (firestoreDocs.docs.isEmpty) return;

      // Get session folders currently pending/uploading in SQLite queue
      // — do NOT delete these even if not on OneDrive yet (still uploading)
      final activeRows = await UploadQueueDb.instance.getActive();
      final pendingSessionFolders = activeRows
          .map((r) => r['onedrive_path'] as String? ?? '') // onedrive_path = sessionFolderName
          .where((s) => s.isNotEmpty)
          .toSet();

      // Get all session folders currently on OneDrive
      final odFiles = await OneDriveService().listUserFiles(
        rootFolder: 'OTN Recorder',
        userFolder: userFolder,
      ).timeout(const Duration(seconds: 60));

      final odSessionFolders = odFiles
          .map((f) => f['sessionFolder'] as String? ?? '')
          .where((s) => s.isNotEmpty)
          .toSet();

      // Delete Firestore docs whose sessionFolder is:
      // 1. Not on OneDrive AND
      // 2. Not currently in the upload queue (would be on OD soon)
      int deleted = 0;
      final batch = _db.batch();
      for (final doc in firestoreDocs.docs) {
        final sf = doc.data()['sessionFolder'] as String? ?? '';
        if (sf.isNotEmpty
            && !odSessionFolders.contains(sf)
            && !pendingSessionFolders.contains(sf)) {
          batch.delete(doc.reference);
          deleted++;
          debugPrint('=== Firestore syncDel: removed $sf (not on OD, not pending)');
        }
      }
      if (deleted > 0) await batch.commit();
      debugPrint('=== Firestore syncDel: removed $deleted orphaned docs');
    } catch (e) {
      debugPrint('=== Firestore syncDeletions error (non-fatal): $e');
    }
  }

  // ── Streams ───────────────────────────────────────────────────────────────

  /// Real-time stream for a specific date folder (DD-MM-YYYY).
  Stream<DashMetrics> metricsStreamForDate(String dateFolder) {
    final col = _sessions;
    if (col == null) return Stream.value(const DashMetrics(totalSecs: 0, sessionCount: 0));
    return col
        .where('dateFolder', isEqualTo: dateFolder)
        .snapshots()
        .map((snap) {
          int totalSecs = 0;
          for (final doc in snap.docs) {
            totalSecs += (doc.data()['totalSecs'] as num? ?? 0).toInt();
          }
          return DashMetrics(totalSecs: totalSecs, sessionCount: snap.docs.length);
        })
        .handleError((e) {
          debugPrint('=== Firestore stream error: $e');
          return const DashMetrics(totalSecs: 0, sessionCount: 0);
        });
  }

  /// Stream for date range (This Week / This Month / custom).
  Stream<DashMetrics> metricsStreamForRange(DateTime from, DateTime to) {
    final col = _sessions;
    if (col == null) return Stream.value(const DashMetrics(totalSecs: 0, sessionCount: 0));

    // Use sessionStartMs range query — no 30-item limit like whereIn
    // from = start of first day, to = end of last day
    final fromMs = DateTime(from.year, from.month, from.day)
        .millisecondsSinceEpoch;
    final toMs   = DateTime(to.year, to.month, to.day, 23, 59, 59)
        .millisecondsSinceEpoch;

    return col
        .where('sessionStartMs', isGreaterThanOrEqualTo: fromMs)
        .where('sessionStartMs', isLessThanOrEqualTo: toMs)
        .snapshots()
        .map((snap) {
          int totalSecs    = 0;
          int sessionCount = 0;
          for (final doc in snap.docs) {
            totalSecs    += (doc.data()['totalSecs'] as num? ?? 0).toInt();
            sessionCount++;
          }
          return DashMetrics(totalSecs: totalSecs, sessionCount: sessionCount);
        })
        .handleError((e) {
          debugPrint('=== Firestore range stream error: $e');
          return const DashMetrics(totalSecs: 0, sessionCount: 0);
        });
  }

  // Kept for backward compat
  Stream<DashMetrics> todayMetricsStream(String dateFolder) =>
      metricsStreamForDate(dateFolder);

  // ── Write (called after upload confirms) ─────────────────────────────────

  Future<void> recordChunkUploaded({
    required String sessionId,
    required String dateFolder,
    required String userFolder,
    required String sessionFolder,
    required int    chunkDurationSecs,
    required int    chunkSizeBytes,
    required int    partNumber,
    required int    sessionStartMs,
  }) async {
    final col = _sessions;
    if (col == null) return;
    try {
      final ref = col.doc(sessionId);
      await _db.runTransaction((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) {
          tx.set(ref, {
            'sessionId':      sessionId,
            'dateFolder':     dateFolder,
            'userFolder':     userFolder,
            'sessionFolder':  sessionFolder,
            'sessionStartMs': sessionStartMs,
            'chunksUploaded': 1,
            'totalSecs':      chunkDurationSecs,
            'totalBytes':     chunkSizeBytes,
            'parts':          [partNumber],
            'partDurations':  {'$partNumber': chunkDurationSecs},
            // 'uploading' = partial session, still has chunks pending
            // 'synced'    = all chunks confirmed on cloud storage
            'status':         'uploading',
            'updatedAt':      FieldValue.serverTimestamp(),
          });
        } else {
          final data  = snap.data()!;
          final parts = List<int>.from(data['parts'] as List? ?? []);
          // Idempotent: only increment counts if this part is new
          // Prevents double-count when WorkManager + main queue both call this
          final isNewPart = !parts.contains(partNumber);
          if (isNewPart) parts.add(partNumber);
          final durations = Map<String, dynamic>.from(
              data['partDurations'] as Map? ?? {});
          durations['$partNumber'] = chunkDurationSecs;
          if (isNewPart) {
            tx.update(ref, {
              'chunksUploaded': FieldValue.increment(1),
              'totalSecs':      FieldValue.increment(chunkDurationSecs),
              'totalBytes':     FieldValue.increment(chunkSizeBytes),
              'parts':          parts,
              'partDurations':  durations,
              // Keep 'uploading' — caller (_writeChunkToFirestore) sets
              // 'synced' only after isSessionFullyDone check passes
              'status':         'uploading',
              'updatedAt':      FieldValue.serverTimestamp(),
            });
          } else {
            // Part already recorded — no status change needed
            tx.update(ref, { 'updatedAt': FieldValue.serverTimestamp() });
          }
        }
      });
    } catch (e) {
      debugPrint('=== Firestore recordChunk error: $e');
    }
  }

  Future<void> markSessionSynced(String sessionId) async {
    final col = _sessions;
    if (col == null) return;
    try {
      await col.doc(sessionId).update({
        'status':    'synced',
        'updatedAt': FieldValue.serverTimestamp(),
      });
      // Trigger attendance Excel update on OneDrive after session is fully synced
      _triggerAttendanceUpdate(sessionId, col).ignore();
    } catch (_) {}
  }

  Future<void> _triggerAttendanceUpdate(
      String sessionId,
      CollectionReference<Map<String, dynamic>> col) async {
    try {
      final snap = await col.doc(sessionId).get();
      if (!snap.exists) return;
      final d = snap.data()!;
      await AttendanceExportService().updateForSession(
        sessionId:      sessionId,
        dateFolder:     d['dateFolder']     as String? ?? '',
        userFolder:     d['userFolder']     as String? ?? '',
        totalSecs:      d['totalSecs']      as int? ?? 0,
        chunksUploaded: d['chunksUploaded'] as int? ?? 0,
        sessionStartMs: d['sessionStartMs'] as int? ?? 0,
        status:         'Complete',
      );
    } catch (e) {
      debugPrint('=== Firestore: attendance trigger error (non-fatal): \$e');
    }
  }
}

// ── Models ────────────────────────────────────────────────────────────────────

class SessionMeta {
  final String    sessionId;
  final String    dateFolder;
  final String    userFolder;
  final String    sessionFolder;
  final int       sessionStartMs;
  final int       chunksUploaded;
  final int       totalSecs;
  final int       totalBytes;
  final List<int>        parts;
  final Map<int, int>    partDurations; // partNumber → durationSecs
  final String           status;

  const SessionMeta({
    required this.sessionId,
    required this.dateFolder,
    required this.userFolder,
    required this.sessionFolder,
    required this.sessionStartMs,
    required this.chunksUploaded,
    required this.totalSecs,
    required this.totalBytes,
    required this.parts,
    required this.partDurations,
    required this.status,
  });

  factory SessionMeta.fromMap(String id, Map<String, dynamic> d) => SessionMeta(
    sessionId:      id,
    dateFolder:     d['dateFolder']    as String? ?? '',
    userFolder:     d['userFolder']    as String? ?? '',
    sessionFolder:  d['sessionFolder'] as String? ?? '',
    sessionStartMs: (d['sessionStartMs'] as num? ?? 0).toInt(),
    chunksUploaded: (d['chunksUploaded'] as num? ?? 0).toInt(),
    totalSecs:      (d['totalSecs']    as num? ?? 0).toInt(),
    totalBytes:     (d['totalBytes']   as num? ?? 0).toInt(),
    parts:          List<int>.from(d['parts'] as List? ?? []),
    partDurations:  (d['partDurations'] as Map? ?? {}).map(
        (k, v) => MapEntry(int.tryParse(k.toString()) ?? 0, (v as num? ?? 0).toInt())),
    status:         d['status']        as String? ?? 'uploading',
  );

  double get totalMb => totalBytes / 1024 / 1024;

  /// Returns actual duration for a given part number, 0 if not stored
  int durationForPart(int partNum) => partDurations[partNum] ?? 0;

  /// Human-readable start time, e.g. "Started 09:15 AM"
  String get startTimeLabel {
    if (sessionStartMs <= 0) return 'Start time unknown';
    final dt = DateTime.fromMillisecondsSinceEpoch(sessionStartMs);
    final h   = dt.hour;
    final m   = dt.minute.toString().padLeft(2, '0');
    final amPm = h >= 12 ? 'PM' : 'AM';
    final h12  = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    return 'Started $h12:$m $amPm';
  }
}

class DashMetrics {
  final int totalSecs;
  final int sessionCount;
  const DashMetrics({required this.totalSecs, required this.sessionCount});
}