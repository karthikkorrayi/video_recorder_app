import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';
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
    String? existingUploadUrl,
    // NEW: called as soon as OneDrive returns the upload session URL.
    // Callers save this to SQLite for expiry-aware resume across app restarts.
    // Signature: (uploadUrl) async { ... }
    Future<void> Function(String url)? onSessionCreated,
  }) async {
    final folderPath = '$rootFolder/$dateFolder/$userFolder/$sessionFolder';

    // Step 1: Already complete on OneDrive? Skip entirely.
    onStatus('Checking...');
    if (await fileExistsAndComplete(folderPath: folderPath, fileName: fileName)) {
      debugPrint('=== OD: $fileName already complete — skip');
      return;
    }

    // Step 2: Delete any incomplete/partial file to clear the way.
    // Only called if a previous incomplete upload exists — avoids a wasted
    // round-trip on first upload. On mobile (high RTT) this matters.
    onStatus('Preparing...');
    final hadIncomplete = await _deleteFileIfExistsIncomplete(
        folderPath: folderPath, fileName: fileName);
    // Only wait if we actually deleted something — OneDrive needs propagation
    // time. If nothing was deleted, skip the delay entirely.
    if (hadIncomplete) {
      await Future.delayed(const Duration(milliseconds: 400));
    }

    // Step 3: Create a fresh upload session.
    onStatus('Creating session...');
    final uploadUrl = await _createFreshSession(
        folderPath: folderPath, fileName: fileName);

    // Notify caller immediately so session URL + expiry can be persisted.
    // This ensures we can resume even if the app is killed mid-upload.
    if (onSessionCreated != null) {
      try { await onSessionCreated(uploadUrl); } catch (_) {}
    }

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
  // ─── Attendance folder upload ────────────────────────────────────────────
  // Uploads directly to: OTN Recorder/Attendance Reports/<fileName>
  // Uses the same resumable upload session as chunk uploads.
  // Overwrites existing file — so re-exporting same range updates the file.
  // Track the active attendance upload session URL so we can cancel it
  // if a new upload starts while the previous one is still in progress.
  static String? _activeAttendanceSessionUrl;

  Future<void> uploadToAttendanceFolder({
    required String filePath,
    required String fileName,
    required void Function(double) onProgress,
    required void Function(String) onStatus,
  }) async {
    const folderPath = 'OTN Recorder/Attendance Reports';
    final file       = File(filePath);
    if (!file.existsSync()) throw Exception('File not found: $filePath');

    onStatus('Preparing attendance upload...');

    // Cancel any in-progress attendance upload session before starting new one.
    // This is why 409 happens: previous session is still "active" on OneDrive.
    if (_activeAttendanceSessionUrl != null) {
      debugPrint('=== OD: cancelling previous attendance session');
      try {
        await http.delete(Uri.parse(_activeAttendanceSessionUrl!),
            headers: {'Content-Length': '0'})
            .timeout(const Duration(seconds: 10));
      } catch (_) {} // ignore cancel errors
      _activeAttendanceSessionUrl = null;
    }

    // Delete any existing completed file so overwrite works cleanly
    await _deleteFileIfExists(folderPath: folderPath, fileName: fileName);
    await Future.delayed(const Duration(seconds: 2));

    onStatus('Creating upload session...');
    final uploadUrl = await _createFreshSession(
        folderPath: folderPath, fileName: fileName);
    _activeAttendanceSessionUrl = uploadUrl;

    onStatus('Uploading attendance report...');
    try {
      await _uploadInChunks(
          uploadUrl: uploadUrl, file: file, onProgress: onProgress);
      _activeAttendanceSessionUrl = null; // clear on success
      debugPrint('=== OD: attendance report uploaded → $folderPath/$fileName');
    } catch (e) {
      _activeAttendanceSessionUrl = null; // clear on failure too
      rethrow;
    }
  }

  // ─── Network profile — read once per upload, not per chunk ─────────────
  // Querying connectivity twice per chunk (chunk size + timeout) was wasteful.
  // Now read once and carry through the entire upload. If the connection
  // switches mid-upload (e.g. Wi-Fi drops → 4G), the next chunk failure
  // triggers a retry which re-evaluates the profile.
  static const int _chunkBytesWifi      = 5 * 1024 * 1024;  // 5MB — few round-trips
  static const int _chunkBytesMobile    = 512 * 1024;        // 512KB — fast recovery on drops
  static const int _maxChunkRetries     = 8;
  static const Duration _timeoutWifi    = Duration(seconds: 120);
  static const Duration _timeoutMobile  = Duration(seconds: 60); // 512KB in 60s = ~68KB/s minimum

  // Sub-slice for streaming reads from disk.
  // Wi-Fi: 512KB — fills the OS send buffer fast.
  // Mobile: 64KB — finer-grained progress callbacks, less wasted data on drop.
  static const int _subSliceWifi   = 512 * 1024;
  static const int _subSliceMobile = 64  * 1024;

  // Persistent HTTP client — reuses TCP connections across chunks.
  // On mobile, TLS handshake is ~200-400ms per new connection.
  // A 5-chunk session saves up to 2 seconds just from connection reuse.
  static http.Client? _uploadClient;
  static http.Client _getClient() {
    _uploadClient ??= http.Client();
    return _uploadClient!;
  }
  static void _closeClient() {
    _uploadClient?.close();
    _uploadClient = null;
  }

  static Future<({bool isWifi, int chunkSize, int subSlice, Duration timeout})>
      _networkProfile() async {
    final results = await Connectivity().checkConnectivity();
    final isWifi  = results.contains(ConnectivityResult.wifi) ||
                    results.contains(ConnectivityResult.ethernet);
    return (
      isWifi:    isWifi,
      chunkSize: isWifi ? _chunkBytesWifi   : _chunkBytesMobile,
      subSlice:  isWifi ? _subSliceWifi     : _subSliceMobile,
      timeout:   isWifi ? _timeoutWifi      : _timeoutMobile,
    );
  }

  static Future<void> _uploadInChunks({
    required String           uploadUrl,
    required File             file,
    required Function(double) onProgress,
    int chunkSize = _chunkBytesWifi,
  }) async {
    final fileSize = await file.length();
    if (fileSize == 0) throw Exception('File is empty: ${file.path}');

    // Read network profile once — single connectivity check for whole upload
    final profile = await _networkProfile();

    debugPrint('=== OD: upload start — ${(fileSize/1024/1024).toStringAsFixed(1)}MB '
        '| ${profile.isWifi ? "WiFi" : "Mobile"} '
        '| chunk=${profile.chunkSize ~/ 1024}KB '
        '| subSlice=${profile.subSlice ~/ 1024}KB '
        '| timeout=${profile.timeout.inSeconds}s');

    int offset = 0;
    final raf  = await file.open();
    final client = _getClient(); // reuse persistent connection

    try {
      while (offset < fileSize) {
        final end    = (offset + profile.chunkSize > fileSize)
            ? fileSize : offset + profile.chunkSize;
        final length = end - offset;

        bool chunkOk      = false;
        int  chunkAttempt = 0;

        while (!chunkOk && chunkAttempt < _maxChunkRetries) {
          chunkAttempt++;
          try {
            final request = http.StreamedRequest('PUT', Uri.parse(uploadUrl))
              ..headers.addAll({
                'Content-Range':  'bytes $offset-${end - 1}/$fileSize',
                'Content-Length': '$length',
              })
              ..contentLength = length;

            // Stream disk → TCP in sub-slices. Two benefits:
            // 1. No full-chunk RAM load (important for low-memory devices).
            // 2. Progress callbacks fire every sub-slice → smooth progress bar.
            //    On mobile (64KB slices) that's 8 callbacks per 512KB chunk.
            //    On WiFi (512KB slices) that's 10 callbacks per 5MB chunk.
            unawaited((() async {
              try {
                await raf.setPosition(offset);
                int sent = 0;
                while (sent < length) {
                  final toRead = (sent + profile.subSlice > length)
                      ? length - sent : profile.subSlice;
                  final slice = await raf.read(toRead);
                  if (slice.isEmpty) break;
                  request.sink.add(slice);
                  sent += slice.length;
                  onProgress((offset + sent) / fileSize);
                }
              } finally {
                await request.sink.close();
              }
            })());

            final streamed = await client
                .send(request)
                .timeout(profile.timeout);
            final response = await http.Response.fromStream(streamed)
                .timeout(profile.timeout);

            if (response.statusCode == 401) {
              _cachedToken = null;
              _tokenExpiry  = null;
              _closeClient(); // force fresh TLS on token refresh
              throw Exception('PUT 401 — token cleared');
            }
            if (response.statusCode == 423) {
              debugPrint('=== OD: 423 Locked — waiting 8s');
              await Future.delayed(const Duration(seconds: 8));
              throw Exception('PUT 423 at offset $offset');
            }
            if (response.statusCode == 200 ||
                response.statusCode == 201 ||
                response.statusCode == 202) {
              chunkOk = true;
              offset  = end;
              onProgress(offset / fileSize);
              debugPrint('=== OD: ✓ '
                  '${(offset/1024/1024).toStringAsFixed(1)}/'
                  '${(fileSize/1024/1024).toStringAsFixed(1)}MB '
                  '(${(offset/fileSize*100).toStringAsFixed(0)}%)');
            } else {
              throw Exception('PUT ${response.statusCode} at offset $offset');
            }

          } catch (e) {
            final errStr = e.toString();
            debugPrint('=== OD: chunk attempt $chunkAttempt failed @$offset: $errStr');

            if (errStr.contains('401')) rethrow;

            // Network gone — recreate client (stale TCP connection), wait briefly
            final isNetworkGone =
                errStr.contains('No address associated with hostname') ||
                errStr.contains('Failed host lookup') ||
                errStr.contains('errno = 7') ||
                errStr.contains('UnknownHostException') ||
                errStr.contains('Connection reset') ||
                errStr.contains('Connection refused') ||
                errStr.contains('SocketException');

            if (isNetworkGone) {
              _closeClient(); // drop stale connection
              debugPrint('=== OD: network error — recreating client, waiting 8s');
              await Future.delayed(const Duration(seconds: 8));
              chunkAttempt--; // don't count against retry limit
              continue;
            }

            if (chunkAttempt < _maxChunkRetries) {
              // Ask OneDrive how many bytes it actually received → true resume
              final resumeOffset = await _queryUploadProgress(uploadUrl);
              if (resumeOffset > offset) {
                debugPrint('=== OD: server confirmed ${resumeOffset}B → resume');
                offset = resumeOffset;
                if (offset >= fileSize) { chunkOk = true; break; }
              }
              // Mobile-friendly backoff: 1s, 2s, 3s, 4s (not 3,6,9,12)
              // 4G handoffs recover in ~1-2s. Long waits just feel broken.
              final waitSecs = profile.isWifi ? chunkAttempt * 3 : chunkAttempt;
              debugPrint('=== OD: waiting ${waitSecs}s before retry');
              await Future.delayed(Duration(seconds: waitSecs));
            }
          }
        }

        if (!chunkOk) {
          _closeClient(); // reset on failure so next upload starts fresh
          throw Exception(
              'Chunk at offset $offset failed after $_maxChunkRetries attempts');
        }
      }
      // Upload complete — don't close client, keep it warm for the next chunk
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

  // ─── Smart pre-delete: only deletes if file exists AND is incomplete ────────
  // Returns true if a file was deleted (caller should wait for propagation).
  // Returns false immediately if file doesn't exist — saves one round-trip
  // on first upload (the common case). On mobile this saves ~100-200ms RTT.
  static Future<bool> _deleteFileIfExistsIncomplete({
    required String folderPath,
    required String fileName,
  }) async {
    try {
      final token = await getAccessToken();
      final path  = '${_encPath(folderPath)}/${_enc(fileName)}';
      final check = await http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$path'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));

      if (check.statusCode == 404) return false; // file doesn't exist — skip delete

      // File exists — delete it to prevent 409 on createUploadSession
      await http.delete(
        Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$path'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      debugPrint('=== OD: pre-cleared existing $fileName');
      return true;
    } catch (_) {
      return false; // non-fatal
    }
  }

  // ─── Delete a specific file unconditionally (best-effort, non-fatal) ────────
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
    } catch (_) {}
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
  // ─── Download file bytes from OneDrive ──────────────────────────────────
  /// Returns raw bytes of a file, or null if not found.
  /// Used to download the attendance Excel, modify it, and re-upload.
  Future<List<int>?> downloadFileBytes({
    required String folderPath,
    required String fileName,
  }) async {
    try {
      final token = await getAccessToken();
      final path  = '${_encPath(folderPath)}/${_enc(fileName)}';
      // Step 1: get download URL
      final meta = await http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me/drive/root:/$path'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (meta.statusCode != 200) return null;
      final downloadUrl = jsonDecode(meta.body)['@microsoft.graph.downloadUrl'] as String?;
      if (downloadUrl == null) return null;
      // Step 2: download content (no auth header needed for pre-signed URL)
      final res = await http.get(Uri.parse(downloadUrl))
          .timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) return null;
      return res.bodyBytes;
    } catch (e) {
      debugPrint('=== OD: downloadFileBytes error: $e');
      return null;
    }
  }

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