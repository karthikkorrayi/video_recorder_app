import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';

/// Uploads files directly from phone to cloud storage using Microsoft Graph API.
/// Backend is only needed for token refresh — no file data passes through it.
class OneDriveService {
  static const String _backendUrl = 'https://video-recorder-app-d7zk.onrender.com';
  static const String _graphBase  = 'https://graph.microsoft.com/v1.0/me/drive';
  static const int    _graphChunk = 10 * 1024 * 1024; // 10MB per slice

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 10),
    sendTimeout:    const Duration(minutes: 10),
  ));

  String?   _accessToken;
  DateTime? _tokenExpiry;

  // ── Token ─────────────────────────────────────────────────────────────────
  Future<String> _getToken() async {
    if (_accessToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!.subtract(const Duration(minutes: 2)))) {
      return _accessToken!;
    }
    print('=== Getting token from backend...');
    try {
      final res = await _dio.get(
        '$_backendUrl/token',
        options: Options(
          receiveTimeout: const Duration(seconds: 75),
          validateStatus: (s) => s != null && s < 600,
        ),
      );
      if (res.statusCode == 404) {
        throw Exception('Backend /token not found — push new server.js to Render');
      }
      if (res.statusCode != 200) {
        throw Exception('Backend returned ${res.statusCode}: ${res.data}');
      }
      _accessToken = res.data['access_token'] as String;
      final expiresIn = res.data['expires_in'] as int? ?? 3600;
      _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
      print('=== Token refreshed OK');
      return _accessToken!;
    } catch (e) {
      throw Exception('Failed to get token: $e');
    }
  }

  // ── Folder helpers ────────────────────────────────────────────────────────
  Future<String> _ensureFolder(String token, String parentId, String name) async {
    try {
      final r = await _dio.get(
        '$_graphBase/items/$parentId/children'
        '?\$filter=name eq \'${Uri.encodeComponent(name)}\'&\$select=id',
        options: Options(headers: {'Authorization': 'Bearer $token'},
            validateStatus: (s) => s != null && s < 600));
      final items = r.data['value'] as List?;
      if (items != null && items.isNotEmpty) return items[0]['id'] as String;
    } catch (_) {}
    final r = await _dio.post(
      '$_graphBase/items/$parentId/children',
      data: {'name': name, 'folder': {}, '@microsoft.graph.conflictBehavior': 'rename'},
      options: Options(headers: {
        'Authorization': 'Bearer $token', 'Content-Type': 'application/json'}));
    return r.data['id'] as String;
  }

  Future<String> _getRootFolderId(String token, String rootName) async {
    try {
      final r = await _dio.get(
        '$_graphBase/root/children'
        '?\$filter=name eq \'${Uri.encodeComponent(rootName)}\'&\$select=id',
        options: Options(headers: {'Authorization': 'Bearer $token'},
            validateStatus: (s) => s != null && s < 600));
      final items = r.data['value'] as List?;
      if (items != null && items.isNotEmpty) return items[0]['id'] as String;
    } catch (_) {}
    final r = await _dio.post(
      '$_graphBase/root/children',
      data: {'name': rootName, 'folder': {}, '@microsoft.graph.conflictBehavior': 'rename'},
      options: Options(headers: {
        'Authorization': 'Bearer $token', 'Content-Type': 'application/json'}));
    return r.data['id'] as String;
  }

  // ── Upload single file ─────────────────────────────────────────────────────
  Future<void> uploadFile({
    required String filePath,
    required String fileName,
    required String dateFolder,
    required String userFolder,
    required String rootFolder,
    required void Function(double) onProgress,
    required void Function(String) onStatus,
    bool Function()? isPaused,
    bool Function()? isCancelled,
  }) async {
    onStatus('Getting access token...');
    final token  = await _getToken();

    onStatus('Preparing cloud folder...');
    final rootId = await _getRootFolderId(token, rootFolder);
    final dateId = await _ensureFolder(token, rootId, dateFolder);
    final userId = await _ensureFolder(token, dateId, userFolder);

    final fileSize = await File(filePath).length();
    print('=== Uploading: $fileName (${(fileSize/1024/1024).toStringAsFixed(1)}MB)');

    // Step 1: Create upload session
    onStatus('Creating upload session...');
    final sessionRes = await _dio.post(
      '$_graphBase/items/$userId:/${Uri.encodeComponent(fileName)}:/createUploadSession',
      data: {'item': {'@microsoft.graph.conflictBehavior': 'replace', 'name': fileName}},
      options: Options(headers: {
        'Authorization': 'Bearer $token',
        'Content-Type':  'application/json',
      }, validateStatus: (s) => s != null && s < 600));

    if (sessionRes.statusCode != 200) {
      throw Exception('Failed to create upload session: ${sessionRes.statusCode} ${sessionRes.data}');
    }
    final uploadUrl = sessionRes.data['uploadUrl'] as String;

    // Step 2: Upload in 10MB slices
    // KEY FIX: send raw Uint8List bytes — NOT Stream.fromIterable()
    // Dio + Graph API requires known content-length which streams don't provide reliably
    int   offset     = 0;
    int   chunkNum   = 0;
    final totalChunks = (fileSize / _graphChunk).ceil();

    while (offset < fileSize) {
      // Pause/cancel check
      while (isPaused != null && isPaused()) {
        if (isCancelled != null && isCancelled()) return;
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (isCancelled != null && isCancelled()) return;

      final end       = (offset + _graphChunk).clamp(0, fileSize);
      final chunkSize = end - offset;
      chunkNum++;

      // Read slice from disk — peak RAM = 10MB
      final chunk = await _readChunk(filePath, offset, chunkSize);

      // Retry each slice up to 3 times
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          final res = await _dio.put(
            uploadUrl,
            data: chunk, // ← raw Uint8List, not Stream
            options: Options(
              headers: {
                'Content-Range':  'bytes $offset-${end - 1}/$fileSize',
                'Content-Length': '$chunkSize',
                'Content-Type':   'application/octet-stream',
              },
              receiveTimeout:  const Duration(minutes: 5),
              sendTimeout:     const Duration(minutes: 5),
              // 200 = intermediate chunk accepted
              // 201/202 = final chunk, file created
              // 308 = Resume Incomplete (Graph uses this for intermediate chunks)
              validateStatus: (s) => s != null && (s == 200 || s == 201 || s == 202 || s == 308),
            ),
          );
          print('=== Chunk $chunkNum/$totalChunks → ${res.statusCode}');
          break;
        } catch (e) {
          print('=== Chunk $chunkNum attempt $attempt failed: $e');
          if (attempt == 3) rethrow;
          await Future.delayed(Duration(seconds: attempt * 3));
        }
      }

      offset = end;
      final pct = offset / fileSize;
      onProgress(pct);
      onStatus('Uploading... ${(pct * 100).toStringAsFixed(0)}%');
    }

    print('=== Upload complete: $fileName');
  }

  // Read a slice of a file into memory
  Future<Uint8List> _readChunk(String filePath, int start, int length) async {
    final raf   = await File(filePath).open();
    await raf.setPosition(start);
    final bytes = await raf.read(length);
    await raf.close();
    return Uint8List.fromList(bytes);
  }
}