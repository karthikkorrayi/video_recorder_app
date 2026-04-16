import 'dart:io';
import 'package:dio/dio.dart';

/// Uploads files directly from phone to OneDrive using Microsoft Graph API.
/// The phone splits chunks locally, uploads each directly — no backend involved.
/// Backend is only needed to get/refresh the access token.
class OneDriveService {
  static const String _backendUrl = 'https://otn-upload-backend.onrender.com';
  static const String _graphBase  = 'https://graph.microsoft.com/v1.0/me/drive';
  static const int    _graphChunk = 10 * 1024 * 1024; // 10MB per Graph API chunk

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 10),
    sendTimeout:    const Duration(minutes: 10),
  ));

  String? _accessToken;
  DateTime? _tokenExpiry;

  // ── Get token from backend (lightweight — no file data involved) ──────────
  Future<String> _getToken() async {
    if (_accessToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!.subtract(const Duration(minutes: 2)))) {
      return _accessToken!;
    }
    try {
      print('=== Getting token from backend...');
      final res = await _dio.get(
        '$_backendUrl/token',
        options: Options(
          receiveTimeout: const Duration(seconds: 75), // covers Render cold start
          validateStatus: (s) => s != null && s < 600,
        ),
      );
      if (res.statusCode == 404) {
        throw Exception(
          'Backend not updated yet. Please push the new server.js to Render '
          'and wait for it to deploy. The /token endpoint is missing.');
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

  // ── Ensure folder exists, return its item ID ──────────────────────────────
  Future<String> _ensureFolder(String token, String parentId, String name) async {
    try {
      final res = await _dio.get(
        '$_graphBase/items/$parentId/children'
        '?\$filter=name eq \'${Uri.encodeComponent(name)}\'&\$select=id',
        options: Options(headers: {'Authorization': 'Bearer $token'}));
      final items = res.data['value'] as List?;
      if (items != null && items.isNotEmpty) return items[0]['id'] as String;
    } catch (_) {}
    final res = await _dio.post(
      '$_graphBase/items/$parentId/children',
      data: {'name': name, 'folder': {}, '@microsoft.graph.conflictBehavior': 'rename'},
      options: Options(headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json'}));
    return res.data['id'] as String;
  }

  Future<String> _getRootFolderId(String token, String rootName) async {
    try {
      final res = await _dio.get(
        '$_graphBase/root/children'
        '?\$filter=name eq \'${Uri.encodeComponent(rootName)}\'&\$select=id',
        options: Options(headers: {'Authorization': 'Bearer $token'}));
      final items = res.data['value'] as List?;
      if (items != null && items.isNotEmpty) return items[0]['id'] as String;
    } catch (_) {}
    final res = await _dio.post(
      '$_graphBase/root/children',
      data: {'name': rootName, 'folder': {}, '@microsoft.graph.conflictBehavior': 'rename'},
      options: Options(headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json'}));
    return res.data['id'] as String;
  }

  // ── Upload single file directly from phone to OneDrive ────────────────────
  // Uses Graph API resumable upload session — handles files of any size.
  // Only 10MB slices are in RAM at any point.
  Future<void> uploadFile({
    required String filePath,
    required String fileName,
    required String dateFolder,
    required String userFolder,
    required String rootFolder,
    required void Function(double) onProgress,
    required void Function(String) onStatus,
    bool Function()? isPaused,   // called before each chunk to check pause
    bool Function()? isCancelled,
  }) async {
    onStatus('Getting access token...');
    final token  = await _getToken();

    onStatus('Preparing OneDrive folder...');
    final rootId = await _getRootFolderId(token, rootFolder);
    final dateId = await _ensureFolder(token, rootId, dateFolder);
    final userId = await _ensureFolder(token, dateId, userFolder);

    final file     = File(filePath);
    final fileSize = await file.length();

    onStatus('Creating upload session...');
    print('=== OneDrive direct upload: $fileName (${(fileSize/1024/1024).toStringAsFixed(1)}MB)');

    // Create upload session
    final sessionRes = await _dio.post(
      '$_graphBase/items/$userId:/${Uri.encodeComponent(fileName)}:/createUploadSession',
      data: {'item': {'@microsoft.graph.conflictBehavior': 'replace', 'name': fileName}},
      options: Options(headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json'}));
    final uploadUrl = sessionRes.data['uploadUrl'] as String;

    // Stream upload in 10MB chunks directly from phone storage
    int    offset     = 0;
    int    chunkNum   = 0;
    final  totalChunks = (fileSize / _graphChunk).ceil();

    while (offset < fileSize) {
      // ── Pause check — waits here until resumed ───────────────────────────
      while (isPaused != null && isPaused()) {
        if (isCancelled != null && isCancelled()) return;
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (isCancelled != null && isCancelled()) return;

      final end       = (offset + _graphChunk).clamp(0, fileSize);
      final chunkSize = end - offset;
      chunkNum++;

      // Read only this slice from disk — peak RAM = 10MB
      final chunk = await _readChunk(filePath, offset, chunkSize);

      // Retry each slice up to 3 times
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          await _dio.put(uploadUrl, data: Stream.fromIterable([chunk]),
            options: Options(
              headers: {
                'Content-Range':  'bytes $offset-${end - 1}/$fileSize',
                'Content-Length': '$chunkSize',
                'Content-Type':   'application/octet-stream',
              },
              receiveTimeout: const Duration(minutes: 5),
              sendTimeout:    const Duration(minutes: 5),
            ));
          break;
        } catch (e) {
          if (attempt == 3) rethrow;
          await Future.delayed(Duration(seconds: attempt * 3));
        }
      }

      offset = end;
      final pct = offset / fileSize;
      onProgress(pct);
      if (chunkNum % 3 == 0 || pct >= 1.0) {
        onStatus('Uploading... ${(pct * 100).toStringAsFixed(0)}%');
      }
    }

    print('=== OneDrive: upload complete — $fileName');
  }

  Future<List<int>> _readChunk(String filePath, int start, int length) async {
    final raf   = await File(filePath).open();
    await raf.setPosition(start);
    final bytes = await raf.read(length);
    await raf.close();
    return bytes;
  }
}