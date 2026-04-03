import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

class LocalVideoStorage {
  static final LocalVideoStorage _i = LocalVideoStorage._();
  factory LocalVideoStorage() => _i;
  LocalVideoStorage._();

  // ── Package name — must match applicationId in build.gradle.kts ──────────
  static const _pkg       = 'com.otn.videorecorder';
  static const _appFolder = 'OTN';

  // ── Permission ────────────────────────────────────────────────────────────
  // Android/media/<pkg>/ needs no runtime permission on Android 10+.
  // Kept for API compatibility only.
  static Future<bool> requestStoragePermission() async => true;

  // ── Core path builder ─────────────────────────────────────────────────────

  /// Builds the Android/media path and falls back to external files dir
  /// if somehow the media path isn't writable.
  Future<Directory> _baseDir() async {
    // Primary: Android/media/<pkg>/OTN/recordings
    // Visible in Files app, no permissions needed on Android 10+
    final mediaPath =
        '/storage/emulated/0/Android/media/$_pkg/$_appFolder/recordings';

    try {
      final dir = Directory(mediaPath);
      await dir.create(recursive: true);
      final t = File('${dir.path}/.wtest');
      await t.writeAsString('ok');
      await t.delete();
      return dir;
    } catch (_) {}
    final ext = await getExternalStorageDirectory();
    if (ext != null) {
      final dir = Directory('${ext.path}/$_appFolder/recordings');
      await dir.create(recursive: true);
      return dir;
    }

    // Last resort: app documents dir (internal, always available)
    final doc = await getApplicationDocumentsDirectory();
    final dir = Directory('${doc.path}/$_appFolder/recordings');
    await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _attendanceDir() async {
    final p = 
    '/storage/emulated/0/Android/media/$_pkg/$_appFolder/attendance';
    try {
      final d = Directory(p);
      await d.create(recursive: true);
      return d;
    } catch (_) {}

    final ext = await getExternalStorageDirectory();
    if (ext != null) {
      final d = Directory('${ext.path}/$_appFolder/attendance');
      await d.create(recursive: true);
      return d;
    }
    final doc = await getApplicationDocumentsDirectory();
    final d = Directory('${doc.path}/$_appFolder/attendance');
    await d.create(recursive: true);
    return d;
  }

  // ── Public accessors ──────────────────────────────────────────────────────

  Future<File> attendanceFile(String userEmail) async {
    final dir = await _attendanceDir();
    return File('${dir.path}/${_safe(userEmail.split('@').first)}_attendance.txt');
  }

  /// Returns (and creates) per-session folder:
  ///   recordings/YYYY-MM-DD/<username>/
  Future<Directory> sessionDir(DateTime t, String userEmail) async {
    final base = await _baseDir();
    final date = DateFormat('yyyy-MM-dd').format(t);
    final user = _safe(userEmail.split('@').first);
    final dir  = Directory('${base.path}/$date/$user');
    await dir.create(recursive: true);
    return dir;
  }

  // ── File naming ───────────────────────────────────────────────────────────

  String blockFileName({
    required String userId,
    required DateTime sessionTime,
    required int blockIndex,
    required int totalBlocks,
  }) {
    final dt = DateFormat('yyyyMMdd_HHmmss').format(sessionTime);
    final id = _safe(userId.length > 12 ? userId.substring(0, 12) : userId);
    if (totalBlocks == 1) return '${id}_$dt.mp4';
    final nn = blockIndex.toString().padLeft(2, '0');
    final mm = totalBlocks.toString().padLeft(2, '0');
    return '${id}_${dt}_block${nn}of${mm}.mp4';
  }

  // ── Listing ───────────────────────────────────────────────────────────────

  Future<List<LocalSession>> listSessionsForUser(String userEmail) async {
    final base     = await _baseDir();
    final username = _safe(userEmail.split('@').first);
    final sessions = <LocalSession>[];
    if (!await base.exists()) return sessions;

    final dateDirs = base.listSync().whereType<Directory>().toList()
      ..sort((a, b) => b.path.compareTo(a.path)); // newest date first

    for (final dateDir in dateDirs) {
      final userDir = Directory('${dateDir.path}/$username');
      if (!await userDir.exists()) continue;

      final files = userDir.listSync().whereType<File>()
          .where((f) => f.path.endsWith('.mp4'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path)); // ascending so block01 is first

      final groups = <String, List<File>>{};
      for (final f in files) {
        final prefix = _prefix(f.uri.pathSegments.last);
        if (prefix != null) groups.putIfAbsent(prefix, () => []).add(f);
      }

      final dateStr = 
      dateDir.uri.pathSegments.where((s) => s.isNotEmpty).last;

      for (final e in groups.entries) {
        final blocks = e.value;
        final total  = _totalBlocks(blocks.first.uri.pathSegments.last) ?? 1;
        sessions.add(LocalSession(
          prefix: e.key, dateStr: dateStr, username: username,
          blocks: blocks, totalBlocks: total,
          isComplete: blocks.length == total,
        ));
      }
    }
    return sessions;
  }

  Future<int> sessionCount(String u) async =>
      (await listSessionsForUser(u)).length;

  /// Returns actual total recorded seconds — reads .dur sidecars only.
  /// Never uses block count × block duration as fallback.
  Future<int> totalDurationSeconds(String userEmail) async {
    final sessions = await listSessionsForUser(userEmail);
    int total = 0;
    for (final s in sessions) {
      final d = s.durationSeconds; // reads .dur sidecar
      if (d > 0) total += d;
    }
    return total;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _safe(String s) =>
      s.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

  String? _prefix(String name) {
    final m1 = RegExp(r'^(.+_\d{8}_\d{6})_block\d+of\d+\.mp4$').firstMatch(name);
    if (m1 != null) return m1.group(1);
    final m2 = RegExp(r'^(.+_\d{8}_\d{6})\.mp4$').firstMatch(name);
    if (m2 != null) return m2.group(1);
    return null;
  }

  int? _totalBlocks(String name) {
    final m = RegExp(r'_block\d+of(\d+)\.mp4$').firstMatch(name);
    return m != null ? int.tryParse(m.group(1)!) : 1;
  }
}

// ── Model ─────────────────────────────────────────────────────────────────────

class LocalSession {
  final String     prefix;
  final String     dateStr;
  final String     username;
  final List<File> blocks;
  final int        totalBlocks;
  final bool       isComplete;

  LocalSession({
    required this.prefix,   required this.dateStr,
    required this.username, required this.blocks,
    required this.totalBlocks, required this.isComplete,
  });

  // ── Duration — reads .dur sidecar written by VideoProcessor ──────────────
  //
  // The .dur file contains the ACTUAL FFprobe-measured duration in seconds.
  // It is written next to the FIRST block file (block01ofNN or single block).
  //
  // We try every block's sidecar path until we find one that exists,
  // because on some devices the sort order may differ.
  //
  // NEVER falls back to blocks.length × blockSecs — that caused the inflation
  // (1 block × 300s = 5min even for a 2min video).
  //
  // Returns 0 if no sidecar found — UI shows "0s" rather than wrong value.

  int? _cachedDuration;

  int get durationSeconds {
    if (_cachedDuration != null) return _cachedDuration!;

    // Try sidecar for every block file until one is found
    for (final blockFile in blocks) {
      final sidecarPath = blockFile.path.replaceAll(RegExp(r'\.mp4$'), '.dur');
      final sidecar = File(sidecarPath);
      if (sidecar.existsSync()) {
        final raw = sidecar.readAsStringSync().trim();
        final val = int.tryParse(raw) ?? double.tryParse(raw)?.toInt();
        if (val != null && val > 0) {
          _cachedDuration = val;
          return _cachedDuration!;
        }
      }
    }

    // No sidecar found — return 0 (honest, not inflated)
    _cachedDuration = 0;
    return 0;
  }

  // ── Metadata (recording start/end) from .meta sidecar ────────────────────

  DateTime? _cachedStart;
  DateTime? _cachedEnd;
  bool _metaLoaded = false;

  void _loadMeta() {
    if (_metaLoaded) return;
    _metaLoaded = true;
    for (final blockFile in blocks) {
      final metaPath = blockFile.path.replaceAll(RegExp(r'\.mp4$'), '.meta');
      final meta = File(metaPath);
      if (meta.existsSync()) {
        final parts = meta.readAsStringSync().split('|');
        if (parts.length == 2) {
          try {
            _cachedStart = DateTime.parse(parts[0].trim());
            _cachedEnd   = DateTime.parse(parts[1].trim());
            return;
          } catch (_) {}
        }
      }
    }
  }

  DateTime get recordingStart {
    _loadMeta();
    return _cachedStart ?? _parseStartFromPrefix();
  }

  DateTime get recordingEnd {
    _loadMeta();
    if (_cachedEnd != null) return _cachedEnd!;
    final d = durationSeconds;
    return recordingStart.add(Duration(seconds: d > 0 ? d : 0));
  }

  DateTime _parseStartFromPrefix() {
    final m = RegExp(r'(\d{8})_(\d{6})').firstMatch(prefix);
    if (m == null) return DateTime.now();
    try {
      final d = m.group(1)!; final t = m.group(2)!;
      return DateTime(
        int.parse(d.substring(0, 4)), int.parse(d.substring(4, 6)),
        int.parse(d.substring(6, 8)), int.parse(t.substring(0, 2)),
        int.parse(t.substring(2, 4)), int.parse(t.substring(4, 6)),
      );
    } catch (_) { return DateTime.now(); }
  }

  // ── Display helpers ───────────────────────────────────────────────────────

  String get displayTitle {
    final m = RegExp(r'(\d{8})_(\d{6})').firstMatch(prefix);
    if (m == null) return prefix;
    final d = m.group(1)!; final t = m.group(2)!;
    return '${d.substring(0,4)}-${d.substring(4,6)}-${d.substring(6,8)}'
        '  ${t.substring(0,2)}:${t.substring(2,4)}:${t.substring(4,6)}';
  }

  String get blockSummary =>
      totalBlocks == 1 ? '1 block' : '${blocks.length}/$totalBlocks blocks';

  /// Human-readable duration — shows actual recorded time from .dur sidecar.
  String get durationStr {
    final s = durationSeconds;
    if (s <= 0) return '—';          // no sidecar yet (still processing)
    if (s < 60) return '${s}s';
    final m = s ~/ 60; 
    final r = s % 60;
    return r > 0 ? '${m}m ${r}s' : '${m}m';
  }

  /// Total minutes as a double (for display like "2.1 min")
  double get totalMinutes => durationSeconds / 60.0;

  String get startTimeStr {
    final t = recordingStart;
    return '${t.hour.toString().padLeft(2,'0')}:'
        '${t.minute.toString().padLeft(2,'0')}:'
        '${t.second.toString().padLeft(2,'0')}';
  }

  String get endTimeStr {
    final t = recordingEnd;
    return '${t.hour.toString().padLeft(2,'0')}:'
        '${t.minute.toString().padLeft(2,'0')}:'
        '${t.second.toString().padLeft(2,'0')}';
  }
}