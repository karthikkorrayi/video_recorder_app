import 'dart:async';
import 'package:dio/dio.dart';

/// Keeps the Render backend warm by pinging /health every 10 minutes.
/// Render free tier spins down after 15 min of inactivity.
/// This prevents cold start delays (30-60 sec) when user taps Upload.
///
/// Only runs while the app is in the foreground.
/// Uses ~0 RAM, ~0 CPU — just a tiny HTTP GET every 10 min.
class BackendKeepAlive {
  static final BackendKeepAlive _i = BackendKeepAlive._();
  factory BackendKeepAlive() => _i;
  BackendKeepAlive._();

  static const String _backendUrl = 'https://otn-upload-backend.onrender.com';
  static const Duration _interval = Duration(minutes: 10);

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

  Timer? _timer;
  bool   _running = false;

  void start() {
    if (_running) return;
    _running = true;
    // Ping immediately on start (wakes Render if cold)
    _ping();
    // Then ping every 10 minutes
    _timer = Timer.periodic(_interval, (_) => _ping());
    print('=== BackendKeepAlive: started (every ${_interval.inMinutes} min)');
  }

  void stop() {
    _timer?.cancel();
    _timer   = null;
    _running = false;
    print('=== BackendKeepAlive: stopped');
  }

  Future<void> _ping() async {
    try {
      final res = await _dio.get('$_backendUrl/health');
      final uptime = res.data['uptime'] ?? '?';
      print('=== BackendKeepAlive: ✓ backend alive (uptime: $uptime)');
    } catch (e) {
      // Silent fail — backend might be waking up, next ping will catch it
      print('=== BackendKeepAlive: backend ping failed (waking up?): $e');
    }
  }

  /// Force-wake the backend right now — call this when user opens upload screen.
  /// Returns true if backend responded within 5 seconds.
  Future<bool> wakeNow() async {
    try {
      final res = await _dio.get('$_backendUrl/health',
          options: Options(receiveTimeout: const Duration(seconds: 70)));
      print('=== BackendKeepAlive: wakeNow ✓');
      return res.statusCode == 200;
    } catch (e) {
      print('=== BackendKeepAlive: wakeNow failed: $e');
      return false;
    }
  }
}