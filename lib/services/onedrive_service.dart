import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Uploads files directly from phone to cloud storage using Microsoft Graph API.
/// Backend only needed for token refresh — no file data passes through it.
class OneDriveService {
  static const String _backendUrl = 'https://video-recorder-app-d7zk.onrender.com';
  static const String _graphBase  = 'https://graph.microsoft.com/v1.0/me/drive';

  // Adaptive chunk sizing: 20MB–40MB based on measured network speed
  static const int _minChunk  = 20 * 1024 * 1024;
  static const int _maxChunk  = 40 * 1024 * 1024;
  static const int _chunkStep =       320 * 1024; // Graph API requires 320KB multiples
  int _currentChunk = _minChunk;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 10),
    sendTimeout:    const Duration(minutes: 10),
  ));

  String?   _accessToken;
  DateTime? _tokenExpiry;

  // ── Adaptive chunk sizing ─────────────────────────────────────────────────
  void _adaptChunkSize(double bytesPerSec) {
    final mbps = bytesPerSec / 1024 / 1024;
    int target;
    if (mbps >= 10) {
      target = _maxChunk;
    } else if (mbps >= 5) {
      target = 30 * 1024 * 1024;
    } else {
      target = _minChunk;
    }
    target = ((target / _chunkStep).round() * _chunkStep).clamp(_minChunk, _maxChunk);
    if (target != _currentChunk) {
      _currentChunk = target;
      debugPrint('=== Adaptive: ${mbps.toStringAsFixed(1)} Mbps → ${(_currentChunk~/1024~/1024)}MB');
    }
  }

  // ── Token ─────────────────────────────────────────────────────────────────
  Future<String> _getToken() async {
    if (_accessToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!.subtract(const Duration(minutes: 2)))) {
      return _accessToken!;
    }
    final res = await _dio.get(
      '$_backendUrl/token',
      options: Options(
        receiveTimeout: const Duration(seconds: 75),
        validateStatus: (s) => s != null && s < 600,
      ),
    );
    if (res.statusCode != 200) {
      throw Exception('Token failed: ${res.statusCode} — push new server.js to Render');
    }
    _accessToken = res.data['access_token'] as String;
    final expiresIn = res.data['expires_in'] as int? ?? 3600;
    _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
    debugPrint('=== Token refreshed');
    return _accessToken!;
  }

  // ── Folder helpers — fixed to avoid duplicate folders ─────────────────────
  // Uses conflictBehavior:fail + catches 409 instead of $filter query.
  // $filter had eventual consistency issues causing duplicate folder creation
  // when multiple users upload simultaneously.
  Future<String> _getOrCreateFolder(String token, String parentId, String name) async {
    // First try to find existing folder by listing children
    try {
      final r = await _dio.get(
        '$_graphBase/items/$parentId/children?\$select=id,name&\$top=200',
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          validateStatus: (s) => s != null && s < 600,
        ),
      );
      if (r.statusCode == 200) {
        final items = r.data['value'] as List? ?? [];
        for (final item in items) {
          if ((item['name'] as String?)?.toLowerCase() == name.toLowerCase()) {
            return item['id'] as String;
          }
        }
      }
    } catch (_) {}

    // Not found — create it
    try {
      final r = await _dio.post(
        '$_graphBase/items/$parentId/children',
        data: {
          'name':   name,
          'folder': {},
          '@microsoft.graph.conflictBehavior': 'fail', // fail if exists → catch 409
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type':  'application/json',
          },
          validateStatus: (s) => s != null && s < 600,
        ),
      );
      if (r.statusCode == 201) return r.data['id'] as String;

      // 409 conflict = folder was created by another request simultaneously
      if (r.statusCode == 409) {
        // Re-fetch to get the ID
        final r2 = await _dio.get(
          '$_graphBase/items/$parentId/children?\$select=id,name&\$top=200',
          options: Options(
            headers: {'Authorization': 'Bearer $token'},
            validateStatus: (s) => s != null && s < 600,
          ),
        );
        final items = r2.data['value'] as List? ?? [];
        for (final item in items) {
          if ((item['name'] as String?)?.toLowerCase() == name.toLowerCase()) {
            return item['id'] as String;
          }
        }
      }
      throw Exception('Could not get/create folder "$name": ${r.statusCode}');
    } catch (e) {
      throw Exception('Folder error "$name": $e');
    }
  }

  Future<String> _getRootFolderId(String token, String rootName) async {
    // Get root's ID first, then use _getOrCreateFolder
    final rootRes = await _dio.get(
      '$_graphBase/root?\$select=id',
      options: Options(
        headers: {'Authorization': 'Bearer $token'},
        validateStatus: (s) => s != null && s < 600,
      ),
    );
    final rootId = rootRes.data['id'] as String;
    return _getOrCreateFolder(token, rootId, rootName);
  }

  // ── Upload single file ────────────────────────────────────────────────────
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
    final token = await _getToken();

    // Build folder structure — no duplicate folders
    onStatus('Preparing cloud folder...');
    final otnId  = await _getRootFolderId(token, rootFolder);
    final dateId = await _getOrCreateFolder(token, otnId,  dateFolder);
    final userId = await _getOrCreateFolder(token, dateId, userFolder);

    final fileSize = await File(filePath).length();
    final fileSizeMB = (fileSize / 1024 / 1024).toStringAsFixed(1);
    debugPrint('=== Uploading: $fileName ($fileSizeMB MB)');

    // Create upload session — valid for 24h, renewed automatically if expired
    onStatus('Starting upload ($fileSizeMB MB)...');
    String uploadUrl = await _createUploadSession(token, userId, fileName);

    _currentChunk = _minChunk;
    int offset   = 0;
    int chunkNum = 0;
    final sessionCreated = DateTime.now();

    while (offset < fileSize) {
      // Pause/cancel
      while (isPaused != null && isPaused()) {
        if (isCancelled != null && isCancelled()) return;
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (isCancelled != null && isCancelled()) return;

      // Renew upload session if it's been open >20 minutes
      // Graph API sessions expire after 24h but connections can drop
      if (DateTime.now().difference(sessionCreated).inMinutes > 20 && offset > 0) {
        debugPrint('=== Renewing upload session...');
        try {
          uploadUrl = await _createUploadSession(token, userId, fileName);
        } catch (_) {
          // If renewal fails, continue with existing URL
        }
      }

      final end       = (offset + _currentChunk).clamp(0, fileSize);
      final chunkSize = end - offset;
      chunkNum++;

      final chunk      = await _readChunk(filePath, offset, chunkSize);
      final sliceStart = DateTime.now();

      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          final res = await _dio.put(
            uploadUrl,
            data: chunk,
            options: Options(
              headers: {
                'Content-Range':  'bytes $offset-${end - 1}/$fileSize',
                'Content-Length': '$chunkSize',
                'Content-Type':   'application/octet-stream',
              },
              receiveTimeout: const Duration(minutes: 8),
              sendTimeout:    const Duration(minutes: 8),
              validateStatus: (s) =>
                  s != null && (s == 200 || s == 201 || s == 202 || s == 308),
            ),
          );

          // Measure speed and adapt
          final elapsedMs = DateTime.now().difference(sliceStart).inMilliseconds;
          if (elapsedMs > 0) {
            _adaptChunkSize(chunkSize / (elapsedMs / 1000));
          }
          debugPrint('=== Slice $chunkNum → ${res.statusCode} | '
              '${(chunkSize~/1024~/1024)}MB in ${elapsedMs}ms');
          break;
        } catch (e) {
          debugPrint('=== Slice $chunkNum attempt $attempt: $e');
          if (attempt == 3) rethrow;
          _currentChunk = _minChunk; // back to safe size on retry
          await Future.delayed(Duration(seconds: attempt * 5));
        }
      }

      offset = end;
      final pct = offset / fileSize;
      onProgress(pct);
      onStatus(
        'Uploading ${(pct * 100).toStringAsFixed(0)}%'
        ' · ${(_currentChunk ~/ 1024 ~/ 1024)}MB slices',
      );
    }

    debugPrint('=== Upload complete: $fileName');
  }

  Future<String> _createUploadSession(
      String token, String parentId, String fileName) async {
    final res = await _dio.post(
      '$_graphBase/items/$parentId:/${Uri.encodeComponent(fileName)}:/createUploadSession',
      data: {'item': {'@microsoft.graph.conflictBehavior': 'replace', 'name': fileName}},
      options: Options(
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type':  'application/json',
        },
        validateStatus: (s) => s != null && s < 600,
      ),
    );
    if (res.statusCode != 200) {
      throw Exception('Upload session failed: ${res.statusCode} ${res.data}');
    }
    return res.data['uploadUrl'] as String;
  }

  Future<Uint8List> _readChunk(String filePath, int start, int length) async {
    final raf   = await File(filePath).open();
    await raf.setPosition(start);
    final bytes = await raf.read(length);
    await raf.close();
    return Uint8List.fromList(bytes);
  }
}