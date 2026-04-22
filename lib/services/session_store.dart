import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/session_model.dart'; // single source of SessionModel

export '../models/session_model.dart'; // re-export so callers get it from here too

enum SessionStatus { pending, uploading, synced }

/// Persists all sessions to SharedPreferences.
/// SessionModel lives in models/session_model.dart — NOT duplicated here.
class SessionStore {
  static const _key = 'otn_sessions_v3';

  List<SessionModel> sessions;

  // ── Constructors ──────────────────────────────────────────────────────────

  /// Named constructor used when you already have a list.
  SessionStore({required this.sessions});

  /// Default factory — loads from disk. Use [SessionStore.load()] instead.
  factory SessionStore.empty() => SessionStore(sessions: []);

  // ── Load / Save ───────────────────────────────────────────────────────────

  static Future<SessionStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_key);
    if (raw == null) return SessionStore(sessions: []);
    final list  = jsonDecode(raw) as List;
    return SessionStore(
      sessions: list
          .map((e) => SessionModel.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(sessions.map((s) => s.toJson()).toList()));
  }

  // ── CRUD ──────────────────────────────────────────────────────────────────

  /// Save or update a full SessionModel object.
  /// Called from main.dart and anywhere that already has a SessionModel.
  Future<void> save(SessionModel session) async {
    sessions.removeWhere((s) => s.id == session.id);
    sessions.insert(0, session);
    await _persist();
  }

  /// Add a brand-new session from raw fields (called from VideoProcessor).
  Future<void> addNew({
    required String id,
    required int    durationSeconds,
    required int    blockCount,
    required String status,
    required List<String> localChunkPaths,
  }) async {
    final session = SessionModel(
      id:              id,
      durationSeconds: durationSeconds,
      blockCount:      blockCount,
      status:          status,
      localChunkPaths: localChunkPaths,
      uploadedBlocks:  [],
      recordedAt:      DateTime.now(),
      // dateFolder / sessionDate / startTime default to now
      dateFolder:      _todayFolder(),
      sessionDate:     _todayDate(),
      startTime:       _nowTime(),
      userFullName:    '',
      partNames:       [],
    );
    await save(session);
  }

  Future<void> updateSession(SessionModel session) async => save(session);

  Future<void> removeSession(String id) async {
    sessions.removeWhere((s) => s.id == id);
    await _persist();
  }

  Future<void> addSession(SessionModel session) async => save(session);

  /// Lookup by id — used in main.dart upload resume logic.
  Future<SessionModel?> getById(String id) async {
    final store = await SessionStore.load();
    try {
      return store.sessions.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  // ── Filtered queries ──────────────────────────────────────────────────────

  List<SessionModel> syncedForFilter(DateFilter filter) => sessions
      .where((s) => s.status == 'synced')
      .where((s) => _matchesFilter(s.recordedAt, filter))
      .toList();

  List<SessionModel> allForFilter(DateFilter filter) =>
      sessions.where((s) => _matchesFilter(s.recordedAt, filter)).toList();

  List<SessionModel> currentMonthAll() {
    final now = DateTime.now();
    return sessions
        .where((s) =>
            s.recordedAt.year == now.year &&
            s.recordedAt.month == now.month)
        .toList();
  }

  static bool _matchesFilter(DateTime dt, DateFilter filter) {
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (filter.type) {
      case FilterType.today:
        return DateTime(dt.year, dt.month, dt.day) == today;
      case FilterType.yesterday:
        final y = today.subtract(const Duration(days: 1));
        return DateTime(dt.year, dt.month, dt.day) == y;
      case FilterType.thisWeek:
        final weekStart =
            today.subtract(Duration(days: today.weekday - 1));
        return !dt.isBefore(weekStart) &&
            dt.isBefore(today.add(const Duration(days: 1)));
      case FilterType.thisMonth:
        return dt.year == now.year && dt.month == now.month;
      case FilterType.custom:
        if (filter.from == null || filter.to == null) return false;
        final d = DateTime(dt.year, dt.month, dt.day);
        return !d.isBefore(filter.from!) && !d.isAfter(filter.to!);
    }
  }

  // ── Date helpers ──────────────────────────────────────────────────────────
  static String _todayFolder() {
    final n = DateTime.now();
    return '${n.day.toString().padLeft(2,'0')}-'
        '${n.month.toString().padLeft(2,'0')}-${n.year}';
  }

  static String _todayDate() {
    final n = DateTime.now();
    return '${n.year}${n.month.toString().padLeft(2,'0')}'
        '${n.day.toString().padLeft(2,'0')}';
  }

  static String _nowTime() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2,'0')}'
        '${n.minute.toString().padLeft(2,'0')}'
        '${n.second.toString().padLeft(2,'0')}';
  }
}

// ── Filter model ──────────────────────────────────────────────────────────────

enum FilterType { today, yesterday, thisWeek, thisMonth, custom }

class DateFilter {
  final FilterType type;
  final DateTime?  from;
  final DateTime?  to;

  const DateFilter(this.type, {this.from, this.to});

  static const DateFilter today     = DateFilter(FilterType.today);
  static const DateFilter yesterday = DateFilter(FilterType.yesterday);
  static const DateFilter thisWeek  = DateFilter(FilterType.thisWeek);
  static const DateFilter thisMonth = DateFilter(FilterType.thisMonth);

  String get label {
    switch (type) {
      case FilterType.today:     return 'Today';
      case FilterType.yesterday: return 'Yesterday';
      case FilterType.thisWeek:  return 'This Week';
      case FilterType.thisMonth: return 'This Month';
      case FilterType.custom:
        if (from != null && to != null) {
          return '${from!.day}/${from!.month} – ${to!.day}/${to!.month}';
        }
        return 'Custom';
    }
  }
}