import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/session_model.dart';

class SessionStore {
  static const String _prefix = 'otn_session_';

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? 'unknown';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  /// Save a new session
  Future<void> save(SessionModel session) async {
    final prefs = await _prefs;
    await prefs.setString('${_prefix}${session.id}', jsonEncode(session.toJson()));
  }

  /// Update status only
  Future<void> updateStatus(String sessionId, String status) async {
    final session = await getById(sessionId);
    if (session == null) return;
    session.status = status;
    await save(session);
  }

  /// Update uploaded blocks list and recalculate status
  Future<void> updateUploadedBlocks(String sessionId, List<int> uploadedBlocks) async {
    final session = await getById(sessionId);
    if (session == null) return;
    session.uploadedBlocks = uploadedBlocks;
    if (session.isFullySynced) {
      session.status = 'synced';
    } else if (session.isPartial) {
      session.status = 'partial';
    } else {
      session.status = 'pending';
    }
    await save(session);
  }

  /// Get a specific session by id
  Future<SessionModel?> getById(String sessionId) async {
    final prefs = await _prefs;
    final raw = prefs.getString('${_prefix}$sessionId');
    if (raw == null) return null;
    return SessionModel.fromJson(jsonDecode(raw));
  }

  /// Get all sessions for the current user, sorted newest first
  Future<List<SessionModel>> getAll() async {
    final prefs = await _prefs;
    final keys  = prefs.getKeys().where((k) => k.startsWith(_prefix));
    final List<SessionModel> sessions = [];

    for (final key in keys) {
      final raw = prefs.getString(key);
      if (raw == null) continue;
      try {
        final s = SessionModel.fromJson(jsonDecode(raw));
        if (s.userId == _uid) sessions.add(s);
      } catch (_) {}
    }

    sessions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sessions;
  }

  /// Count pending/partial sessions for current user
  Future<int> pendingCount() async {
    final all = await getAll();
    return all.where((s) => s.status == 'pending' || s.status == 'partial').length;
  }

  /// Delete a session record (only allowed if not synced)
  Future<bool> delete(String sessionId) async {
    final session = await getById(sessionId);
    if (session == null) return false;
    if (session.status == 'synced') return false; // Cannot delete synced sessions
    final prefs = await _prefs;
    await prefs.remove('${_prefix}$sessionId');
    return true;
  }
}