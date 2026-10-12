import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/supabase_client.dart';
import 'notification_service.dart';

/// Handles Firebase Cloud Messaging (FCM) for push notifications.
///
/// This service:
/// - Initializes Firebase Messaging
/// - Requests notification permissions
/// - Handles foreground/background/terminated messages
/// - Manages FCM token registration with Supabase
/// - Integrates with existing NotificationService for local notifications
class FirebaseMessagingService {
  FirebaseMessagingService._();
  static final FirebaseMessagingService instance = FirebaseMessagingService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  String? _fcmToken;
  StreamSubscription<RemoteMessage>? _messageSubscription;
  StreamSubscription<RemoteMessage>? _initialMessageSubscription;

  /// Initializes FCM and sets up message handlers.
  ///
  /// Must be called after Firebase.initializeApp() and after the user
  /// has granted notification permissions.
  Future<void> initialize() async {
    if (kIsWeb) return; // Web handled separately

    // Request permissions
    await _requestPermissions();

    // Get FCM token
    await _refreshToken();

    // Handle foreground messages
    _messageSubscription = FirebaseMessaging.onMessage.listen(_handleMessage);

    // Handle background messages (app in background but not terminated)
    _initialMessageSubscription =
        FirebaseMessaging.onMessageOpenedApp.listen(_handleOpenedApp);

    // Handle terminated state messages (app was killed)
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      _handleOpenedApp(initialMessage);
    }

    // Listen for token refresh
    _messaging.onTokenRefresh.listen(_onTokenRefresh);

    debugPrint('FCM initialized successfully');
  }

  /// Alias for initialize() to match the expected API in main.dart
  Future<void> start(String userId) async {
    return initialize();
  }

  /// Requests notification permissions from the user.
  Future<void> _requestPermissions() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    );

    debugPrint('FCM permission status: ${settings.authorizationStatus}');

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      debugPrint('FCM permission denied by user');
    }
  }

  /// Gets the current FCM token and stores it.
  Future<String?> _refreshToken() async {
    try {
      final token = await _messaging.getToken();
      if (token != null && token != _fcmToken) {
        _fcmToken = token;
        debugPrint('FCM Token: $token');
        await _saveTokenToSupabase(token);
      }
      return _fcmToken;
    } catch (e) {
      debugPrint('Failed to get FCM token: $e');
      return null;
    }
  }

  /// Saves the FCM token to the user's profile in Supabase.
  ///
  /// This MUST actually persist. It is the entire link between the device and
  /// the server-side push sender: with nothing stored, a backend has no
  /// address to deliver to, and push silently can never work no matter how
  /// correct the rest of the code is.
  ///
  /// Requires `supabase/fcm.sql` to have added the `fcm_token` column. If the
  /// column is missing this logs and gives up rather than throwing, so an
  /// un-migrated database does not break app startup.
  Future<void> _saveTokenToSupabase(String token) async {
    try {
      final uid = supabase.auth.currentUser?.id;
      if (uid == null) {
        debugPrint('FCM token not saved: no signed-in user');
        return;
      }
      await supabase
          .from('profiles')
          .update({'fcm_token': token}).eq('id', uid);
      debugPrint('FCM token saved to profiles.fcm_token for $uid');
    } catch (e) {
      debugPrint('Failed to save FCM token to Supabase: $e '
          '(has supabase/fcm.sql been run?)');
    }
  }

  /// Handles token refresh from FCM.
  void _onTokenRefresh(String newToken) {
    _fcmToken = newToken;
    debugPrint('FCM Token refreshed: $newToken');
    _saveTokenToSupabase(newToken);
  }

  /// Handles a message when the app is in the foreground.
  void _handleMessage(RemoteMessage message) {
    debugPrint('FCM foreground message: ${message.messageId}');
    _showLocalNotification(message);
  }

  /// Handles a message when the app is opened from a notification.
  void _handleOpenedApp(RemoteMessage message) {
    debugPrint('FCM opened app from message: ${message.messageId}');
    final data = message.data;
    if (data.isNotEmpty) {
      final payload = Map<String, String?>.from(
        data.map((key, value) => MapEntry(key.toString(), value?.toString())),
      );
      final callback = NotificationService.onOpenConversation;
      if (callback != null) {
        callback(payload);
      } else {
        PendingNotificationPayload.payload = payload;
      }
    }
  }

  /// Sends a push notification via the `send-push` Supabase Edge Function.
  static Future<void> sendPushNotification({
    required String recipientUserId,
    required String title,
    required String body,
    Map<String, String>? data,
  }) async {
    try {
      final res = await supabase.functions.invoke(
        'send-push',
        body: {
          'user_id': recipientUserId,
          'title': title,
          'body': body,
          'data': data ?? {},
        },
      );
      debugPrint('send-push response status: ${res.status}');
    } catch (e) {
      debugPrint('Failed to send push notification: $e');
    }
  }

  /// Shows a local notification using the existing NotificationService.
  void _showLocalNotification(RemoteMessage message) {
    final notification = message.notification;
    final data = message.data;

    if (notification == null) return;

    final conversationId = data['conversation_id'] ?? data['conversationId'];
    final senderId = data['sender_id'] ?? data['senderId'];
    final messageId = data['message_id'] ?? data['messageId'];

    if (conversationId != null) {
      NotificationService.instance.showMessage(
        conversationId: conversationId,
        title: notification.title ?? 'New message',
        body: notification.body ?? '',
        messageId: messageId?.hashCode ?? DateTime.now().millisecondsSinceEpoch,
        senderId: senderId,
      );
    }
  }

  /// Gets the current FCM token.
  String? get token => _fcmToken;

  /// Disposes resources.
  void dispose() {
    _messageSubscription?.cancel();
    _initialMessageSubscription?.cancel();
  }
}
