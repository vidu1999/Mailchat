/// Placeholder for the future call service.
///
/// Wiring: when WebRTC + signaling are available, implement
/// CallService.placeCall / acceptCall / endCall here, backed by Supabase
/// Realtime for signaling and flutter_webrtc for media.
class CallService {
  CallService();

  /// Not implemented — call infrastructure not configured.
  Future<void> placeCall({
    required String conversationId,
    required String callerId,
    required String receiverId,
    required bool isVideo,
  }) async {
    throw UnsupportedError(
      'Voice/video calling is not yet implemented. '
      'See docs/calls.md for the required signaling/STUN-TURN setup.',
    );
  }

  /// Not implemented.
  Future<void> endCall(String callId) async {
    throw UnsupportedError(
      'Voice/video calling is not yet implemented. '
      'See docs/calls.md for the required signaling/STUN-TURN setup.',
    );
  }
}
