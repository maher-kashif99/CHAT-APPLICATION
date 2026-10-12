import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_client.dart';
import '../../models/models.dart';
import '../../services/call_manager.dart';
import '../../services/chat_service.dart';
import '../../services/notification_service.dart';
import '../../services/storage_service.dart';
import '../../widgets/audio_player.dart';
import '../../widgets/common.dart';
import '../../widgets/message_bubble.dart';
import '../profile/user_profile_screen.dart';

class ChatScreen extends StatefulWidget {
  final String conversationId;

  const ChatScreen({super.key, required this.conversationId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _recorder = AudioRecorder();

  Stream<List<Message>>? _messageStream;
  List<Message> _messages = [];
  List<Profile> _members = [];

  bool _sending = false;
  bool _loading = true;
  String? _error;

  // Recording state
  bool _recording = false;
  bool _uploading = false;
  int _recordMs = 0;
  double _level = 0;
  Timer? _recordTimer;
  DateTime? _recordStart;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.activeConversationId = widget.conversationId;
    _loadMembers();
    _listen();
    _markRead();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationService.activeConversationId = null;
    _messageController.dispose();
    _scrollController.dispose();
    _recordTimer?.cancel();
    _recorder.dispose();
    _messageStream = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _markRead();
    } else if (state == AppLifecycleState.paused && _recording) {
      // Don't leave the mic hot in the background.
      _discardRecording();
    }
  }

  Future<void> _loadMembers() async {
    try {
      final m = await ChatService.instance.membersOf(widget.conversationId);
      if (mounted) setState(() => _members = m);
    } catch (_) {
      // Non-fatal: header falls back to "Chat".
    }
  }

  void _listen() {
    final s = ChatService.instance.watchMessages(widget.conversationId);
    _messageStream = s;
    s.listen((rows) {
      if (!mounted) return;
      setState(() {
        _messages = rows;
        _loading = false;
      });
      _scrollToBottom();
      _notifyIncoming(rows);
      ChatService.broadcastConversationRefresh();
    }, onError: (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load messages.';
        });
      }
    });
  }

  /// Notifications are raised globally by MessageNotificationListener, not
  /// from inside this screen. Doing it here meant a message could only ever
  /// notify for a conversation that was already open.
  void _notifyIncoming(List<Message> rows) {
    // Intentionally empty — see MessageNotificationListener.
  }

  Future<void> _markRead() async {
    try {
      await ChatService.instance.markRead(widget.conversationId);
    } catch (_) {
      // Non-fatal.
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Profile? get _other {
    final me = currentUserId;
    return _members.where((m) => m.id != me).firstOrNull;
  }

  // ------------------------------------------------------------- messaging

  Future<void> _send() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await ChatService.instance.sendText(widget.conversationId, text);
      _messageController.clear();
    } on ChatException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Message could not be sent.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _confirmDelete(Message m) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text(
          'This removes it for both of you. It cannot be undone.',
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
      await ChatService.instance.deleteMessage(m);
    } on ChatException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Could not delete that message.');
    }
  }

  // ------------------------------------------------------------- recording

  Future<void> _startRecording() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      _toast('Microphone permission is required to send a voice note.');
      return;
    }
    try {
      final file = await StorageService.instance.newRecordingFile();
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
        ),
        path: file.path,
      );
      _pendingFile = file;
      _recordStart = DateTime.now();
      _recordMs = 0;
      _level = 0;

      _recordTimer?.cancel();
      _recordTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        final start = _recordStart;
        if (start == null) return;
        setState(() {
          _recordMs = DateTime.now().difference(start).inMilliseconds;
        });
      });

      // Amplitude stream drives the level meter.
      _ampSub = _recorder.onAmplitudeChanged(const Duration(milliseconds: 120))
          .listen((amp) {
        if (!mounted) return;
        // amp.current is roughly dBFS (-160..0); map to 0..1
        final v = (amp.current + 60) / 60;
        setState(() => _level = v.clamp(0.0, 1.0));
      });

      setState(() => _recording = true);
    } catch (e) {
      debugPrint('Recording failed to start: $e');
      _toast('Could not start recording: $e');
      setState(() {
        _recording = false;
        _pendingFile = null;
      });
    }
  }

  File? _pendingFile;
  StreamSubscription<Amplitude>? _ampSub;

  Future<void> _discardRecording() async {
    _recordTimer?.cancel();
    await _ampSub?.cancel();
    try {
      await _recorder.cancel();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _recording = false;
        _recordMs = 0;
        _level = 0;
      });
    }
  }

  Future<void> _stopAndSend() async {
    if (_pendingFile == null) return;
    final file = _pendingFile!;
    final durationMs = _recordMs;

    _recordTimer?.cancel();
    await _ampSub?.cancel();

    setState(() {
      _recording = false;
      _uploading = true;
      _level = 0;
    });

    try {
      final path = await _recorder.stop();
      if (path == null) throw Exception('recorder returned no file path');

      final me = currentUserId;
      if (me == null) throw Exception('signed out');

      final url = await StorageService.instance
          .uploadVoiceNote(userId: me, file: file);
      await ChatService.instance.sendVoiceNote(
        conversationId: widget.conversationId,
        url: url,
        durationMs: durationMs,
      );
    } catch (e) {
      // Surface the real reason — "Voice note could not be sent" hid whether
      // the problem was the recorder, the upload, or the database.
      debugPrint('Voice note failed: $e');
      _toast('Voice note failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          _recordMs = 0;
        });
      }
      _pendingFile = null;
    }
  }

  // ----------------------------------------------------------------- calls
  // Actual call handling lives in CallManager / CallScreen (services/).
  // The AppBar just exposes the two buttons via CallActionButtons.

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final other = _other;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: other == null
              ? null
              : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => UserProfileScreen(profile: other),
                    ),
                  ),
          child: Row(
            children: [
              ProfileAvatar(profile: other, size: 38, showOnline: true),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      other?.label ?? 'Chat',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    if (other != null)
                      Text(
                        '@${other.username ?? other.label}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (other != null)
            CallActionButtons(
              otherUserId: other.id,
              otherName: other.label,
              conversationId: widget.conversationId,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessages(theme)),
          if (_recording || _uploading)
            RecordingBar(
              elapsed: Duration(milliseconds: _recordMs),
              cancelling: _uploading,
              level: _level,
              onCancel: _discardRecording,
              onStop: _stopAndSend,
            )
          else
            _buildComposer(theme),
        ],
      ),
    );
  }

  Widget _buildMessages(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return EmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load messages',
        message: _error,
        action: FilledButton(
          onPressed: () {
            setState(() {
              _loading = true;
              _error = null;
            });
            _listen();
          },
          child: const Text('Retry'),
        ),
      );
    }
    if (_messages.isEmpty) {
      return const EmptyState(
        icon: Icons.waving_hand_rounded,
        title: 'Say hello',
        message: 'Send a message or a voice note to start the conversation.',
      );
    }

    final me = currentUserId;
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
      itemCount: _messages.length,
      itemBuilder: (context, i) {
        final m = _messages[i];
        final mine = m.senderId == me;
        return GestureDetector(
          onLongPress: mine && !m.isDeleted ? () => _confirmDelete(m) : null,
          child: MessageBubble(
            message: m,
            mine: mine,
          ),
        );
      },
    );
  }

  Widget _buildComposer(ThemeData theme) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: theme.appBarTheme.backgroundColor,
          border: Border(
            top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.6)),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: 'Record voice note',
              onPressed: _startRecording,
              icon: const Icon(Icons.mic_none_rounded),
            ),
            Expanded(
              child: TextField(
                controller: _messageController,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: 'Write a message…',
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded),
            ),
          ],
        ),
      ),
    );
  }
}