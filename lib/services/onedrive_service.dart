import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Uploads files directly from phone to cloud storage using Microsoft Graph API.
/// Backend only needed for token refresh — no file data passes through it.
///
/// Adaptive chunk sizing: measures real upload speed per slice and adjusts
/// between 20MB (slow network) and 40MB (fast network) for next slice.
/// Peak phone RAM = current chunk size (20–40MB) regardless of file size.
class OneDriveService {
  static const String _backendUrl = 'https://video-recorder-app-d7zk.onrender.com';
  static const String _graphBase  = 'https://graph.microsoft.com/v1.0/me/drive';

  // Adaptive chunk range — Graph API requires multiples of 320KB
  static const int _minChunk  = 20 * 1024 * 1024; // 20MB — slow network
  static const int _maxChunk  = 40 * 1024 * 1024; // 40MB — fast network
  static const int _chunkStep = 320 * 1024;        // 320KB step

  // Current chunk size — resets to min at start of each upload, adapts per slice
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
      target = _maxChunk;            // fast  → 40MB
    } else if (mbps >= 5) {
      target = 30 * 1024 * 1024;    // medium→ 30MB
    } else {
      target = _minChunk;            // slow  → 20MB
    }
    // Snap to nearest 320KB multiple and clamp to range
    target = ((target / _chunkStep).round() * _chunkStep).clamp(_minChunk, _maxChunk);
    if (target != _currentChunk) {
      _currentChunk = target;
      debugPrint('=== Adaptive: ${mbps.toStringAsFixed(1)} Mbps → ${(_currentChunk / 1024 / 1024).toStringAsFixed(0)}MB slices');
    }
  }

  // ── Token ─────────────────────────────────────────────────────────────────
  Future<String> _getToken() async {
    if (_accessToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!.subtract(const Duration(minutes: 2)))) {
      return _accessToken!;
    }
    debugPrint('=== Getting token from backend...');
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
    debugPrint('=== Token refreshed OK');
    return _accessToken!;
  }

  // ── Folder helpers ────────────────────────────────────────────────────────
  Future<String> _ensureFolder(String token, String parentId, String name) async {
    try {
      final r = await _dio.get(
        '$_graphBase/items/$parentId/children'
        '?\$filter=name eq \'${Uri.encodeComponent(name)}\'&\$select=id',
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          validateStatus: (s) => s != null && s < 600,
        ),
      );
      final items = r.data['value'] as List?;
      if (items != null && items.isNotEmpty) return items[0]['id'] as String;
    } catch (_) {}
    final r = await _dio.post(
      '$_graphBase/items/$parentId/children',
      data: {'name': name, 'folder': {}, '@microsoft.graph.conflictBehavior': 'rename'},
      options: Options(headers: {
        'Authorization': 'Bearer $token',
        'Content-Type':  'application/json',
      }),
    );
    return r.data['id'] as String;
  }

  Future<String> _getRootFolderId(String token, String rootName) async {
    try {
      final r = await _dio.get(
        '$_graphBase/root/children'
        '?\$filter=name eq \'${Uri.encodeComponent(rootName)}\'&\$select=id',
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          validateStatus: (s) => s != null && s < 600,
        ),
      );
      final items = r.data['value'] as List?;
      if (items != null && items.isNotEmpty) return items[0]['id'] as String;
    } catch (_) {}
    final r = await _dio.post(
      '$_graphBase/root/children',
      data: {'name': rootName, 'folder': {}, '@microsoft.graph.conflictBehavior': 'rename'},
      options: Options(headers: {
        'Authorization': 'Bearer $token',
        'Content-Type':  'application/json',
      }),
    );
    return r.data['id'] as String;
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
    final token  = await _getToken();

    onStatus('Preparing cloud folder...');
    final rootId = await _getRootFolderId(token, rootFolder);
    final dateId = await _ensureFolder(token, rootId, dateFolder);
    final userId = await _ensureFolder(token, dateId, userFolder);

    final fileSize = await File(filePath).length();
    debugPrint('=== Uploading: $fileName (${(fileSize / 1024 / 1024).toStringAsFixed(1)}MB)');

    // Step 1: Create upload session
    onStatus('Creating upload session...');
    final sessionRes = await _dio.post(
      '$_graphBase/items/$userId:/${Uri.encodeComponent(fileName)}:/createUploadSession',
      data: {'item': {'@microsoft.graph.conflictBehavior': 'replace', 'name': fileName}},
      options: Options(
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type':  'application/json',
        },
        validateStatus: (s) => s != null && s < 600,
      ),
    );
    if (sessionRes.statusCode != 200) {
      throw Exception('Failed to create upload session: ${sessionRes.statusCode}');
    }
    final uploadUrl = sessionRes.data['uploadUrl'] as String;

    // Step 2: Upload with adaptive chunk sizing
    _currentChunk = _minChunk; // reset to 20MB at start
    int offset   = 0;
    int chunkNum = 0;

    while (offset < fileSize) {
      // Pause/cancel check
      while (isPaused != null && isPaused()) {
        if (isCancelled != null && isCancelled()) return;
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (isCancelled != null && isCancelled()) return;

      final end       = (offset + _currentChunk).clamp(0, fileSize);
      final chunkSize = end - offset;
      chunkNum++;

      // Read slice from disk — peak RAM = _currentChunk (20–40MB)
      final chunk = await _readChunk(filePath, offset, chunkSize);

      final sliceStart = DateTime.now();

      // Retry each slice up to 3 times
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          final res = await _dio.put(
            uploadUrl,
            data: chunk, // raw Uint8List — Dio sends with correct Content-Length
            options: Options(
              headers: {
                'Content-Range':  'bytes $offset-${end - 1}/$fileSize',
                'Content-Length': '$chunkSize',
                'Content-Type':   'application/octet-stream',
              },
              receiveTimeout: const Duration(minutes: 5),
              sendTimeout:    const Duration(minutes: 5),
              // 200/308 = intermediate chunk OK
              // 201/202 = final chunk — file created in cloud
              validateStatus: (s) =>
                  s != null && (s == 200 || s == 201 || s == 202 || s == 308),
            ),
          );

          // Measure speed → adapt chunk size for next slice
          final elapsedMs = DateTime.now().difference(sliceStart).inMilliseconds;
          if (elapsedMs > 0) {
            final bytesPerSec = chunkSize / (elapsedMs / 1000);
            _adaptChunkSize(bytesPerSec);
          }

          final mbps = (chunkSize / 1024 / 1024 / (elapsedMs / 1000)).toStringAsFixed(1);
          debugPrint('=== Slice $chunkNum → ${res.statusCode} | '
              '${(chunkSize / 1024 / 1024).toStringAsFixed(0)}MB '
              'in ${elapsedMs}ms ($mbps Mbps) | '
              'next: ${(_currentChunk / 1024 / 1024).toStringAsFixed(0)}MB');
          break;
        } catch (e) {
          debugPrint('=== Slice $chunkNum attempt $attempt failed: $e');
          if (attempt == 3) rethrow;
          // On retry: drop back to minimum (network may be unstable)
          _currentChunk = _minChunk;
          await Future.delayed(Duration(seconds: attempt * 3));
        }
      }

      offset = end;
      final pct = offset / fileSize;
      onProgress(pct);
      onStatus('Uploading... ${(pct * 100).toStringAsFixed(0)}%'
          ' · ${(_currentChunk / 1024 / 1024).toStringAsFixed(0)}MB slices');
    }

    debugPrint('=== Upload complete: $fileName');
  }

  // Read a slice of a file into memory (peak RAM = slice size)
  Future<Uint8List> _readChunk(String filePath, int start, int length) async {
    final raf   = await File(filePath).open();
    await raf.setPosition(start);
    final bytes = await raf.read(length);
    await raf.close();
    return Uint8List.fromList(bytes);
  }
}