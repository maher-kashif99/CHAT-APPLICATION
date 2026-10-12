import 'package:flutter/material.dart';

import '../models/models.dart';
import 'audio_player.dart';
import 'common.dart';

/// A single message bubble.
///
/// Handles text, voice notes and the soft-deleted placeholder, and exposes a
/// long-press menu for deleting your own messages.
class MessageBubble extends StatelessWidget {
  final Message message;
  final bool mine;

  const MessageBubble({
    super.key,
    required this.message,
    required this.mine,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final bg = mine ? scheme.primary : (theme.cardTheme.color ?? Colors.white);
    final fg = mine ? scheme.onPrimary : scheme.onSurface;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.76,
        ),
        margin: const EdgeInsets.only(bottom: 8),
        padding: message.type == MessageType.voice
            ? const EdgeInsets.fromLTRB(12, 10, 12, 8)
            : const EdgeInsets.fromLTRB(14, 10, 14, 7),
        decoration: BoxDecoration(
          color: message.isDeleted ? bg.withValues(alpha: 0.5) : bg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(mine ? 18 : 4),
            bottomRight: Radius.circular(mine ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            _body(context, fg, theme),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message.isDeleted)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(Icons.block_rounded,
                        size: 12, color: fg.withValues(alpha: 0.6)),
                  ),
                Text(
                  formatListTimestamp(message.createdAt),
                  style: TextStyle(
                    fontSize: 10,
                    color: fg.withValues(alpha: 0.65),
                  ),
                ),
                if (mine && !message.isDeleted) ...[
                  const SizedBox(width: 5),
                  Icon(
                    message.read ? Icons.done_all_rounded : Icons.done_rounded,
                    size: 13,
                    color: fg.withValues(alpha: 0.75),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, Color fg, ThemeData theme) {
    if (message.isDeleted) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          'This message was deleted',
          style: TextStyle(
            color: fg.withValues(alpha: 0.7),
            fontSize: 14,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    switch (message.type) {
      case MessageType.voice:
        final url = message.mediaUrl;
        if (url == null) {
          return Text('Voice message unavailable',
              style: TextStyle(color: fg, fontSize: 14));
        }
        return VoiceNotePlayer(
          key: ValueKey('${message.id}-${message.mediaUrl}'),
          url: url,
          durationMs: message.durationMs,
          accent: theme.colorScheme.primary,
          onAccent: fg,
        );
      case MessageType.image:
        return const Text('Photo');
      case MessageType.text:
        return Text(
          message.body ?? '',
          style: TextStyle(color: fg, fontSize: 15, height: 1.35),
        );
    }
  }
}