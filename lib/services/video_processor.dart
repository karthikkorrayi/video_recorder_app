import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:path_provider/path_provider.dart'; // for getTemporaryDirectory
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

  // Chunk size for upload splitting only (not during recording)
  static const int chunkSecs = 5 * 60; // 5 min

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
    if (user == null) { print('=== VideoProcessor: no user'); return; }

    final userId     = user.uid;
    final sessionId  = const Uuid().v4();
    final folderName = await UserService().getDisplayName();

    print('=== VideoProcessor: processing for $folderName');
    print('=== VideoProcessor: raw file = $rawVideoPath');

    // ── Verify raw file exists and has content ────────────────────────────
    final rawFile = File(rawVideoPath);
    if (!await rawFile.exists()) {
      print('=== VideoProcessor: raw file not found!');
      return;
    }
    final rawSize = await rawFile.length();
    print('=== VideoProcessor: raw size = ${(rawSize/1024/1024).toStringAsFixed(1)}MB');
    if (rawSize < 1024) {
      print('=== VideoProcessor: raw file too small, skipping');
      return;
    }

    try {
      // ── Build output directory ────────────────────────────────────────
      final dir = await _sessionDir(sessionTime, folderName);
      print('=== VideoProcessor: output dir = ${dir.path}');

      // ── Build filename ────────────────────────────────────────────────
      final safeUid  = _sanitize(userId.length > 12
          ? userId.substring(0, 12) : userId);
      final dateStr  = DateFormat('yyyyMMdd').format(sessionTime);
      final timeStr  = DateFormat('HHmmss').format(sessionTime);
      final fileName = '${safeUid}_${dateStr}_$timeStr.mp4';
      final outputPath = '${dir.path}/$fileName';

      print('=== VideoProcessor: saving → $fileName');

      // ── Copy raw → organised path (lossless, no re-encode) ────────────
      final rc = await _runFFmpeg(
          '-i "$rawVideoPath" -c copy -movflags +faststart -y "$outputPath"');

      if (!rc) {
        print('=== VideoProcessor: FFmpeg copy failed — trying direct file copy');
        // Fallback: direct file copy if FFmpeg fails
        try {
          await rawFile.copy(outputPath);
          print('=== VideoProcessor: direct copy succeeded');
        } catch (copyErr) {
          print('=== VideoProcessor: direct copy also failed: $copyErr');
          return;
        }
      }

      // ── Verify output ─────────────────────────────────────────────────
      final outFile = File(outputPath);
      if (!await outFile.exists()) {
        print('=== VideoProcessor: output file not created');
        return;
      }
      final outSize = await outFile.length();
      if (outSize < 1024) {
        print('=== VideoProcessor: output too small ($outSize bytes)');
        await outFile.delete();
        return;
      }
      print('=== VideoProcessor: output OK — ${(outSize/1024/1024).toStringAsFixed(1)}MB');

      // ── Probe duration ────────────────────────────────────────────────
      // Use actual recording time difference as primary source — much more reliable
      // than probing the file, which can fail on freshly written videos
      final recordedDuration = recordingEnd.difference(sessionTime);
      var durationSec = recordedDuration.inSeconds;
      if (durationSec <= 0) {
        // Fallback: probe the output file
        durationSec = (await _probeDurationSec(outputPath)).toInt();
      }
      print('=== VideoProcessor: duration = ${durationSec}s');

      // ── Clean up raw file ─────────────────────────────────────────────
      try { await rawFile.delete(); } catch (_) {}

      // ── Record attendance ─────────────────────────────────────────────
      await _attendance.recordSession(durationSec);

      // ── Save session to store ─────────────────────────────────────────
      final model = SessionModel(
        id:              sessionId,
        userId:          userId,
        createdAt:       sessionTime,
        durationSeconds: durationSec,
        blockCount:      1,
        status:          'pending',
        localChunkPaths: [outputPath],
        uploadedBlocks:  [],
      );
      await _store.save(model);
      print('=== VideoProcessor: ✓ saved → $fileName (${durationSec}s)');

    } catch (e) {
      print('=== VideoProcessor error: $e');
    }
  }

  /// Returns the session directory, creating it if needed.
  /// Path: <external>/Android/media/com.otn.videorecorder/OTN/VideoRecorder/YYYY-MM-DD/DisplayName/
  Future<Directory> _sessionDir(DateTime t, String displayName) async {
    Directory? base;

    // Try external media dir first (accessible in Files app)
    try {
      final dirs = await getExternalStorageDirectories();
      if (dirs != null && dirs.isNotEmpty) {
        // Go up to Android/media/com.otn.videorecorder/
        String p = dirs.first.path;
        // dirs.first is usually .../Android/data/com.otn.videorecorder/files
        // We want .../Android/media/com.otn.videorecorder/OTN/VideoRecorder
        p = p.replaceFirst('/Android/data/', '/Android/media/');
        p = p.replaceFirst('/files', '');
        base = Directory('$p/OTN/VideoRecorder');
      }
    } catch (_) {}

    // Fallback to app documents dir
    if (base == null) {
      final docs = await getApplicationDocumentsDirectory();
      base = Directory('${docs.path}/OTN/VideoRecorder');
    }

    final dateStr    = DateFormat('yyyy-MM-dd').format(t);
    final safeName   = _sanitize(displayName);
    final dir = Directory('${base.path}/$dateStr/$safeName');
    await dir.create(recursive: true);
    return dir;
  }

  /// Run an FFmpeg command, return true if successful.
  Future<bool> _runFFmpeg(String cmd) async {
    try {
      final session = await FFmpegKit.execute(cmd);
      final rc      = await session.getReturnCode();
      if (!ReturnCode.isSuccess(rc)) {
        final logs = await session.getAllLogsAsString();
        print('=== FFmpeg failed: ${logs?.substring(0, logs.length.clamp(0, 300))}');
        return false;
      }
      return true;
    } catch (e) {
      print('=== FFmpeg exception: $e');
      return false;
    }
  }

  /// Probe video duration using FFmpeg.
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
    } catch (e) {
      print('=== probeDuration error: $e');
    }
    return 0.0;
  }

  /// Split a local session file into 5-min chunks for upload.
  /// Returns list of chunk paths in order. Called only at upload time.
  Future<List<String>> splitForUpload(String filePath, DateTime sessionTime) async {
    final file = File(filePath);
    if (!await file.exists()) {
      print('=== splitForUpload: file not found: $filePath');
      return [];
    }

    final durationSec = await _probeDurationSec(filePath);
    final totalChunks = durationSec > 0
        ? (durationSec / chunkSecs).ceil().clamp(1, 999)
        : 1;

    if (totalChunks == 1) {
      print('=== splitForUpload: single chunk, no split needed');
      return [filePath];
    }

    // Save chunks to app cache — NOT the media folder
    // This prevents them from appearing in the device photo gallery
    final cacheDir = await getTemporaryDirectory();
    final chunksDir = Directory('${cacheDir.path}/otn_upload_chunks');
    await chunksDir.create(recursive: true);
    final baseName = filePath.split('/').last.replaceAll('.mp4', '');
    final chunks   = <String>[];

    print('=== splitForUpload: ${durationSec.toStringAsFixed(1)}s → $totalChunks chunks');

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

      if (ok) {
        final f = File(chunkPath);
        if (await f.exists() && await f.length() > 512) {
          chunks.add(chunkPath);
          print('=== Chunk ${i+1} ✓');
        }
      } else {
        print('=== Chunk ${i+1} failed');
      }
    }

    return chunks;
  }

  String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')
       .replaceAll(RegExp(r'_+'), '_')
       .replaceAll(RegExp(r'^_|_$'), '');
}