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

  // ── Public constants ──────────────────────────────────────────────────────
  // Session = full 20-min recording stored as ONE file locally
  // Chunk   = 5-min split used ONLY during upload (not during recording)
  static const int sessionSecs = 20 * 60; // 20 min — local file duration
  static const int chunkSecs   =  5 * 60; // 5 min  — upload chunk size

  /// Called from CameraScreen after stopVideoRecording().
  /// Saves the raw file as a single session file (no splitting during recording).
  void startBackgroundProcessing({
    required String rawVideoPath,
    required DateTime sessionTime,
    required DateTime recordingEnd,
  }) {
    Future(() => _process(
      rawVideoPath: rawVideoPath,
      sessionTime:  sessionTime,
      recordingEnd: recordingEnd,
    )).catchError((e) => print('=== VideoProcessor error: $e'));
  }

  Future<void> _process({
    required String rawVideoPath,
    required DateTime sessionTime,
    required DateTime recordingEnd,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final userId     = user.uid;
    final sessionId  = const Uuid().v4();
    final folderName = await UserService().getDisplayName();

    print('=== VideoProcessor: saving session → $folderName');

    try {
      final durationSec = await _probeDurationSec(rawVideoPath);
      print('=== VideoProcessor: duration = ${durationSec}s');

      final dir      = await _storage.sessionDir(sessionTime, folderName);
      // Single file per session — no block suffix needed
      final fileName = '${_sanitizeUid(userId)}_'
          '${_fmtDate(sessionTime)}_'
          '${_fmtTime(sessionTime)}.mp4';
      final outputPath = '${dir.path}/$fileName';

      // Copy raw file to organised location (lossless, fast)
      final copyCmd = '-i "$rawVideoPath" -c copy -movflags +faststart "$outputPath"';
      final session = await FFmpegKit.execute(copyCmd);
      final rc      = await session.getReturnCode();

      if (!ReturnCode.isSuccess(rc)) {
        final logs = await session.getAllLogsAsString();
        print('=== VideoProcessor: copy failed: $logs');
        return;
      }

      final outFile = File(outputPath);
      if (!await outFile.exists() || await outFile.length() < 512) {
        print('=== VideoProcessor: output missing');
        return;
      }

      // Clean up raw file
      try { await File(rawVideoPath).delete(); } catch (_) {}

      // Record attendance
      await _attendance.recordSession(durationSec.toInt());

      // Save session — single file, no chunks yet
      final model = SessionModel(
        id:              sessionId,
        userId:          userId,
        createdAt:       sessionTime,
        durationSeconds: durationSec.toInt(),
        blockCount:      1,          // 1 file locally
        status:          'pending',
        localChunkPaths: [outputPath],
        uploadedBlocks:  [],
      );
      await _store.save(model);
      print('=== VideoProcessor: session saved → $fileName');

    } catch (e) {
      print('=== VideoProcessor error: $e');
    }
  }

  /// Split a local session file into 5-min chunks for upload.
  /// Returns list of chunk file paths in order.
  /// Called by UploadService just before uploading.
  Future<List<String>> splitForUpload(String filePath, DateTime sessionTime) async {
    final durationSec = await _probeDurationSec(filePath);
    final totalChunks = (durationSec / chunkSecs).ceil().clamp(1, 999);

    if (totalChunks == 1) {
      print('=== splitForUpload: single chunk, no split needed');
      return [filePath];
    }

    final dir    = filePath.substring(0, filePath.lastIndexOf('/'));
    final baseName = filePath.split('/').last.replaceAll('.mp4', '');
    final chunks = <String>[];

    print('=== splitForUpload: ${durationSec}s → $totalChunks chunks');

    for (int i = 0; i < totalChunks; i++) {
      final startSec  = i * chunkSecs;
      final remaining = durationSec - startSec;
      final dur       = remaining < chunkSecs ? remaining : chunkSecs.toDouble();
      final chunkNum  = i + 1;
      final chunkPath = '$dir/${baseName}_chunk${chunkNum.toString().padLeft(2,'0')}of'
          '${totalChunks.toString().padLeft(2,'0')}.mp4';

      final cmd = '-ss $startSec -i "$filePath" -t $dur '
          '-c copy -avoid_negative_ts make_zero -movflags +faststart '
          '"$chunkPath"';

      final session = await FFmpegKit.execute(cmd);
      final rc      = await session.getReturnCode();

      if (ReturnCode.isSuccess(rc)) {
        final f = File(chunkPath);
        if (await f.exists() && await f.length() > 512) {
          chunks.add(chunkPath);
          print('=== Chunk $chunkNum ✓');
        }
      } else {
        print('=== Chunk $chunkNum failed');
      }
    }

    return chunks;
  }

  Future<double> _probeDurationSec(String path) async {
    double dur = 0;
    try {
      final session = await FFmpegKit.execute('-i "$path" -f null -');
      final logs    = await session.getAllLogsAsString() ?? '';
      final match   = RegExp(r'Duration:\s*(\d+):(\d+):(\d+\.?\d*)').firstMatch(logs);
      if (match != null) {
        dur = int.parse(match.group(1)!) * 3600
            + int.parse(match.group(2)!) * 60
            + double.parse(match.group(3)!);
      }
    } catch (_) {}
    return dur <= 0 ? 10.0 : dur;
  }

  String _sanitizeUid(String uid) =>
      (uid.length > 12 ? uid.substring(0, 12) : uid)
          .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');

  String _fmtDate(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2,'0')}${d.day.toString().padLeft(2,'0')}';

  String _fmtTime(DateTime d) =>
      '${d.hour.toString().padLeft(2,'0')}${d.minute.toString().padLeft(2,'0')}'
      '${d.second.toString().padLeft(2,'0')}';
}