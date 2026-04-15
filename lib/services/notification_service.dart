import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService _i = NotificationService._();
  factory NotificationService() => _i;
  NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const int _uploadChannelId = 1;
  static const String _channelName  = 'OTN Upload';

  Future<void> init() async {
    if (_initialized) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios     = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: false,
    );

    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    // ── Request notification permission (Android 13+ requires this) ──────
    // This shows the system dialog asking user to allow notifications.
    // Without this, notifications are silently dropped on Android 13+.
    await androidPlugin?.requestNotificationsPermission();

    // Create notification channel
    const channel = AndroidNotificationChannel(
      'otn_upload',
      _channelName,
      description: 'Shows upload progress to OneDrive',
      importance: Importance.low,
    );
    await androidPlugin?.createNotificationChannel(channel);

    _initialized = true;
  }

  Future<void> showUploadProgress({
    required int block,
    required int total,
    required int percentDone,
  }) async {
    if (!_initialized) return;
    await _plugin.show(
      _uploadChannelId,
      'Uploading to OneDrive',
      'Part $block of $total — $percentDone%',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'otn_upload', _channelName,
          channelDescription: 'Upload progress',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          showProgress: true,
          maxProgress: 100,
          progress: percentDone,
          onlyAlertOnce: true,
        ),
      ),
    );
  }

  Future<void> showUploadComplete(int totalParts) async {
    if (!_initialized) return;
    await _plugin.cancel(_uploadChannelId);
    await _plugin.show(
      _uploadChannelId + 1,
      'Upload Complete ✓',
      'Video synced to OneDrive ($totalParts part${totalParts != 1 ? 's' : ''} merged)',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'otn_upload', _channelName,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
      ),
    );
  }

  Future<void> showUploadFailed(String reason) async {
    if (!_initialized) return;
    await _plugin.cancel(_uploadChannelId);
    await _plugin.show(
      _uploadChannelId + 2,
      'Upload Failed',
      reason,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'otn_upload', _channelName,
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }

  Future<void> cancelUploadNotification() async {
    await _plugin.cancel(_uploadChannelId);
  }
}