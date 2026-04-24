import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'onedrive_service.dart';
import 'user_service.dart';
import 'chunk_upload_queue.dart' show fmtDuration;

class CloudCacheService {
  static final CloudCacheService _i = CloudCacheService._();
  factory CloudCacheService() => _i;
  CloudCacheService._();

  static const _key          = 'cloud_file_cache_v5';
  static const _syncKey      = 'cloud_last_sync_v5';
  static const _syncInterval = Duration(minutes: 5);

  final _onedrive = OneDriveService();

  List<Map<String, dynamic>> _files    = [];
  DateTime?                  _lastSync;
  bool                       _syncing  = false;
  DateTime?                  _lastUploadCompletedAt;

  final _ctrl = StreamController<CacheState>.broadcast();
  Stream<CacheState> get stream => _ctrl.stream;

  CacheState get current => CacheState(
    files: _files, lastSync: _lastSync, isSyncing: _syncing,
    isStale: _lastSync == null || DateTime.now().difference(_lastSync!) > _syncInterval,
    lastUploadCompletedAt: _lastUploadCompletedAt,
  );

  void _emit() => _ctrl.add(current);

  // ── Init ──────────────────────────────────────────────────────────────────
  Future<void> init() async {
    await _loadFromDisk();
    _emit();
    await syncNow();
  }

  Future<void> _loadFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getString(_key);
      if (raw != null) {
        _files = (jsonDecode(raw) as List)
            .cast<Map<String, dynamic>>()
            .where((f) => (f['size'] as int? ?? 0) > 0)
            .toList();
      }
      final ms = prefs.getInt(_syncKey);
      if (ms != null) _lastSync = DateTime.fromMillisecondsSinceEpoch(ms);
      debugPrint('=== CloudCache: loaded ${_files.length} files from disk');
    } catch (e) { debugPrint('=== CloudCache loadFromDisk: $e'); }
  }

  Future<void> _saveToDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(_files));
      if (_lastSync != null) await prefs.setInt(_syncKey, _lastSync!.millisecondsSinceEpoch);
    } catch (e) { debugPrint('=== CloudCache saveToDisk: $e'); }
  }

  Future<void> syncNow() async {
    if (_syncing) return;
    _syncing = true;
    _emit();
    try {
      final user  = await UserService().getDisplayName();
      final files = await _onedrive.listUserFiles(
          rootFolder: 'OTN Recorder', userFolder: user);

      // Filter 0-byte and deduplicate
      final seen  = <String>{};
      final dedup = <Map<String, dynamic>>[];
      for (final f in files) {
        if ((f['size'] as int? ?? 0) == 0) continue;
        final key = f['name'] as String? ?? '';
        if (key.isNotEmpty && seen.add(key)) dedup.add(f);
      }

      final prevCount = _files.length;
      _files    = dedup;
      _lastSync = DateTime.now();
      await _saveToDisk();
      debugPrint('=== CloudCache: synced ${dedup.length} files');

      if (dedup.length > prevCount) _lastUploadCompletedAt = DateTime.now();
      OneDriveService.writeAdminAttendanceCsv().ignore();

    } catch (e) {
      debugPrint('=== CloudCache sync error: $e');
    } finally {
      _syncing = false;
      _emit();
    }
  }

  List<Map<String, dynamic>> get files     => _files;
  DateTime?                  get lastSync  => _lastSync;
  bool                       get isSyncing => _syncing;
  bool get isStale => _lastSync == null || DateTime.now().difference(_lastSync!) > _syncInterval;

  String get lastSyncLabel {
    if (_lastSync == null) return 'Never synced';
    final diff = DateTime.now().difference(_lastSync!);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours   < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  void syncIfStale() { if (!_syncing && isStale) syncNow(); }

  // ── Computed metrics ──────────────────────────────────────────────────────

  /// Issue 1: Total duration in SECONDS for a date folder
  int totalSecsForFolder(String dateFolder) {
    return _files
        .where((f) => f['dateFolder'] == dateFolder)
        .fold(0, (s, f) => s + _parseFileSecs(f['name'] as String? ?? ''));
  }

  /// Issue 1: Formatted duration string (handles seconds)
  String formattedDurationForFolder(String dateFolder) =>
      fmtDuration(totalSecsForFolder(dateFolder));

  int sessionCountForFolder(String dateFolder) => _files
      .where((f) => f['dateFolder'] == dateFolder)
      .map((f) => f['sessionFolder'] as String? ?? '')
      .toSet().length;

  /// Issue 3: Group files by sessionFolder, sorted LATEST FIRST
  /// within a date filter. Session key order = newest session folder name desc.
  Map<String, List<Map<String, dynamic>>> groupedSessions(
      List<Map<String, dynamic>> filteredFiles) {
    final result = <String, List<Map<String, dynamic>>>{};

    for (final f in filteredFiles) {
      final key = (f['sessionFolder'] as String?)?.isNotEmpty == true
          ? f['sessionFolder'] as String
          : (f['dateFolder'] as String? ?? 'Unknown');
      result.putIfAbsent(key, () => []);
      final name = f['name'] as String? ?? '';
      if (!result[key]!.any((e) => e['name'] == name)) result[key]!.add(f);
    }

    // Sort parts within each session by part number (ascending)
    for (final parts in result.values) {
      parts.sort((a, b) =>
          (a['name'] as String? ?? '').compareTo(b['name'] as String? ?? ''));
    }

    // Issue 3: Sort sessions LATEST FIRST
    // Session folder name format: SESSIONID_YYYYMMDD_HHMMSS
    // Sorting desc by key = latest date+time first
    final sorted = result.entries.toList()
      ..sort((a, b) {
        // Sort by dateFolder desc first, then session folder desc
        final aDate = (result[a.key]!.isNotEmpty
            ? result[a.key]!.first['dateFolder'] as String? : null) ?? '';
        final bDate = (result[b.key]!.isNotEmpty
            ? result[b.key]!.first['dateFolder'] as String? : null) ?? '';
        // DD-MM-YYYY → compare as YYYY-MM-DD for correct ordering
        final ac = _normDate(aDate);
        final bc = _normDate(bDate);
        final dc = bc.compareTo(ac); // desc
        if (dc != 0) return dc;
        return b.key.compareTo(a.key); // session folder desc within same date
      });

    return Map.fromEntries(sorted);
  }

  String _normDate(String ddmmyyyy) {
    final p = ddmmyyyy.split('-');
    if (p.length != 3) return ddmmyyyy;
    return '${p[2]}-${p[1]}-${p[0]}'; // YYYY-MM-DD for proper comparison
  }

  /// Issue 1: Parse duration in SECONDS from new filename format
  /// Format: SESSIONID_DATE_TIME_NN_MM-MM.mp4 (minute-level)
  static int _parseFileSecs(String name) {
    final m = RegExp(r'_(\d{2})-(\d{2})\.mp4').firstMatch(name);
    if (m == null) return 0;
    final startMin = int.parse(m.group(1)!);
    final endMin   = int.parse(m.group(2)!);
    return (endMin - startMin) * 60; // in seconds
  }

  /// Expose for history screen
  static int parseFileSecs(String name) => _parseFileSecs(name);
}

class CacheState {
  final List<Map<String, dynamic>> files;
  final DateTime? lastSync;
  final DateTime? lastUploadCompletedAt;
  final bool isSyncing;
  final bool isStale;
  const CacheState({
    required this.files, required this.lastSync, required this.isSyncing,
    required this.isStale, this.lastUploadCompletedAt,
  });
}