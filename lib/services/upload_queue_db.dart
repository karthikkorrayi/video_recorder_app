import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';

// ─── Status constants (stored as TEXT in DB) ──────────────────────────────────
// pending   → waiting for network / workmanager to pick up
// uploading → actively being uploaded (reset to pending on app start)
// done      → confirmed on OneDrive — local file safe to delete
// failed    → exhausted retries — user must tap Retry
// ─────────────────────────────────────────────────────────────────────────────

class UploadQueueDb {
  static final UploadQueueDb instance = UploadQueueDb._();
  UploadQueueDb._();

  static Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir  = await getDatabasesPath();
    final path = p.join(dir, 'otn_upload_queue.db');
    return openDatabase(
      path,
      // ── VERSION 3: adds upload_session_expiry column ──────────────────
      version: 3,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
              'ALTER TABLE upload_queue ADD COLUMN total_parts INTEGER NOT NULL DEFAULT 0');
          debugPrint('=== DB migrated v1→v2: added total_parts column');
        }
        if (oldVersion < 3) {
          // Expiry timestamp (ms) for OneDrive upload sessions.
          // NULL = no session URL stored (safe default).
          await db.execute(
              'ALTER TABLE upload_queue ADD COLUMN upload_session_expiry INTEGER');
          debugPrint('=== DB migrated v2→v3: added upload_session_expiry column');
        }
      },
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE upload_queue (
            chunk_id               TEXT PRIMARY KEY,
            session_id             TEXT NOT NULL,
            local_file_path        TEXT NOT NULL,
            onedrive_path          TEXT NOT NULL,
            file_name              TEXT NOT NULL,
            file_size_bytes        INTEGER NOT NULL DEFAULT 0,
            bytes_uploaded         INTEGER NOT NULL DEFAULT 0,
            total_parts            INTEGER NOT NULL DEFAULT 0,
            upload_session_url     TEXT,
            upload_session_expiry  INTEGER,
            status                 TEXT NOT NULL DEFAULT 'pending',
            retry_count            INTEGER NOT NULL DEFAULT 0,
            part_number            INTEGER NOT NULL DEFAULT 1,
            start_sec              INTEGER NOT NULL DEFAULT 0,
            end_sec                INTEGER NOT NULL DEFAULT 0,
            session_date_ms        INTEGER NOT NULL DEFAULT 0,
            session_start_ms       INTEGER NOT NULL DEFAULT 0,
            user_id                TEXT NOT NULL DEFAULT '',
            created_at             INTEGER NOT NULL,
            updated_at             INTEGER NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_session ON upload_queue(session_id)');
        await db.execute(
            'CREATE INDEX idx_status ON upload_queue(status)');
      },
    );
  }

  // ── Insert ──────────────────────────────────────────────────────────────────
  Future<void> insertChunk(Map<String, dynamic> row) async {
    final d = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await d.insert(
      'upload_queue',
      {...row, 'created_at': now, 'updated_at': now},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    debugPrint('=== DB insert: ${row['chunk_id']}');
  }

  // ── Update local file path (when file moved to alternate location) ─────────
  Future<void> updateFilePath(String chunkId, String newPath) async {
    final d = await db;
    await d.update(
      'upload_queue',
      {'local_file_path': newPath, 'chunk_id': newPath,
       'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'chunk_id = ?', whereArgs: [chunkId],
    );
    debugPrint('=== DB: updated file path for $chunkId → $newPath');
  }

  // ── Update status ───────────────────────────────────────────────────────────
  Future<void> updateStatus(String chunkId, String status) async {
    final d = await db;
    await d.update(
      'upload_queue',
      {'status': status, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'chunk_id = ?',
      whereArgs: [chunkId],
    );
  }

  // ── Update bytes uploaded + optional session URL + expiry (for resume) ──────
  Future<void> updateProgress(String chunkId,
      {required int bytesUploaded,
      String? uploadSessionUrl,
      DateTime? uploadSessionExpiry}) async {
    final d = await db;
    final vals = <String, dynamic>{
      'bytes_uploaded': bytesUploaded,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    if (uploadSessionUrl != null) vals['upload_session_url'] = uploadSessionUrl;
    if (uploadSessionExpiry != null) {
      vals['upload_session_expiry'] = uploadSessionExpiry.millisecondsSinceEpoch;
    }
    await d.update('upload_queue', vals,
        where: 'chunk_id = ?', whereArgs: [chunkId]);
  }

  // ── Save / clear upload session URL + expiry atomically ─────────────────────
  Future<void> saveUploadSession(
      String chunkId, String url, DateTime expiry) async {
    final d = await db;
    await d.update(
      'upload_queue',
      {
        'upload_session_url':    url,
        'upload_session_expiry': expiry.millisecondsSinceEpoch,
        'updated_at':            DateTime.now().millisecondsSinceEpoch,
      },
      where: 'chunk_id = ?',
      whereArgs: [chunkId],
    );
  }

  Future<void> clearUploadSession(String chunkId) async {
    final d = await db;
    await d.update(
      'upload_queue',
      {
        'upload_session_url':    null,
        'upload_session_expiry': null,
        'bytes_uploaded':        0,
        'updated_at':            DateTime.now().millisecondsSinceEpoch,
      },
      where: 'chunk_id = ?',
      whereArgs: [chunkId],
    );
  }

  // ── Returns true if stored session URL is still valid (not expired) ─────────
  Future<bool> hasValidSession(String chunkId) async {
    final d = await db;
    final rows = await d.query('upload_queue',
        columns: ['upload_session_url', 'upload_session_expiry'],
        where: 'chunk_id = ?',
        whereArgs: [chunkId],
        limit: 1);
    if (rows.isEmpty) return false;
    final url    = rows.first['upload_session_url'] as String?;
    final expiry = rows.first['upload_session_expiry'] as int?;
    if (url == null || url.isEmpty) return false;
    if (expiry == null) return false;
    // Consider expired if within 10 minutes of actual expiry
    return DateTime.now().millisecondsSinceEpoch < expiry - 600000;
  }

  // ── Increment retry count ───────────────────────────────────────────────────
  Future<void> incrementRetry(String chunkId) async {
    final d = await db;
    await d.rawUpdate(
      'UPDATE upload_queue SET retry_count = retry_count + 1, updated_at = ? WHERE chunk_id = ?',
      [DateTime.now().millisecondsSinceEpoch, chunkId],
    );
  }

  // ── Mark done ───────────────────────────────────────────────────────────────
  Future<void> markDone(String chunkId) async {
    await updateStatus(chunkId, 'done');
    debugPrint('=== DB done: $chunkId');
  }

  // ── Mark failed ─────────────────────────────────────────────────────────────
  Future<void> markFailed(String chunkId) async {
    await updateStatus(chunkId, 'failed');
    debugPrint('=== DB failed: $chunkId');
  }

  // ── Delete row (after confirmed upload + local delete) ──────────────────────
  Future<void> deleteChunk(String chunkId) async {
    final d = await db;
    await d.delete('upload_queue',
        where: 'chunk_id = ?', whereArgs: [chunkId]);
  }

  // ── Purge all done rows older than [days] days ───────────────────────────
  // Called once on app start to clean up any done rows left behind by older
  // versions of the app that didn't delete rows on upload completion.
  // This is the safety net for the ghost-session bug — even if deleteChunk()
  // wasn't called at upload time, done rows get cleaned up within [days] days.
  Future<int> purgeDoneRows({int olderThanDays = 2}) async {
    final d       = await db;
    final cutoff  = DateTime.now()
        .subtract(Duration(days: olderThanDays))
        .millisecondsSinceEpoch;
    final count   = await d.delete(
      'upload_queue',
      where: "status = 'done' AND updated_at < ?",
      whereArgs: [cutoff],
    );
    if (count > 0) debugPrint('=== DB: purged $count stale done rows');
    return count;
  }

  // ── Reset any 'uploading' → 'pending' on app start ──────────────────────────
  // Keeps bytes_uploaded and upload_session_url for resume capability.
  // Expiry is also kept — hasValidSession() decides whether to reuse or recreate.
  Future<void> resetStuckUploadingKeepProgress() async {
    final d = await db;
    final count = await d.rawUpdate(
      "UPDATE upload_queue SET status = 'pending', updated_at = ? "
      "WHERE status = 'uploading'",
      [DateTime.now().millisecondsSinceEpoch],
    );
    if (count > 0) debugPrint('=== DB reset $count stuck → pending (keeping progress + session)');
  }

  // Legacy version that resets progress (keep for compatibility)
  Future<void> resetStuckUploading() async {
    await resetStuckUploadingKeepProgress();
  }

  // ── Fetch all pending chunks ordered by session + part ──────────────────────
  Future<List<Map<String, dynamic>>> getPending() async {
    final d = await db;
    return d.query(
      'upload_queue',
      where: "status = 'pending'",
      orderBy: 'session_date_ms ASC, session_id ASC, part_number ASC',
    );
  }

  // ── Fetch every chunk in the DB (any status, any session) ──────────────
  Future<List<Map<String, dynamic>>> getAllChunks() async {
    final d = await db;
    return d.query('upload_queue', orderBy: 'created_at ASC');
  }

  // ── Fetch all chunks for a session (any status) ──────────────────────────
  Future<List<Map<String, dynamic>>> getSessionChunks(String sessionId) async {
    final d = await db;
    return d.query(
      'upload_queue',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'part_number ASC',
    );
  }

  // ── Fetch all non-done for UI display ──────────────────────────────────────
  Future<List<Map<String, dynamic>>> getActive() async {
    final d = await db;
    return d.query(
      'upload_queue',
      where: "status != 'done'",
      orderBy: 'session_date_ms ASC, session_id ASC, part_number ASC',
    );
  }

  // ── Session-level helpers ───────────────────────────────────────────────────
  Future<bool> isSessionFullyDone(String sessionId) async {
    final d = await db;
    final rows = await d.query(
      'upload_queue',
      columns: ['status', 'total_parts'],
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
    if (rows.isEmpty) return false;
    final declaredTotal = (rows.first['total_parts'] as int? ?? 0);
    final doneCount     = rows.where((r) => r['status'] == 'done').length;
    if (declaredTotal > 0) {
      return doneCount >= declaredTotal;
    }
    return rows.isNotEmpty && rows.every((r) => r['status'] == 'done');
  }

  Future<void> setSessionTotalParts(String sessionId, int totalParts) async {
    final d = await db;
    await d.update(
      'upload_queue',
      {'total_parts': totalParts, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
    debugPrint('=== DB: session $sessionId totalParts set to $totalParts');
  }

  Future<bool> sessionHasAnyPending(String sessionId) async {
    final d = await db;
    final rows = await d.query(
      'upload_queue',
      where: "session_id = ? AND status IN ('pending','uploading','failed')",
      whereArgs: [sessionId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  // ── Retry all failed ────────────────────────────────────────────────────────
  Future<void> retryAllFailed() async {
    final d = await db;
    // Also clear session URLs — they may have expired during the failure window
    await d.rawUpdate(
      "UPDATE upload_queue SET status = 'pending', retry_count = 0, "
      "bytes_uploaded = 0, upload_session_url = NULL, "
      "upload_session_expiry = NULL, updated_at = ? "
      "WHERE status = 'failed'",
      [DateTime.now().millisecondsSinceEpoch],
    );
    debugPrint('=== DB retryAllFailed done');
  }

  // ── Stats ───────────────────────────────────────────────────────────────────
  Future<Map<String, int>> getStats() async {
    final d = await db;
    final rows = await d.rawQuery(
      "SELECT status, COUNT(*) as cnt FROM upload_queue GROUP BY status",
    );
    return {for (final r in rows) r['status'] as String: r['cnt'] as int};
  }
}