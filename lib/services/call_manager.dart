import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'call_screens.dart';
import 'notification_service.dart';

/// Give this to your MaterialApp:  navigatorKey: callNavigatorKey
/// It lets an incoming call open on top of whatever screen you are on.
final GlobalKey<NavigatorState> callNavigatorKey = GlobalKey<NavigatorState>();

SupabaseClient get callDb => Supabase.instance.client;

/// STUN finds your public address. TURN relays audio/video when two phones
/// cannot connect directly (different mobile networks, strict Wi-Fi).
/// For reliable calls, configured with metered.ca TURN servers.
const List<Map<String, dynamic>> kIceServers = [
  {
    'urls': [
      'stun:stun.l.google.com:19302',
      'stun:stun1.l.google.com:19302',
    ],
  },
  {
    'urls': 'stun:stun.relay.metered.ca:80',
  },
  {
    'urls': 'turn:global.relay.metered.ca:80',
    'username': 'a59029d33f76451585960b97',
    'credential': 'nhHza3YVf4EuG6Ns',
  },
  {
    'urls': 'turn:global.relay.metered.ca:80?transport=tcp',
    'username': 'a59029d33f76451585960b97',
    'credential': 'nhHza3YVf4EuG6Ns',
  },
  {
    'urls': 'turn:global.relay.metered.ca:443',
    'username': 'a59029d33f76451585960b97',
    'credential': 'nhHza3YVf4EuG6Ns',
  },
  {
    'urls': 'turns:global.relay.metered.ca:443?transport=tcp',
    'username': 'a59029d33f76451585960b97',
    'credential': 'nhHza3YVf4EuG6Ns',
  },
];

const int kRingSeconds = 45;

class CallInfo {
  final String id;
  final String conversationId;
  final String callerId;
  final String calleeId;
  final String media;
  final String status;
  final DateTime createdAt;

  const CallInfo({
    required this.id,
    required this.conversationId,
    required this.callerId,
    required this.calleeId,
    required this.media,
    required this.status,
    required this.createdAt,
  });

  bool get isVideo => media == 'video';

  factory CallInfo.fromMap(Map<String, dynamic> m) => CallInfo(
        id: m['id'] as String,
        conversationId: m['conversation_id'] as String,
        callerId: m['caller_id'] as String,
        calleeId: m['callee_id'] as String,
        media: (m['media'] ?? 'audio').toString(),
        status: (m['status'] ?? 'ringing').toString(),
        createdAt: DateTime.parse(m['created_at'] as String),
      );
}

/// Watches one call's status. Uses realtime for speed AND a slow poll as a
/// safety net, so a missed realtime event can never leave a call stuck.
class CallWatcher {
  final String callId;
  final void Function(String status) onStatus;
  RealtimeChannel? _channel;
  Timer? _poll;
  String _last;
  bool _disposed = false;

  CallWatcher(this.callId, String initialStatus, this.onStatus)
      : _last = initialStatus {
    _channel = callDb
        .channel('call-status:$callId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'calls',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: callId,
          ),
          callback: (payload) {
            final s = payload.newRecord['status'];
            if (s is String) _emit(s);
          },
        )
        .subscribe();

    _poll = Timer.periodic(const Duration(seconds: 3), (_) async {
      try {
        final row = await callDb
            .from('calls')
            .select('status')
            .eq('id', callId)
            .maybeSingle();
        final s = row?['status'];
        if (s is String) _emit(s);
      } catch (_) {}
    });
  }

  void _emit(String status) {
    if (_disposed || status == _last) return;
    _last = status;
    onStatus(status);
  }

  void dispose() {
    _disposed = true;
    _poll?.cancel();
    final c = _channel;
    if (c != null) callDb.removeChannel(c);
    _channel = null;
  }
}

class CallManager with WidgetsBindingObserver {
  CallManager._();
  static final CallManager instance = CallManager._();

  RealtimeChannel? _incoming;
  String? _userId;
  bool _busy = false;
  String? currentCallId;

  /// Call once after the user is logged in and approved.
  Future<void> start(String userId) async {
    if (_userId == userId && _incoming != null) return;
    await stop();
    _userId = userId;
    WidgetsBinding.instance.addObserver(this);
    _incoming = callDb
        .channel('incoming-calls:$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'calls',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'callee_id',
            value: userId,
          ),
          callback: (payload) => _handleIncoming(payload.newRecord),
        )
        .subscribe();
    unawaited(_checkRinging());
  }

  /// Call when the user logs out.
  Future<void> stop() async {
    WidgetsBinding.instance.removeObserver(this);
    final c = _incoming;
    if (c != null) await callDb.removeChannel(c);
    _incoming = null;
    _userId = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // If a call arrived while the app was in the background, show it now.
    if (state == AppLifecycleState.resumed) unawaited(_checkRinging());
  }

  Future<void> _checkRinging() async {
    final uid = _userId;
    if (uid == null) return;
    try {
      final since = DateTime.now()
          .toUtc()
          .subtract(const Duration(seconds: kRingSeconds))
          .toIso8601String();
      final rows = await callDb
          .from('calls')
          .select()
          .eq('callee_id', uid)
          .eq('status', 'ringing')
          .gte('created_at', since)
          .order('created_at', ascending: false)
          .limit(1);
      if (rows.isNotEmpty) _handleIncoming(rows.first);
    } catch (_) {}
  }

  void _handleIncoming(Map<String, dynamic> record) {
    CallInfo? parsed;
    try {
      parsed = CallInfo.fromMap(record);
    } catch (_) {
      parsed = null;
    }
    if (parsed == null) return;
    final call = parsed;
    if (call.status != 'ringing') return;
    final age = DateTime.now().toUtc().difference(call.createdAt.toUtc());
    if (age.inSeconds > kRingSeconds) return;

    // Never ring twice for the same call. The realtime INSERT and the
    // `_checkRinging` poll can both deliver the same row.
    if (currentCallId == call.id) return;

    if (_busy) {
      // Already on a call: tell the caller we are busy (unless it is this call).
      if (call.id != currentCallId) {
        unawaited(setStatus(call.id, 'declined'));
      }
      return;
    }
    final nav = callNavigatorKey.currentState;
    if (nav == null) return;
    _busy = true;
    currentCallId = call.id;

    // Raise the system notification FIRST. This is what actually rings the
    // phone: it runs on the `calls` channel with the ringer stream and a
    // full-screen intent, so it fires even when the app is backgrounded or the
    // screen is locked. The in-app screen alone produces no sound outside the
    // foreground.
    unawaited(_ring(call));

    nav.push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => IncomingCallScreen(call: call),
    ));
  }

  /// Posts the incoming-call notification, looking the caller's name up
  /// first. Never throws.
  Future<void> _ring(CallInfo call) async {
    try {
      var name = 'Incoming call';
      final row = await callDb
          .from('profiles')
          .select('display_name,username')
          .eq('id', call.callerId)
          .maybeSingle();
      final dn = row?['display_name'];
      final un = row?['username'];
      if (dn is String && dn.trim().isNotEmpty) {
        name = dn.trim();
      } else if (un is String && un.trim().isNotEmpty) {
        name = un.trim();
      }
      await NotificationService.instance.showIncomingCall(
        conversationId: call.conversationId,
        name: name,
        isVideo: call.isVideo,
      );
    } catch (e) {
      debugPrint('incoming call notification failed: $e');
    }
  }

  /// Withdraw the ringing notification once the call is answered, declined or
  /// over, so a stale notification is not left sitting in the shade.
  static void stopRinging() {
    unawaited(NotificationService.instance.cancelCallNotification());
  }

  bool begin() {
    if (_busy) return false;
    _busy = true;
    return true;
  }

  void release() {
    _busy = false;
    currentCallId = null;
  }

  /// Safe to call at any time. Errors are ignored on purpose, because a
  /// failed network request must never stop someone from leaving a call.
  Future<void> setStatus(String callId, String status) async {
    try {
      await callDb.from('calls').update({'status': status}).eq('id', callId);
    } catch (_) {}
  }

  /// Ends a call whatever state it is in. The database ignores the step that
  /// does not apply (for example "cancelled" once the call was answered).
  Future<void> hangUp(String callId, {required bool isCaller}) async {
    await setStatus(callId, isCaller ? 'cancelled' : 'declined');
    await setStatus(callId, 'ended');
  }

  Future<void> startCall({
    required BuildContext context,
    required String otherUserId,
    required String otherName,
    required String conversationId,
    required bool video,
  }) async {
    if (!begin()) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('You are already in a call.')),
      );
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => CallScreen(
        callId: null,
        isCaller: true,
        otherUserId: otherUserId,
        otherName: otherName,
        conversationId: conversationId,
        video: video,
      ),
    ));
  }
}

/// Drop this into the chat screen's AppBar: actions: [CallActionButtons(...)]
/// Use it for one-to-one chats only.
class CallActionButtons extends StatelessWidget {
  final String otherUserId;
  final String otherName;
  final String conversationId;

  const CallActionButtons({
    super.key,
    required this.otherUserId,
    required this.otherName,
    required this.conversationId,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Voice call',
          icon: const Icon(Icons.call),
          onPressed: () => CallManager.instance.startCall(
            context: context,
            otherUserId: otherUserId,
            otherName: otherName,
            conversationId: conversationId,
            video: false,
          ),
        ),
        IconButton(
          tooltip: 'Video call',
          icon: const Icon(Icons.videocam),
          onPressed: () => CallManager.instance.startCall(
            context: context,
            otherUserId: otherUserId,
            otherName: otherName,
            conversationId: conversationId,
            video: true,
          ),
        ),
      ],
    );
  }
}