import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Simple notification service for upload progress.
/// Shows a progress notification while uploading, updates it block by block,
/// and shows a completion/failure notification when done.
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

    // Create the Android notification channel
    const channel = AndroidNotificationChannel(
      'otn_upload',
      _channelName,
      description: 'Shows upload progress to OneDrive',
      importance: Importance.low, // low = no sound, no popup
    );

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(channel);

    _initialized = true;
  }

  /// Show or update upload progress notification.
  /// [block] and [total] are 1-based.
  Future<void> showUploadProgress({
    required int block,
    required int total,
    required int percentDone,
  }) async {
    if (!_initialized) return;
    await _plugin.show(
      _uploadChannelId,
      'Uploading to OneDrive',
      'Block $block of $total — $percentDone%',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'otn_upload', _channelName,
          channelDescription: 'Upload progress',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,          // can't be dismissed while uploading
          showProgress: true,
          maxProgress: 100,
          progress: percentDone,
          onlyAlertOnce: true,    // don't vibrate on every update
        ),
      ),
    );
  }

  /// Show upload complete notification.
  Future<void> showUploadComplete(int totalBlocks) async {
    if (!_initialized) return;
    await _plugin.cancel(_uploadChannelId); // remove progress notification
    await _plugin.show(
      _uploadChannelId + 1,
      'Upload Complete ✓',
      '$totalBlocks block${totalBlocks != 1 ? 's' : ''} synced to OneDrive',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'otn_upload', _channelName,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
      ),
    );
  }

  /// Show upload failed notification.
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

  /// Cancel the upload progress notification (e.g. when user cancels).
  Future<void> cancelUploadNotification() async {
    await _plugin.cancel(_uploadChannelId);
  }
}