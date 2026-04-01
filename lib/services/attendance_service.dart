import 'dart:io';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'local_video_storage.dart';

/// Tracks daily recording activity per user.
/// Saved as plain text at:
///   /storage/emulated/0/Movies/KineSync/attendance/<username>_attendance.txt
///
/// Each line:
///   2026-04-01 | sessions: 3 | total_sec: 185 | avg_sec: 61 | first: 09:12:04 | last: 17:43:22
class AttendanceService {
  static final AttendanceService _i = AttendanceService._();
  factory AttendanceService() => _i;
  AttendanceService._();

  final _storage = LocalVideoStorage();

  // ─── Public API ───────────────────────────────────────────────────────────

  /// Called after every successful recording save.
  Future<void> recordSession(int durationSeconds) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || durationSeconds <= 0) return;

    final file = await _storage.attendanceFile(user.email ?? user.uid);
    final lines = await _readLines(file);
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final nowTime = DateFormat('HH:mm:ss').format(DateTime.now());

    final idx = lines.indexWhere((l) => l.startsWith(today));
    if (idx >= 0) {
      final entry = _parse(lines[idx]);
      if (entry != null) {
        final sessions = (entry['sessions'] as int) + 1;
        final total = (entry['total_sec'] as int) + durationSeconds;
        lines[idx] = _fmt(today, {
          'sessions': sessions,
          'total_sec': total,
          'avg_sec': total ~/ sessions,
          'first': entry['first'],
          'last': nowTime,
        });
      }
    } else {
      lines.add(_fmt(today, {
        'sessions': 1,
        'total_sec': durationSeconds,
        'avg_sec': durationSeconds,
        'first': nowTime,
        'last': nowTime,
      }));
    }

    lines.sort((a, b) => b.compareTo(a)); // newest first
    await file.writeAsString('${lines.join('\n')}\n');
    print('=== Attendance: updated → ${file.path}');
  }

  /// All entries for current user, newest first.
  Future<List<AttendanceEntry>> getEntries() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return [];
    final file = await _storage.attendanceFile(user.email ?? user.uid);
    if (!await file.exists()) return [];
    final lines = await _readLines(file);
    return lines.map((l) {
      final date = l.split(' | ').first;
      final data = _parse(l);
      if (data == null) return null;
      return AttendanceEntry(
        date: date,
        sessions: data['sessions'] as int,
        totalSeconds: data['total_sec'] as int,
        avgSeconds: data['avg_sec'] as int,
        firstSession: data['first'] as String,
        lastSession: data['last'] as String,
      );
    }).whereType<AttendanceEntry>().toList();
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  Future<List<String>> _readLines(File f) async {
    if (!await f.exists()) return [];
    return (await f.readAsString())
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  Map<String, dynamic>? _parse(String line) {
    try {
      final p = line.split(' | ');
      if (p.length < 6) return null;
      return {
        'sessions': int.parse(p[1].split(': ')[1]),
        'total_sec': int.parse(p[2].split(': ')[1]),
        'avg_sec': int.parse(p[3].split(': ')[1]),
        'first': p[4].split(': ')[1],
        'last': p[5].split(': ')[1],
      };
    } catch (_) { return null; }
  }

  String _fmt(String date, Map<String, dynamic> d) =>
      '$date | sessions: ${d['sessions']} | total_sec: ${d['total_sec']} '
      '| avg_sec: ${d['avg_sec']} | first: ${d['first']} | last: ${d['last']}';
}

// ─── Model ────────────────────────────────────────────────────────────────────

class AttendanceEntry {
  final String date;
  final int sessions;
  final int totalSeconds;
  final int avgSeconds;
  final String firstSession;
  final String lastSession;

  const AttendanceEntry({
    required this.date, required this.sessions,
    required this.totalSeconds, required this.avgSeconds,
    required this.firstSession, required this.lastSession,
  });

  String get totalStr => _f(totalSeconds);
  String get avgStr => _f(avgSeconds);

  String _f(int s) {
    if (s < 60) return '${s}s';
    final m = s ~/ 60; final r = s % 60;
    return r > 0 ? '${m}m ${r}s' : '${m}m';
  }
}