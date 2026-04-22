import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'onedrive_service.dart';
import 'user_service.dart';

/// Local cache for OneDrive file list.
/// Persists to SharedPreferences — survives app restarts.
/// Both Dashboard and History read from here for instant display.
/// Background sync updates it periodically and on network return.
class CloudCacheService {
  static final CloudCacheService _i = CloudCacheService._();
  factory CloudCacheService() => _i;
  CloudCacheService._();

  static const _key        = 'cloud_file_cache_v2';
  static const _syncKey    = 'cloud_last_sync';
  static const _syncInterval = Duration(minutes: 5);

  final _onedrive = OneDriveService();

  // In-memory cache — fast access, no disk read on every call
  List<Map<String, dynamic>> _files    = [];
  DateTime?                  _lastSync;
  bool                       _syncing  = false;

  // Stream so UI rebuilds when cache updates
  final _ctrl = StreamController<CacheState>.broadcast();
  Stream<CacheState> get stream => _ctrl.stream;

  CacheState get current => CacheState(
    files:     _files,
    lastSync:  _lastSync,
    isSyncing: _syncing,
    isStale:   _lastSync == null ||
        DateTime.now().difference(_lastSync!) > _syncInterval,
  );

  void _emit() => _ctrl.add(current);

  // ── Init: load from disk, then sync from cloud ────────────────────────────
  Future<void> init() async {
    await _loadFromDisk();
    _emit();
    syncNow(); // background sync on startup
  }

  Future<void> _loadFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getString(_key);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        _files = list.cast<Map<String, dynamic>>();
      }
      final syncMs = prefs.getInt(_syncKey);
      if (syncMs != null) {
        _lastSync = DateTime.fromMillisecondsSinceEpoch(syncMs);
      }
      debugPrint('=== CloudCache: loaded ${_files.length} files from disk');
    } catch (e) {
      debugPrint('=== CloudCache loadFromDisk error: $e');
    }
  }

  Future<void> _saveToDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(_files));
      if (_lastSync != null) {
        await prefs.setInt(_syncKey, _lastSync!.millisecondsSinceEpoch);
      }
    } catch (e) {
      debugPrint('=== CloudCache saveToDisk error: $e');
    }
  }

  // ── Sync from OneDrive ────────────────────────────────────────────────────
  Future<void> syncNow() async {
    if (_syncing) return;
    _syncing = true;
    _emit();
    try {
      final user  = await UserService().getDisplayName();
      final files = await _onedrive.listUserFiles(
          rootFolder: 'OTN Recorder', userFolder: user);
      _files    = files;
      _lastSync = DateTime.now();
      await _saveToDisk();
      debugPrint('=== CloudCache: synced ${files.length} files');
    } catch (e) {
      debugPrint('=== CloudCache sync error: $e — using cached data');
      // Keep existing cache — show stale data
    } finally {
      _syncing = false;
      _emit();
    }
  }

  // ── Getters ───────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> get files     => _files;
  DateTime?                  get lastSync  => _lastSync;
  bool                       get isSyncing => _syncing;
  bool get isStale => _lastSync == null ||
      DateTime.now().difference(_lastSync!) > _syncInterval;

  /// Q2: Silent sync label — never shows "Syncing..." spinner in UI.
  /// Only shows the last known sync time. Sync runs invisibly in background.
  String get lastSyncLabel {
    if (_lastSync == null) return 'Never synced';
    final diff = DateTime.now().difference(_lastSync!);
    if (diff.inSeconds < 60)  return 'Just now';
    if (diff.inMinutes < 60)  return '${diff.inMinutes}m ago';
    if (diff.inHours   < 24)  return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  /// Q1: Sync only if cache is stale (>5 min old). Safe to call on screen open.
  /// Returns immediately if fresh or already syncing — never blocks UI.
  void syncIfStale() {
    if (_syncing) return;
    if (isStale) syncNow(); // fire-and-forget, UI updates via stream
  }

  /// Force clear local cache and re-sync from scratch.
  /// Use when cloud data has changed (deletions, renames) and cache is stale.
  Future<void> clearAndSync() async {
    _files    = [];
    _lastSync = null;
    await _saveToDisk();
    _emit();
    await syncNow();
  }
}

class CacheState {
  final List<Map<String, dynamic>> files;
  final DateTime? lastSync;
  final bool isSyncing;
  final bool isStale;
  const CacheState({
    required this.files, required this.lastSync,
    required this.isSyncing, required this.isStale,
  });
}