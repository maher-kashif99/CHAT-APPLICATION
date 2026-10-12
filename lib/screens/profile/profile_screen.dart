import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_client.dart';
import '../../models/models.dart';
import '../../services/chat_service.dart';
import '../../widgets/common.dart';
import 'user_profile_screen.dart';

/// View + edit your own profile.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Profile? _profile;
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;

  final _name = TextEditingController();
  final _username = TextEditingController();
  final _status = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _status.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final p = await ChatService.instance.myProfile();
      if (!mounted) return;
      setState(() {
        _profile = p;
        _loading = false;
      });
      if (p != null) {
        _name.text = p.displayName ?? '';
        _username.text = p.username ?? '';
        _status.text = p.status ?? '';
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ChatService.instance.updateMyProfile(
        displayName: _name.text.trim(),
        username: _username.text.trim(),
        status: _status.text.trim(),
      );
      await _load();
      if (mounted) {
        setState(() => _editing = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Profile updated')));
      }
    } on ChatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Could not save.')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My profile'),
        actions: [
          if (!_loading && _profile != null)
            IconButton(
              tooltip: _editing ? 'Cancel' : 'Edit',
              icon: Icon(_editing ? Icons.close_rounded : Icons.edit_rounded),
              onPressed: () => setState(() => _editing = !_editing),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _profile == null
              ? EmptyState(
                  icon: Icons.person_off_rounded,
                  title: 'No profile',
                  message:
                      'Your profile row could not be loaded. Sign out and back in.',
                  action: FilledButton(
                    onPressed: () => supabase.auth.signOut(),
                    child: const Text('Sign out'),
                  ),
                )
              : _editing
                  ? _buildEditForm(theme)
                  : _buildView(theme),
    );
  }

  Widget _buildView(ThemeData theme) {
    final p = _profile!;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Center(child: ProfileAvatar(profile: p, size: 110)),
        const SizedBox(height: 20),
        Text(
          p.label,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '@${p.username ?? ''}',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (p.status != null && p.status!.isNotEmpty) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(p.status!, style: const TextStyle(fontSize: 14)),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.alternate_email_rounded),
                title: const Text('Email'),
                subtitle: Text(p.email ?? 'Not set'),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.schedule_rounded),
                title: const Text('Last seen'),
                subtitle: Text(
                  p.lastSeen == null
                      ? 'Unknown'
                      : formatListTimestamp(p.lastSeen),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEditForm(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(
            labelText: 'Display name',
            prefixIcon: Icon(Icons.badge_outlined),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _username,
          decoration: const InputDecoration(
            labelText: 'Username',
            prefixIcon: Icon(Icons.alternate_email_rounded),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _status,
          maxLength: 120,
          decoration: const InputDecoration(
            labelText: 'About you',
            prefixIcon: Icon(Icons.info_outline),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save changes'),
        ),
      ],
    );
  }
}