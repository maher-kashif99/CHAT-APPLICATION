import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/chat_service.dart';
import '../../widgets/common.dart';

/// Admin dashboard: approve new users and manage roles.
class AdminScreen extends StatefulWidget {
  final String myUserId;

  const AdminScreen({super.key, required this.myUserId});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  List<Profile> _users = [];
  bool _loading = true;
  String? _error;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final users = await ChatService.instance
          .allUsers()
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() {
        _users = users;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  List<Profile> get _pending => _users.where((u) => !u.isApproved).toList();

  /// Filter applied to the "All users" tab.
  List<Profile> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _users;
    return _users
        .where((u) =>
            u.label.toLowerCase().contains(q) ||
            (u.username ?? '').toLowerCase().contains(q) ||
            (u.email ?? '').toLowerCase().contains(q))
        .toList();
  }

  Future<void> _setApproved(Profile user, bool approved) async {
    try {
      await ChatService.instance.setApproved(user.id, approved);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(approved
              ? '${user.label} approved'
              : '${user.label} un-approved'),
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not update: $e')));
    }
  }

  Future<void> _deleteUser(Profile user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded,
            color: Theme.of(ctx).colorScheme.error),
        title: const Text('Delete this user?'),
        content: Text(
          '${user.label} will lose access.\n\n'
          'Their profile and conversation memberships are removed. '
          'Their messages are kept so other people\'s chat history is not '
          'destroyed.\n\n'
          'They can still sign in, but will have to be approved again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ChatService.instance.deleteUser(user.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${user.label} deleted')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not delete: $e')));
    }
  }

  Future<void> _setAdmin(Profile user, bool admin) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(admin ? 'Grant admin?' : 'Remove admin?'),
        content: Text(
          admin
              ? '${user.label} will be able to approve users and manage roles.'
              : '${user.label} will lose their admin access.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(admin ? 'Grant' : 'Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ChatService.instance.setAdmin(user.id, admin);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not update: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: 'Pending (${_pending.length})'),
            const Tab(text: 'All users'),
          ],
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return EmptyState(
        icon: Icons.gpp_maybe_rounded,
        title: 'Could not load users',
        message: _error,
        action: FilledButton(onPressed: _load, child: const Text('Retry')),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _searchController,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: 'Search by name, username or email',
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
          ),
        ),
        Expanded(child: _buildTabs()),
      ],
    );
  }

  Widget _buildTabs() {
    return TabBarView(
      controller: _tabs,
      children: [
        _pending.isEmpty
            ? const EmptyState(
                icon: Icons.verified_rounded,
                title: 'Nothing pending',
                message: 'New accounts will appear here for approval.',
              )
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _pending.length,
                separatorBuilder: (_, __) =>
                    const Divider(indent: 80, height: 1),
                itemBuilder: (context, i) => _UserTile(
                  user: _pending[i],
                  isMe: _pending[i].id == widget.myUserId,
                  onApprove: () => _setApproved(_pending[i], true),
                  onReject: () => _setApproved(_pending[i], false),
                  onToggleAdmin: () => _setAdmin(_pending[i], true),
                  onDelete: () => _deleteUser(_pending[i]),
                ),
              ),
        _filtered.isEmpty
            ? const EmptyState(
                icon: Icons.search_off_rounded,
                title: 'No matching users',
                message: 'Try a different name, username or email.',
              )
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _filtered.length,
                separatorBuilder: (_, __) =>
                    const Divider(indent: 80, height: 1),
                itemBuilder: (context, i) {
                  final u = _filtered[i];
                  return _UserTile(
                    user: u,
                    isMe: u.id == widget.myUserId,
                    onApprove: u.isApproved
                        ? () => _setApproved(u, false)
                        : () => _setApproved(u, true),
                    onToggleAdmin: () => _setAdmin(u, !u.isAdmin),
                    onDelete: () => _deleteUser(u),
                  );
                },
              ),
      ],
    );
  }
}

class _UserTile extends StatelessWidget {
  final Profile user;
  final bool isMe;
  final VoidCallback onApprove;
  final VoidCallback? onReject;
  final VoidCallback onToggleAdmin;
  final VoidCallback? onDelete;

  const _UserTile({
    required this.user,
    required this.isMe,
    required this.onApprove,
    this.onReject,
    required this.onToggleAdmin,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: ProfileAvatar(profile: user, size: 46),
      title: Row(
        children: [
          Flexible(
            child: Text(
              user.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (user.isAdmin) ...[
            const SizedBox(width: 6),
            Icon(Icons.shield_rounded,
                size: 15, color: theme.colorScheme.primary),
          ],
          if (!user.isApproved) ...[
            const SizedBox(width: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'pending',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
          if (isMe) ...[
            const SizedBox(width: 6),
            Text(
              'you',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        user.email ?? '@${user.username ?? '—'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'approve') onApprove();
          if (v == 'reject') onReject?.call();
          if (v == 'admin') onToggleAdmin();
          if (v == 'delete') onDelete?.call();
        },
        itemBuilder: (ctx) => [
          if (!user.isApproved)
            const PopupMenuItem(value: 'approve', child: Text('Approve')),
          if (user.isApproved && !isMe)
            const PopupMenuItem(value: 'reject', child: Text('Un-approve')),
          if (!isMe)
            PopupMenuItem(
              value: 'admin',
              child: Text(user.isAdmin ? 'Remove admin' : 'Make admin'),
            ),
          if (!isMe) const PopupMenuDivider(),
          if (!isMe && onDelete != null)
            PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.person_remove_rounded,
                      size: 18, color: Theme.of(ctx).colorScheme.error),
                  const SizedBox(width: 10),
                  Text(
                    'Delete user',
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}