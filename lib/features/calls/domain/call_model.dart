/// Call feature domain model and business rules.
///
/// Real-time audio/video calling is a later milestone (see requirements
/// section 17). Before enabling production calls:
///  1. Document the threat model.
///  2. Choose a maintained WebRTC implementation (flutter_webrtc).
///  3. Provide signaling (Supabase Realtime / Edge Functions) + STUN/TURN.
///  4. Implement call acceptance/rejection, ICE candidate exchange and
///     connection-state handling.
///  5. Add microphone/camera permissions and privacy access control.
///
/// This file holds the call state machine and intent types so the UI and a
/// future WebRTC implementation share a single model.
class Call {
  final String id;
  final String conversationId;
  final String callerId;
  final String receiverId;
  final bool isVideo;
  final CallState state; // ringing | ongoing | ended | missed | declined
  final DateTime createdAt;
  final DateTime? endedAt;
  final int? durationSeconds;

  Call({
    required this.id,
    required this.conversationId,
    required this.callerId,
    required this.receiverId,
    required this.isVideo,
    required this.state,
    required this.createdAt,
    this.endedAt,
    this.durationSeconds,
  });

  bool get isRinging => state == CallState.ringing;
  bool get isOngoing => state == CallState.ongoing;
  bool get isEnded => state == CallState.ended;
}

enum CallState { ringing, ongoing, ended, missed, declined }

/// Intent sent through Supabase Realtime to signal an incoming call.
class CallSignal {
  final String type; // offer | answer | ice-candidate | hangup | ringing
  final String callId;
  final String from;
  final String to;
  final Map<String, dynamic>? payload;

  CallSignal({
    required this.type,
    required this.callId,
    required this.from,
    required this.to,
    this.payload,
  });

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'call_id': callId,
      'from': from,
      'to': to,
      'payload': payload,
    };
  }
}
