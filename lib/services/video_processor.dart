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
// NOTE: session_model.dart is imported via session_store.dart (re-exported)
// Do NOT add a direct import of session_model.dart here — causes ambiguous_import

class VideoProcessor {
  static final VideoProcessor _i = VideoProcessor._();
  factory VideoProcessor() => _i;
  VideoProcessor._();

  final _attendance = AttendanceService();

  static const int chunkSecs = 5 * 60;

  void startBackgroundProcessing({
    required String   rawVideoPath,
    required DateTime sessionTime,
    required DateTime recordingEnd,
  }) {
    Future(() => _process(
      rawVideoPath: rawVideoPath,
      sessionTime:  sessionTime,
      recordingEnd: recordingEnd,
    )).catchError((e) {
      // ignore: avoid_print
      print('=== VideoProcessor bg error: $e');
    });
  }

  Future<void> _process({
    required String   rawVideoPath,
    required DateTime sessionTime,
    required DateTime recordingEnd,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      // ignore: avoid_print
      print('=== VideoProcessor: no user'); return;
    }

    final userId     = user.uid;
    final sessionId  = const Uuid().v4();
    final folderName = await UserService().getDisplayName();

    // ignore: avoid_print
    print('=== VP: processing for $folderName');

    final rawFile = File(rawVideoPath);
    if (!await rawFile.exists()) {
      // ignore: avoid_print
      print('=== VP: raw file missing'); return;
    }
    final rawSize = await rawFile.length();
    // ignore: avoid_print
    print('=== VP: raw = ${(rawSize/1024/1024).toStringAsFixed(1)}MB');
    if (rawSize < 1024) {
      // ignore: avoid_print
      print('=== VP: raw too small'); return;
    }

    try {
      // ── Step 1: Build output path ─────────────────────────────────────
      final dir     = await _sessionDir(sessionTime, folderName);
      final safeUid = _sanitize(userId.length > 12 ? userId.substring(0,12) : userId);
      final dateStr = DateFormat('yyyyMMdd').format(sessionTime);
      final timeStr = DateFormat('HHmmss').format(sessionTime);
      final fileName   = '${safeUid}_${dateStr}_$timeStr.mp4';
      final outputPath = '${dir.path}/$fileName';
      final tmpDir     = await getTemporaryDirectory();
      final tmpPath    = '${tmpDir.path}/otn_tmp_$timeStr.mp4';

      // ignore: avoid_print
      print('=== VP: output → $fileName');

      // ── Step 2: Process to temp path first ───────────────────────────
      final ok = await _runFFmpeg(
          '-i "$rawVideoPath" -c copy -movflags +faststart -y "$tmpPath"');

      if (!ok || !await File(tmpPath).exists() || await File(tmpPath).length() < 1024) {
        // ignore: avoid_print
        print('=== VP: FFmpeg failed, trying direct copy as fallback');
        await rawFile.copy(tmpPath);
      }

      final tmpSize = await File(tmpPath).length();
      // ignore: avoid_print
      print('=== VP: tmp = ${(tmpSize/1024/1024).toStringAsFixed(1)}MB');

      if (tmpSize < 1024) {
        // ignore: avoid_print
        print('=== VP: output too small, aborting');
        try { await File(tmpPath).delete(); } catch (_) {}
        return;
      }

      // ── Step 3: Move from temp to final media location ───────────────
      await File(tmpPath).copy(outputPath);
      try { await File(tmpPath).delete(); } catch (_) {}

      final outSize = await File(outputPath).length();
      if (outSize < 1024) {
        // ignore: avoid_print
        print('=== VP: final file missing'); return;
      }
      // ignore: avoid_print
      print('=== VP: ✓ final = ${(outSize/1024/1024).toStringAsFixed(1)}MB');

      // ── Step 4: Duration ──────────────────────────────────────────────
      final durationSec = recordingEnd.difference(sessionTime).inSeconds
          .clamp(1, 24 * 3600);
      // ignore: avoid_print
      print('=== VP: duration = ${durationSec}s');

      // ── Step 5: Cleanup ───────────────────────────────────────────────
      try { await rawFile.delete(); } catch (_) {}

      // ── Step 6: Attendance + Store ────────────────────────────────────
      await _attendance.recordSession(durationSec);

      // FIX: use addNew() instead of save(id:...) — matches new SessionStore API
      final store = await SessionStore.load();
      await store.addNew(
        id:              sessionId,
        durationSeconds: durationSec,
        blockCount:      1,
        status:          'pending',
        localChunkPaths: [outputPath],
      );
      // ignore: avoid_print
      print('=== VP: ✓ saved → $fileName (${durationSec}s)');

    } catch (e) {
      // ignore: avoid_print
      print('=== VP error: $e');
    }
  }

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
        // ignore: avoid_print
        print('=== FFmpeg failed: ${logs?.substring(0, logs.length.clamp(0, 200))}');
        return false;
      }
      return true;
    } catch (e) {
      // ignore: avoid_print
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

  Future<List<String>> splitForUpload(String filePath, DateTime sessionTime) async {
    final file = File(filePath);
    if (!await file.exists()) {
      // ignore: avoid_print
      print('=== splitForUpload: not found: $filePath'); return [];
    }
    final durationSec  = await _probeDurationSec(filePath);
    final totalChunks  = durationSec > 0
        ? (durationSec / chunkSecs).ceil().clamp(1, 999) : 1;

    if (totalChunks == 1) return [filePath];

    final tmpDir    = await getTemporaryDirectory();
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

      if (ok && await File(chunkPath).exists() &&
          await File(chunkPath).length() > 512) {
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