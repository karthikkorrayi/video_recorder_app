import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists upload state so it survives app kills.
/// When app is cleared from recents during upload, on reopen
/// we detect the incomplete upload and auto-resume it.
class UploadResumeService {
  static final UploadResumeService _i = UploadResumeService._();
  factory UploadResumeService() => _i;
  UploadResumeService._();

  static const _key = 'otn_active_upload';

  /// Save upload state before starting
  Future<void> markUploading({
    required String sessionId,
    required int totalBlocks,
    required List<int> uploadedBlocks,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode({
      'sessionId':     sessionId,
      'totalBlocks':   totalBlocks,
      'uploadedBlocks': uploadedBlocks,
      'startedAt':     DateTime.now().toIso8601String(),
    }));
  }

  /// Update progress as blocks complete
  Future<void> updateProgress(String sessionId, List<int> uploaded) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    final map = jsonDecode(raw) as Map<String, dynamic>;
    if (map['sessionId'] != sessionId) return;
    map['uploadedBlocks'] = uploaded;
    await prefs.setString(_key, jsonEncode(map));
  }

  /// Clear after upload completes or fails cleanly
  Future<void> clearUpload() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  /// Check if there's a pending upload on app start
  Future<PendingUpload?> getPendingUpload() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return PendingUpload(
        sessionId:     map['sessionId'] as String,
        totalBlocks:   map['totalBlocks'] as int,
        uploadedBlocks: List<int>.from(map['uploadedBlocks'] ?? []),
        startedAt:     DateTime.parse(map['startedAt'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}

class PendingUpload {
  final String sessionId;
  final int totalBlocks;
  final List<int> uploadedBlocks;
  final DateTime startedAt;

  PendingUpload({
    required this.sessionId,
    required this.totalBlocks,
    required this.uploadedBlocks,
    required this.startedAt,
  });

  int get completedBlocks => uploadedBlocks.length;
  bool get isIncomplete => uploadedBlocks.length < totalBlocks;
}