import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:mailchat/core/config/app_config.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/features/calls/domain/call_model.dart';

/// One call's media session: camera/microphone, a peer connection, and the
/// renderers the call screen paints.
///
/// The signalling half of a call lives in the database (migration 0007). This is
/// the other half: it captures media, negotiates SDP through
/// [CallService][1], and exchanges ICE candidates through `call_ice_candidates`.
///
/// [1]: ../domain/call_service.dart
///
/// Deliberately owns nothing about *who* is calling. It is handed an SDP string
/// and returns one; the ordering, retries and database writes belong to the call
/// screens and `CallService`.
///
/// Failure is reported, not hidden: [initialise] throws when the microphone or
/// camera is refused or absent, and the screen turns that into "could not start
/// the call" rather than a silent, silent call.
class CallMedia {
  CallMedia({AppConfig? config}) : _config = config;

  final AppConfig? _config;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  bool _video = false;
  bool _renderersReady = false;
  bool _disposed = false;

  /// ICE candidate produced locally, to be written to `call_ice_candidates`.
  void Function(RTCIceCandidate candidate)? onIceCandidate;

  /// The remote side's media arrived; the screen can show the video view.
  void Function(MediaStream stream)? onRemoteStream;

  /// Connection state changed (connected, disconnected, failed).
  void Function(RTCPeerConnectionState state)? onConnectionState;

  bool get isDisposed => _disposed;
  bool get hasLocalVideo => _video && _localStream != null;
  bool get hasRemoteVideo => _remoteStream?.getVideoTracks().isNotEmpty ?? false;

  MediaStream? get localStream => _localStream;

  /// Creates the renderers, opens the devices and builds the peer connection.
  ///
  /// Call this **before** creating an offer: a call that cannot capture media
  /// should never ring. If it throws, no call row exists yet.
  Future<void> initialise({required bool video}) async {
    _video = video;

    if (!_renderersReady) {
      await localRenderer.initialize();
      await remoteRenderer.initialize();
      _renderersReady = true;
    }

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      // Ask for the front camera at a resolution that survives a mobile
      // connection; 720p on a 3G link is worse than 480p that keeps up.
      'video': video
          ? {
              'facingMode': 'user',
              'width': {'ideal': 640},
              'height': {'ideal': 480},
            }
          : false,
    });

    localRenderer.srcObject = _localStream;

    final config = _config ?? AppConfig.instance;
    final iceServers = config.iceServers;

    _peer = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      // A relay-only policy would keep the caller's IP off the wire but
      // requires TURN; only use it when a relay is actually configured.
      if (config.hasTurnRelay) 'iceTransportPolicy': 'all',
    });

    _peer!.onIceCandidate = (candidate) {
      final value = candidate.candidate;
      if (value == null || value.isEmpty) return;
      onIceCandidate?.call(candidate);
    };

    _peer!.onTrack = (event) {
      final stream = event.streams.isNotEmpty ? event.streams.first : null;
      if (stream == null) return;
      _remoteStream = stream;
      remoteRenderer.srcObject = stream;
      onRemoteStream?.call(stream);
    };

    _peer!.onConnectionState = (state) {
      AppLogger.info('call_media_state', details: {'state': state.name});
      onConnectionState?.call(state);
    };

    for (final track in _localStream!.getTracks()) {
      await _peer!.addTrack(track, _localStream!);
    }

    AppLogger.info('call_media_ready', details: {
      'video': video,
      'iceServers': iceServers.length,
      'turn': config.hasTurnRelay,
    });
  }

  /// Creates the caller's offer. The caller then stores it in `calls.offer_sdp`.
  Future<String> createOffer() async {
    final peer = _requirePeer();
    final offer = await peer.createOffer();
    await peer.setLocalDescription(offer);
    return offer.sdp ?? '';
  }

  /// Applies the caller's offer and returns the callee's answer.
  ///
  /// The callee's answer goes into `calls.answer_sdp`, which the trigger only
  /// lets the callee write.
  Future<String> createAnswer(String offerSdp) async {
    final peer = _requirePeer();
    await peer.setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
    final answer = await peer.createAnswer();
    await peer.setLocalDescription(answer);
    return answer.sdp ?? '';
  }

  /// Applies the callee's answer on the caller's side.
  Future<void> applyAnswer(String answerSdp) async {
    final peer = _requirePeer();
    if (answerSdp.isEmpty) return;
    await peer.setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));
  }

  /// Adds a candidate produced by the other side.
  ///
  /// A failure here is logged and ignored: candidates that arrive after the
  /// connection settled are normal, and one bad row must not tear down a call
  /// that is already carrying audio.
  Future<void> addRemoteCandidate({
    required String candidate,
    String? sdpMid,
    int? sdpMlineIndex,
  }) async {
    final peer = _peer;
    if (peer == null || candidate.isEmpty) return;
    try {
      await peer.addCandidate(RTCIceCandidate(
        candidate,
        sdpMid ?? '0',
        sdpMlineIndex ?? 0,
      ));
    } catch (e, st) {
      AppLogger.warning('call_ice_add_failed', details: {'error': e.toString()});
      AppLogger.error(e, st, {'where': 'call_ice_add'});
    }
  }

  /// Mutes or unmutes the camera without renegotiating.
  Future<void> setVideoEnabled(bool enabled) async {
    final track = _first(_localStream?.getVideoTracks());
    if (track != null) track.enabled = enabled;
  }

  Future<void> setAudioEnabled(bool enabled) async {
    final track = _first(_localStream?.getAudioTracks());
    if (track != null) track.enabled = enabled;
  }

  Future<void> switchCamera() async {
    if (!_video) return;
    final track = _first(_localStream?.getVideoTracks());
    if (track == null) return;
    try {
      await Helper.switchCamera(track);
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'call_switch_camera'});
    }
  }

  /// First track of [tracks], or null. Deliberately hand-rolled: `firstOrNull`
  /// comes from package:collection, which this project does not depend on.
  MediaStreamTrack? _first(List<MediaStreamTrack>? tracks) {
    if (tracks == null || tracks.isEmpty) return null;
    return tracks.first;
  }

  RTCPeerConnection _requirePeer() {
    final peer = _peer;
    if (peer == null) {
      throw StateError('CallMedia.initialise() was not awaited before negotiation');
    }
    return peer;
  }

  /// Releases the camera and microphone, closes the peer connection and the
  /// renderers. Safe to call twice; the call screens do, because a call can end
  /// and be disposed from two paths at once.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    for (final track in _localStream?.getTracks() ?? const <MediaStreamTrack>[]) {
      try {
        await track.stop();
      } catch (e) {
        AppLogger.warning('call_track_stop_failed',
            details: {'error': e.toString()});
      }
    }
    try {
      await _localStream?.dispose();
    } catch (_) {
      // Already gone.
    }
    _localStream = null;
    _remoteStream = null;

    try {
      await _peer?.close();
    } catch (_) {
      // Already closed.
    }
    _peer = null;

    if (_renderersReady) {
      try {
        localRenderer.srcObject = null;
        remoteRenderer.srcObject = null;
        await localRenderer.dispose();
        await remoteRenderer.dispose();
      } catch (_) {
        // Renderers only fail to dispose when the engine is tearing down.
      }
      _renderersReady = false;
    }
  }
}

/// Folds a peer-connection state into the screen's stage.
///
/// Kept pure and separate from [CallMedia] so it is unit tested: the mapping is
/// where a "connected" badge could be shown for a connection that never
/// established.
CallMediaStage stageFromPeerState(RTCPeerConnectionState? state) =>
    switch (state) {
      RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
        CallMediaStage.connected,
      RTCPeerConnectionState.RTCPeerConnectionStateConnecting ||
      RTCPeerConnectionState.RTCPeerConnectionStateNew =>
        CallMediaStage.connecting,
      RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
        CallMediaStage.connecting,
      RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
        CallMediaStage.failed,
      RTCPeerConnectionState.RTCPeerConnectionStateClosed =>
        CallMediaStage.ended,
      null => CallMediaStage.idle,
    };
