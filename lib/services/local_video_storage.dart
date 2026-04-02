import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

/// Saves videos to Android/media — visible in Files app, not in Gallery.
///
/// Full path on device:
///   /storage/emulated/0/Android/media/com.otn.videorecorder/OTN/
///     recordings/
///       YYYY-MM-DD/
///         <username>/
///           <userId>_YYYYMMDD_HHmmss.mp4
///           <userId>_YYYYMMDD_HHmmss_block01of03.mp4
///     attendance/
///       <username>_attendance.txt
///
/// How to find files on phone:
///   Files app → Internal Storage → Android → media → com.otn.videorecorder → OTN
///
/// WHY Android/media instead of Android/data:
///   - Android/data  is HIDDEN from file managers on Android 11+ (scoped storage)
///   - Android/media is VISIBLE in file managers on all Android versions
///   - Neither appears in the Gallery (no DCIM folder = no gallery indexing)
///   - Both need ZERO special permissions on Android 10+
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

      // Quick write test to confirm we can actually write here
      final test = File('${dir.path}/.wtest');
      await test.writeAsString('ok');
      await test.delete();

      return dir;
    } catch (e) {
      print('=== Storage: Android/media not writable ($e), using fallback');
    }

    // Fallback: Android/data via path_provider (hidden but always writable)
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
    final mediaPath =
        '/storage/emulated/0/Android/media/$_pkg/$_appFolder/attendance';
    try {
      final dir = Directory(mediaPath);
      await dir.create(recursive: true);
      return dir;
    } catch (_) {}

    final ext = await getExternalStorageDirectory();
    if (ext != null) {
      final dir = Directory('${ext.path}/$_appFolder/attendance');
      await dir.create(recursive: true);
      return dir;
    }

    final doc = await getApplicationDocumentsDirectory();
    final dir = Directory('${doc.path}/$_appFolder/attendance');
    await dir.create(recursive: true);
    return dir;
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

  Future<int> totalDurationSeconds(String u) async {
    final s = await listSessionsForUser(u);
    return s.fold<int>(0, (sum, s) => sum + s.estimatedDurationSeconds);
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
  int?             _cached;

  LocalSession({
    required this.prefix,   required this.dateStr,
    required this.username, required this.blocks,
    required this.totalBlocks, required this.isComplete,
  });

  int get estimatedDurationSeconds {
    if (_cached != null) return _cached!;
    if (blocks.isNotEmpty) {
      final sidecar =
          File(blocks.first.path.replaceAll(RegExp(r'\.mp4$'), '.dur'));
      if (sidecar.existsSync()) {
        final v = int.tryParse(sidecar.readAsStringSync().trim());
        if (v != null) { _cached = v; return v; }
      }
    }
    return blocks.length * 120;
  }

  String get displayTitle {
    final m = RegExp(r'(\d{8})_(\d{6})').firstMatch(prefix);
    if (m == null) return prefix;
    final d = m.group(1)!;
    final t = m.group(2)!;
    return '${d.substring(0,4)}-${d.substring(4,6)}-${d.substring(6,8)}'
        '  ${t.substring(0,2)}:${t.substring(2,4)}:${t.substring(4,6)}';
  }

  String get blockSummary =>
      totalBlocks == 1 ? '1 block' : '${blocks.length}/$totalBlocks blocks';

  String get durationStr {
    final s = estimatedDurationSeconds;
    if (s < 60) return '${s}s';
    final m = s ~/ 60;
    final r = s % 60;
    return r > 0 ? '${m}m ${r}s' : '${m}m';
  }
}