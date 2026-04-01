import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/session_model.dart';

class SessionStore {
  static const _key = 'sessions';

  Future<List<SessionModel>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    return raw.map((s) => SessionModel.fromMap(jsonDecode(s))).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> save(SessionModel session) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await getAll();
    final index = all.indexWhere((s) => s.id == session.id);
    if (index >= 0) {
      all[index] = session;
    } else {
      all.insert(0, session);
    }
    await prefs.setStringList(
      _key,
      all.map((s) => jsonEncode(s.toMap())).toList(),
    );
  }

  Future<void> updateStatus(String sessionId, String status) async {
    final all = await getAll();
    final index = all.indexWhere((s) => s.id == sessionId);
    if (index < 0) return;
    final updated = SessionModel(
      id: all[index].id,
      userId: all[index].userId,
      createdAt: all[index].createdAt,
      durationSeconds: all[index].durationSeconds,
      blockCount: all[index].blockCount,
      status: status,
      localChunkPaths: status == 'synced' ? [] : all[index].localChunkPaths,
    );
    all[index] = updated;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _key,
      all.map((s) => jsonEncode(s.toMap())).toList(),
    );
  }
}