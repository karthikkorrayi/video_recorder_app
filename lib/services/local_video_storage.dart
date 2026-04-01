import 'dart:io';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

/// Saves videos to Android's media folder — visible in dev/file manager:
///   /storage/emulated/0/Android/media/com.example.video_recorder_app/OTN/
///     recordings/YYYY-MM-DD/<username>/<userId>_YYYYMMDD_HHmmss.mp4
///
/// This path is writable without MANAGE_EXTERNAL_STORAGE on Android 10+.
/// Visible in Files app under: Internal Storage > Android > media > com.example... > OTN
class LocalVideoStorage {
  static final LocalVideoStorage _i = LocalVideoStorage._();
  factory LocalVideoStorage() => _i;
  LocalVideoStorage._();

  static const _pkg = 'com.example.video_recorder_app';
  static const _appFolder = 'OTN';

  // ─── Permission ───────────────────────────────────────────────────────────

  static Future<bool> requestStoragePermission() async {
    if (!Platform.isAndroid) return true;
    // Android/media/<pkg>/ is writable without special perms on Android 10+
    // For older Android we still request WRITE_EXTERNAL_STORAGE
    final sdkInt = await _sdkInt();
    if (sdkInt < 29) {
      final s = await Permission.storage.request();
      return s.isGranted;
    }
    return true; // Android 10+ — no permission needed for Android/media/<pkg>/
  }

  static Future<int> _sdkInt() async {
    try {
      final r = await Process.run('getprop', ['ro.build.version.sdk']);
      return int.tryParse(r.stdout.toString().trim()) ?? 30;
    } catch (_) { return 30; }
  }

  // ─── Directories ──────────────────────────────────────────────────────────

  /// Base: /storage/emulated/0/Android/media/<pkg>/OTN/recordings/
  Future<Directory> _baseDir() async {
    // Primary: Android/media path (no special permission needed Android 10+)
    final primary = '/storage/emulated/0/Android/media/$_pkg/$_appFolder/recordings';
    final dir = Directory(primary);
    try {
      await dir.create(recursive: true);
      // Quick write test
      final t = File('${dir.path}/.ok');
      await t.writeAsString('1');
      await t.delete();
      return dir;
    } catch (_) {
      // Fallback: app-external files dir
      final fb = Directory('/storage/emulated/0/$_appFolder/recordings');
      await fb.create(recursive: true);
      return fb;
    }
  }

  /// Attendance: /storage/emulated/0/Android/media/<pkg>/OTN/attendance/
  Future<Directory> _attendanceDir() async {
    final path = '/storage/emulated/0/Android/media/$_pkg/$_appFolder/attendance';
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

  Future<File> attendanceFile(String userEmail) async {
    final dir = await _attendanceDir();
    final name = _safe(userEmail.split('@').first);
    return File('${dir.path}/${name}_attendance.txt');
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

  // ─── Listing ──────────────────────────────────────────────────────────────

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

  Future<int> sessionCount(String u) async =>
      (await listSessionsForUser(u)).length;

  Future<int> totalDurationSeconds(String u) async {
    final s = await listSessionsForUser(u);
    return s.fold<int>(0, (sum, s) => sum + s.estimatedDurationSeconds);
  }

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
  int? _cached;

  LocalSession({
    required this.prefix, required this.dateStr, required this.username,
    required this.blocks, required this.totalBlocks, required this.isComplete,
  });

  int get estimatedDurationSeconds {
    if (_cached != null) return _cached!;
    if (blocks.isNotEmpty) {
      final s = File(blocks.first.path.replaceAll(RegExp(r'\.mp4$'), '.dur'));
      if (s.existsSync()) {
        final v = int.tryParse(s.readAsStringSync().trim());
        if (v != null) { _cached = v; return v; }
      }
    }
    return blocks.length * 120;
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