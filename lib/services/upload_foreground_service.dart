import 'package:flutter/foundation.dart';

/// Flutter bridge to the Android UploadForegroundService.
/// Currently disabled while background service stability is being verified.
/// Upload continues normally — just without the persistent notification.
class UploadForegroundService {
  static Future<void> start({
    required String progressText,
    required String chunksText,
  }) async {
    debugPrint('=== ForegroundService: start (disabled) — $progressText');
  }

  static Future<void> update({
    required String progressText,
    required String chunksText,
  }) async {
    // No-op while disabled
  }

  static Future<void> stop() async {
    debugPrint('=== ForegroundService: stop (disabled)');
  }
}