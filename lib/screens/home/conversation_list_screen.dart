import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/chat_service.dart';
import '../../widgets/common.dart';
import '../chat/chat_screen.dart';
import '../profile/profile_screen.dart';
import '../settings/settings_screen.dart';
import 'new_chat_screen.dart';

class ConversationListScreen extends StatefulWidget {
  const ConversationListScreen({super.key});

  @override
  State<ConversationListScreen> createState() => _ConversationListScreenState();
}

class _ConversationListScreenState extends State<ConversationListScreen>
    with WidgetsBindingObserver {
  Stream<List<Conversation>>? _stream;
  List<Conversation> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the foreground should show fresh presence.
    if (state == AppLifecycleState.resumed) {
      ChatService.instance.setOnline(true);
      _refresh();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Bounded: if the network stalls we show an error rather than an
      // endless spinner.
      final list = await ChatService.instance
          .myConversations()
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
      // Now attach the live stream for subsequent changes.
      final s = ChatService.instance.watchConversationList();
      _stream = s;
      s.listen((data) {
        if (!mounted) return;
        setState(() {
          _items = data;
          _loading = false;
        });
      }, onError: (_) {
        if (mounted) setState(() => _loading = false);
      });
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _error = 'The server took too long to respond. Check your connection.';
          _loading = false;
        });
      }
    } on ChatException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not load your conversations.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _refresh() async {
    try {
      final list = await ChatService.instance.myConversations();
      if (mounted) setState(() => _items = list);
    } catch (_) {
      // keep whatever is on screen
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Profile',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProfileScreen()),
            ),
            icon: const Icon(Icons.account_circle_outlined),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final convId = await Navigator.push<String>(
            context,
            MaterialPageRoute(builder: (_) => const NewChatScreen()),
          );
          if (convId != null) _openChat(convId);
        },
        icon: const Icon(Icons.edit_rounded),
        label: const Text('New chat'),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _buildBody(theme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return EmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Something went wrong',
        message: _error,
        action: FilledButton(onPressed: _load, child: const Text('Retry')),
      );
    }
    if (_items.isEmpty) {
      return ListView(
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.12),
          EmptyState(
            icon: Icons.chat_bubble_outline_rounded,
            title: 'No conversations yet',
            message:
                'Tap "New chat" to search for someone by username, name or email.',
          ),
        ],
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: _items.length,
      separatorBuilder: (_, __) =>
          const Divider(indent: 80, height: 1, endIndent: 16),
      itemBuilder: (context, index) {
        final c = _items[index];
        return _ConversationTile(
          conversation: c,
          onTap: () => _openChat(c.id),
        );
      },
    );
  }

  void _openChat(String conversationId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(conversationId: conversationId),
      ),
    ).then((_) => _refresh());
  }
}

class _ConversationTile extends StatelessWidget {
  final Conversation conversation;
  final VoidCallback onTap;

  const _ConversationTile({required this.conversation, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final other = conversation.otherUser;

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: ProfileAvatar(profile: other, size: 52, showOnline: true),
      title: Text(
        conversation.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          conversation.lastMessage?.preview ?? 'Start a conversation',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      trailing: Text(
        formatListTimestamp(conversation.lastMessageAt),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}