import 'dart:io';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

/// Saves videos to a public folder visible in the device Files app:
///   /storage/emulated/0/Movies/KineSync/
///     recordings/
///       YYYY-MM-DD/
///         <username>/
///           <userId>_YYYYMMDD_HHmmss.mp4          ← single block
///           <userId>_YYYYMMDD_HHmmss_block01of03.mp4  ← multi-block
///
/// Attendance logs:
///   /storage/emulated/0/Movies/KineSync/attendance/<username>_attendance.txt
class LocalVideoStorage {
  static final LocalVideoStorage _i = LocalVideoStorage._();
  factory LocalVideoStorage() => _i;
  LocalVideoStorage._();

  static const _appFolder = 'KineSync';

  // ─── Permission ───────────────────────────────────────────────────────────

  /// Must be called before writing. Returns true if permission granted.
  static Future<bool> requestStoragePermission() async {
    // Android 13+ (API 33+): no permission needed for own-created files in public dirs
    // Android 11–12 (API 30–32): MANAGE_EXTERNAL_STORAGE for full access
    // Android 10 and below: READ/WRITE_EXTERNAL_STORAGE
    if (Platform.isAndroid) {
      final sdkInt = await _getSdkInt();
      if (sdkInt >= 30) {
        // Request MANAGE_EXTERNAL_STORAGE for Android 11+
        final status = await Permission.manageExternalStorage.request();
        if (status.isGranted) return true;
        // Fallback: even without it, we can still write to our Movies subfolder
        // on most devices. Try without.
        return true;
      } else {
        final status = await Permission.storage.request();
        return status.isGranted;
      }
    }
    return true;
  }

  static Future<int> _getSdkInt() async {
    try {
      final result = await Process.run('getprop', ['ro.build.version.sdk']);
      return int.tryParse(result.stdout.toString().trim()) ?? 29;
    } catch (_) {
      return 29;
    }
  }

  // ─── Directories ──────────────────────────────────────────────────────────

  /// Public base: /storage/emulated/0/Movies/KineSync/recordings/
  Future<Directory> _baseDir() async {
    // Primary public external storage
    const publicPath = '/storage/emulated/0/Movies/$_appFolder/recordings';
    final dir = Directory(publicPath);
    try {
      await dir.create(recursive: true);
      // Quick write test
      final test = File('${dir.path}/.test');
      await test.writeAsString('ok');
      await test.delete();
      return dir;
    } catch (_) {
      // Fallback to secondary external or internal
      final fallback = Directory('/storage/emulated/0/$_appFolder/recordings');
      await fallback.create(recursive: true);
      return fallback;
    }
  }

  /// Attendance folder: /storage/emulated/0/Movies/KineSync/attendance/
  Future<Directory> _attendanceDir() async {
    const path = '/storage/emulated/0/Movies/$_appFolder/attendance';
    final dir = Directory(path);
    try {
      await dir.create(recursive: true);
      return dir;
    } catch (_) {
      final fb = Directory('/storage/emulated/0/$_appFolder/attendance');
      await fb.create(recursive: true);
      return fb;
    }
  }

  /// Session folder: recordings/YYYY-MM-DD/<username>/
  Future<Directory> sessionDir(DateTime t, String userEmail) async {
    final base = await _baseDir();
    final date = DateFormat('yyyy-MM-dd').format(t);
    final user = _safe(userEmail.split('@').first);
    final dir = Directory('${base.path}/$date/$user');
    await dir.create(recursive: true);
    return dir;
  }

  // ─── File naming ──────────────────────────────────────────────────────────

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

  // ─── Attendance file ──────────────────────────────────────────────────────

  Future<File> attendanceFile(String userEmail) async {
    final dir = await _attendanceDir();
    final name = _safe(userEmail.split('@').first);
    return File('${dir.path}/${name}_attendance.txt');
  }

  // ─── Listing (user-specific) ──────────────────────────────────────────────

  Future<List<LocalSession>> listSessionsForUser(String userEmail) async {
    final base = await _baseDir();
    final username = _safe(userEmail.split('@').first);
    final sessions = <LocalSession>[];
    if (!await base.exists()) return sessions;

    final dateDirs = base.listSync().whereType<Directory>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));

    for (final dateDir in dateDirs) {
      final userDir = Directory('${dateDir.path}/$username');
      if (!await userDir.exists()) continue;

      final files = userDir.listSync().whereType<File>()
          .where((f) => f.path.endsWith('.mp4'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      final groups = <String, List<File>>{};
      for (final f in files) {
        final name = f.uri.pathSegments.last;
        final prefix = _prefix(name);
        if (prefix != null) groups.putIfAbsent(prefix, () => []).add(f);
      }

      final dateStr = dateDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
      for (final e in groups.entries) {
        final blocks = e.value;
        final total = _totalBlocks(blocks.first.uri.pathSegments.last) ?? 1;
        sessions.add(LocalSession(
          prefix: e.key, dateStr: dateStr, username: username,
          blocks: blocks, totalBlocks: total,
          isComplete: blocks.length == total,
        ));
      }
    }
    return sessions;
  }

  Future<int> sessionCount(String userEmail) async =>
      (await listSessionsForUser(userEmail)).length;

  Future<int> totalDurationSeconds(String userEmail) async {
    final s = await listSessionsForUser(userEmail);
    return s.fold<int>(0, (sum, s) => sum + s.estimatedDurationSeconds);
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  String _safe(String s) => s.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

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

// ─── Model ────────────────────────────────────────────────────────────────────

class LocalSession {
  final String prefix;
  final String dateStr;
  final String username;
  final List<File> blocks;
  final int totalBlocks;
  final bool isComplete;
  int? _cachedDuration;

  LocalSession({
    required this.prefix, required this.dateStr, required this.username,
    required this.blocks, required this.totalBlocks, required this.isComplete,
  });

  int get estimatedDurationSeconds {
    if (_cachedDuration != null) return _cachedDuration!;
    if (blocks.isNotEmpty) {
      final sidecar = File(blocks.first.path.replaceAll(RegExp(r'\.mp4$'), '.dur'));
      if (sidecar.existsSync()) {
        final v = int.tryParse(sidecar.readAsStringSync().trim());
        if (v != null) { _cachedDuration = v; return v; }
      }
    }
    return blocks.length * 120; // fallback estimate
  }

  String get displayTitle {
    final m = RegExp(r'(\d{8})_(\d{6})').firstMatch(prefix);
    if (m == null) return prefix;
    final d = m.group(1)!; final t = m.group(2)!;
    return '${d.substring(0,4)}-${d.substring(4,6)}-${d.substring(6,8)}'
        '  ${t.substring(0,2)}:${t.substring(2,4)}:${t.substring(4,6)}';
  }

  String get blockSummary =>
      totalBlocks == 1 ? '1 block' : '${blocks.length}/$totalBlocks blocks';

  String get durationStr {
    final s = estimatedDurationSeconds;
    if (s < 60) return '${s}s';
    final m = s ~/ 60; final r = s % 60;
    return r > 0 ? '${m}m ${r}s' : '${m}m';
  }
}