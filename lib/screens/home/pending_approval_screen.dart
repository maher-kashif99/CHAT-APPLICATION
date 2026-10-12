import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_client.dart';
import '../../models/models.dart';

/// Shown when the signed-in account has not been approved yet.
///
/// The user is fully signed in — we simply hold them here until an admin
/// approves the account. Pull to refresh re-checks their status.
class PendingApprovalScreen extends StatefulWidget {
  final Future<Profile?> profileLoader;

  const PendingApprovalScreen({super.key, required this.profileLoader});

  @override
  State<PendingApprovalScreen> createState() => _PendingApprovalScreenState();
}

class _PendingApprovalScreenState extends State<PendingApprovalScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          // The auth listener in main.dart swaps this screen out the moment
          // is_approved flips, so a pull-to-refresh just nudges the UI.
          onRefresh: () async {
            setState(() {});
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(28, 60, 28, 28),
            children: [
              Column(
                children: [
                  Container(
                    height: 96,
                    width: 96,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.hourglass_top_rounded,
                      size: 46,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Waiting for approval',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Your account has been created, but an administrator has '
                    'to approve it before you can start chatting.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),
                  FutureBuilder<Profile?>(
                    future: widget.profileLoader,
                    builder: (context, snapshot) => Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          _row(theme, 'Name', snapshot.data?.label ?? '—'),
                          const SizedBox(height: 10),
                          _row(
                            theme,
                            'Username',
                            snapshot.data?.username == null
                                ? '—'
                                : '@${snapshot.data!.username}',
                          ),
                          const SizedBox(height: 10),
                          _row(theme, 'Email', snapshot.data?.email ?? '—'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: () => setState(() {}),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Check again'),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () => supabase.auth.signOut(),
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('Sign out'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(ThemeData theme, String label, String value) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      );
}