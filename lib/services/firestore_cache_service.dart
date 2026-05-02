import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'onedrive_service.dart';
import 'user_service.dart';

/// Fast metadata cache backed by Firestore.
/// Written after each chunk upload. Backfilled from OneDrive on first open.
/// All date filters read from Firestore — no slow OneDrive listing needed.
class FirestoreCacheService {
  static final FirestoreCacheService _i = FirestoreCacheService._();
  factory FirestoreCacheService() => _i;
  FirestoreCacheService._();

  static const _backfillKey = 'firestore_backfill_done_v1';

  FirebaseFirestore get _db  => FirebaseFirestore.instance;
  String?           get _uid => FirebaseAuth.instance.currentUser?.uid;

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

        // Check if already exists in Firestore
        final existing = await col.doc(sessionId).get();
        if (existing.exists) continue; // already backfilled

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
        final totalBytes   = parts.fold<int>(0,
            (s, p) => s + ((p['size'] as int?) ?? 0));
        final totalSecs    = parts.fold<int>(0,
            (s, p) => s + _parseFileSecs(p['name'] as String? ?? ''));
        final partNums     = parts.map((p) =>
            _parsePartNumber(p['name'] as String? ?? '')).toList();

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
          'status':         'synced',
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

  static int _parseFileSecs(String name) {
    // Format: SESSIONID_DATE_TIME_NN_MM-MM.mp4
    // MM-MM are minute markers
    final m = RegExp(r'_(\d{2})-(\d{2})\.mp4$').firstMatch(name);
    if (m == null) return 0;
    return (int.parse(m.group(2)!) - int.parse(m.group(1)!)) * 60;
  }

  static int _parsePartNumber(String name) {
    final m = RegExp(r'_(\d{2})_\d{2}-\d{2}\.mp4$').firstMatch(name);
    if (m == null) return 1;
    return int.parse(m.group(1)!);
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

    // Build list of date folders in the range
    final folders = <String>[];
    var cur = DateTime(from.year, from.month, from.day);
    final end = DateTime(to.year, to.month, to.day);
    while (!cur.isAfter(end)) {
      folders.add(DateFormat('dd-MM-yyyy').format(cur));
      cur = cur.add(const Duration(days: 1));
    }

    if (folders.isEmpty) return Stream.value(const DashMetrics(totalSecs: 0, sessionCount: 0));

    // Firestore 'whereIn' supports max 30 items
    final limited = folders.take(30).toList();

    return col
        .where('dateFolder', whereIn: limited)
        .snapshots()
        .map((snap) {
          int totalSecs = 0;
          for (final doc in snap.docs) {
            totalSecs += (doc.data()['totalSecs'] as num? ?? 0).toInt();
          }
          return DashMetrics(totalSecs: totalSecs, sessionCount: snap.docs.length);
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
            'status':         'uploading',
            'updatedAt':      FieldValue.serverTimestamp(),
          });
        } else {
          final data  = snap.data()!;
          final parts = List<int>.from(data['parts'] as List? ?? []);
          if (!parts.contains(partNumber)) parts.add(partNumber);
          tx.update(ref, {
            'chunksUploaded': FieldValue.increment(1),
            'totalSecs':      FieldValue.increment(chunkDurationSecs),
            'totalBytes':     FieldValue.increment(chunkSizeBytes),
            'parts':          parts,
            'updatedAt':      FieldValue.serverTimestamp(),
          });
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
    } catch (_) {}
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
  final List<int> parts;
  final String    status;

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
    status:         d['status']        as String? ?? 'uploading',
  );

  double get totalMb => totalBytes / 1024 / 1024;
}

class DashMetrics {
  final int totalSecs;
  final int sessionCount;
  const DashMetrics({required this.totalSecs, required this.sessionCount});
}