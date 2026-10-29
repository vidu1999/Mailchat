import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:mailchat/core/config/app_config.dart';
import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/features/calls/domain/call_media.dart';
import 'package:mailchat/features/calls/domain/call_model.dart';
import 'package:mailchat/features/calls/domain/call_service.dart';
import 'package:mailchat/features/calls/domain/ice_path.dart';

/// A call in progress.
///
/// Owns the whole negotiation for **both** roles, because the order is what
/// matters and splitting it across two screens is how it goes wrong:
///
/// ```text
/// caller: prepare media → offer  → placeCall(offer_sdp)
/// callee: prepare media → answer → accept(answer_sdp)
/// both:   watch the call row and the candidate table; feed each other's ICE
/// ```
///
/// Media is prepared *before* the call row exists (caller) or before the accept
/// is written (callee), so a refused microphone never rings anybody. Every
/// failure ends up on screen as [CallMediaStage.failed] — this screen never
/// pretends a call is connected.
class ActiveCallScreen extends StatefulWidget {
  final Map<String, dynamic>? arguments;

  const ActiveCallScreen({super.key, this.arguments});

  @override
  State<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends State<ActiveCallScreen> {
  final CallService _calls = CallService();
  final CallMedia _media = CallMedia();

  late final String _selfId;
  late final String _peerName;
  late final bool _isVideo;
  late final bool _isCaller;
  late final String _conversationId;
  late final String _peerId;
  String? _callId;

  CallMediaStage _stage = CallMediaStage.idle;
  Call? _call;
  String? _error;
  bool _micOn = true;
  bool _cameraOn = true;
  bool _finishing = false;
  VoidCallback? _onActiveCallClosed;

  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  /// How long this call has been waiting for a peer connection, and whether it
  /// has waited long enough to say something about it.
  ///
  /// A call that cannot connect otherwise sits on "Connecting..." forever, which
  /// the user reads as the app being broken rather than the network refusing to
  /// pass media. Fifteen seconds is past every normal ICE exchange.
  Duration _waited = Duration.zero;
  bool _slowConnect = false;
  static const Duration _slowConnectAfter = Duration(seconds: 15);

  StreamSubscription<Call>? _callEvents;
  StreamSubscription<Map<String, dynamic>>? _candidateEvents;

  /// Realtime can miss the accept, or deliver ICE before the answer is applied.
  /// Polling the row and the candidate table is what makes a call connect when
  /// the socket is late — which is the usual case on a flaky mobile network.
  Timer? _syncTimer;
  bool _answerApplied = false;
  bool _syncFailureLogged = false;
  final Set<String> _seenRemote = <String>{};

  @override
  void initState() {
    super.initState();
    final args = widget.arguments ?? const <String, dynamic>{};
    _selfId = (args['selfId'] as String?) ??
        (SupabaseClient.instance.userId ?? '');
    _peerName = (args['peerName'] as String?) ?? 'Unknown';
    _peerId = (args['peerId'] as String?) ?? '';
    _isVideo = (args['isVideo'] as bool?) ?? false;
    _isCaller = (args['isCaller'] as bool?) ?? true;
    _conversationId = (args['conversationId'] as String?) ?? '';
    _callId = args['callId'] as String?;
    final onActiveCallClosed = args['onActiveCallClosed'];
    if (onActiveCallClosed is VoidCallback) {
      _onActiveCallClosed = onActiveCallClosed;
    }
    _start();
  }

  Future<void> _start() async {
    setState(() => _stage = CallMediaStage.preparing);
    _media.onPathChanged = (_) {
      if (mounted) setState(() {});
    };
    try {
      if (!_isCaller) {
        // The callee needs the caller's offer before it can answer at all.
        if (_callId == null || _callId!.isEmpty) {
          throw AppException('That call is no longer available.');
        }
        final pending = await _calls.fetch(_callId!);
        if (pending == null) {
          throw AppException('That call is no longer available.');
        }
        if (pending.state != CallState.ringing) {
          throw AppException('That call was already ${pending.state.label.toLowerCase()}.');
        }
        _call = pending;

        await _media.initialise(video: _isVideo);
        var offer = pending.offerSdp ?? '';
        if (sdpForInterop(offer).isEmpty) {
          // The ring can arrive before the offer write is visible. One more
          // read, then stop — an empty description is what Android reports
          // as "SessionDescription is NULL".
          final again = await _calls.fetch(_callId!);
          offer = again?.offerSdp ?? offer;
        }
        if (sdpForInterop(offer).isEmpty) {
          throw AppException(
            'The caller did not send an offer, so this call cannot connect.',
          );
        }
        final answer = await _media.createAnswer(offer);
        _call = await _calls.accept(_callId!, answerSdp: answer);
      } else {
        await _media.initialise(video: _isVideo);
        final offer = await _media.createOffer();
        if (sdpForInterop(offer).isEmpty) {
          throw AppException(
            'This phone could not build a call description. Call again.',
          );
        }
        _call = await _calls.placeCall(
          conversationId: _conversationId,
          callerId: _selfId,
          calleeId: _peerId,
          isVideo: _isVideo,
          offerSdp: offer,
        );
        _callId = _call!.id;
      }

      if (!mounted) return;
      setState(() {
        _stage = CallMediaStage.connecting;
        _callId = _call?.id ?? _callId;
      });
      _wireChannels();
      _startTicker();
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'call_start'});
      if (!mounted) return;
      setState(() {
        _stage = CallMediaStage.failed;
        _error = e is AppException ? e.message : friendlyCallFailure(e);
      });
      await _media.dispose();
    }
  }

  void _wireChannels() {
    final callId = _callId;
    if (callId == null) return;

    _media.listenForLocalCandidates((candidate) {
      final value = candidate.candidate;
      if (value == null || value.isEmpty) return;
      // Fired and forgotten: a lost candidate is recoverable (ICE retries with
      // the others), and blocking the media pipeline on a database write is not.
      _logOnly(
        _calls.sendIceCandidate(
          callId: callId,
          senderId: _selfId,
          candidate: value,
          sdpMid: candidate.sdpMid,
          sdpMlineIndex: candidate.sdpMLineIndex,
        ),
        'call_ice_send',
      );
    });

    _media.onRemoteStream = (_) {
      if (mounted) setState(() {});
    };

    _media.onConnectionState = (state) {
      if (!mounted) return;
      final stage = stageFromPeerState(state);
      // ICE can report connected before the peer-connection state does. A
      // later "connecting" from the slower callback must not put the screen
      // back on "Connecting..." for a call that is already up.
      if (_stage == CallMediaStage.connected &&
          stage == CallMediaStage.connecting) {
        return;
      }
      setState(() {
        _stage = stage;
        if (stage == CallMediaStage.connected) {
          // Connected, then momentarily disconnected and reconnecting is a
          // blip, not a call that never connected: restart the wait so the
          // "still not connected" hint does not fire on the first wobble.
          _waited = Duration.zero;
          _slowConnect = false;
          _syncTimer?.cancel();
        }
      });
    };

    _calls.watchCall(callId);

    _callEvents = _calls.callUpdates.listen((call) {
      unawaited(_handleCallUpdate(call));
    });

    _candidateEvents = _calls.candidateUpdates.listen((row) {
      unawaited(_takeCandidate(row));
    });

    // Immediate, then every two seconds. The first poll is what recovers an
    // accept that happened before this subscription existed.
    unawaited(_syncSignalling());
    _syncTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_syncSignalling());
    });
  }

  Future<void> _handleCallUpdate(Call call) async {
    if (!mounted || call.id != _callId) return;
    setState(() => _call = call);

    if (call.state == CallState.ongoing) {
      final answer = call.answerSdp ?? '';
      if (_isCaller && answer.isNotEmpty && !_answerApplied) {
        _answerApplied = true;
        try {
          await _media.applyAnswer(answer);
          if (mounted) setState(() {});
        } catch (e, st) {
          _answerApplied = false;
          AppLogger.error(e, st, {'where': 'call_apply_answer'});
          if (mounted) {
            setState(() {
              _stage = CallMediaStage.failed;
              _error = e is AppException ? e.message : friendlyCallFailure(e);
            });
          }
        }
      }
    } else if (call.state.isTerminal) {
      if (mounted && _stage != CallMediaStage.ended) {
        setState(() => _error = call.state.label);
      }
      await _finish(localEnd: false);
    }
  }

  Future<void> _syncSignalling() async {
    final callId = _callId;
    if (callId == null || _finishing || !mounted) return;
    if (_stage == CallMediaStage.connected ||
        _stage == CallMediaStage.ended ||
        _stage == CallMediaStage.failed) {
      _syncTimer?.cancel();
      return;
    }
    try {
      final call = await _calls.fetch(callId);
      if (call != null) await _handleCallUpdate(call);
      if (_finishing || !mounted) return;
      final rows = await _calls.iceCandidates(
        callId: callId,
        excludeUserId: _selfId,
      );
      for (final row in rows) {
        await _takeCandidate(row);
      }
      _syncFailureLogged = false;
    } catch (e, st) {
      if (_syncFailureLogged) return;
      _syncFailureLogged = true;
      AppLogger.warning('call_sync_failed', details: {'error': e.toString()});
      AppLogger.error(e, st, {'where': 'call_sync'});
    }
  }

  Future<void> _takeCandidate(Map<String, dynamic> row) async {
    if (row['sender_id'] == _selfId) return;
    final value = '${row['candidate']}';
    if (value.isEmpty || value == 'null' || !_seenRemote.add(value)) return;
    await _media.addRemoteCandidate(
      candidate: value,
      sdpMid: row['sdp_mid'] as String?,
      sdpMlineIndex: _asInt(row['sdp_mline_index']),
    );
  }

  /// PostgREST integers sometimes arrive as [num]. A failed cast used to drop
  /// the candidate inside the stream listener.
  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  /// Runs a best-effort write and logs a failure instead of throwing.
  ///
  /// Used from `dispose()` and from socket callbacks, where there is no caller
  /// to hand an exception to and a lost ICE candidate or end-of-call write must
  /// not become an unhandled error.
  void _logOnly(Future<dynamic> action, String where) {
    unawaited(action.then<void>(
      (_) {},
      onError: (Object e, StackTrace st) {
        AppLogger.error(e, st, {'where': where});
      },
    ));
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_stage == CallMediaStage.connected) {
        setState(() => _elapsed += const Duration(seconds: 1));
        return;
      }
      if (_stage != CallMediaStage.connecting) return;
      var crossed = false;
      setState(() {
        _waited += const Duration(seconds: 1);
        if (!_slowConnect && _waited >= _slowConnectAfter) {
          _slowConnect = true;
          crossed = true;
        }
      });
      if (crossed) {
        AppLogger.warning('call_connect_slow', details: {
          'waited_seconds': _waited.inSeconds,
          'has_relay': AppConfig.instance.hasTurnRelay,
          'has_tcp_fallback': AppConfig.instance.hasTurnFallback,
          'answer_applied': !_isCaller || _answerApplied,
          'is_caller': _isCaller,
          ..._media.path.logDetails,
        });
      }
    });
  }

  /// Ends the call exactly once, from whichever side got there first: the local
  /// hang-up button, a remote `ended`/`declined`, or an error.
  Future<void> _finish({required bool localEnd}) async {
    if (_finishing) return;
    _finishing = true;
    _ticker?.cancel();
    _syncTimer?.cancel();

    final callId = _callId;
    if (localEnd && callId != null && (_call?.state.isTerminal != true)) {
      try {
        await _calls.end(callId);
      } catch (e, st) {
        // The trigger refuses `end` on a call that never connected. Reporting
        // the failure instead keeps the row honest.
        AppLogger.error(e, st, {'where': 'call_end'});
        try {
          await _calls.reportFailure(callId);
        } catch (_) {
          // Nothing left to do: the row stays in whatever state the server has.
        }
      }
    }

    await _media.dispose();
    if (!mounted) return;
    setState(() => _stage = CallMediaStage.ended);
    if (localEnd) Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    // Leaving by the back gesture must hang up, not orphan a live call row. The
    // write is fired and forgotten: this method cannot be async, and a failure
    // is logged by CallService.
    final callId = _callId;
    if (!_finishing && callId != null && _call?.state.isTerminal != true) {
      final state = _call?.state;
      _logOnly(
        state == CallState.ongoing
            ? _calls.end(callId)
            : _calls.reportFailure(callId),
        'call_dispose_end',
      );
    }
    _ticker?.cancel();
    _syncTimer?.cancel();
    _callEvents?.cancel();
    _candidateEvents?.cancel();
    _calls.unwatchCall();
    _calls.dispose();
    _media.dispose();
    final onActiveCallClosed = _onActiveCallClosed;
    _onActiveCallClosed = null;
    onActiveCallClosed?.call();
    super.dispose();
  }

  /// What to say about a call that will not connect, if anything.
  ///
  /// The sentence names the gap (no relay, no answer, relay refused this
  /// phone, the other phone never reached it, or both did and audio is still
  /// blocked). A single "the network is blocking the call" sent people into
  /// phone settings when the missing piece was configuration.
  String? get _connectHint {
    if (_stage == CallMediaStage.ended) return null;
    // A failed ICE check can arrive before the 15-second hint. Treat that as
    // slow too, so the screen still names the gap instead of only saying
    // "Could not connect".
    final slow = _stage == CallMediaStage.failed ||
        (_slowConnect && _stage == CallMediaStage.connecting);
    return callConnectAdvice(
      hasRelay: AppConfig.instance.hasTurnRelay,
      hasTcpFallback: AppConfig.instance.hasTurnFallback,
      slow: slow,
      waitedSeconds: _slowConnectAfter.inSeconds,
      isCaller: _isCaller,
      answerApplied: _answerApplied,
      path: _media.path,
    );
  }

  String get _timerLabel {
    final minutes = _elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final connected = _stage == CallMediaStage.connected;

    return Scaffold(
      backgroundColor: colors.surface,
      body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 24),
              CircleAvatar(
                radius: 40,
                backgroundColor: colors.primaryContainer,
                child: Text(
                  _peerName.isEmpty ? '?' : _peerName.substring(0, 1).toUpperCase(),
                  style: TextStyle(
                    fontSize: 30,
                    color: colors.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _peerName,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                connected ? _timerLabel : _stage.label,
                style: TextStyle(
                  fontSize: 14,
                  color: _stage == CallMediaStage.failed
                      ? colors.error
                      : colors.onSurfaceVariant,
                ),
              ),
              if (_error == null && _connectHint != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                  child: Text(
                    _connectHint!,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: 12),
              Expanded(child: _buildVideoArea(colors)),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.error, fontSize: 13),
                  ),
                ),
            _buildControls(colors),
            const SizedBox(height: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoArea(ColorScheme colors) {
    final connected = _stage == CallMediaStage.connected;
    if (!_isVideo) {
      return Center(
        child: Icon(
          connected ? Icons.phone_in_talk_outlined : Icons.phone_outlined,
          size: 72,
          color: colors.onSurfaceVariant,
        ),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: _media.hasRemoteVideo
              ? RTCVideoView(
                  _media.remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              : Center(
                  child: Text(
                    connected ? 'Waiting for their video...' : '',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
        ),
        Positioned(
          right: 16,
          top: 16,
          width: 96,
          height: 128,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _cameraOn
                  ? RTCVideoView(
                      _media.localRenderer,
                      mirror: true,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  : Icon(Icons.videocam_off_outlined, color: colors.onSurfaceVariant),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildControls(ColorScheme colors) {
    final failed = _stage == CallMediaStage.failed;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _circleButton(
            colors,
            icon: _micOn ? Icons.mic : Icons.mic_off,
            tooltip: _micOn ? 'Mute' : 'Unmute',
            onPressed: () {
              setState(() => _micOn = !_micOn);
              unawaited(_media.setAudioEnabled(_micOn));
            },
          ),
          if (_isVideo)
            _circleButton(
              colors,
              icon: _cameraOn ? Icons.videocam : Icons.videocam_off,
              tooltip: _cameraOn ? 'Turn camera off' : 'Turn camera on',
              onPressed: () {
                setState(() => _cameraOn = !_cameraOn);
                unawaited(_media.setVideoEnabled(_cameraOn));
              },
            ),
          if (_isVideo)
            _circleButton(
              colors,
              icon: Icons.flip_camera_android_outlined,
              tooltip: 'Switch camera',
              onPressed: () => unawaited(_media.switchCamera()),
            ),
          _circleButton(
            colors,
            icon: failed ? Icons.close : Icons.call_end,
            tooltip: failed ? 'Close' : 'End call',
            background: colors.error,
            foreground: colors.onError,
            onPressed: () {
              if (_stage.isTerminalLike) {
                Navigator.of(context).maybePop();
              } else {
                unawaited(_finish(localEnd: true));
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _circleButton(
    ColorScheme colors, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? background,
    Color? foreground,
  }) {
    return IconButton.filled(
      onPressed: onPressed,
      tooltip: tooltip,
      iconSize: 26,
      style: IconButton.styleFrom(
        backgroundColor: background ?? colors.surfaceContainerHighest,
        foregroundColor: foreground ?? colors.onSurface,
        minimumSize: const Size(58, 58),
      ),
      icon: Icon(icon),
    );
  }
}

extension on CallMediaStage {
  /// True once there is nothing left to negotiate, so the screen may be popped
  /// without hanging up first.
  bool get isTerminalLike =>
      this == CallMediaStage.failed || this == CallMediaStage.ended;
}
