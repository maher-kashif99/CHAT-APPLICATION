import 'package:flutter/material.dart';

import '../models/models.dart';

/// Circular avatar that falls back to coloured initials.
class ProfileAvatar extends StatelessWidget {
  final Profile? profile;
  final double size;
  final bool showOnline;

  const ProfileAvatar({
    super.key,
    this.profile,
    this.size = 48,
    this.showOnline = false,
  });

  /// Deterministic colour from the user id, so a person keeps the same
  /// colour everywhere without storing anything.
  static Color _colorFor(String id) {
    const palette = [
      Color(0xFF3B5BFD),
      Color(0xFF00A86B),
      Color(0xFFE8590C),
      Color(0xFF7048E8),
      Color(0xFFD6336C),
      Color(0xFF1098AD),
    ];
    if (id.isEmpty) return palette.first;
    return palette[id.hashCode.abs() % palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final base = _colorFor(p?.id ?? '');
    final initials = p?.initials ?? '?';

    Widget content;
    if (p?.avatarUrl != null && p!.avatarUrl!.isNotEmpty) {
      content = ClipOval(
        child: Image.network(
          p.avatarUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _initials(base, initials),
        ),
      );
    } else {
      content = _initials(base, initials);
    }

    if (!showOnline) return content;

    return Stack(
      children: [
        content,
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: size * 0.28,
            height: size * 0.28,
            decoration: BoxDecoration(
              color: const Color(0xFF2FB457),
              shape: BoxShape.circle,
              border: Border.all(
                color: Theme.of(context).scaffoldBackgroundColor,
                width: 2,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _initials(Color color, String text) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Text(
          text,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: size * 0.36,
          ),
        ),
      );
}

/// Empty-state placeholder used by the list and chat screens.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 88,
              width: 88,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

/// Formats a timestamp the way chat apps do: time today, weekday this week,
/// otherwise a date.
String formatListTimestamp(DateTime? time) {
  if (time == null) return '';
  final now = DateTime.now();
  final sameDay =
      time.year == now.year && time.month == now.month && time.day == now.day;
  if (sameDay) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
  }
  final delta = now.difference(time);
  if (delta.inDays < 7) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[time.weekday - 1];
  }
  return '${time.day.toString().padLeft(2, '0')}/'
      '${time.month.toString().padLeft(2, '0')}/${time.year % 100}';
}

/// `mm:ss` for voice-note durations.
String formatDuration(int? ms) {
  if (ms == null) return '0:00';
  final d = Duration(milliseconds: ms);
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}