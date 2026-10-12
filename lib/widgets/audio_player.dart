import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../models/models.dart';
import 'common.dart';

/// Plays a voice note with a seek bar.
///
/// Each instance owns its own [AudioPlayer]; the screen disposes it when the
/// bubble leaves the tree.
class VoiceNotePlayer extends StatefulWidget {
  final String url;
  final int? durationMs;
  final Color accent;
  final Color onAccent;

  const VoiceNotePlayer({
    super.key,
    required this.url,
    this.durationMs,
    required this.accent,
    required this.onAccent,
  });

  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer> {
  late final AudioPlayer _player;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _init();
  }

  Future<void> _init() async {
    try {
      // just_audio needs a server for remote audio; a public Supabase URL
      // serves the right MIME type so this works directly.
      final dur = await _player.setUrl(widget.url);
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
      if (dur == null && widget.durationMs == null) {
        // Fall back to the duration we stored at record time.
        _player.setLoopMode(LoopMode.off);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }

    _player.playerStateStream.listen((s) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
    }
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_failed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: widget.onAccent),
          const SizedBox(width: 8),
          Text(
            'Could not load audio',
            style: TextStyle(color: widget.onAccent, fontSize: 13),
          ),
        ],
      );
    }

    final isPlaying = _player.playing;
    final position = _player.position;
    final total = _player.duration ??
        Duration(milliseconds: widget.durationMs ?? 0);

    // Progress as a fraction; guard against divide-by-zero.
    final progress = total.inMilliseconds == 0
        ? 0.0
        : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

    return SizedBox(
      width: 210,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InkWell(
                onTap: _toggle,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  height: 38,
                  width: 38,
                  decoration: BoxDecoration(
                    color: widget.onAccent.withValues(alpha: 0.22),
                    shape: BoxShape.circle,
                  ),
                  child: _loading
                      ? Padding(
                          padding: const EdgeInsets.all(10),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: widget.onAccent,
                          ),
                        )
                      : Icon(
                          isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: widget.onAccent,
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    backgroundColor: widget.onAccent.withValues(alpha: 0.25),
                    valueColor: AlwaysStoppedAnimation(widget.onAccent),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatDuration(
                  isPlaying || position > Duration.zero
                      ? total.inMilliseconds - position.inMilliseconds
                      : total.inMilliseconds,
                ),
                style: TextStyle(
                  color: widget.onAccent.withValues(alpha: 0.85),
                  fontSize: 11,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (_loading)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 2),
              child: Text(
                'Loading audio…',
                style: TextStyle(
                  color: widget.onAccent.withValues(alpha: 0.7),
                  fontSize: 11,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Floating "recording" panel: timer, waveform-ish level meter, cancel/send.
class RecordingBar extends StatelessWidget {
  final Duration elapsed;
  final bool cancelling;
  final double level; // 0..1
  final VoidCallback onCancel;
  final Future<void> Function() onStop;

  const RecordingBar({
    super.key,
    required this.elapsed,
    required this.cancelling,
    required this.level,
    required this.onCancel,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final danger = theme.colorScheme.error;

    return Container(
      color: theme.scaffoldBackgroundColor,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          IconButton.filledTonal(
            onPressed: cancelling ? null : onCancel,
            style: IconButton.styleFrom(
              backgroundColor: danger.withValues(alpha: 0.12),
              foregroundColor: danger,
            ),
            icon: const Icon(Icons.delete_outline_rounded),
            tooltip: 'Discard',
          ),
          const SizedBox(width: 12),
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: danger,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${elapsed.inMinutes}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                // A crude level meter; smooths jitter from the recorder.
                value: level.clamp(0.02, 1.0),
                minHeight: 5,
                backgroundColor: danger.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation(danger),
              ),
            ),
          ),
          const SizedBox(width: 12),
          IconButton.filled(
            onPressed: cancelling ? null : onStop,
            style: IconButton.styleFrom(backgroundColor: theme.colorScheme.primary),
            icon: cancelling
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_rounded),
            tooltip: 'Send',
          ),
        ],
      ),
    );
  }
}