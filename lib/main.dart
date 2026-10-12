import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config.dart';
import 'core/supabase_client.dart';
import 'core/theme.dart';
import 'core/theme_controller.dart';
import 'firebase_options.dart';
import 'models/models.dart';
import 'screens/auth/auth_screen.dart';
import 'screens/chat/chat_screen.dart';
import 'screens/home/conversation_list_screen.dart';
import 'screens/home/pending_approval_screen.dart';
import 'services/call_manager.dart';
import 'services/chat_service.dart';
import 'services/firebase_messaging_service.dart';
import 'services/message_notification_listener.dart';
import 'services/notification_service.dart';

/// Background message handler for FCM (required for background/terminated messages).
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  debugPrint('Background FCM message: ${message.messageId}');
  // The message will be handled by the foreground handler when app resumes
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Initialize FCM background handler
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
  );

  final themeController = await ThemeController.load();

  // Notifications must be initialised before the first frame so a tap on a
  // notification that launched the app is not lost.
  await NotificationService.instance.init();

  runApp(ConnectApp(themeController: themeController));
}

class ConnectApp extends StatelessWidget {
  final ThemeController themeController;

  const ConnectApp({super.key, required this.themeController});

  @override
  Widget build(BuildContext context) {
    return ThemeScope(
      controller: themeController,
      child: AnimatedBuilder(
        animation: themeController,
        builder: (context, _) {
          return MaterialApp(
            title: 'Connect',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: themeController.mode,
            themeAnimationDuration: const Duration(milliseconds: 250),
            // Required by CallManager so an incoming call can be pushed on top
            // of whatever screen the user happens to be on.
            navigatorKey: callNavigatorKey,
            home: const _RootGate(),
          );
        },
      ),
    );
  }
}

/// Decides between the auth screen and the chat list, and bootstraps
/// per-session state (profile row, presence, call + notification listeners).
class _RootGate extends StatefulWidget {
  const _RootGate();

  @override
  State<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<_RootGate> with WidgetsBindingObserver {
  bool _bootstrapped = false;

  /// null = not checked yet, otherwise the error if the schema is missing.
  String? _schemaError;
  bool _checkingSchema = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.onOpenConversation = _openFromNotification;
    WidgetsBinding.instance.addPostFrameCallback((_) => _drainPendingPayload());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationService.onOpenConversation = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ChatService.instance.setOnline(true);
      // CallManager re-checks for calls that arrived while backgrounded.
      _drainPendingPayload();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      ChatService.instance.setOnline(false);
    }
  }

  void _drainPendingPayload() {
    final payload = PendingNotificationPayload.take();
    if (payload != null) _openFromNotification(payload);
  }

  void _openFromNotification(Map<String, String?> payload) {
    final convId = payload[NotificationService.payloadConversationId];
    if (convId is! String || convId.isEmpty) return;
    if (supabase.auth.currentSession == null) return;
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(conversationId: convId)),
    );
  }

  Future<void> _checkSchema() async {
    if (_schemaError != null || _checkingSchema) return;
    _checkingSchema = true;
    final error = await SchemaCheck.verify();
    if (!mounted) return;
    setState(() {
      _schemaError = error;
      _checkingSchema = false;
    });
  }

  Future<void> _bootstrap() async {
    if (_bootstrapped) return;
    _bootstrapped = true;
    final me = supabase.auth.currentUser?.id;
    if (me == null) return;

    try {
      await ChatService.instance.ensureMyProfile();
    } catch (e) {
      debugPrint('Profile bootstrap failed (has schema.sql been run?): $e');
    }

    // Notifications for messages in every conversation.
    try {
      await MessageNotificationListener.instance.start(me);
    } catch (e) {
      debugPrint('Notification listener failed: $e');
    }

    // Incoming calls. Without this the app is subscribed to nothing and no
    // call can ever arrive.
    try {
      await CallManager.instance.start(me);
    } catch (e) {
      debugPrint('Call manager failed to start: $e');
    }

    // Request notification permission and wait for it to complete.
    // This must complete before we try to show any notifications.
    try {
      final granted = await NotificationService.instance.requestPermission();
      if (!granted) {
        debugPrint('Notification permission denied by user');
      }
    } catch (e) {
      debugPrint('Failed to request notification permission: $e');
    }

    // Initialize FCM for push notifications
    try {
      await FirebaseMessagingService.instance.start(me);
    } catch (e) {
      debugPrint('FCM service failed to start: $e');
    }

    try {
      await ChatService.instance.setOnline(true);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: supabase.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = supabase.auth.currentSession;
        if (session == null) return const AuthScreen();
        // Fire-and-forget; failure here must not block the UI.
        _bootstrap();
        _checkSchema();

        // NOTE: deliberately NOT gating on _checkingSchema. Blocking the whole
        // app on a network probe is what made the app look frozen; the
        // conversation list has its own loading and error states.
        if (_schemaError != null) {
          return SchemaMissingScreen(detail: _schemaError!);
        }

        // Approval gate. Re-reads the profile so that flipping is_approved in
        // the admin screen moves the user through without a restart.
        return FutureBuilder<Profile?>(
          future: ChatService.instance.myProfile(),
          builder: (context, snapshot) {
            final profile = snapshot.data;
            if (profile != null && !profile.isApproved) {
              return PendingApprovalScreen(
                profileLoader: Future.value(profile),
              );
            }
            return const ConversationListScreen();
          },
        );
      },
    );
  }
}

/// Verifies the database has the schema this build expects.
///
/// This must never block the UI. It is bounded by [timeout] and only produces
/// a hard failure for a genuine schema error, not for a slow network.
class SchemaCheck {
  SchemaCheck._();

  static const timeout = Duration(seconds: 12);

  static Future<String?> verify() async {
    try {
      await supabase
          .from('conversations')
          .select('id')
          .limit(1)
          .timeout(timeout);
      await supabase
          .from('profiles')
          .select('username')
          .limit(1)
          .timeout(timeout);
      await supabase
          .from('messages')
          .select('media_url')
          .limit(1)
          .timeout(timeout);
      return null;
    } on TimeoutException {
      debugPrint('SchemaCheck: timed out, continuing anyway');
      return null;
    } catch (e) {
      return '$e';
    }
  }
}

/// Shown instead of the chat list when the database is not migrated.
class SchemaMissingScreen extends StatelessWidget {
  final String detail;

  const SchemaMissingScreen({super.key, required this.detail});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Setup required'),
        automaticallyImplyLeading: false,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.warning_amber_rounded,
                size: 56, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              'The database schema has not been applied',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              'This app needs extra tables and columns. Run the SQL that ships '
              'with the project, in order, then reopen the app.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const SelectableText(
                'supabase/schema.sql\n'
                'supabase/admin.sql\n'
                'supabase/admin_fix.sql\n'
                'supabase/fix_start_dm.sql\n'
                'supabase/fix_conversation_rls.sql\n'
                'supabase/admin_delete_user.sql\n'
                'supabase/calls.sql\n\n'
                'Supabase dashboard → SQL Editor → paste → Run',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              title: const Text('Technical detail'),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    detail,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const Spacer(),
            FilledButton(
              onPressed: () async {
                await supabase.auth.signOut();
              },
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}