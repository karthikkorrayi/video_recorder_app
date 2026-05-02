import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'session_store.dart';
import 'user_service.dart';

class OneDriveService {
  static const String _backendBaseUrl = 'https://video-recorder-app-d7zk.onrender.com';
  static const String _rootFolder     = 'OTN Recorder';

  // ─── Token (cached, auto-refreshes) ──────────────────────────────────────
  static String?   _cachedToken;
  static DateTime? _tokenExpiry;

  static Future<String> getAccessToken({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _cachedToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!)) {
      return _cachedToken!;
    }
    final res = await http
        .get(Uri.parse('$_backendBaseUrl/token'))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception('Token failed: ${res.body}');
    final data   = jsonDecode(res.body);
    _cachedToken = data['access_token'] as String;
    // Refresh 5 minutes before actual expiry
    _tokenExpiry = DateTime.now().add(const Duration(seconds: 2700));
    return _cachedToken!;
  }

  // ─── Encode a path segment ────────────────────────────────────────────────
  static String _enc(String s) => Uri.encodeComponent(s);
  static String _encPath(String path) =>
      path.split('/').map(_enc).join('/');

  // ─── Folder path builder ──────────────────────────────────────────────────
  static String buildSessionFolderPath({
    required String dateFolder,
    required String userFullName,
    required String sessionId,
    required String sessionDate,
    required String sessionStartTime,
  }) =>
      '$_rootFolder/$dateFolder/$userFullName/${sessionId}_${sessionDate}_$sessionStartTime';

  // ─────────────────────────────────────────────────────────────────────────
  // CORE UPLOAD METHOD — simple, reliable, no complex resume logic
  //
  // Strategy:
  // 1. Check if file already exists and is complete → skip (idempotent)
  // 2. Delete ANY existing incomplete file for this name (prevents 409)
  // 3. Create fresh upload session with conflictBehavior:'replace'
  // 4. Upload in 5MB chunks
  // 5. If anything fails → caller handles retry
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> uploadFileInSession({
    required String filePath,
    required String fileName,
    required String dateFolder,
    required String userFolder,
    required String sessionFolder,
    required String rootFolder,
    required void Function(double) onProgress,
    required void Function(String) onStatus,
    String? existingUploadUrl, // kept for API compat, no longer used
  }) async {
    final folderPath = '$rootFolder/$dateFolder/$userFolder/$sessionFolder';

    // Step 1: Already complete on OneDrive? Skip entirely.
    onStatus('Checking...');
    if (await fileExistsAndComplete(folderPath: folderPath, fileName: fileName)) {
      debugPrint('=== OD: $fileName already complete — skip');
      return;
    }

    // Step 2: Delete any incomplete/partial file to clear the way.
    // This is the key fix — prevents 409 CONFLICT on retry.
    onStatus('Preparing...');
    await _deleteFileIfExists(folderPath: folderPath, fileName: fileName);
    // Small delay to let OneDrive propagate the delete
    await Future.delayed(const Duration(milliseconds: 800));

    // Step 3: Create a fresh upload session.
    // Use 'replace' as belt-and-suspenders in case delete hasn't propagated.
    onStatus('Creating session...');
    final uploadUrl = await _createFreshSession(
        folderPath: folderPath, fileName: fileName);

    // Step 4: Upload in chunks.
    onStatus('Uploading...');
    await _uploadInChunks(
      uploadUrl:  uploadUrl,
      file:       File(filePath),
      onProgress: onProgress,
    );
  }

  // ─── Create upload session ────────────────────────────────────────────────
  static Future<String> _createFreshSession({
    required String folderPath,
    required String fileName,
  }) async {
    final token = await getAccessToken();
    final url   = 'https://graph.microsoft.com/v1.0/me/drive/root:/'
        '${_encPath(folderPath)}/$fileName:/createUploadSession';

    final res = await http.post(
      Uri.parse(url),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type':  'application/json',
      },
      body: jsonEncode({
        'item': {
          // 'replace' means: if the file already exists, overwrite it.
          // This prevents 409 CONFLICT even if delete didn't fully propagate.
          '@microsoft.graph.conflictBehavior': 'replace',
          'name': fileName,
        }
      }),
    ).timeout(const Duration(seconds: 30));

    if (res.statusCode == 401) {
      _cachedToken = null;
      _tokenExpiry  = null;
      throw Exception('createSession failed 401 (token cleared for retry): ${res.body}');
    }
    if (res.statusCode != 200) {
      throw Exception('createSession failed ${res.statusCode}: ${res.body}');
    }
    return jsonDecode(res.body)['uploadUrl'] as String;
  }

  // ─── Upload file in 5MB chunks ────────────────────────────────────────────
  // ─── True resumable chunked upload ───────────────────────────────────────
  // Uses 1MB chunks (vs 5MB) for finer progress granularity.
  // On any network error (timeout, reset, etc.) → queries OneDrive for how
  // many bytes it already received → resumes from that offset automatically.
  // This handles "Connection reset by peer" and "Connection timed out" without
  // losing progress or requiring a full restart.
  static const int _chunkBytes = 5 * 1024 * 1024; // 5 MB per PUT request
  static const int _maxChunkRetries = 5; // retry each individual chunk up to 5x

  static Future<void> _uploadInChunks({
    required String           uploadUrl,
    required File             file,
    required Function(double) onProgress,
    int chunkSize = _chunkBytes, // kept for compat, uses _chunkBytes internally
  }) async {
    final fileSize = await file.length();
    if (fileSize == 0) throw Exception('File is empty: ${file.path}');

    int offset = 0;
    final raf  = await file.open();

    try {
      while (offset < fileSize) {
        final end    = (offset + _chunkBytes > fileSize)
            ? fileSize : offset + _chunkBytes;
        final length = end - offset;

        bool chunkOk = false;
        int  chunkAttempt = 0;

        while (!chunkOk && chunkAttempt < _maxChunkRetries) {
          chunkAttempt++;
          try {
            await raf.setPosition(offset);
            final chunk = await raf.read(length);

            final res = await http.put(
              Uri.parse(uploadUrl),
              headers: {
                'Content-Range':  'bytes $offset-${end - 1}/$fileSize',
                'Content-Length': '$length',
              },
              body: chunk,
            ).timeout(const Duration(seconds: 300)); // 300s per 1MB chunk — slow connections

            if (res.statusCode == 401) {
              _cachedToken = null;
              _tokenExpiry  = null;
              throw Exception('PUT 401 — token cleared');
            }
            if (res.statusCode == 200 ||
                res.statusCode == 201 ||
                res.statusCode == 202) {
              chunkOk = true;
              offset  = end;
              onProgress(offset / fileSize);
              debugPrint('=== OD: chunk $offset/$fileSize (${(offset/fileSize*100).toStringAsFixed(0)}%)');
            } else {
              throw Exception('PUT ${res.statusCode} at offset $offset');
            }

          } catch (e) {
            final errStr = e.toString();
            debugPrint('=== OD: chunk attempt $chunkAttempt failed at offset $offset: $errStr');

            if (errStr.contains('401')) rethrow; // token error — bubble up immediately

            // DNS/network-gone errors: do NOT count against retry limit
            // Wait for DNS to recover then retry same attempt
            final isDnsError = errStr.contains('No address associated with hostname') ||
                errStr.contains('Failed host lookup') ||
                errStr.contains('errno = 7') ||
                errStr.contains('UnknownHostException');

            if (isDnsError) {
              debugPrint('=== OD: DNS failure — waiting 15s for network to recover');
              await Future.delayed(const Duration(seconds: 15));
              chunkAttempt--; // do NOT count DNS failure as a retry attempt
              continue;       // retry same chunk without consuming a retry slot
            }

            if (chunkAttempt < _maxChunkRetries) {
              // For real network errors (timeout, reset): query resume offset
              final resumeOffset = await _queryUploadProgress(uploadUrl);
              if (resumeOffset > offset) {
                debugPrint('=== OD: resuming from $resumeOffset (was $offset)');
                offset = resumeOffset;
                if (offset >= fileSize) { chunkOk = true; break; }
              }
              final waitSecs = chunkAttempt * 3;
              debugPrint('=== OD: waiting ${waitSecs}s before chunk retry');
              await Future.delayed(Duration(seconds: waitSecs));
            }
          }
        }

        if (!chunkOk) {
          // All chunk retries exhausted — bubble up to outer retry logic
          throw Exception(
              'Chunk at offset $offset failed after $_maxChunkRetries attempts');
        }
      }
    } finally {
      await raf.close();
    }
  }

  // ─── Query OneDrive for upload progress ──────────────────────────────────
  // Returns how many bytes OneDrive has already received.
  // Used to resume after a connection reset.
  static Future<int> _queryUploadProgress(String uploadUrl) async {
    try {
      final res = await http.put(
        Uri.parse(uploadUrl),
        headers: {
          'Content-Range': 'bytes */*', // special: query-only, no body
          'Content-Length': '0',
        },
      ).timeout(const Duration(seconds: 15));

      // 308 Resume Incomplete — response header tells us the range received
      if (res.statusCode == 308) {
        final range = res.headers['range'];
        if (range != null) {
          // range = "bytes=0-12345" → next offset is 12346
          final parts = range.split('-');
          if (parts.length == 2) {
            return int.parse(parts[1]) + 1;
          }
        }
      }
    } catch (_) {}
    return 0; // unknown — restart chunk from beginning
  }

  // ─── Delete a specific file (best-effort, non-fatal) ─────────────────────
  static Future<void> _deleteFileIfExists({
    required String folderPath,
    required String fileName,
  }) async {
    try {
      final token = await getAccessToken();
      final path  = '${_encPath(folderPath)}/${_enc(fileName)}';
      await http.delete(
        Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$path'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      debugPrint('=== OD: pre-cleared $fileName');
    } catch (_) {
      // Non-fatal — file may not exist yet, that's fine
    }
  }

  // ─── Delete a folder (best-effort) ───────────────────────────────────────
  static Future<void> deleteOneDriveFolder({required String folderPath}) async {
    try {
      final token = await getAccessToken();
      await http.delete(
        Uri.parse(
            'https://graph.microsoft.com/v1.0/me/drive/root:/${_encPath(folderPath)}'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  // ─── File integrity check ─────────────────────────────────────────────────
  /// Returns true only if file exists AND size > 0 bytes on OneDrive.
  Future<bool> fileExistsAndComplete({
    required String folderPath,
    required String fileName,
  }) async {
    try {
      final token = await getAccessToken();
      final path  = '${_encPath(folderPath)}/${_enc(fileName)}';
      final r     = await http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$path'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return false;
      return (jsonDecode(r.body)['size'] as int? ?? 0) > 0;
    } catch (_) {
      return false;
    }
  }

  // ─── Compatibility methods (used by upload_manager.dart + upload_service.dart)

  /// Public wrapper — used by upload_manager.dart
  static Future<String> createUploadSession({
    required String folderPath,
    required String fileName,
  }) => _createFreshSession(folderPath: folderPath, fileName: fileName);

  /// Public wrapper — used by upload_manager.dart
  static Future<void> uploadFileInChunks({
    required String           uploadUrl,
    required File             file,
    required Function(double) onProgress,
    int chunkSize   = 5 * 1024 * 1024,
    int startOffset = 0,
  }) => _uploadInChunks(
    uploadUrl:  uploadUrl,
    file:       file,
    onProgress: onProgress,
    chunkSize:  chunkSize,
  );

  /// Public wrapper — used by upload_service.dart
  Future<void> uploadFile({
    required String filePath,
    required String fileName,
    required String dateFolder,
    required String userFolder,
    required String rootFolder,
    required bool Function() isPaused,
    required bool Function() isCancelled,
    required void Function(double) onProgress,
    required void Function(String) onStatus,
  }) async {
    await uploadFileInSession(
      filePath:      filePath,
      fileName:      fileName,
      dateFolder:    dateFolder,
      userFolder:    userFolder,
      sessionFolder: '',
      rootFolder:    rootFolder,
      onProgress:    (p) {
        if (isCancelled()) throw Exception('Upload cancelled');
        onProgress(p);
      },
      onStatus: onStatus,
    );
  }

  // ─── List user files ──────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> listUserFiles({
    required String rootFolder,
    required String userFolder,
  }) async {
    final token = await getAccessToken();
    final files = <Map<String, dynamic>>[];
    try {
      final rp       = _enc(rootFolder);
      final datesRes = await http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$rp:/children'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));
      if (datesRes.statusCode != 200) return files;

      for (final df in (jsonDecode(datesRes.body)['value'] as List)
          .cast<Map<String, dynamic>>()) {
        if (df['folder'] == null) continue;
        final dateName = df['name'] as String;
        final up       = _encPath('$rootFolder/$dateName/$userFolder');
        final userRes  = await http.get(
          Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$up:/children'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 20));
        if (userRes.statusCode != 200) continue;

        for (final item in (jsonDecode(userRes.body)['value'] as List)
            .cast<Map<String, dynamic>>()) {
          if (item['folder'] != null) {
            final sn = item['name'] as String;
            final sp = _encPath('$rootFolder/$dateName/$userFolder/$sn');
            final sr = await http.get(
              Uri.parse(
                  'https://graph.microsoft.com/v1.0/me/drive/root:/$sp:/children'),
              headers: {'Authorization': 'Bearer $token'},
            ).timeout(const Duration(seconds: 20));
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

  // ─── Attendance CSVs ──────────────────────────────────────────────────────
  static Future<void> writeAdminAttendanceCsv() async {
    try {
      final token    = await getAccessToken();
      final rp       = _enc(_rootFolder);
      final datesRes = await http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$rp:/children'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));
      if (datesRes.statusCode != 200) return;

      final detail = <Map<String, dynamic>>[];

      for (final df in (jsonDecode(datesRes.body)['value'] as List)
          .cast<Map<String, dynamic>>()) {
        if (df['folder'] == null) continue;
        final dateName = df['name'] as String;
        final usersRes = await http.get(
          Uri.parse(
              'https://graph.microsoft.com/v1.0/me/drive/root:/${_encPath('$_rootFolder/$dateName')}:/children'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 20));
        if (usersRes.statusCode != 200) continue;

        for (final uf in (jsonDecode(usersRes.body)['value'] as List)
            .cast<Map<String, dynamic>>()) {
          if (uf['folder'] == null) continue;
          final userName = uf['name'] as String;
          final sessRes  = await http.get(
            Uri.parse(
                'https://graph.microsoft.com/v1.0/me/drive/root:/${_encPath('$_rootFolder/$dateName/$userName')}:/children'),
            headers: {'Authorization': 'Bearer $token'},
          ).timeout(const Duration(seconds: 20));
          if (sessRes.statusCode != 200) continue;

          for (final sf in (jsonDecode(sessRes.body)['value'] as List)
              .cast<Map<String, dynamic>>()) {
            if (sf['folder'] == null) continue;
            final sessionName = sf['name'] as String;
            final partsRes    = await http.get(
              Uri.parse(
                  'https://graph.microsoft.com/v1.0/me/drive/root:/${_encPath('$_rootFolder/$dateName/$userName/$sessionName')}:/children'),
              headers: {'Authorization': 'Bearer $token'},
            ).timeout(const Duration(seconds: 20));
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
                startTime =
                    '${t.substring(0,2)}:${t.substring(2,4)}:${t.substring(4,6)}';
              }
            }
            for (final p in parts) {
              totalMins += _parseFileMins(p['name'] as String? ?? '');
            }
            if (startTime.isNotEmpty && totalMins > 0) {
              try {
                final hh  = int.parse(startTime.substring(0,2));
                final mm  = int.parse(startTime.substring(3,5));
                final ss  = int.parse(startTime.substring(6,8));
                final end = DateTime(2000,1,1,hh,mm,ss)
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
        return (a['user'] as String).compareTo(b['user'] as String);
      });

      final summaryMap = <String, Map<String, dynamic>>{};
      for (final r in detail) {
        final key = '${r['date']}|${r['user']}';
        summaryMap.putIfAbsent(key, () => {
          'date': r['date'], 'user': r['user'],
          'totalSessions': 0, 'totalMins': 0, 'totalParts': 0,
        });
        summaryMap[key]!['totalSessions'] =
            (summaryMap[key]!['totalSessions'] as int) + 1;
        summaryMap[key]!['totalMins'] =
            (summaryMap[key]!['totalMins'] as int) + (r['mins'] as int);
        summaryMap[key]!['totalParts'] =
            (summaryMap[key]!['totalParts'] as int) + (r['parts'] as int);
      }

      final detailSb = StringBuffer()
        ..writeln('Date,User,Session,StartTime,EndTime,Duration(mins),Parts');
      for (final r in detail) {
        detailSb.writeln('${r['date']},${r['user']},${r['session']},'
            '${r['startTime']},${r['endTime']},${r['mins']},${r['parts']}');
      }
      await _writeCsv(token, 'attendance_detail.csv', detailSb.toString());

      final sumSb = StringBuffer()
        ..writeln('Date,User,TotalSessions,TotalMins,TotalParts');
      for (final r in summaryMap.values.toList()
          ..sort((a,b) {
            final dc = (b['date'] as String).compareTo(a['date'] as String);
            return dc != 0 ? dc :
                (a['user'] as String).compareTo(b['user'] as String);
          })) {
        sumSb.writeln('${r['date']},${r['user']},'
            '${r['totalSessions']},${r['totalMins']},${r['totalParts']}');
      }
      await _writeCsv(token, 'attendance_summary.csv', sumSb.toString());

      debugPrint('=== Attendance CSVs written: ${detail.length} sessions');
    } catch (e) {
      debugPrint('=== writeAdminAttendanceCsv error: $e');
    }
  }

  static Future<void> _writeCsv(
      String token, String fileName, String content) async {
    final path = '${_enc(_rootFolder)}/${_enc(fileName)}';
    await http.put(
      Uri.parse(
          'https://graph.microsoft.com/v1.0/me/drive/root:/$path:/content'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type':  'text/csv',
      },
      body: utf8.encode(content),
    ).timeout(const Duration(seconds: 30));
  }

  static int _parseFileMins(String name) {
    final m = RegExp(r'_(\d{2})-(\d{2})\.mp4').firstMatch(name);
    if (m == null) return 0;
    return int.parse(m.group(2)!) - int.parse(m.group(1)!);
  }

  // ─── Background sync ──────────────────────────────────────────────────────
  static Timer? _syncTimer;

  static void startBackgroundSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(
        const Duration(minutes: 5), (_) => _verifySyncedSessions());
    _verifySyncedSessions();
  }

  static void stopBackgroundSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  static Future<void> _verifySyncedSessions() async {
    try {
      final userFullName = await UserService().getDisplayName();
      final token        = await getAccessToken();
      final store        = await SessionStore.load();
      for (final s in store.sessions.where((s) => s.status == 'synced')) {
        final fp = buildSessionFolderPath(
          dateFolder:       s.dateFolder,
          userFullName:     userFullName,
          sessionId:        s.id.length >= 6
              ? s.id.substring(0, 6).toUpperCase()
              : s.id.toUpperCase(),
          sessionDate:      s.sessionDate,
          sessionStartTime: s.startTime,
        );
        try {
          final ep  = _encPath(fp);
          final res = await http.get(
            Uri.parse(
                'https://graph.microsoft.com/v1.0/me/drive/root:/$ep'),
            headers: {'Authorization': 'Bearer $token'},
          ).timeout(const Duration(seconds: 10));
          if (res.statusCode != 200) await store.removeSession(s.id);
        } catch (_) {}
      }
    } catch (_) {}
  }

  static Future<void> forceSync() async => _verifySyncedSessions();
}