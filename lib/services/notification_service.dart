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
      onDidReceiveNotificationResponse: (details) {
        // Q3: tapping failure notification → open history
        if (details.payload == 'history' || details.actionId == 'retry') {
          _onFailureTap?.call();
        }
      },
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
      description: 'Shows upload progress to Cloud Storage',
      importance: Importance.low,
    );
    await androidPlugin?.createNotificationChannel(channel);

    // High importance channel for failures
    const failChannel = AndroidNotificationChannel(
      'otn_upload_fail',
      'OTN Upload Failures',
      description: 'Alerts when a video chunk fails to upload',
      importance: Importance.high,
    );
    await androidPlugin?.createNotificationChannel(failChannel);

    _initialized = true;
  }

  /// Call this from main.dart to wire notification tap → navigate to history.
  /// Pass a callback that navigates to HistoryScreen.
  void setOnFailureTap(void Function() callback) {
    _onFailureTap = callback;
  }
  void Function()? _onFailureTap;

  Future<void> showUploadProgress({
    required int block,
    required int total,
    required int percentDone,
  }) async {
    if (!_initialized) return;
    await _plugin.show(
      _uploadChannelId,
      'Uploading to Cloud Storage',
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
      'Video synced to Cloud Storage ($totalParts part${totalParts != 1 ? 's' : ''} merged)',
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
    await _plugin.show(
      _uploadChannelId + 2,
      'OTN Upload Failed ✕',
      reason,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'otn_upload_fail', 'OTN Upload Failures',
          channelDescription: 'Alerts when video upload fails',
          importance: Importance.high,
          priority: Priority.high,
          // Action button: tap notification body → open history
          actions: const [
            AndroidNotificationAction(
              'retry', 'Open History',
              showsUserInterface: true,
            ),
          ],
        ),
      ),
      payload: 'history', // used by tap handler to route
    );
  }

  Future<void> cancelUploadNotification() async {
    await _plugin.cancel(_uploadChannelId);
  }
}