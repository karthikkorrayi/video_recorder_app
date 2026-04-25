import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Fast metadata cache backed by Firestore.
/// Structure: users/{uid}/sessions/{sessionId} → metadata doc
///
/// Written after each chunk upload completes.
/// Read instantly on app open — no OneDrive API calls needed for metrics.
///
/// OneDrive remains the source of truth for actual video files.
/// Firestore only stores lightweight metadata for fast UI updates.
class FirestoreCacheService {
  static final FirestoreCacheService _i = FirestoreCacheService._();
  factory FirestoreCacheService() => _i;
  FirestoreCacheService._();

  FirebaseFirestore get _db  => FirebaseFirestore.instance;
  String?           get _uid => FirebaseAuth.instance.currentUser?.uid;

  CollectionReference<Map<String, dynamic>>? get _sessions {
    final uid = _uid;
    if (uid == null) return null;
    return _db.collection('users').doc(uid).collection('sessions');
  }

  // ── Stream: real-time session list ───────────────────────────────────────

  /// Streams session metadata for a specific date folder (DD-MM-YYYY).
  /// Returns empty list if not signed in.
  Stream<List<SessionMeta>> sessionsForDate(String dateFolder) {
    final col = _sessions;
    if (col == null) return const Stream.empty();
    return col
        .where('dateFolder', isEqualTo: dateFolder)
        .orderBy('sessionStartMs', descending: true)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => SessionMeta.fromMap(d.id, d.data()))
            .toList());
  }

  /// Streams ALL sessions ordered by date desc.
  Stream<List<SessionMeta>> allSessions() {
    final col = _sessions;
    if (col == null) return const Stream.empty();
    return col
        .orderBy('sessionStartMs', descending: true)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => SessionMeta.fromMap(d.id, d.data()))
            .toList());
  }

  // ── Write: called after each chunk upload confirmed ───────────────────────

  /// Upserts session metadata after a chunk is confirmed on OneDrive.
  /// Increments chunksUploaded, totalSecs, totalBytes.
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
            'sessionId':       sessionId,
            'dateFolder':      dateFolder,
            'userFolder':      userFolder,
            'sessionFolder':   sessionFolder,
            'sessionStartMs':  sessionStartMs,
            'chunksUploaded':  1,
            'totalSecs':       chunkDurationSecs,
            'totalBytes':      chunkSizeBytes,
            'parts':           [partNumber],
            'status':          'uploading',
            'updatedAt':       FieldValue.serverTimestamp(),
          });
        } else {
          final data  = snap.data()!;
          final parts = List<int>.from(data['parts'] as List? ?? []);
          if (!parts.contains(partNumber)) parts.add(partNumber);
          tx.update(ref, {
            'chunksUploaded':  FieldValue.increment(1),
            'totalSecs':       FieldValue.increment(chunkDurationSecs),
            'totalBytes':      FieldValue.increment(chunkSizeBytes),
            'parts':           parts,
            'updatedAt':       FieldValue.serverTimestamp(),
          });
        }
      });
    } catch (e) {
      debugPrint('=== Firestore recordChunkUploaded error: $e');
    }
  }

  /// Mark a session as fully synced (all chunks uploaded).
  Future<void> markSessionSynced(String sessionId) async {
    final col = _sessions;
    if (col == null) return;
    try {
      await col.doc(sessionId).update({
        'status':    'synced',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('=== Firestore markSessionSynced error: $e');
    }
  }

  // ── Aggregated metrics (used by dashboard) ────────────────────────────────

  /// One-time fetch of today's metrics: total secs + session count.
  /// Fast — Firestore local cache returns instantly.
  Future<DashMetrics> todayMetrics(String dateFolder) async {
    final col = _sessions;
    if (col == null) return const DashMetrics(totalSecs: 0, sessionCount: 0);
    try {
      final snap = await col
          .where('dateFolder', isEqualTo: dateFolder)
          .get(); // uses default (server + cache) — works in v4
      int totalSecs    = 0;
      int sessionCount = 0;
      for (final doc in snap.docs) {
        final d = doc.data();
        totalSecs    += (d['totalSecs']  as num? ?? 0).toInt();
        sessionCount += 1;
      }
      return DashMetrics(totalSecs: totalSecs, sessionCount: sessionCount);
    } catch (e) {
      debugPrint('=== Firestore todayMetrics error: $e');
      return const DashMetrics(totalSecs: 0, sessionCount: 0);
    }
  }

  /// Stream of today's metrics — updates in real-time as chunks upload.
  Stream<DashMetrics> todayMetricsStream(String dateFolder) {
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
          return DashMetrics(
              totalSecs:    totalSecs,
              sessionCount: snap.docs.length);
        });
  }

  // ── Clear user data (on logout) ───────────────────────────────────────────
  Future<void> clearLocalCache() async {
    try {
      await _db.clearPersistence();
    } catch (_) {}
  }
}

// ── Models ────────────────────────────────────────────────────────────────────

class SessionMeta {
  final String sessionId;
  final String dateFolder;
  final String userFolder;
  final String sessionFolder;
  final int    sessionStartMs;
  final int    chunksUploaded;
  final int    totalSecs;
  final int    totalBytes;
  final List<int> parts;
  final String status;

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