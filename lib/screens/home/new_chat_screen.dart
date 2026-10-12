import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/chat_service.dart';
import '../../widgets/common.dart';

/// Search for a person and open (or create) a 1-1 conversation.
///
/// Pops the conversation id back to the caller so it can open the chat.
class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key});

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<Profile> _results = [];
  bool _searching = false;
  String? _error;
  final Set<String> _opening = {};

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().length < 2) {
      setState(() {
        _results = [];
        _searching = false;
        _error = null;
      });
      return;
    }
    // Debounced so we don't hit the database on every keystroke.
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(value));
  }

  Future<void> _search(String query) async {
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await ChatService.instance.searchUsers(query);
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Search failed. Check your connection.';
          _searching = false;
        });
      }
    }
  }

  Future<void> _open(Profile user) async {
    if (_opening.contains(user.id)) return;
    setState(() => _opening.add(user.id));
    try {
      final convId = await ChatService.instance.startDirectChat(user.id);
      if (!mounted) return;
      Navigator.pop(context, convId);
    } on ChatException catch (e) {
      if (mounted) {
        setState(() => _opening.remove(user.id));
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _opening.remove(user.id));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start the conversation.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('New chat')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _onChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search by username, name or email',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : (_controller.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded),
                            onPressed: () {
                              _controller.clear();
                              _onChanged('');
                            },
                          )
                        : null),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
              ),
            ),
          Expanded(child: _buildResults(theme)),
        ],
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    if (_controller.text.trim().length < 2) {
      return const EmptyState(
        icon: Icons.person_search_rounded,
        title: 'Find someone to chat with',
        message: 'Type at least two characters to search.',
      );
    }
    if (!_searching && _results.isEmpty) {
      return const EmptyState(
        icon: Icons.person_off_rounded,
        title: 'No people found',
        message:
            'Nobody matches that search. They need an account with that username first.',
      );
    }

    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final u = _results[i];
        final busy = _opening.contains(u.id);
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: ProfileAvatar(profile: u, size: 46),
          title: Text(
            u.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '@${u.username ?? u.label}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          trailing: busy
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right_rounded),
          onTap: busy ? null : () => _open(u),
        );
      },
    );
  }
}