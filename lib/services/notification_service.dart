import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;

/// Bridges incoming Supabase Realtime messages to Android system
/// notifications, and routes a notification tap back to the right chat.
///
/// We use `awesome_notifications` rather than `flutter_local_notifications`
/// because the latter depends on `timezone`, which has **no** release that
/// resolves on Dart 3.8 (0.9/0.10 cap at `<3.0.0`; 0.11 requires `^3.10.0`),
/// and this project is pinned to Flutter 3.32.4 (Dart 3.8.1).
class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  // NOTE: these are `final`, not `const`. The NotificationChannel constructor
  // is not a const constructor, and the enum values are `NotificationImportance.Max`
  // and `NotificationCategory.Call` (capitalised).
  static final _messagesChannel = NotificationChannel(
    channelKey: 'messages',
    channelName: 'Messages',
    channelDescription: 'New chat messages',
    importance: NotificationImportance.High,
    defaultColor: const Color(0xFF3B5BFD),
    ledColor: const Color(0xFFFFFFFF),
    playSound: true,
    enableVibration: true,
    channelShowBadge: true,
  );

  static final _callsChannel = NotificationChannel(
    channelKey: 'calls',
    channelName: 'Calls',
    channelDescription: 'Incoming voice and video calls',
    importance: NotificationImportance.Max,
    defaultColor: const Color(0xFF00C853),
    playSound: true,
    // Without an explicit ringtone type, Android routes the notification
    // through the notification volume instead of the ringer, so an incoming
    // call is inaudible when the phone is on silent. Ringtone forces the
    // ringer stream, which is what an incoming call should use.
    defaultRingtoneType: DefaultRingtoneType.Ringtone,
    enableVibration: true,
    channelShowBadge: true,
  );

  /// Payload keys used to navigate when a notification is tapped.
  static const payloadConversationId = 'conversation_id';
  static const payloadName = 'name';
  static const payloadBody = 'body';
  static const payloadType = 'type';

  bool _initialised = false;

  /// The conversation currently on screen. Messages arriving for it are
  /// already visible, so we don't raise a notification for them.
  static String? activeConversationId;

  Future<bool> init() async {
    if (_initialised) return true;
    try {
      // The default icon MUST be a native Android drawable and MUST carry the
      // `resource://` prefix. A bare name like 'ic_launcher' trips an
      // assertion inside the plugin, and `ic_launcher` is a *mipmap* so it
      // would not resolve anyway. See
      // android/app/src/main/res/drawable/ic_notification.xml
      AwesomeNotifications().initialize(
        'resource://drawable/ic_notification',
        [_messagesChannel, _callsChannel],
        // Channel groups
        channelGroups: [
          NotificationChannelGroup(
            channelGroupKey: 'messages',
            channelGroupName: 'Messages',
          ),
          NotificationChannelGroup(
            channelGroupKey: 'calls',
            channelGroupName: 'Calls',
          ),
        ],
        debug: kDebugMode,
      );
      AwesomeNotifications().setListeners(
        onActionReceivedMethod: onActionReceived,
      );
      _initialised = true;
      debugPrint('Notification service initialized successfully');
      return true;
    } catch (e, st) {
      // Notifications are a nice-to-have. A failure here must never stop the
      // app from starting, so we log and carry on without them.
      debugPrint('Notification init failed: $e\n$st');
      return false;
    }
  }

  /// Check if notifications are allowed by the OS.
  Future<bool> notificationsAllowed() async {
    try {
      return await AwesomeNotifications().isNotificationAllowed();
    } catch (_) {
      return false;
    }
  }

  /// Request notification permission from the user.
  Future<bool> requestPermission() async {
    try {
      final allowed = await AwesomeNotifications().requestPermissionToSendNotifications();
      debugPrint('Notification permission requested: $allowed');
      return allowed;
    } catch (_) {
      return false;
    }
  }

  /// Shows a diagnostic notification so the notification layer can be tested
  /// independently of realtime delivery.
  Future<bool> showTestNotification() async {
    if (!_initialised && !await init()) return false;
    try {
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: DateTime.now().millisecondsSinceEpoch.remainder(2000000000),
          channelKey: 'messages',
          title: 'Connect',
          body: 'Notifications are working.',
          payload: {
            payloadConversationId: 'test',
            payloadName: 'Connect',
            payloadType: 'test',
          },
        ),
      );
      return true;
    } catch (e) {
      debugPrint('Test notification failed: $e');
      return false;
    }
  }

  /// Shows a notification for an incoming message.
  Future<void> showMessage({
    required String conversationId,
    required String title,
    required String body,
    required int messageId,
    String? senderId,
  }) async {
    if (activeConversationId == conversationId) return;

    // NOTE: do not gate on notificationsAllowed() here.
    //
    // `isNotificationAllowed()` is an optimistic reading of the OS permission
    // cache and returns false on several OEM builds (including stock Motorola)
    // even when posting works perfectly. Gating on it meant every real message
    // was dropped with "Notifications not allowed" while the Settings test
    // button — which does not consult it — kept working. Posting and catching
    // the failure is both simpler and correct: if the OS really refuses, the
    // catch below logs it.
    try {
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: messageId,
          channelKey: 'messages',
          title: title,
          body: body,
          payload: {
            payloadConversationId: conversationId,
            payloadName: title,
            payloadBody: body,
            payloadType: 'message',
          },
        ),
      );
      debugPrint('Message notification posted: $title');
    } catch (e) {
      debugPrint('showMessage failed: $e');
    }
  }

  /// A fixed id for the incoming-call notification, so it can be withdrawn
  /// deterministically when the call is answered or declined. A
  /// millisecond-timestamp id could never be matched up afterwards.
  static const incomingCallNotificationId = 7001;

  Future<void> showIncomingCall({
    required String conversationId,
    required String name,
    required bool isVideo,
  }) async {
    if (!_initialised && !await init()) return;

    try {
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: incomingCallNotificationId,
          channelKey: 'calls',
          title: isVideo ? 'Incoming video call' : 'Incoming voice call',
          body: name,
          category: NotificationCategory.Call,
          // Required for the notification to be able to take over the screen
          // and ring at ringer volume. The manifest must also declare
          // USE_FULL_SCREEN_INTENT, or Android 14+ silently drops this.
          fullScreenIntent: true,
          // Sound is a property of the CHANNEL, not of individual
          // notifications: `_callsChannel` sets playSound + a Ringtone
          // defaultRingtoneType, which is what routes it to the ringer.
          payload: {
            payloadConversationId: conversationId,
            payloadName: name,
            payloadType: isVideo ? 'video_call' : 'voice_call',
          },
        ),
      );
      debugPrint('Incoming call notification posted for $name');
    } catch (e) {
      debugPrint('showIncomingCall failed: $e');
    }
  }

  /// Withdraws the incoming-call notification.
  Future<void> cancelCallNotification() async {
    try {
      await AwesomeNotifications().cancel(incomingCallNotificationId);
    } catch (e) {
      debugPrint('cancelCallNotification failed: $e');
    }
  }

  /// Fired when the user taps the notification, once the UI is running.
  static void Function(Map<String, String?> payload)? onOpenConversation;

  @pragma('vm:entry-point')
  static Future<void> onActionReceived(ReceivedAction action) async {
    // This runs in a background isolate without a navigator, so we stash the
    // payload and let main.dart pick it up once the UI exists.
    final payload = action.payload;
    if (payload == null || payload.isEmpty) return;
    PendingNotificationPayload.payload = Map<String, String?>.from(payload);
  }
}

/// Holds a notification payload that arrived before the UI existed.
class PendingNotificationPayload {
  static Map<String, String?>? payload;

  static Map<String, String?>? take() {
    final p = payload;
    payload = null;
    return p;
  }
}