import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'session_store.dart';
import 'user_service.dart';

class OneDriveService {
  static const String _backendBaseUrl =
      'https://video-recorder-app-d7zk.onrender.com';
  static const String _rootFolder = 'OTN Recorder';

  // ─── Token ────────────────────────────────────────────────────────────────

  static String?   _cachedToken;
  static DateTime? _tokenExpiry;

  static Future<String> getAccessToken() async {
    if (_cachedToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!)) {
      return _cachedToken!;
    }
    final res = await http
        .get(Uri.parse('$_backendBaseUrl/token'))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception('Token failed: ${res.body}');
    final data   = jsonDecode(res.body);
    _cachedToken = data['access_token'] as String;
    _tokenExpiry = DateTime.now().add(const Duration(seconds: 3500));
    return _cachedToken!;
  }

  // ─── Folder path ──────────────────────────────────────────────────────────

  static String buildSessionFolderPath({
    required String dateFolder,
    required String userFullName,
    required String sessionId,
    required String sessionDate,
    required String sessionStartTime,
  }) =>
      '$_rootFolder/$dateFolder/$userFullName/${sessionId}_${sessionDate}_$sessionStartTime';

  // ─── Create fresh resumable upload session ────────────────────────────────

  static Future<String> createUploadSession({
    required String folderPath,
    required String fileName,
  }) async {
    final token       = await getAccessToken();
    final encodedPath = folderPath.split('/').map(Uri.encodeComponent).join('/');
    final url =
        'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath/$fileName:/createUploadSession';
    final res = await http.post(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode({'item': {
        '@microsoft.graph.conflictBehavior': 'fail',
        'name': fileName,
      }}),
    );
    if (res.statusCode == 409) throw Exception('FILE_EXISTS:$fileName');
    if (res.statusCode != 200) {
      throw Exception('createUploadSession ${res.statusCode}: ${res.body}');
    }
    return jsonDecode(res.body)['uploadUrl'] as String;
  }

  // ─── Resume API ───────────────────────────────────────────────────────────
  /// Queries OneDrive for how many bytes were received so far.
  /// Returns the next byte offset to resume from, or null if session expired.
  static Future<int?> queryUploadProgress(String uploadUrl) async {
    try {
      final res = await http.get(Uri.parse(uploadUrl))
          .timeout(const Duration(seconds: 10));
      // 200/308 = still active, body contains nextExpectedRanges
      if (res.statusCode == 200 || res.statusCode == 308) {
        final data   = jsonDecode(res.body);
        final ranges = data['nextExpectedRanges'] as List?;
        if (ranges != null && ranges.isNotEmpty) {
          final first = ranges.first as String; // e.g. "0-" or "5242880-"
          final start = int.tryParse(first.split('-').first) ?? 0;
          return start;
        }
        return 0;
      }
      // 404/410 = expired
      return null;
    } catch (_) {
      return null;
    }
  }

  // ─── Delete a folder on OneDrive (used when abandoning stale session) ─────
  static Future<void> deleteOneDriveFolder({
    required String folderPath,
  }) async {
    try {
      final token       = await getAccessToken();
      final encodedPath = folderPath.split('/').map(Uri.encodeComponent).join('/');
      await http.delete(
        Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      // Non-fatal — stale folder cleanup is best-effort
    }
  }

  // ─── Chunked PUT with optional resume offset ──────────────────────────────
  static Future<void> uploadFileInChunks({
    required String           uploadUrl,
    required File             file,
    required Function(double) onProgress,
    int    chunkSize    = 5 * 1024 * 1024, // 5 MB
    int    startOffset  = 0,               // for resume
  }) async {
    final fileSize = await file.length();
    int   offset   = startOffset;
    final raf      = await file.open();
    try {
      while (offset < fileSize) {
        final end    = (offset + chunkSize > fileSize) ? fileSize : offset + chunkSize;
        final length = end - offset;
        await raf.setPosition(offset);
        final chunk = await raf.read(length);

        final res = await http.put(
          Uri.parse(uploadUrl),
          headers: {
            'Content-Range':  'bytes $offset-${end - 1}/$fileSize',
            'Content-Length': '$length',
          },
          body: chunk,
        ).timeout(const Duration(seconds: 120));

        if (res.statusCode != 200 &&
            res.statusCode != 201 &&
            res.statusCode != 202) {
          throw Exception('Chunk PUT failed ${res.statusCode} at $offset');
        }
        offset = end;
        onProgress(offset / fileSize);
      }
    } finally {
      await raf.close();
    }
  }

  // ─── uploadFileInSession (used by ChunkUploadQueue) ───────────────────────
  /// Supports resume: if [existingUploadUrl] is provided, tries to resume.
  /// If the URL is expired → deletes the stale OneDrive folder → starts fresh.
  Future<void> uploadFileInSession({
    required String filePath,
    required String fileName,
    required String dateFolder,
    required String userFolder,
    required String sessionFolder,
    required String rootFolder,
    required void Function(double) onProgress,
    required void Function(String) onStatus,
    String? existingUploadUrl, // for resume attempt
  }) async {
    final folderPath = '$rootFolder/$dateFolder/$userFolder/$sessionFolder';
    String uploadUrl;
    int    startOffset = 0;

    if (existingUploadUrl != null) {
      // Try to resume from existing upload session
      onStatus('Checking upload progress...');
      final resumeOffset = await queryUploadProgress(existingUploadUrl);
      if (resumeOffset != null) {
        // Session still alive — resume from where it left off
        uploadUrl   = existingUploadUrl;
        startOffset = resumeOffset;
        onStatus('Resuming from ${(resumeOffset / 1024 / 1024).toStringAsFixed(1)} MB...');
      } else {
        // Session expired — delete the incomplete/stale OneDrive folder
        // then start a completely fresh upload session
        onStatus('Upload session expired — restarting...');
        await deleteOneDriveFolder(folderPath: folderPath);
        await Future.delayed(const Duration(seconds: 2)); // let OneDrive settle
        uploadUrl   = await createUploadSession(folderPath: folderPath, fileName: fileName);
        startOffset = 0;
      }
    } else {
      // No existing session — create fresh
      onStatus('Creating upload session...');
      uploadUrl   = await createUploadSession(folderPath: folderPath, fileName: fileName);
      startOffset = 0;
    }

    onStatus('Uploading...');
    await uploadFileInChunks(
      uploadUrl:   uploadUrl,
      file:        File(filePath),
      onProgress:  onProgress,
      startOffset: startOffset,
    );
  }

  // ─── uploadFile (used by upload_service.dart) ─────────────────────────────
  Future<void> uploadFile({
    required String filePath, required String fileName,
    required String dateFolder, required String userFolder,
    required String rootFolder,
    required bool Function() isPaused, required bool Function() isCancelled,
    required void Function(double) onProgress, required void Function(String) onStatus,
  }) async {
    final fp  = '$rootFolder/$dateFolder/$userFolder';
    final url = await createUploadSession(folderPath: fp, fileName: fileName);
    await uploadFileInChunks(
      uploadUrl: url, file: File(filePath),
      onProgress: (p) { if (isCancelled()) throw Exception('cancelled'); onProgress(p); },
    );
  }

  // ─── File integrity check (size > 0) ─────────────────────────────────────
  Future<bool> fileExistsAndComplete({
    required String folderPath,
    required String fileName,
  }) async {
    try {
      final token       = await getAccessToken();
      final encodedPath = folderPath.split('/').map(Uri.encodeComponent).join('/');
      final fr = await http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (fr.statusCode != 200) return false;

      final ef = Uri.encodeComponent(fileName);
      final r  = await http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath/$ef'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return false;
      return (jsonDecode(r.body)['size'] as int? ?? 0) > 0;
    } catch (_) {
      return false;
    }
  }

  // ─── listUserFiles ────────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> listUserFiles({
    required String rootFolder,
    required String userFolder,
  }) async {
    final token = await getAccessToken();
    final files = <Map<String, dynamic>>[];
    try {
      final rp      = Uri.encodeComponent(rootFolder);
      final datesRes = await http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$rp:/children'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      if (datesRes.statusCode != 200) return files;

      for (final df in (jsonDecode(datesRes.body)['value'] as List)
          .cast<Map<String, dynamic>>()) {
        if (df['folder'] == null) continue;
        final dateName = df['name'] as String;
        final up = Uri.encodeComponent('$rootFolder/$dateName/$userFolder');
        final userRes = await http.get(
          Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$up:/children'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 15));
        if (userRes.statusCode != 200) continue;

        for (final item in (jsonDecode(userRes.body)['value'] as List)
            .cast<Map<String, dynamic>>()) {
          if (item['folder'] != null) {
            final sn = item['name'] as String;
            final sp = Uri.encodeComponent('$rootFolder/$dateName/$userFolder/$sn');
            final sr = await http.get(
              Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$sp:/children'),
              headers: {'Authorization': 'Bearer $token'},
            ).timeout(const Duration(seconds: 15));
            if (sr.statusCode != 200) continue;
            for (final part in (jsonDecode(sr.body)['value'] as List)
                .cast<Map<String, dynamic>>()) {
              if (part['file'] != null) {
                files.add({
                  'name':          part['name'],
                  'size':          part['size'] as int? ?? 0,
                  'dateFolder':    dateName,
                  'sessionFolder': sn,
                  'userFolder':    userFolder,
                  'id':            part['id'],
                });
              }
            }
          } else if (item['file'] != null) {
            files.add({
              'name':       item['name'],
              'size':       item['size'] as int? ?? 0,
              'dateFolder': dateName,
              'userFolder': userFolder,
              'id':         item['id'],
            });
          }
        }
      }
    } catch (e) { throw Exception('listUserFiles failed: $e'); }
    return files;
  }

  // ─── Two attendance CSVs ──────────────────────────────────────────────────
  static Future<void> writeAdminAttendanceCsv() async {
    try {
      final token    = await getAccessToken();
      final rp       = Uri.encodeComponent(_rootFolder);
      final datesRes = await http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$rp:/children'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      if (datesRes.statusCode != 200) return;

      final detail = <Map<String, dynamic>>[];

      for (final df in (jsonDecode(datesRes.body)['value'] as List)
          .cast<Map<String, dynamic>>()) {
        if (df['folder'] == null) continue;
        final dateName = df['name'] as String;
        final dp = Uri.encodeComponent('$_rootFolder/$dateName');
        final usersRes = await http.get(
          Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$dp:/children'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 15));
        if (usersRes.statusCode != 200) continue;

        for (final uf in (jsonDecode(usersRes.body)['value'] as List)
            .cast<Map<String, dynamic>>()) {
          if (uf['folder'] == null) continue;
          final userName = uf['name'] as String;
          final up = Uri.encodeComponent('$_rootFolder/$dateName/$userName');
          final sessRes = await http.get(
            Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$up:/children'),
            headers: {'Authorization': 'Bearer $token'},
          ).timeout(const Duration(seconds: 15));
          if (sessRes.statusCode != 200) continue;

          for (final sf in (jsonDecode(sessRes.body)['value'] as List)
              .cast<Map<String, dynamic>>()) {
            if (sf['folder'] == null) continue;
            final sessionName = sf['name'] as String;
            final sp = Uri.encodeComponent('$_rootFolder/$dateName/$userName/$sessionName');
            final partsRes = await http.get(
              Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$sp:/children'),
              headers: {'Authorization': 'Bearer $token'},
            ).timeout(const Duration(seconds: 15));
            if (partsRes.statusCode != 200) continue;

            final parts = (jsonDecode(partsRes.body)['value'] as List)
                .cast<Map<String, dynamic>>()
                .where((p) => p['file'] != null).toList();
            if (parts.isEmpty) continue;

            int    totalMins = 0;
            String startTime = '';
            String endTime   = '';

            final nameParts = sessionName.split('_');
            if (nameParts.length >= 3) {
              final t = nameParts[2];
              if (t.length == 6) {
                startTime = '${t.substring(0,2)}:${t.substring(2,4)}:${t.substring(4,6)}';
              }
            }
            for (final p in parts) {
              totalMins += _parseFileMins(p['name'] as String? ?? '');
            }
            if (startTime.isNotEmpty && totalMins > 0) {
              try {
                final hh  = int.parse(startTime.substring(0, 2));
                final mm  = int.parse(startTime.substring(3, 5));
                final ss  = int.parse(startTime.substring(6, 8));
                final end = DateTime(2000, 1, 1, hh, mm, ss)
                    .add(Duration(minutes: totalMins));
                endTime = '${end.hour.toString().padLeft(2,'0')}:'
                    '${end.minute.toString().padLeft(2,'0')}:'
                    '${end.second.toString().padLeft(2,'0')}';
              } catch (_) {}
            }
            detail.add({
              'date': dateName, 'user': userName, 'session': sessionName,
              'startTime': startTime, 'endTime': endTime,
              'mins': totalMins, 'parts': parts.length,
            });
          }
        }
      }

      detail.sort((a, b) {
        final dc = (b['date'] as String).compareTo(a['date'] as String);
        if (dc != 0) return dc;
        final uc = (a['user'] as String).compareTo(b['user'] as String);
        return uc != 0 ? uc : (a['session'] as String).compareTo(b['session'] as String);
      });

      final summaryMap = <String, Map<String, dynamic>>{};
      for (final r in detail) {
        final key = '${r['date']}|${r['user']}';
        summaryMap.putIfAbsent(key, () => {
          'date': r['date'], 'user': r['user'],
          'totalSessions': 0, 'totalMins': 0, 'totalParts': 0,
        });
        summaryMap[key]!['totalSessions'] = (summaryMap[key]!['totalSessions'] as int) + 1;
        summaryMap[key]!['totalMins']     = (summaryMap[key]!['totalMins']     as int) + (r['mins'] as int);
        summaryMap[key]!['totalParts']    = (summaryMap[key]!['totalParts']    as int) + (r['parts'] as int);
      }
      final summary = summaryMap.values.toList()
        ..sort((a, b) {
          final dc = (b['date'] as String).compareTo(a['date'] as String);
          return dc != 0 ? dc : (a['user'] as String).compareTo(b['user'] as String);
        });

      final detailSb = StringBuffer();
      detailSb.writeln('Date,User,Session,StartTime,EndTime,Duration(mins),Parts');
      for (final r in detail) {
        detailSb.writeln('${r['date']},${r['user']},${r['session']},'
            '${r['startTime']},${r['endTime']},${r['mins']},${r['parts']}');
      }
      await _writeCsv(token, 'attendance_detail.csv', detailSb.toString());

      final sumSb = StringBuffer();
      sumSb.writeln('Date,User,TotalSessions,TotalMins,TotalParts');
      for (final r in summary) {
        sumSb.writeln('${r['date']},${r['user']},'
            '${r['totalSessions']},${r['totalMins']},${r['totalParts']}');
      }
      await _writeCsv(token, 'attendance_summary.csv', sumSb.toString());

      // ignore: avoid_print
      print('=== Attendance CSVs: ${detail.length} sessions, ${summary.length} user-days');
    } catch (e) {
      // ignore: avoid_print
      print('=== writeAdminAttendanceCsv error: $e');
    }
  }

  static Future<void> _writeCsv(String token, String fileName, String content) async {
    final path = Uri.encodeComponent(_rootFolder) + '/' + Uri.encodeComponent(fileName);
    await http.put(
      Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$path:/content'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'text/csv'},
      body: utf8.encode(content),
    ).timeout(const Duration(seconds: 30));
  }

  static int _parseFileMins(String name) {
    final m = RegExp(r'_(\d{2})-(\d{2})\.mp4').firstMatch(name);
    if (m == null) return 0;
    return int.parse(m.group(2)!) - int.parse(m.group(1)!);
  }

  // ─── Background sync ─────────────────────────────────────────────────────
  static Timer? _syncTimer;

  static void startBackgroundSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(minutes: 5), (_) => _verifySyncedSessions());
    _verifySyncedSessions();
  }

  static void stopBackgroundSync() { _syncTimer?.cancel(); _syncTimer = null; }

  static Future<void> _verifySyncedSessions() async {
    try {
      final userFullName = await UserService().getDisplayName();
      final token        = await getAccessToken();
      final store        = await SessionStore.load();
      for (final s in store.sessions.where((s) => s.status == 'synced')) {
        final fp = buildSessionFolderPath(
          dateFolder: s.dateFolder, userFullName: userFullName,
          sessionId: s.id.length >= 6 ? s.id.substring(0,6).toUpperCase() : s.id.toUpperCase(),
          sessionDate: s.sessionDate, sessionStartTime: s.startTime,
        );
        if (!await _folderExistsOnOneDrive(token: token, folderPath: fp)) {
          await store.removeSession(s.id);
        }
      }
    } catch (_) {}
  }

  static Future<bool> _folderExistsOnOneDrive({required String token, required String folderPath}) async {
    try {
      final ep  = folderPath.split('/').map(Uri.encodeComponent).join('/');
      final res = await http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$ep'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      return res.statusCode == 200;
    } catch (_) { return true; }
  }

  static Future<void> forceSync() async => _verifySyncedSessions();
}