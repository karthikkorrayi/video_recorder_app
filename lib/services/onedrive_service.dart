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
    if (res.statusCode != 200) {
      throw Exception('Token fetch failed: ${res.body}');
    }
    final data    = jsonDecode(res.body);
    _cachedToken  = data['access_token'] as String;
    _tokenExpiry  = DateTime.now().add(const Duration(seconds: 3500));
    return _cachedToken!;
  }

  // ─── Folder path builder ──────────────────────────────────────────────────

  /// All parts of one session go into ONE folder.
  /// Format: OTN Recorder/DD-MM-YYYY/UserFullName/SessionID_Date_StartTime
  static String buildSessionFolderPath({
    required String dateFolder,
    required String userFullName,
    required String sessionId,
    required String sessionDate,
    required String sessionStartTime, // START time only — never stop time
  }) {
    final sessionFolder = '${sessionId}_${sessionDate}_$sessionStartTime';
    return '$_rootFolder/$dateFolder/$userFullName/$sessionFolder';
  }

  // ─── Create resumable upload session ─────────────────────────────────────

  static Future<String> createUploadSession({
    required String folderPath,
    required String fileName,
  }) async {
    final token       = await getAccessToken();
    final encodedPath = folderPath.split('/').map(Uri.encodeComponent).join('/');
    final graphUrl    =
        'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath/$fileName:/createUploadSession';

    final res = await http.post(
      Uri.parse(graphUrl),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type':  'application/json',
      },
      body: jsonEncode({
        'item': {
          '@microsoft.graph.conflictBehavior': 'rename',
          'name': fileName,
        }
      }),
    );

    if (res.statusCode != 200) {
      throw Exception(
          'createUploadSession failed ${res.statusCode}: ${res.body}');
    }
    return jsonDecode(res.body)['uploadUrl'] as String;
  }

  // ─── Chunked PUT upload ───────────────────────────────────────────────────

  static Future<void> uploadFileInChunks({
    required String         uploadUrl,
    required File           file,
    required Function(double) onProgress,
    int chunkSize = 5 * 1024 * 1024, // 5 MB
  }) async {
    final fileSize = await file.length();
    int   offset   = 0;
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
          throw Exception(
              'Chunk PUT failed ${res.statusCode} at offset $offset');
        }
        offset = end;
        onProgress(offset / fileSize);
      }
    } finally {
      await raf.close();
    }
  }

  // ─── uploadFile ───────────────────────────────────────────────────────────
  // Called by upload_service.dart (the compression + single-file upload path)

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
    final folderPath = '$rootFolder/$dateFolder/$userFolder';
    final uploadUrl  = await createUploadSession(
      folderPath: folderPath,
      fileName:   fileName,
    );

    final file = File(filePath);
    await uploadFileInChunks(
      uploadUrl:  uploadUrl,
      file:       file,
      onProgress: (p) {
        // Respect pause/cancel
        if (isCancelled()) throw Exception('Upload cancelled');
        onProgress(p);
      },
    );
  }

  // ─── uploadFileInSession ──────────────────────────────────────────────────
  // Called by chunk_upload_queue.dart (the auto-split background upload path)

  Future<void> uploadFileInSession({
    required String filePath,
    required String fileName,
    required String dateFolder,
    required String userFolder,
    required String sessionFolder,
    required String rootFolder,
    required void Function(double) onProgress,
    required void Function(String) onStatus,
  }) async {
    // Full path: OTN Recorder/DD-MM-YYYY/UserName/SessionFolder/
    final folderPath = '$rootFolder/$dateFolder/$userFolder/$sessionFolder';
    onStatus('Creating upload session...');
    final uploadUrl = await createUploadSession(
      folderPath: folderPath,
      fileName:   fileName,
    );
    onStatus('Uploading...');
    await uploadFileInChunks(
      uploadUrl:  uploadUrl,
      file:       File(filePath),
      onProgress: onProgress,
    );
  }

  // ─── listUserFiles ────────────────────────────────────────────────────────
  // Called by cloud_cache_service.dart

  Future<List<Map<String, dynamic>>> listUserFiles({
    required String rootFolder,
    required String userFolder,
  }) async {
    final token = await getAccessToken();
    final files = <Map<String, dynamic>>[];

    try {
      // List date folders under OTN Recorder/
      final rootPath    = Uri.encodeComponent(rootFolder);
      final datesRes    = await http.get(
        Uri.parse(
            'https://graph.microsoft.com/v1.0/me/drive/root:/$rootPath:/children'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));

      if (datesRes.statusCode != 200) return files;
      final dateFolders = (jsonDecode(datesRes.body)['value'] as List)
          .cast<Map<String, dynamic>>();

      for (final dateFolder in dateFolders) {
        if (dateFolder['folder'] == null) continue; // skip files
        final dateName   = dateFolder['name'] as String;
        final userPath   = Uri.encodeComponent('$rootFolder/$dateName/$userFolder');

        final userRes = await http.get(
          Uri.parse(
              'https://graph.microsoft.com/v1.0/me/drive/root:/$userPath:/children'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 15));

        if (userRes.statusCode != 200) continue;
        final items = (jsonDecode(userRes.body)['value'] as List)
            .cast<Map<String, dynamic>>();

        for (final item in items) {
          if (item['folder'] != null) {
            // Session subfolder — list files inside it
            final sessionName = item['name'] as String;
            final sessionPath = Uri.encodeComponent(
                '$rootFolder/$dateName/$userFolder/$sessionName');
            final sessionRes  = await http.get(
              Uri.parse(
                  'https://graph.microsoft.com/v1.0/me/drive/root:/$sessionPath:/children'),
              headers: {'Authorization': 'Bearer $token'},
            ).timeout(const Duration(seconds: 15));

            if (sessionRes.statusCode != 200) continue;
            final parts = (jsonDecode(sessionRes.body)['value'] as List)
                .cast<Map<String, dynamic>>();

            for (final part in parts) {
              if (part['file'] != null) {
                files.add({
                  'name':          part['name'],
                  'size':          part['size'],
                  'dateFolder':    dateName,
                  'sessionFolder': sessionName,
                  'userFolder':    userFolder,
                  'id':            part['id'],
                });
              }
            }
          } else if (item['file'] != null) {
            // Direct file (legacy format without session subfolder)
            files.add({
              'name':       item['name'],
              'size':       item['size'],
              'dateFolder': dateName,
              'userFolder': userFolder,
              'id':         item['id'],
            });
          }
        }
      }
    } catch (e) {
      throw Exception('listUserFiles failed: $e');
    }

    return files;
  }

  // ─── Background sync ─────────────────────────────────────────────────────

  static Timer? _syncTimer;

  /// Starts background sync every 5 min.
  /// Removes sessions from local store if their OneDrive folder is gone.
  static void startBackgroundSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _verifySyncedSessions();
    });
    _verifySyncedSessions(); // run once immediately
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

      final synced = store.sessions
          .where((s) => s.status == 'synced')
          .toList();

      for (final session in synced) {
        final folderPath = buildSessionFolderPath(
          dateFolder:       session.dateFolder,
          userFullName:     userFullName,
          sessionId:        session.id.length >= 6
              ? session.id.substring(0, 6).toUpperCase()
              : session.id.toUpperCase(),
          sessionDate:      session.sessionDate,
          sessionStartTime: session.startTime,
        );

        final exists = await _folderExistsOnOneDrive(
            token: token, folderPath: folderPath);

        if (!exists) {
          await store.removeSession(session.id);
        }
      }
    } catch (_) {
      // Silent fail — retry next cycle
    }
  }

  static Future<bool> _folderExistsOnOneDrive({
    required String token,
    required String folderPath,
  }) async {
    try {
      final encodedPath =
          folderPath.split('/').map(Uri.encodeComponent).join('/');
      final res = await http.get(
        Uri.parse(
            'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      return res.statusCode == 200;
    } catch (_) {
      return true; // Network error → assume still exists
    }
  }

  /// Force immediate sync (called on pull-to-refresh in HistoryScreen).
  static Future<void> forceSync() async {
    await _verifySyncedSessions();
  }
}