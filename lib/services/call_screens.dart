import 'dart:async';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'call_manager.dart';
import 'chat_service.dart';
import 'firebase_messaging_service.dart';

const _bg = Color(0xFF0F1B2D);

/// Configure audio routing for calls on Android.
///
/// NOTE: we deliberately do NOT call `SystemChannels.platform.invokeMethod`
/// here. There is no `AudioManager.setMode` handler on that channel, so the
/// call always throws MissingPluginException — and because it sat inside the
/// same try block as `setSpeakerphoneOn`, the throw skipped the speakerphone
/// call entirely. flutter_webrtc puts the device into MODE_IN_COMMUNICATION
/// itself once an audio track is added, so all we need is speaker routing.
Future<void> _configureAudioSession({required bool speaker}) async {
  try {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    await Helper.setSpeakerphoneOn(speaker);
  } catch (e) {
    debugPrint('audio session setup failed: $e');
  }
}

/// Different realtime versions hand back either the payload itself or a
/// wrapper {event, payload, type}. Accept both.
Map<String, dynamic> _unwrap(Map<String, dynamic> p) {
  final inner = p['payload'];
  if (inner is Map && p.containsKey('event')) {
    return Map<String, dynamic>.from(inner);
  }
  return p;
}

String _initial(String name) =>
    name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

String _clock(int seconds) {
  final m = (seconds ~/ 60).toString().padLeft(2, '0');
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

// ---------------------------------------------------------------------------
// Incoming call: Accept / Decline
// ---------------------------------------------------------------------------

class IncomingCallScreen extends StatefulWidget {
  final CallInfo call;
  const IncomingCallScreen({super.key, required this.call});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  String _name = 'Someone';
  CallWatcher? _watcher;
  Timer? _ring;
  Timer? _giveUp;
  bool _handedOff = false;
  bool _closed = false;
  bool _released = false;

  @override
  void initState() {
    super.initState();
    _loadName();
    _watcher = CallWatcher(widget.call.id, 'ringing', (status) {
      if (status != 'ringing') _close();
    });
    _ring = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
    });
    _giveUp = Timer(const Duration(seconds: kRingSeconds + 5), _close);
  }

  Future<void> _loadName() async {
    try {
      final row = await callDb
          .from('profiles')
          .select('display_name')
          .eq('id', widget.call.callerId)
          .maybeSingle();
      final n = row?['display_name'];
      if (n is String && n.isNotEmpty && mounted) setState(() => _name = n);
    } catch (_) {}
  }

  void _stopRinging() {
    _ring?.cancel();
    _giveUp?.cancel();
    // Also withdraw the system notification so the phone stops ringing.
    try {
      AwesomeNotifications().cancel(7001);
    } catch (_) {}
  }

  void _release() {
    if (_released) return;
    _released = true;
    CallManager.instance.release();
  }

  void _close() {
    if (_closed || _handedOff) return;
    _closed = true;
    _stopRinging();
    _watcher?.dispose();
    _release();
    if (mounted) Navigator.of(context).pop();
  }

  void _accept() {
    if (_closed || _handedOff) return;
    _handedOff = true;
    _stopRinging();
    _watcher?.dispose();
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => CallScreen(
        callId: widget.call.id,
        isCaller: false,
        otherUserId: widget.call.callerId,
        otherName: _name,
        conversationId: widget.call.conversationId,
        video: widget.call.isVideo,
      ),
    ));
  }

  void _decline() {
    unawaited(CallManager.instance.setStatus(widget.call.id, 'declined'));
    _close();
  }

  @override
  void dispose() {
    _stopRinging();
    _watcher?.dispose();
    if (!_handedOff) _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _decline();
      },
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),
              CircleAvatar(
                radius: 56,
                backgroundColor: const Color(0xFF2457C5),
                child: Text(_initial(_name),
                    style: const TextStyle(
                        fontSize: 44,
                        color: Colors.white,
                        fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 24),
              Text(_name,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                widget.call.isVideo
                    ? 'Incoming video call'
                    : 'Incoming voice call',
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const Spacer(flex: 3),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 56),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _RoundButton(
                      icon: Icons.call_end,
                      label: 'Decline',
                      color: Colors.red,
                      size: 68,
                      onTap: _decline,
                    ),
                    _RoundButton(
                      icon: widget.call.isVideo ? Icons.videocam : Icons.call,
                      label: 'Accept',
                      color: Colors.green,
                      size: 68,
                      onTap: _accept,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 56),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The call itself (used by both the caller and the person answering)
// ---------------------------------------------------------------------------

enum _Phase { starting, ringing, connecting, connected, ended }

class CallScreen extends StatefulWidget {
  /// null when we are the caller and the call has not been created yet.
  final String? callId;
  final bool isCaller;
  final String otherUserId;
  final String otherName;
  final String conversationId;
  final bool video;

  const CallScreen({
    super.key,
    required this.callId,
    required this.isCaller,
    required this.otherUserId,
    required this.otherName,
    required this.conversationId,
    required this.video,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  RealtimeChannel? _signal;
  CallWatcher? _watcher;
  String? _callId;

  final List<RTCIceCandidate> _pendingIce = [];
  Timer? _ringTimeout;
  Timer? _tick;
  Timer? _disconnectTimer;
  Timer? _offerRetry;
  Timer? _connectTimeout;
  RTCSessionDescription? _offer;
  RTCSessionDescription? _answer;
  int _offerSends = 0;

  /// Every ICE candidate we have gathered, kept so it can be REPLAYED.
  ///
  /// Supabase broadcast messages are ephemeral: they are delivered only to
  /// clients subscribed at that instant, and are NOT buffered for a late
  /// joiner. When the callee's app is killed and relaunched from the incoming
  /// call notification, it subscribes to `call-signal:<id>` *after* the caller
  /// has already broadcast its candidates -- so every one of them is lost.
  ///
  /// The offer survived that gap only because it is resent on a timer. ICE
  /// candidates were not, which is why a call to a backgrounded/killed app
  /// rang and showed the caller but never carried voice: the offer arrived,
  /// the TURN relay candidates did not, and ICE had no route to complete.
  ///
  /// Buffering them and replaying the full bundle with every resend makes the
  /// handshake idempotent, so whoever subscribes last still gets everything.
  final List<Map<String, dynamic>> _localIce = [];

  /// Remote candidates we have already consumed, keyed for dedupe. Replaying
  /// the ICE bundle is intentional, so duplicates are expected and must be
  /// ignored rather than thrown on.
  final Set<String> _remoteIceKeys = {};

  _Phase _phase = _Phase.starting;
  String _statusText = 'Starting…';
  bool _remoteSet = false;
  bool _offered = false;
  bool _gotOffer = false;
  bool _closing = false;
  bool _released = false;
  bool _rendererReady = false;
  bool _muted = false;
  bool _speaker = false;
  bool _camOff = false;
  bool _hasRemoteVideo = false;
  int _remoteAudioTracks = 0;
  int _seconds = 0;
  String _iceState = 'new';

  @override
  void initState() {
    super.initState();
    _callId = widget.callId;
    _speaker = widget.video;
    _init();
  }

  // ---------- setup ----------

  Future<void> _init() async {
    try {
      // Configure audio routing for this call.
      await _configureAudioSession(speaker: _speaker);

      await _localRenderer.initialize();
      await _remoteRenderer.initialize();
      _rendererReady = true;

      final perms = await [
        Permission.microphone,
        if (widget.video) Permission.camera,
      ].request();
      if (perms.values.any((s) => !s.isGranted)) {
        _abort(widget.video
            ? 'Allow microphone and camera access in Settings to make video calls.'
            : 'Allow microphone access in Settings to make calls.');
        return;
      }
      if (_closing) return;

      await _prepareMedia();
      if (_closing) return;

      if (widget.isCaller) {
        final row = await callDb
            .from('calls')
            .insert({
              'conversation_id': widget.conversationId,
              'callee_id': widget.otherUserId,
              'media': widget.video ? 'video' : 'audio',
            })
            .select()
            .single();
        _callId = row['id'] as String;
        CallManager.instance.currentCallId = _callId;
        if (_closing) {
          // The caller hung up while the call was still being created.
          unawaited(CallManager.instance.hangUp(_callId!, isCaller: true));
          return;
        }

        unawaited(_sendCallPushNotification(
          calleeId: widget.otherUserId,
          callId: _callId!,
          conversationId: widget.conversationId,
          isVideo: widget.video,
        ));

        await _openSignal();
        _watcher = CallWatcher(_callId!, 'ringing', _onStatus);
        _setPhase(_Phase.ringing, 'Ringing…');
        _ringTimeout = Timer(const Duration(seconds: kRingSeconds), () {
          if (_phase == _Phase.ringing) {
            unawaited(CallManager.instance.setStatus(_callId!, 'missed'));
            _finish('No answer');
          }
        });
      } else {
        // Get ready to receive the offer BEFORE telling the caller we answered.
        await _openSignal();
        _watcher = CallWatcher(_callId!, 'ringing', _onStatus);
        final res = await callDb
            .from('calls')
            .update({'status': 'accepted'})
            .eq('id', _callId!)
            .select('status')
            .single();
        if (res['status'] != 'accepted') {
          _finish('Call ended');
          return;
        }
        _setPhase(_Phase.connecting, 'Connecting…');
      }
    } catch (e) {
      debugPrint('call setup failed: $e');
      _abort('Could not start the call. Check your connection and try again.');
    }
  }

  Future<void> _prepareMedia() async {
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': widget.video ? {'facingMode': 'user'} : false,
    });
    _localStream = stream;
    _localRenderer.srcObject = stream;

    // Ensure audio track is enabled and not muted
    for (final track in stream.getAudioTracks()) {
      track.enabled = true;
    }

    final pc = await createPeerConnection({
      'iceServers': kIceServers,
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;

    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }

    pc.onIceCandidate = (RTCIceCandidate c) {
      final cand = c.candidate;
      if (cand == null) return;
      final payload = <String, dynamic>{
        't': 'ice',
        'candidate': cand,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      };
      // Buffer first so a later resend can replay it to a peer that was not
      // listening when this candidate was originally produced.
      _localIce.add(payload);
      _sendSignal(payload);
    };

    // ICE diagnostics. "Connecting…" hanging forever is almost always ICE
    // failing to find a route between the two networks, so log every state.
    pc.onIceGatheringState = (RTCIceGatheringState s) {
      debugPrint('[call] ICE gathering: $s');
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        debugPrint('[call] ICE gathering complete');
      }
    };

    pc.onIceConnectionState = (RTCIceConnectionState s) {
      debugPrint('[call] ICE connection: $s');
      setState(() => _iceState = s.name);
    };

    pc.onSignalingState = (RTCSignalingState s) {
      debugPrint('[call] signaling state: $s');
    };

    pc.onTrack = (RTCTrackEvent e) {
      debugPrint('[call] onTrack kind=${e.track.kind}');
      // Android can hand over a remote audio track that is still flagged
      // muted; unmuting here is what makes the other person audible.
      if (e.track.kind == 'audio') {
        e.track.enabled = true;
        unawaited(_enableRemoteAudio());
      }
      if (e.streams.isNotEmpty) {
        _remoteRenderer.srcObject = e.streams.first;
      }
      if (!mounted) return;
      setState(() {
        if (e.track.kind == 'video') _hasRemoteVideo = true;
        if (e.track.kind == 'audio') _remoteAudioTracks++;
      });
    };

    pc.onConnectionState = (RTCPeerConnectionState s) {
      if (_closing) return;
      switch (s) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _disconnectTimer?.cancel();
          _onConnected();
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          if (mounted) setState(() => _statusText = 'Reconnecting…');
          _disconnectTimer?.cancel();
          _disconnectTimer = Timer(const Duration(seconds: 15), () {
            _endBecause('Connection lost');
          });
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _endBecause('Could not connect. Check your internet and try again.');
          break;
        default:
          break;
      }
    };
  }

  Future<void> _openSignal() async {
    final ready = Completer<void>();
    final ch = callDb.channel('call-signal:$_callId');
    ch.onBroadcast(
      event: 'signal',
      callback: (payload) => _onSignal(_unwrap(payload)),
    );
    ch.subscribe((status, error) {
      if (status == RealtimeSubscribeStatus.subscribed && !ready.isCompleted) {
        ready.complete();
      } else if ((status == RealtimeSubscribeStatus.channelError ||
              status == RealtimeSubscribeStatus.timedOut) &&
          !ready.isCompleted) {
        ready.completeError(error ?? 'channel error');
      }
    });
    _signal = ch;
    await ready.future.timeout(const Duration(seconds: 10));
  }

  // ---------- call state ----------

  void _onStatus(String status) {
    if (_closing) return;
    switch (status) {
      case 'accepted':
        if (widget.isCaller && !_offered) {
          _ringTimeout?.cancel();
          _setPhase(_Phase.connecting, 'Connecting…');
          _makeOffer();
        }
        break;
      case 'ringing':
        break;
      case 'declined':
        _finish('Call declined');
        break;
      case 'missed':
        _finish('No answer');
        break;
      case 'cancelled':
        _finish('Call cancelled');
        break;
      default:
        _finish('Call ended');
    }
  }

  void _onConnected() {
    if (_phase == _Phase.connected) return;
    debugPrint('[call] CONNECTED (ice=$_iceState)');
    _ringTimeout?.cancel();
    _offerRetry?.cancel();
    _connectTimeout?.cancel();
    _tick?.cancel();
    _seconds = 0;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });

    // Ensure audio is routed correctly on Android. Video calls default to the
    // speaker; voice calls default to the earpiece.
    unawaited(Helper.setSpeakerphoneOn(_speaker));

    // Re-enable our own capture track in case a toggle muted it earlier.
    for (final track
        in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !_muted;
    }

    // Unmute the remote audio and count how many tracks actually arrived.
    //
    // NOTE: this used to read `_pc?.getRemoteStreams().first?.getAudioTracks()`.
    // `getRemoteStreams()` was REMOVED in flutter_webrtc 1.6.x (this project
    // pins 1.6.2), so that never compiled. The replacement is `getReceivers()`,
    // and each receiver's `track` is nullable -- it is null until the track is
    // attached, which is exactly why the old `.first` on an empty list threw
    // and pinned the UI on "Connecting…" forever. So: await the receivers and
    // null-check every track.
    unawaited(_enableRemoteAudio());

    _setPhase(_Phase.connected, 'Connected');
  }

  /// Unmutes every remote audio track and records how many there were.
  Future<void> _enableRemoteAudio() async {
    var count = 0;
    try {
      final pc = _pc;
      if (pc == null) return;
      final receivers = await pc.getReceivers();
      for (final r in receivers) {
        final track = r.track;
        if (track == null) continue;
        if (track.kind != 'audio') continue;
        track.enabled = true;
        count++;
      }
    } catch (e) {
      debugPrint('[call] remote audio setup failed: $e');
    }
    debugPrint('[call] CONNECTED remote audio tracks=$count');
    if (mounted) setState(() => _remoteAudioTracks = count);
  }

  void _setPhase(_Phase p, String text) {
    if (!mounted) return;
    setState(() {
      _phase = p;
      _statusText = text;
    });

    // Once we are trying to connect, bound the wait. Without this the screen
    // can sit on "Connecting…" forever when ICE cannot find a route.
    if (p == _Phase.connecting) {
      _connectTimeout?.cancel();
      _connectTimeout = Timer(const Duration(seconds: 30), () {
        if (_closing || _phase == _Phase.connected) return;
        _endBecause(
          'Could not connect. Your networks may block direct calls.',
        );
      });
    }
  }

  // ---------- WebRTC signalling ----------

  Future<void> _sendSignal(Map<String, dynamic> data) async {
    try {
      await _signal?.sendBroadcastMessage(event: 'signal', payload: data);
    } catch (_) {}
  }

  Future<void> _makeOffer() async {
    _offered = true;
    try {
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      _offer = offer;
      await _sendOffer();
      // Resend the offer a few times in case the first one is lost.
      _offerRetry = Timer.periodic(const Duration(seconds: 4), (t) {
        if (_remoteSet || _closing || _offerSends >= 5) {
          t.cancel();
          return;
        }
        _sendOffer();
      });
    } catch (_) {
      _endBecause('Could not connect the call.');
    }
  }

  Future<void> _sendOffer() async {
    final o = _offer;
    if (o == null) return;
    _offerSends++;
    debugPrint('[call] sending OFFER (attempt $_offerSends)');
    await _sendSignal({'t': 'offer', 'sdp': o.sdp, 'type': o.type});
    // Replay every candidate gathered so far. The offer alone is not enough:
    // ICE needs the remote candidates too, and they are exactly what a
    // late-joining (cold-started) peer would otherwise miss.
    await _replayIce();
  }

  /// Re-sends all buffered local ICE candidates.
  Future<void> _replayIce() async {
    for (final c in List<Map<String, dynamic>>.from(_localIce)) {
      await _sendSignal(c);
    }
  }

  Future<void> _onSignal(Map<String, dynamic> m) async {
    if (_closing || _pc == null) return;
    try {
      switch (m['t']) {
        case 'offer':
          debugPrint('[call] received OFFER');
          if (!widget.isCaller) await _onOffer(m);
          break;
        case 'answer':
          debugPrint('[call] received ANSWER');
          if (widget.isCaller) await _onAnswer(m);
          break;
        case 'ice':
          await _onIce(m);
          break;
      }
    } catch (e) {
      debugPrint('signal error: $e');
    }
  }

  Future<void> _onOffer(Map<String, dynamic> m) async {
    // A repeated offer means the caller never got our answer (it subscribed
    // late, or the broadcast was dropped). Re-send the answer we already made
    // rather than renegotiating -- renegotiating would tear down the call that
    // is already working.
    if (_gotOffer) {
      debugPrint('[call] duplicate OFFER, re-sending ANSWER');
      final a = _answer;
      if (a != null) {
        await _sendSignal({'t': 'answer', 'sdp': a.sdp, 'type': a.type});
        await _replayIce();
      }
      return;
    }
    _gotOffer = true;
    await _pc!.setRemoteDescription(
        RTCSessionDescription(m['sdp'] as String?, m['type'] as String?));
    await _flushIce();
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    _answer = answer;
    await _sendSignal({'t': 'answer', 'sdp': answer.sdp, 'type': answer.type});
    // Same reasoning as the offer: replay our candidates so the caller, which
    // may have subscribed before we gathered any, ends up with all of them.
    await _replayIce();
  }

  Future<void> _onAnswer(Map<String, dynamic> m) async {
    if (_remoteSet) return;
    await _pc!.setRemoteDescription(
        RTCSessionDescription(m['sdp'] as String?, m['type'] as String?));
    await _flushIce();
    await _replayIce();
  }

  Future<void> _sendCallPushNotification({
    required String calleeId,
    required String callId,
    required String conversationId,
    required bool isVideo,
  }) async {
    try {
      final me = callDb.auth.currentUser?.id;
      var callerName = 'Someone';
      if (me != null) {
        final profile = await ChatService.instance.myProfile();
        callerName = profile?.displayName ?? profile?.username ?? 'Someone';
      }
      final callType = isVideo ? 'Incoming video call' : 'Incoming voice call';
      await FirebaseMessagingService.sendPushNotification(
        recipientUserId: calleeId,
        title: callType,
        body: '$callerName is calling you',
        data: {
          'conversation_id': conversationId,
          'caller_id': me ?? '',
          'call_id': callId,
          'type': isVideo ? 'video_call' : 'voice_call',
        },
      );
    } catch (e) {
      debugPrint('Call push notification failed: $e');
    }
  }

  Future<void> _onIce(Map<String, dynamic> m) async {
    final cand = RTCIceCandidate(
      m['candidate'] as String?,
      m['sdpMid'] as String?,
      (m['sdpMLineIndex'] as num?)?.toInt(),
    );

    // Replaying the bundle means the SAME candidate legitimately arrives more
    // than once, and addCandidate throws on a duplicate. Remember what we
    // have already added so a replay is a no-op instead of an error.
    final key = '${cand.sdpMid}|${cand.sdpMLineIndex}|${cand.candidate}';
    if (!_remoteIceKeys.add(key)) return;

    if (_remoteSet) {
      try {
        await _pc?.addCandidate(cand);
      } catch (e) {
        debugPrint('[call] addCandidate failed: $e');
      }
    } else {
      _pendingIce.add(cand);
    }
  }

  Future<void> _flushIce() async {
    _remoteSet = true;
    for (final c in List<RTCIceCandidate>.from(_pendingIce)) {
      try {
        await _pc!.addCandidate(c);
      } catch (_) {}
    }
    _pendingIce.clear();
  }

  // ---------- leaving ----------

  /// The red button. Closes the screen at once, whatever the network is doing,
  /// and tells the other person in the background.
  void _hangUp() {
    if (_closing) return;
    final id = _callId;
    if (id != null) {
      unawaited(CallManager.instance.hangUp(id, isCaller: widget.isCaller));
    }
    _finish(null);
  }

  void _endBecause(String message) {
    if (_closing) return;
    final id = _callId;
    if (id != null) {
      unawaited(CallManager.instance.hangUp(id, isCaller: widget.isCaller));
    }
    _finish(message);
  }

  void _abort(String message) {
    _endBecause(message);
  }

  void _finish(String? message) {
    if (_closing) return;
    _closing = true;
    _cleanup();
    if (message == null) {
      _pop();
      return;
    }
    if (mounted) {
      setState(() {
        _phase = _Phase.ended;
        _statusText = message;
      });
    }
    Future.delayed(const Duration(milliseconds: 1500), _pop);
  }

  void _pop() {
    if (!_released) {
      _released = true;
      CallManager.instance.release();
    }
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  void _cleanup() {
    _ringTimeout?.cancel();
    _tick?.cancel();
    _disconnectTimer?.cancel();
    _offerRetry?.cancel();
    _connectTimeout?.cancel();
    _watcher?.dispose();
    _watcher = null;
    final ch = _signal;
    if (ch != null) callDb.removeChannel(ch);
    _signal = null;
    final stream = _localStream;
    if (stream != null) {
      for (final t in stream.getTracks()) {
        unawaited(t.stop());
      }
      unawaited(stream.dispose());
    }
    _localStream = null;
    final pc = _pc;
    if (pc != null) unawaited(pc.close());
    _pc = null;
  }

  @override
  void dispose() {
    _closing = true;
    _cleanup();
    if (!_released) {
      _released = true;
      CallManager.instance.release();
    }
    if (_rendererReady) {
      _localRenderer.srcObject = null;
      _remoteRenderer.srcObject = null;
      _localRenderer.dispose();
      _remoteRenderer.dispose();
    }
    super.dispose();
  }

  // ---------- controls ----------

  void _toggleMute() {
    setState(() => _muted = !_muted);
    for (final t in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !_muted;
    }
  }

  void _toggleSpeaker() {
    setState(() => _speaker = !_speaker);
    unawaited(Helper.setSpeakerphoneOn(_speaker));
  }

  void _toggleCamera() {
    setState(() => _camOff = !_camOff);
    for (final t in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !_camOff;
    }
  }

  void _switchCamera() {
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isNotEmpty) unawaited(Helper.switchCamera(tracks.first));
  }

  // ---------- UI ----------

  String get _subtitle =>
      _phase == _Phase.connected ? _clock(_seconds) : _statusText;

  /// Small diagnostic line, shown while connecting. Makes it possible to tell
  /// "the other side never sent an offer" from "ICE could not find a route"
  /// without attaching a debugger.
  String get _diagnostic {
    if (_phase != _Phase.connecting) return '';
    final parts = <String>[];
    parts.add('ice: $_iceState');
    if (widget.isCaller) {
      parts.add(_offered ? 'offer sent' : 'no offer yet');
    } else {
      parts.add(_gotOffer ? 'offer received' : 'no offer yet');
    }
    if (_remoteSet) parts.add('remote set');
    parts.add('audio: $_remoteAudioTracks');
    return parts.join('  •  ');
  }

  @override
  Widget build(BuildContext context) {
    final ended = _phase == _Phase.ended;
    final showRemoteVideo = widget.video && _hasRemoteVideo && !ended;
    final showLocalVideo = widget.video && !_camOff && !ended;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _hangUp();
      },
      child: Scaffold(
        backgroundColor: _bg,
        body: Stack(
          children: [
            if (showRemoteVideo)
              Positioned.fill(
                child: RTCVideoView(
                  _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              )
            else if (widget.video == false && !ended && _remoteRenderer.srcObject != null)
              // Audio-only call: we still need an RTCVideoView to render the
              // remote audio track. Make it invisible (zero size) but present
              // in the tree so the audio plays.
              Positioned(
                left: -1,
                top: -1,
                width: 1,
                height: 1,
                child: Opacity(
                  opacity: 0,
                  child: RTCVideoView(
                    _remoteRenderer,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            if (showRemoteVideo)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.otherName,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold)),
                        Text(_subtitle,
                            style: const TextStyle(color: Colors.white70)),
                      ],
                    ),
                  ),
                ),
              )
            else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 56,
                      backgroundColor: const Color(0xFF2457C5),
                      child: Text(_initial(widget.otherName),
                          style: const TextStyle(
                              fontSize: 44,
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 24),
                    Text(widget.otherName,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(_subtitle,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 16)),
                    ),
                    if (_diagnostic.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(_diagnostic,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 11,
                                letterSpacing: 0.2)),
                      ),
                    ],
                  ],
                ),
              ),
            if (showLocalVideo)
              Positioned(
                top: 56,
                right: 16,
                width: 110,
                height: 150,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: RTCVideoView(
                    _localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _RoundButton(
                            icon: _muted ? Icons.mic_off : Icons.mic,
                            label: _muted ? 'Unmute' : 'Mute',
                            color: _muted ? Colors.white : Colors.white24,
                            iconColor: _muted ? _bg : Colors.white,
                            onTap: _toggleMute,
                          ),
                          _RoundButton(
                            icon:
                                _speaker ? Icons.volume_up : Icons.volume_down,
                            label: 'Speaker',
                            color: _speaker ? Colors.white : Colors.white24,
                            iconColor: _speaker ? _bg : Colors.white,
                            onTap: _toggleSpeaker,
                          ),
                          if (widget.video)
                            _RoundButton(
                              icon:
                                  _camOff ? Icons.videocam_off : Icons.videocam,
                              label: _camOff ? 'Camera on' : 'Camera',
                              color: _camOff ? Colors.white : Colors.white24,
                              iconColor: _camOff ? _bg : Colors.white,
                              onTap: _toggleCamera,
                            ),
                          if (widget.video)
                            _RoundButton(
                              icon: Icons.cameraswitch,
                              label: 'Flip',
                              color: Colors.white24,
                              onTap: _switchCamera,
                            ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      _RoundButton(
                        icon: Icons.call_end,
                        label: ended ? '' : 'End',
                        color: Colors.red,
                        size: 68,
                        onTap: _hangUp,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color iconColor;
  final double size;
  final VoidCallback onTap;

  const _RoundButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.iconColor = Colors.white,
    this.size = 56,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, color: iconColor, size: size * 0.45),
            ),
          ),
        ),
        if (label.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ],
    );
  }
}
