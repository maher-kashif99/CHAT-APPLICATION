import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/supabase_client.dart';
import 'notification_service.dart';

/// Watches the `messages` table globally and raises a system notification for
/// any message that arrives in a conversation the user is not currently
/// looking at.
///
/// This has to live outside the chat screen. Previously notifications were
/// raised from inside `ChatScreen`, which meant they could only ever fire for
/// a conversation that was already open — exactly backwards.
class MessageNotificationListener {
  MessageNotificationListener._();
  static final instance = MessageNotificationListener._();

  RealtimeChannel? _channel;
  String? _forUserId;
  bool _starting = false;

  /// Safety net. Realtime is the fast path, but a subscription can silently
  /// stop delivering (reconnect blip, a dropped socket, RLS rejecting the
  /// INSERT because the table is not in the realtime publication). This poll
  /// guarantees a notification still arrives.
  Timer? _poll;

  /// Timestamp watermark: we only ever consider messages newer than this.
  ///
  /// This MUST be time-based. The previous version stored a single "last seen
  /// message id" and compared `id == _lastSeenId` while walking the list
  /// oldest-first — so the very first row never matched the watermark and it
  /// notified for the entire backlog, then reset the watermark to the oldest
  /// id and did it again every 5 seconds. That produced a continuous stream of
  /// notifications for old messages.
  DateTime? _watermark;

  /// Ids already notified, so the realtime path and the poll can never both
  /// report the same message. Bounded to stop it growing forever.
  final Set<String> _seen = {};

  /// Names looked up once per sender, to avoid a query per notification.
  final Map<String, String> _nameCache = {};

  /// Subscribes for [userId]. Safe to call repeatedly; it is a no-op if
  /// already listening for that user.
  Future<void> start(String userId) async {
    if (_starting || _forUserId == userId) return;
    _starting = true;

    await stop();
    _forUserId = userId;
    _nameCache.clear();
    _seen.clear();

    // Start the watermark at "now" rather than reading the newest existing
    // row. Anything already in the table arrived before this app session and
    // must never raise a notification, no matter how far back it goes.
    _watermark = DateTime.now().toUtc();

    final channel = supabase.channel('notif:$userId');
    _channel = channel;

    channel.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'messages',
      callback: (payload) => _onMessage(payload.newRecord),
    );

    await channel.subscribe();
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _pollForNewMessages());
    _starting = false;
    debugPrint('Message notifications: listening for $userId');
  }

  /// Fallback path: fetch only messages newer than the watermark.
  ///
  /// The filter is done in the QUERY (`gt`), not in Dart. Fetching the newest
  /// 20 rows and filtering client-side was the original bug: every row that
  /// was not the watermark got notified, including the entire backlog, on
  /// every single tick.
  Future<void> _pollForNewMessages() async {
    final since = _watermark;
    if (since == null) return;
    try {
      final rows = await supabase
          .from('messages')
          .select('*')
          .gt('created_at', since.toIso8601String())
          .order('created_at', ascending: true)
          .limit(20);
      if (rows.isEmpty) return;

      for (final row in rows) {
        _onMessage(row);
        // Advance as we go, so a partial run does not replay itself.
        _advanceWatermark(row);
      }
    } catch (e) {
      debugPrint('Notification poll failed: $e');
    }
  }

  /// Moves the watermark forward to this row's timestamp, never backwards.
  void _advanceWatermark(Map<String, dynamic> row) {
    final raw = row['created_at'];
    if (raw is! String) return;
    final ts = DateTime.tryParse(raw);
    if (ts == null) return;
    final t = ts.toUtc();
    final current = _watermark;
    if (current == null || t.isAfter(current)) _watermark = t;
  }

  /// Remembers an id, returning false if we have already handled it.
  bool _claim(String id) {
    if (id.isEmpty) return false;
    if (_seen.contains(id)) return false;
    _seen.add(id);
    // Bound the set. 500 is far more than any plausible burst.
    if (_seen.length > 500) {
      _seen.remove(_seen.first);
    }
    return true;
  }

  Future<void> stop() async {
    _poll?.cancel();
    _poll = null;
    final ch = _channel;
    _channel = null;
    _forUserId = null;
    // Clear per-session state so signing in as someone else does not inherit
    // the previous user's watermark or seen-set.
    _watermark = null;
    _seen.clear();
    if (ch != null) {
      try {
        await supabase.removeChannel(ch);
      } catch (_) {
        // Best effort.
      }
    }
  }

  void _onMessage(Object? raw) {
    if (raw == null) return;

    // PostgresChangePayload.newRecord is ALREADY a Map<String, dynamic>.
    // Interpolating it into a string and calling jsonDecode was wrong: Dart's
    // Map.toString() emits single quotes ({a: b}), which is not valid JSON, so
    // the decode threw every time and every notification was silently dropped.
    final Map<String, dynamic> row;
    if (raw is Map<String, dynamic>) {
      row = raw;
    } else if (raw is Map) {
      row = Map<String, dynamic>.from(raw);
    } else if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return;
        row = Map<String, dynamic>.from(decoded);
      } catch (e) {
        debugPrint('Notification: bad payload: $e');
        return;
      }
    } else {
      return;
    }

    final me = currentUserId;
    if (me == null) return;

    // Backstop, checked BEFORE anything mutates state: never notify for a
    // message that predates this app session. Without this, any drift between
    // the poll's `gt` filter and the watermark turns into a flood of old
    // messages.
    final createdAt = row['created_at'];
    if (createdAt is String) {
      final ts = DateTime.tryParse(createdAt)?.toUtc();
      final since = _watermark;
      if (ts != null && since != null && ts.isBefore(since)) return;
    }

    // Both paths (realtime INSERT and the poll) funnel through here, so this
    // is the single place that guarantees one notification per message.
    final id = '${row['id'] ?? ''}';
    if (!_claim(id)) return;

    // Keep the watermark moving even for messages we skip below, otherwise
    // the poll would keep re-reading them.
    _advanceWatermark(row);

    final senderId = '${row['sender_id'] ?? ''}';
    if (senderId.isEmpty || senderId == me) return; // our own message

    final conversationId = '${row['conversation_id'] ?? ''}';
    if (conversationId.isEmpty) return;

    // Already on screen — no notification needed.
    if (NotificationService.activeConversationId == conversationId) return;

    final body = _preview(row);
    NotificationService.instance.showMessage(
      conversationId: conversationId,
      title: 'New message',
      body: body,
      messageId: _stableId(row['id'], conversationId, senderId),
      senderId: senderId,
    );
  }

  /// Builds the notification text from the raw row.
  String _preview(Map<String, dynamic> row) {
    final type = '${row['type'] ?? 'text'}';
    switch (type) {
      case 'voice':
        return '🎤 Voice message';
      case 'image':
        return '📷 Photo';
      default:
        final body = '${row['body'] ?? ''}'.trim();
        return body.isEmpty ? 'New message' : body;
    }
  }

  /// A stable positive int for the notification id, derived from the row id.
  ///
  /// Message ids may be uuid (String) or bigint. Deriving the hash keeps the
  /// id stable across restarts so a re-delivered insert does not create a
  /// duplicate notification.
  int _stableId(Object? rawId, String conversationId, String senderId) {
    final seed = '${rawId ?? ''}|$conversationId|$senderId';
    var hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x3FFFFFFF;
    }
    return hash == 0 ? 1 : hash;
  }
}