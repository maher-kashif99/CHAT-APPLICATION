import 'dart:convert';

/// A row from the `profiles` table.

/// A row from the `profiles` table.
class Profile {
  final String id;
  final String? email;
  final String? displayName;
  final String? username;
  final String? avatarUrl;
  final String? status;
  final DateTime? lastSeen;

  /// Full access — can approve users and manage roles.
  final bool isAdmin;

  /// Must be true before this account may chat.
  final bool isApproved;

  const Profile({
    required this.id,
    this.email,
    this.displayName,
    this.username,
    this.avatarUrl,
    this.status,
    this.lastSeen,
    this.isAdmin = false,
    this.isApproved = true,
  });

  factory Profile.fromRow(Map<String, dynamic> row) => Profile(
        id: '${row['id']}',
        email: row['email']?.toString(),
        displayName: row['display_name']?.toString(),
        username: row['username']?.toString(),
        avatarUrl: row['avatar_url']?.toString(),
        status: row['status']?.toString(),
        lastSeen: row['last_seen'] == null
            ? null
            : DateTime.tryParse('${row['last_seen']}')?.toLocal(),
        isAdmin: row['is_admin'] == true,
        isApproved: row['is_approved'] != false,
      );

  /// Best available human-readable label.
  String get label {
    final d = displayName?.trim();
    if (d != null && d.isNotEmpty) return d;
    final u = username?.trim();
    if (u != null && u.isNotEmpty) return u;
    final e = email?.trim();
    if (e != null && e.isNotEmpty) return e.split('@').first;
    return 'Unknown user';
  }

  /// Up to two letters for the avatar placeholder.
  String get initials {
    final src = label.trim();
    if (src.isEmpty) return '?';
    final parts = src.split(RegExp(r'[\s_.-]+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return (parts[0][0] + parts[1][0]).toUpperCase();
    }
    return src.substring(0, src.length >= 2 ? 2 : 1).toUpperCase();
  }
}

/// A row from the `conversations` table (1-1 DM for now, group-ready).
class Conversation {
  final String id;
  final bool isGroup;
  final String? title;
  final DateTime createdAt;
  final DateTime? lastMessageAt;

  /// Denormalised for the conversation list so it renders in one query.
  final Message? lastMessage;
  final Profile? otherUser;

  const Conversation({
    required this.id,
    this.isGroup = false,
    this.title,
    required this.createdAt,
    this.lastMessageAt,
    this.lastMessage,
    this.otherUser,
  });

  factory Conversation.fromRow(
    Map<String, dynamic> row, {
    Message? lastMessage,
    Profile? otherUser,
  }) =>
      Conversation(
        id: row['id'] as String,
        isGroup: row['is_group'] == true,
        title: row['title']?.toString(),
        createdAt:
            DateTime.tryParse('${row['created_at']}')?.toLocal() ?? DateTime.now(),
        lastMessageAt: row['last_message_at'] == null
            ? null
            : DateTime.tryParse('${row['last_message_at']}')?.toLocal(),
        lastMessage: lastMessage,
        otherUser: otherUser,
      );

  String get displayTitle => isGroup ? (title ?? 'Group') : (otherUser?.label ?? 'Chat');
}

/// What kind of content a [Message] carries.
enum MessageType { text, voice, image }

MessageType _parseType(Object? raw) {
  switch (raw?.toString()) {
    case 'voice':
      return MessageType.voice;
    case 'image':
      return MessageType.image;
    default:
      return MessageType.text;
  }
}

/// A row from the `messages` table.
///
/// Deletion is *soft*: `deletedAt` is set and the body is nulled, so both
/// participants see "This message was deleted" instead of the bubble
/// vanishing out from under them mid-scroll.
class Message {
  final String id;
  final String conversationId;
  final String senderId;
  final String? body;
  final String? mediaUrl;
  final MessageType type;
  final int? durationMs;
  final DateTime createdAt;
  final DateTime? deletedAt;
  final bool read;

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    this.body,
    this.mediaUrl,
    this.type = MessageType.text,
    this.durationMs,
    required this.createdAt,
    this.deletedAt,
    this.read = false,
  });

  bool get isDeleted => deletedAt != null;

  factory Message.fromRow(Map<String, dynamic> row) => Message(
        id: '${row['id']}',
        conversationId: '${row['conversation_id']}',
        senderId: '${row['sender_id']}',
        body: row['body']?.toString(),
        mediaUrl: row['media_url']?.toString(),
        type: _parseType(row['type']),
        durationMs: row['duration_ms'] == null
            ? null
            : int.tryParse('${row['duration_ms']}'),
        createdAt:
            DateTime.tryParse('${row['created_at']}')?.toLocal() ?? DateTime.now(),
        deletedAt: row['deleted_at'] == null
            ? null
            : DateTime.tryParse('${row['deleted_at']}')?.toLocal(),
        read: row['read_at'] != null,
      );

  /// One-line preview for the conversation list.
  String get preview {
    if (isDeleted) return 'Message deleted';
    switch (type) {
      case MessageType.voice:
        return 'Voice message';
      case MessageType.image:
        return 'Photo';
      case MessageType.text:
        return body ?? '';
    }
  }

  static Duration? durationOf(Message m) => m.durationMs == null
      ? null
      : Duration(milliseconds: m.durationMs!);
}

/// Realtime payload helper — Postgres changes arrive as a list of maps.
class RealtimeChange {
  final String event;
  final String? newRecord;
  final String? oldRecord;

  const RealtimeChange(this.event, {this.newRecord, this.oldRecord});

  static RealtimeChange? parse(Map<String, dynamic> payload) {
    final data = payload['data'];
    if (data is! Map) return null;
    final record = data['record'];
    return RealtimeChange(
      '${data['type']}',
      newRecord: record == null ? null : jsonEncode(record),
      oldRecord: data['old_record'] == null
          ? null
          : jsonEncode(data['old_record']),
    );
  }
}