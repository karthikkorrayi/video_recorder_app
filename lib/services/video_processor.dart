import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
import 'local_video_storage.dart';
import 'attendance_service.dart';
import 'session_store.dart';
import 'user_service.dart';
import '../models/session_model.dart';

class VideoProcessor {
  static final VideoProcessor _i = VideoProcessor._();
  factory VideoProcessor() => _i;
  VideoProcessor._();

  final _storage    = LocalVideoStorage();
  final _attendance = AttendanceService();
  final _store      = SessionStore();

  static const int blockSecs = 5 * 60;  // 5 minutes per chunk

  void startBackgroundProcessing({
    required String rawVideoPath,
    required DateTime sessionTime,
    required DateTime recordingEnd,
  }) {
    Future(() => _process(
      rawVideoPath: rawVideoPath,
      sessionTime:  sessionTime,
      recordingEnd: recordingEnd,
    )).catchError((e) => print('=== VideoProcessor background error: $e'));
  }

  Future<void> _process({
    required String rawVideoPath,
    required DateTime sessionTime,
    required DateTime recordingEnd,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final userId    = user.uid;
    final sessionId = const Uuid().v4();

    // ── KEY FIX: use display name (from Firestore) for local folder, not email
    final folderName = await UserService().getDisplayName();
    print('=== VideoProcessor: local folder = $folderName');

    try {
      print('=== VideoProcessor: starting for $rawVideoPath');

      final durationSec = await _probeDurationSec(rawVideoPath);
      final totalBlocks = (durationSec / blockSecs).ceil().clamp(1, 999);
      print('=== VideoProcessor: ${durationSec}s → $totalBlocks block(s)');

      final dir        = await _storage.sessionDir(sessionTime, folderName);
      final savedPaths = <String>[];

      for (int i = 0; i < totalBlocks; i++) {
        final blockNum  = i + 1;
        final startSec  = i * blockSecs;
        final remaining = durationSec - startSec;
        final blockDur  = remaining < blockSecs ? remaining : blockSecs.toDouble();

        final fileName = _storage.blockFileName(
          userId:      userId,
          sessionTime: sessionTime,
          blockIndex:  blockNum,
          totalBlocks: totalBlocks,
        );
        final outputPath = '${dir.path}/$fileName';

        final cmd =
            '-ss $startSec '
            '-i "$rawVideoPath" '
            '-t $blockDur '
            '-c copy '
            '-avoid_negative_ts make_zero '
            '-movflags +faststart '
            '"$outputPath"';

        print('=== Block $blockNum: ss=$startSec t=$blockDur → $fileName');

        final session = await FFmpegKit.execute(cmd);
        final rc      = await session.getReturnCode();

        if (!ReturnCode.isSuccess(rc)) {
          final logs = await session.getAllLogsAsString();
          print('=== Block $blockNum FAILED: $logs');
          continue;
        }

        final outFile = File(outputPath);
        if (!await outFile.exists() || await outFile.length() < 512) {
          print('=== Block $blockNum output missing/empty');
          continue;
        }

        savedPaths.add(outputPath);
        print('=== Block $blockNum ✓');
      }

      try { await File(rawVideoPath).delete(); } catch (_) {}
      await _attendance.recordSession(durationSec.toInt());

      if (savedPaths.isNotEmpty) {
        final model = SessionModel(
          id:              sessionId,
          userId:          userId,
          createdAt:       sessionTime,
          durationSeconds: durationSec.toInt(),
          blockCount:      savedPaths.length,
          status:          'pending',
          localChunkPaths: savedPaths,
          uploadedBlocks:  [],
        );
        await _store.save(model);
        print('=== VideoProcessor: saved ${savedPaths.length} block(s) — folder: $folderName');
      }

    } catch (e) {
      print('=== VideoProcessor error: $e');
    }
  }

  Future<double> _probeDurationSec(String path) async {
    double dur = 0;
    try {
      final session = await FFmpegKit.execute('-i "$path" -f null -');
      final logs = await session.getAllLogsAsString() ?? '';
      final match = RegExp(r'Duration:\s*(\d+):(\d+):(\d+\.?\d*)').firstMatch(logs);
      if (match != null) {
        final h = int.parse(match.group(1)!);
        final m = int.parse(match.group(2)!);
        final s = double.parse(match.group(3)!);
        dur = h * 3600 + m * 60 + s;
      }
    } catch (e) {
      print('=== probeDuration error: $e');
    }
    if (dur <= 0) dur = 10.0;
    return dur;
  }
}