import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Persists the upload queue state to app documents directory.
/// This directory is NOT cleared when user swipes app from recents
/// or clears app cache — only cleared when user uninstalls the app.
///
/// Each pending chunk is stored as a JSON entry. On app open,
/// recoverFromPersistence() re-enqueues all unfinished chunks.
class QueuePersistence {
  static const _fileName = 'otn_pending_queue.json';

  static QueuePersistence? _instance;
  static QueuePersistence get instance => _instance ??= QueuePersistence._();
  QueuePersistence._();

  File? _file;

  Future<File> _getFile() async {
    if (_file != null) return _file!;
    final dir  = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/$_fileName');
    return _file!;
  }

  /// Save all pending chunk entries to disk.
  Future<void> save(List<Map<String, dynamic>> entries) async {
    try {
      final file = await _getFile();
      await file.writeAsString(jsonEncode(entries));
      debugPrint('=== QueuePersist: saved ${entries.length} entries');
    } catch (e) {
      debugPrint('=== QueuePersist save error: $e');
    }
  }

  /// Load all pending chunk entries from disk.
  Future<List<Map<String, dynamic>>> load() async {
    try {
      final file = await _getFile();
      if (!await file.exists()) return [];
      final raw  = await file.readAsString();
      final list = jsonDecode(raw) as List;
      debugPrint('=== QueuePersist: loaded ${list.length} entries');
      return list.cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('=== QueuePersist load error: $e');
      return [];
    }
  }

  /// Remove a single entry by filePath (called after successful upload).
  Future<void> remove(String filePath) async {
    try {
      final entries = await load();
      final updated = entries.where((e) => e['filePath'] != filePath).toList();
      await save(updated);
    } catch (e) {
      debugPrint('=== QueuePersist remove error: $e');
    }
  }

  /// Clear all entries (called when user explicitly clears queue).
  Future<void> clear() async {
    try {
      final file = await _getFile();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Convert a PendingChunk to a storable map.
  static Map<String, dynamic> chunkToMap(dynamic chunk) => {
    'filePath':         chunk.filePath,
    'backupPath':       chunk.backupPath,
    'sessionId':        chunk.sessionId,
    'userId':           chunk.userId,
    'partNumber':       chunk.partNumber,
    'sessionDateMs':    chunk.sessionDate.millisecondsSinceEpoch,
    'sessionStartMs':   chunk.sessionStartTime.millisecondsSinceEpoch,
    'sessionEndMs':     chunk.sessionEndTime.millisecondsSinceEpoch,
    'startSec':         chunk.startSec,
    'endSec':           chunk.endSec,
  };
}