import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'attendance_service.dart';
import 'session_store.dart';
import 'user_service.dart';
import '../models/session_model.dart';

class VideoProcessor {
  static final VideoProcessor _i = VideoProcessor._();
  factory VideoProcessor() => _i;
  VideoProcessor._();

  final _attendance = AttendanceService();
  final _store      = SessionStore();

  // Upload chunk size — only used at upload time, not during recording
  static const int chunkSecs = 5 * 60;

  void startBackgroundProcessing({
    required String rawVideoPath,
    required DateTime sessionTime,
    required DateTime recordingEnd,
  }) {
    Future(() => _process(
      rawVideoPath: rawVideoPath,
      sessionTime:  sessionTime,
      recordingEnd: recordingEnd,
    )).catchError((e) => print('=== VideoProcessor bg error: $e'));
  }

  Future<void> _process({
    required String rawVideoPath,
    required DateTime sessionTime,
    required DateTime recordingEnd,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) { print('=== VideoProcessor: no user'); return; }

    final userId     = user.uid;
    final sessionId  = const Uuid().v4();
    final folderName = await UserService().getDisplayName();

    print('=== VP: processing for $folderName');

    final rawFile = File(rawVideoPath);
    if (!await rawFile.exists()) {
      print('=== VP: raw file missing'); return;
    }
    final rawSize = await rawFile.length();
    print('=== VP: raw = ${(rawSize/1024/1024).toStringAsFixed(1)}MB');
    if (rawSize < 1024) { print('=== VP: raw too small'); return; }

    try {
      // ── Step 1: Build output path ─────────────────────────────────────
      final dir     = await _sessionDir(sessionTime, folderName);
      final safeUid = _sanitize(userId.length > 12 ? userId.substring(0,12) : userId);
      final dateStr = DateFormat('yyyyMMdd').format(sessionTime);
      final timeStr = DateFormat('HHmmss').format(sessionTime);
      final fileName    = '${safeUid}_${dateStr}_$timeStr.mp4';
      final outputPath  = '${dir.path}/$fileName';
      // Temp path in cache — process here first, then move
      final tmpDir      = await getTemporaryDirectory();
      final tmpPath     = '${tmpDir.path}/otn_tmp_$timeStr.mp4';

      print('=== VP: output → $fileName');

      // ── Step 2: Process to temp path first ───────────────────────────
      // -c copy = lossless, no re-encode
      // -movflags +faststart = move moov atom to front so file is playable
      // Writing to temp first ensures we never leave a partial file in media dir
      final ok = await _runFFmpeg(
        '-i "$rawVideoPath" -c copy -movflags +faststart -y "$tmpPath"');

      if (!ok || !await File(tmpPath).exists() || await File(tmpPath).length() < 1024) {
        print('=== VP: FFmpeg failed, trying direct copy as fallback');
        // Direct copy — file won't have faststart but is still valid
        await rawFile.copy(tmpPath);
      }

      final tmpSize = await File(tmpPath).length();
      print('=== VP: tmp = ${(tmpSize/1024/1024).toStringAsFixed(1)}MB');

      if (tmpSize < 1024) {
        print('=== VP: output too small, aborting');
        try { await File(tmpPath).delete(); } catch (_) {}
        return;
      }

      // ── Step 3: Move from temp to final media location ───────────────
      await File(tmpPath).copy(outputPath);
      try { await File(tmpPath).delete(); } catch (_) {}

      final outSize = await File(outputPath).length();
      if (outSize < 1024) {
        print('=== VP: final file missing');
        return;
      }
      print('=== VP: ✓ final = ${(outSize/1024/1024).toStringAsFixed(1)}MB');

      // ── Step 4: Duration ──────────────────────────────────────────────
      // Use recording time difference — more reliable than FFmpeg probe
      // for freshly written files
      final durationSec = recordingEnd.difference(sessionTime).inSeconds
          .clamp(1, 24 * 3600);
      print('=== VP: duration = ${durationSec}s');

      // ── Step 5: Cleanup ───────────────────────────────────────────────
      try { await rawFile.delete(); } catch (_) {}

      // ── Step 6: Attendance + Store ────────────────────────────────────
      await _attendance.recordSession(durationSec);
      await _store.save(SessionModel(
        id:              sessionId,
        userId:          userId,
        createdAt:       sessionTime,
        durationSeconds: durationSec,
        blockCount:      1,
        status:          'pending',
        localChunkPaths: [outputPath],
        uploadedBlocks:  [],
      ));
      print('=== VP: ✓ saved → $fileName (${durationSec}s)');

    } catch (e) {
      print('=== VP error: $e');
    }
  }

  /// Returns the session directory under Android/media (visible in Files app)
  Future<Directory> _sessionDir(DateTime t, String displayName) async {
    Directory? base;
    try {
      final dirs = await getExternalStorageDirectories();
      if (dirs != null && dirs.isNotEmpty) {
        String p = dirs.first.path
            .replaceFirst('/Android/data/', '/Android/media/')
            .replaceFirst('/files', '');
        base = Directory('$p/OTN/VideoRecorder');
      }
    } catch (_) {}
    base ??= Directory(
        '${(await getApplicationDocumentsDirectory()).path}/OTN/VideoRecorder');

    final dateStr  = DateFormat('yyyy-MM-dd').format(t);
    final safeName = _sanitize(displayName);
    final dir      = Directory('${base.path}/$dateStr/$safeName');
    await dir.create(recursive: true);
    return dir;
  }

  Future<bool> _runFFmpeg(String cmd) async {
    try {
      final session = await FFmpegKit.execute(cmd);
      final rc      = await session.getReturnCode();
      if (!ReturnCode.isSuccess(rc)) {
        final logs = await session.getAllLogsAsString();
        print('=== FFmpeg failed: ${logs?.substring(0, logs.length.clamp(0,200))}');
        return false;
      }
      return true;
    } catch (e) {
      print('=== FFmpeg exception: $e');
      return false;
    }
  }

  Future<double> _probeDurationSec(String path) async {
    try {
      final session = await FFmpegKit.execute('-i "$path" -f null -');
      final logs    = await session.getAllLogsAsString() ?? '';
      final match   = RegExp(r'Duration:\s*(\d+):(\d+):(\d+\.?\d*)').firstMatch(logs);
      if (match != null) {
        return int.parse(match.group(1)!) * 3600.0
             + int.parse(match.group(2)!) * 60.0
             + double.parse(match.group(3)!);
      }
    } catch (_) {}
    return 0.0;
  }

  /// Split into upload chunks — saved to cache dir (not media/gallery)
  Future<List<String>> splitForUpload(String filePath, DateTime sessionTime) async {
    final file = File(filePath);
    if (!await file.exists()) {
      print('=== splitForUpload: not found: $filePath'); return [];
    }
    final durationSec = await _probeDurationSec(filePath);
    final totalChunks = durationSec > 0
        ? (durationSec / chunkSecs).ceil().clamp(1, 999) : 1;

    if (totalChunks == 1) return [filePath];

    final tmpDir   = await getTemporaryDirectory();
    final chunksDir = Directory('${tmpDir.path}/otn_upload_chunks');
    await chunksDir.create(recursive: true);
    final baseName = filePath.split('/').last.replaceAll('.mp4', '');
    final chunks   = <String>[];

    for (int i = 0; i < totalChunks; i++) {
      final startSec  = i * chunkSecs;
      final remaining = durationSec - startSec;
      final dur       = remaining < chunkSecs ? remaining : chunkSecs.toDouble();
      final n         = (i + 1).toString().padLeft(2, '0');
      final m         = totalChunks.toString().padLeft(2, '0');
      final chunkPath = '${chunksDir.path}/${baseName}_chunk${n}of$m.mp4';

      final ok = await _runFFmpeg(
        '-ss $startSec -i "$filePath" -t $dur '
        '-c copy -avoid_negative_ts make_zero -movflags +faststart '
        '-y "$chunkPath"');

      if (ok && await File(chunkPath).exists() && await File(chunkPath).length() > 512) {
        chunks.add(chunkPath);
      }
    }
    return chunks;
  }

  String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')
       .replaceAll(RegExp(r'_+'), '_')
       .replaceAll(RegExp(r'^_|_$'), '');
}