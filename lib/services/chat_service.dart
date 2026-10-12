import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/supabase_client.dart';
import '../models/models.dart';
import 'firebase_messaging_service.dart';

class ChatException implements Exception {
  final String message;
  ChatException(this.message);
  @override
  String toString() => message;
}

/// All database access for conversations, messages and profiles.
///
/// Read paths use Supabase Realtime so the UI can subscribe with
/// [watchMessages] / [watchConversationList] instead of polling.
class ChatService {
  ChatService._();
  static final instance = ChatService._();

  // ---------------------------------------------------------------- profile

  /// Ensures a `profiles` row exists for the signed-in user.
  ///
  /// Deliberately forgiving: if the optional columns (`username`) have not been
  /// added yet it falls back to the original three, so the app still works
  /// against an older schema instead of crashing on boot.
  Future<void> ensureMyProfile() async {
    final user = supabase.auth.currentUser;
    if (user == null) return;
    final base = (user.email ?? 'user').split('@').first;

    final existing = await supabase
        .from('profiles')
        .select('id')
        .eq('id', user.id)
        .maybeSingle();

    if (existing != null) {
      // Backfill a username if it was never set. If the column is missing the
      // whole call is a no-op rather than a crash.
      try {
        final row = await supabase
            .from('profiles')
            .select('username')
            .eq('id', user.id)
            .maybeSingle();
        final name = (row?['username'] as String?)?.trim();
        if (name == null || name.isEmpty) {
          await supabase
              .from('profiles')
              .update({'username': base}).eq('id', user.id);
        }
      } catch (_) {
        // `profiles.username` not added yet.
      }
      return;
    }

    try {
      await supabase.from('profiles').insert({
        'id': user.id,
        'email': user.email,
        'username': base,
        'display_name': base,
      });
    } catch (_) {
      // Fall back to the pre-existing column set.
      await supabase.from('profiles').insert({
        'id': user.id,
        'email': user.email,
        'display_name': base,
      });
    }
  }

  Future<Profile?> myProfile() async {
    final id = currentUserId;
    if (id == null) return null;
    final row =
        await supabase.from('profiles').select('*').eq('id', id).maybeSingle();
    return row == null ? null : Profile.fromRow(row);
  }

  Future<void> updateMyProfile({
    String? displayName,
    String? username,
    String? avatarUrl,
    String? status,
  }) async {
    final id = currentUserId;
    if (id == null) throw ChatException('Not signed in.');
    final patch = <String, dynamic>{};
    if (displayName != null) patch['display_name'] = displayName;
    if (username != null) patch['username'] = username;
    if (avatarUrl != null) patch['avatar_url'] = avatarUrl;
    if (status != null) patch['status'] = status;
    if (patch.isEmpty) return;
    await supabase.from('profiles').update(patch).eq('id', id);
  }

  /// Search other users by username, display name or email.
  Future<List<Profile>> searchUsers(String query) async {
    final q = query.trim();
    if (q.length < 2) return [];
    final me = currentUserId;

    // Prefer the `username` column; fall back to email if the schema has not
    // been updated yet.
    try {
      final rows = await supabase
          .from('profiles')
          .select('*')
          .neq('id', me ?? '')
          .ilike('username', '%$q%')
          .limit(25);
      return rows.map(Profile.fromRow).toList();
    } catch (_) {
      final rows = await supabase
          .from('profiles')
          .select('*')
          .neq('id', me ?? '')
          .ilike('email', '%$q%')
          .limit(25);
      return rows.map(Profile.fromRow).toList();
    }
  }

  Future<Profile?> profileById(String id) async {
    final row =
        await supabase.from('profiles').select('*').eq('id', id).maybeSingle();
    return row == null ? null : Profile.fromRow(row);
  }

  Future<List<Profile>> membersOf(String conversationId) async {
    final rows = await supabase
        .from('chat_members')
        .select('user_id')
        .eq('conversation_id', conversationId);
    final ids = rows.map((r) => '${r['user_id']}').toList();
    if (ids.isEmpty) return [];
    final profiles =
        await supabase.from('profiles').select('*').inFilter('id', ids);
    return profiles.map(Profile.fromRow).toList();
  }

  // ---------------------------------------------------------- conversations

  /// Calls the `start_dm` RPC: finds an existing 1-1 conversation with
  /// [otherUserId] or creates one, then returns its id.
  ///
  /// The RPC does the lookup+insert server-side so two people tapping each
  /// other at the same moment can't create two duplicate conversations.
  Future<String> startDirectChat(String otherUserId) async {
    final me = currentUserId;
    if (me == null) throw ChatException('Not signed in.');
    if (me == otherUserId) {
      throw ChatException('You cannot start a chat with yourself.');
    }
    dynamic res;
    try {
      res = await supabase.rpc(
        'start_dm',
        params: {'other_user_id': otherUserId},
      );
    } on PostgrestException catch (e) {
      // Surface the server's reason instead of a generic failure — "not
      // authorised" and "permission denied" need very different fixes.
      throw ChatException('Could not start chat: ${e.message}');
    }

    // A scalar `returns uuid` comes back as a bare string. Be tolerant of a
    // wrapped single-row result too.
    String id = '';
    if (res is String) {
      id = res;
    } else if (res is List && res.isNotEmpty && res.first is Map) {
      final first = (res.first as Map).values.first;
      id = '${first ?? ''}';
    } else if (res != null) {
      id = '$res';
    }

    if (id.isEmpty || id == 'null') {
      throw ChatException('The server returned no conversation id.');
    }
    return id;
  }

  Future<List<Conversation>> myConversations() async {
    final me = currentUserId;
    if (me == null) return [];

    // 1. which conversations am I in?
    final memberships = await supabase
        .from('chat_members')
        .select('conversation_id')
        .eq('user_id', me);
    final ids = memberships.map((r) => '${r['conversation_id']}').toList();
    if (ids.isEmpty) return [];

    // 2. the conversation rows
    final convRows = await supabase
        .from('conversations')
        .select('*')
        .inFilter('id', ids)
        .order('last_message_at', ascending: false, nullsFirst: false);

    // 3. who am I talking to? (for the avatar + title)
    final otherRows = await supabase
        .from('chat_members')
        .select('conversation_id,user_id')
        .inFilter('conversation_id', ids);
    final otherByConv = <String, String>{};
    for (final r in otherRows) {
      final cid = '${r['conversation_id']}';
      final uid = '${r['user_id']}';
      if (uid != me) otherByConv[cid] = uid;
    }
    final profileIds = otherByConv.values.toSet().toList();
    final profiles = <String, Profile>{};
    if (profileIds.isNotEmpty) {
      final prows = await supabase
          .from('profiles')
          .select('*')
          .inFilter('id', profileIds);
      for (final r in prows) {
        profiles['${r['id']}'] = Profile.fromRow(r);
      }
    }

    // 4. newest message per conversation, for the list preview.
    final lastByConv = await _latestMessages(ids);

    return convRows.map((r) {
      final cid = '${r['id']}';
      return Conversation.fromRow(
        r,
        otherUser: profiles[otherByConv[cid]],
        lastMessage: lastByConv[cid],
      );
    }).toList();
  }

  /// Fetches the most recent message for each conversation.
  ///
  /// PostgREST has no "latest row per group" primitive, so we fetch a small
  /// descending window per conversation. Conversations are capped at 50 for
  /// this reason.
  Future<Map<String, Message>> _latestMessages(List<String> ids) async {
    final result = <String, Message>{};
    for (final id in ids) {
      try {
        final rows = await supabase
            .from('messages')
            .select('*')
            .eq('conversation_id', id)
            .order('created_at', ascending: false)
            .limit(1);
        if (rows.isNotEmpty) {
          result[id] = Message.fromRow(rows.first);
        }
      } catch (_) {
        // A conversation with no messages, or a transient error.
      }
    }
    return result;
  }

  /// Live list of conversations, refreshed whenever anything changes.
  ///
  /// Uses a broadcast channel carrying a `refresh` signal rather than
  /// postgres_changes on every table — one code path for new messages,
  /// deletes and new conversations.
  Stream<List<Conversation>> watchConversationList() async* {
    yield await myConversations();

    final me = currentUserId;
    if (me == null) return;

    final controller = StreamController<List<Conversation>>.broadcast();
    final channel = supabase.channel('convlist:$me');

    Future<void> refresh() async {
      try {
        controller.add(await myConversations());
      } catch (_) {
        // transient network error; the next event will refresh again
      }
    }

    channel.onBroadcast(event: 'refresh', callback: (_) => refresh());
    await channel.subscribe();

    // Anything that changes a conversation row invalidates the list.
    for (final table in ['conversations', 'chat_members']) {
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (_) => refresh(),
      );
    }
    await channel.subscribe();

    controller.onCancel = () async {
      await supabase.removeChannel(channel);
    };

    yield* controller.stream;
  }

  /// Nudges every client to re-fetch their conversation list.
  static Future<void> broadcastConversationRefresh() async {
    final me = currentUserId;
    if (me == null) return;
    final channel = supabase.channel('convlist:$me');
    await channel.subscribe();
    await channel.sendBroadcastMessage(event: 'refresh', payload: {});
    await supabase.removeChannel(channel);
  }

  // -------------------------------------------------------------- messages

  Stream<List<Message>> watchMessages(String conversationId) {
    return supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .order('created_at', ascending: true)
        .map((rows) => rows.map(Message.fromRow).toList());
  }

  Future<List<Message>> messagesOnce(String conversationId) async {
    final rows = await supabase
        .from('messages')
        .select('*')
        .eq('conversation_id', conversationId)
        .order('created_at', ascending: true);
    return rows.map(Message.fromRow).toList();
  }

  Future<void> sendText(String conversationId, String text) async {
    final me = currentUserId;
    final body = text.trim();
    if (me == null) throw ChatException('Not signed in.');
    if (body.isEmpty) return;

    final inserted = await supabase
        .from('messages')
        .insert({
          'conversation_id': conversationId,
          'sender_id': me,
          'body': body,
          'type': 'text',
        })
        .select('id')
        .maybeSingle();

    await _touchConversation(conversationId);

    unawaited(_notifyParticipants(
      conversationId: conversationId,
      senderId: me,
      body: body,
      messageId: inserted?['id']?.toString(),
    ));
  }

  Future<void> sendVoiceNote({
    required String conversationId,
    required String url,
    required int durationMs,
  }) async {
    final me = currentUserId;
    if (me == null) throw ChatException('Not signed in.');
    final inserted = await supabase
        .from('messages')
        .insert({
          'conversation_id': conversationId,
          'sender_id': me,
          'body': null,
          'media_url': url,
          'type': 'voice',
          'duration_ms': durationMs,
        })
        .select('id')
        .maybeSingle();

    await _touchConversation(conversationId);

    unawaited(_notifyParticipants(
      conversationId: conversationId,
      senderId: me,
      body: '🎤 Voice message',
      messageId: inserted?['id']?.toString(),
    ));
  }

  Future<void> _notifyParticipants({
    required String conversationId,
    required String senderId,
    required String body,
    String? messageId,
  }) async {
    try {
      final senderProfile = await myProfile();
      final senderName =
          senderProfile?.displayName ?? senderProfile?.username ?? 'Someone';

      final members = await membersOf(conversationId);
      for (final member in members) {
        if (member.id != senderId) {
          await FirebaseMessagingService.sendPushNotification(
            recipientUserId: member.id,
            title: senderName,
            body: body,
            data: {
              'conversation_id': conversationId,
              'sender_id': senderId,
              if (messageId != null) 'message_id': messageId,
              'type': 'message',
            },
          );
        }
      }
    } catch (e) {
      debugPrint('Failed to send push notification to participants: $e');
    }
  }

  /// Soft-deletes a message. The RLS policy in schema.sql restricts this to
  /// the sender, so this call fails for anyone else's messages.
  Future<void> deleteMessage(Message message) async {
    if (!isMine(message.senderId)) {
      throw ChatException('You can only delete your own messages.');
    }
    await supabase.from('messages').update({
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
      'body': null,
      'media_url': null,
    }).eq('id', message.id);
  }

  Future<void> markRead(String conversationId) async {
    final me = currentUserId;
    if (me == null) return;
    await supabase
        .from('messages')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('conversation_id', conversationId)
        .neq('sender_id', me)
        .isFilter('read_at', null);
  }

  Future<void> _touchConversation(String conversationId) async {
    await supabase.from('conversations').update({
      'last_message_at': DateTime.now().toUtc().toIso8601String()
    }).eq('id', conversationId);
  }

  // --------------------------------------------------------------- presence

  // ------------------------------------------------------------------ admin

  /// Whether the signed-in user has the admin role.
  ///
  /// Reads the cached value from our own profile row rather than calling
  /// `is_admin()`, so the UI can render without a round trip. The database
  /// re-checks the role on every privileged call regardless.
  Future<bool> amIAdmin() async => (await myProfile())?.isAdmin ?? false;

  /// Users awaiting approval. Requires the admin role.
  Future<List<Profile>> pendingUsers() async {
    final rows = await supabase.rpc('list_pending_users');
    return (rows as List).map((r) => Profile.fromRow(r)).toList();
  }

  /// Every registered user. Requires the admin role.
  Future<List<Profile>> allUsers() async {
    final rows = await supabase.rpc('list_all_users');
    return (rows as List).map((r) => Profile.fromRow(r)).toList();
  }

  /// Approves or un-approves a user.
  /// Approves or un-approves a user.
  ///
  /// Throws a [ChatException] with the server's reason, because "Not
  /// authorised" means the caller's `is_admin` is false and silently doing
  /// nothing would be very confusing.
  Future<void> setApproved(String userId, bool approved) async {
    try {
      await supabase.rpc(
        'set_user_approved',
        params: {'target_id': userId, 'approved': approved},
      );
    } on PostgrestException catch (e) {
      throw ChatException(_explain(e.message));
    }
  }

  /// Grants or removes the admin role.
  Future<void> setAdmin(String userId, bool admin) async {
    try {
      await supabase.rpc(
        'set_user_admin',
        params: {'target_id': userId, 'admin': admin},
      );
    } on PostgrestException catch (e) {
      throw ChatException(_explain(e.message));
    }
  }

  /// Deletes a user's profile and conversation memberships.
  ///
  /// Their messages are kept so other people's chat history survives. This
  /// cannot delete the `auth.users` row — that needs the service-role key,
  /// which must not ship in the app. The removed person can still sign in but
  /// lands back in "Waiting for approval".
  Future<void> deleteUser(String userId) async {
    try {
      await supabase.rpc('delete_user', params: {'target_id': userId});
    } on PostgrestException catch (e) {
      throw ChatException(_explain(e.message));
    }
  }

  /// Turns a raw Postgres message into something a human can act on.
  String _explain(String message) {
    final m = message.toLowerCase();
    if (m.contains('not authorised')) {
      return 'Your account is not an admin, so this change was rejected. '
          'Run: select promote_first_admin(\'your-email@example.com\');';
    }
    if (m.contains('un-approve yourself')) {
      return 'You cannot un-approve your own account.';
    }
    if (m.contains('remove your own admin')) {
      return 'You cannot remove your own admin role.';
    }
    if (m.contains('admin or approval status')) {
      return 'The database rejected this change because it controls admin '
          'and approval flags server-side. Run supabase/admin_fix.sql.';
    }
    if (m.contains('cannot delete your own')) {
      return 'You cannot delete your own account.';
    }
    if (m.contains('no profile found')) {
      return 'That user no longer exists.';
    }
    if (m.contains('function public.delete_user') ||
        m.contains('does not exist') && m.contains('delete_user')) {
      return 'delete_user() is not installed. Run supabase/admin_delete_user.sql.';
    }
    return message;
  }

  /// Marks the user online/offline in `profiles`.
  Future<void> setOnline(bool online) async {
    final me = currentUserId;
    if (me == null) return;
    try {
      await supabase.from('profiles').update({
        'is_online': online,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', me);
    } catch (_) {
      // Presence is best-effort; never block the UI on it.
    }
  }
}
