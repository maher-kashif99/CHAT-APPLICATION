import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../widgets/common.dart';

/// Read-only view of another participant, reached by tapping the chat header.
class UserProfileScreen extends StatelessWidget {
  final Profile profile;

  const UserProfileScreen({super.key, required this.profile});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(child: ProfileAvatar(profile: profile, size: 110)),
          const SizedBox(height: 20),
          Text(
            profile.label,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          if (profile.username != null && profile.username!.isNotEmpty)
            Text(
              '@${profile.username}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          if (profile.status != null && profile.status!.isNotEmpty) ...[
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: 18, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(profile.status!,
                        style: const TextStyle(fontSize: 14)),
                  ),
                ],
              ),
            ),
          ],
          if (profile.lastSeen != null) ...[
            const SizedBox(height: 18),
            Center(
              child: Text(
                'Last seen ${formatListTimestamp(profile.lastSeen)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}