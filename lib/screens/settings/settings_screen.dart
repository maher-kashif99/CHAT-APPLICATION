import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_client.dart';
import '../../core/theme_controller.dart';
import '../../models/models.dart';
import '../../services/chat_service.dart';
import '../../services/notification_service.dart';
import '../admin/admin_screen.dart';
import '../profile/profile_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _isAdmin;

  @override
  void initState() {
    super.initState();
    _checkAdmin();
  }

  Future<void> _checkAdmin() async {
    final admin = await ChatService.instance.amIAdmin();
    if (mounted) setState(() => _isAdmin = admin);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = ThemeController.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Appearance'),
          for (final mode in ThemeMode.values)
            RadioListTile<ThemeMode>(
              value: mode,
              // ignore: deprecated_member_use
              groupValue: controller.mode,
              // ignore: deprecated_member_use
              onChanged: (m) {
                if (m != null) controller.setMode(m);
              },
              title: Text(_themeLabel(mode)),
              secondary: Icon(_themeIcon(mode)),
            ),

          const Divider(height: 24),
          const _SectionHeader('Account'),
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: const Text('My profile'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProfileScreen()),
            ),
          ),

          if (_isAdmin == true) ...[
            const Divider(height: 24),
            const _SectionHeader('Administration'),
            ListTile(
              leading: Icon(Icons.admin_panel_settings_rounded,
                  color: theme.colorScheme.primary),
              title: const Text('Admin dashboard'),
              subtitle: const Text('Approve users and manage roles'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AdminScreen(
                    myUserId: currentUserId ?? '',
                  ),
                ),
              ),
            ),
          ],

          const Divider(height: 24),
          const _SectionHeader('Notifications'),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('Enable notifications'),
            subtitle: const Text('Required to be told about new messages'),
            trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14),
            onTap: () async {
              final ok = await NotificationService.instance.requestPermission();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(ok
                      ? 'Notifications enabled'
                      : 'Permission denied. Enable it in Android settings.'),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('Send a test notification'),
            subtitle: const Text(
              'Diagnostic: if this appears, the notification layer works '
              'and the problem is message delivery.',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () async {
              final allowed =
                  await NotificationService.instance.notificationsAllowed();
              final sent = allowed
                  ? await NotificationService.instance.showTestNotification()
                  : false;
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    !allowed
                        ? 'Blocked by Android. Enable notifications for this '
                            'app in Settings.'
                        : sent
                            ? 'Test notification sent.'
                            : 'Could not create the notification.',
                  ),
                ),
              );
            },
          ),

          const Divider(height: 24),
          const _SectionHeader('Session'),
          ListTile(
            leading: Icon(Icons.logout_rounded, color: theme.colorScheme.error),
            title: Text(
              'Sign out',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Sign out?'),
                  content: const Text('You will need to sign in again.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await supabase.auth.signOut();
              }
            },
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  String _themeLabel(ThemeMode m) {
    switch (m) {
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
      case ThemeMode.system:
        return 'Match system';
    }
  }

  IconData _themeIcon(ThemeMode m) {
    switch (m) {
      case ThemeMode.light:
        return Icons.light_mode_rounded;
      case ThemeMode.dark:
        return Icons.dark_mode_rounded;
      case ThemeMode.system:
        return Icons.brightness_auto_rounded;
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}