/// Call domain model.
///
/// A call is one row in `public.calls` (migration 0007), and its lifecycle is
/// decided by a trigger on that table. This model mirrors those rules so the UI
/// can grey out the wrong button, while the database stays the authority: a
/// client that lies about who it is gets a 42501, not a connected call.
///
/// Media is carried by `CallMedia` (`call_media.dart`), which wraps
/// `flutter_webrtc`: a call holds a real `RTCPeerConnection`, and the SDP and
/// ICE exchanged through the database are what connect the two sides.
///
/// Whether it actually connects depends on the network. With only a STUN server
/// the two ends must be able to reach each other; a TURN relay is what makes a
/// call work on mobile data. The call screen says so when no relay is
/// configured rather than pretending the call failed for another reason.
library;

/// Whether this build can carry call media.
///
/// True now that `flutter_webrtc` is a dependency and `CallMedia` negotiates a
/// real peer connection. It is a single constant because two things read it —
/// [CallService] for logging and the chat screen for deciding whether to open a
/// call — and a test holds the value so a future refactor cannot quietly
/// pretend media exists.
const bool callMediaConnected = true;

/// Where a call is in its lifecycle. Values match the `calls.status` check
/// constraint except [ringing]/[ongoing], which are named for readability and
/// mapped in [Call.fromJson].
enum CallState { ringing, ongoing, ended, missed, declined, failed }

extension CallStateX on CallState {
  /// The value stored in the database.
  String get wire => switch (this) {
        CallState.ringing => 'ringing',
        CallState.ongoing => 'accepted',
        CallState.ended => 'ended',
        CallState.missed => 'missed',
        CallState.declined => 'declined',
        CallState.failed => 'failed',
      };

  /// Once true, no further state change is possible — matching the trigger,
  /// which refuses any transition out of a terminal state.
  bool get isTerminal => switch (this) {
        CallState.ended => true,
        CallState.missed => true,
        CallState.declined => true,
        CallState.failed => true,
        _ => false,
      };

  String get label => switch (this) {
        CallState.ringing => 'Ringing',
        CallState.ongoing => 'In progress',
        CallState.ended => 'Ended',
        CallState.missed => 'Missed',
        CallState.declined => 'Declined',
        CallState.failed => 'Failed',
      };
}

/// The camera/microphone permission explanation shown before the system prompt.
///
/// Pure so it can be tested: the wording is the only part of the permission
/// flow that can be pinned without a device.
String callPermissionRationale({required bool video}) => video
    ? 'MailChat needs the camera and microphone for this video call. '
        'Nothing is recorded.'
    : 'MailChat needs the microphone for this call. Nothing is recorded.';

/// Where the media engine is in its own lifecycle, independent of the call row.
///
/// The call row says whether the two people agreed to talk; this says whether
/// the phone can actually do it. A call can be `accepted` while media is still
/// [CallMediaStage.connecting], and the screen must not claim otherwise.
enum CallMediaStage {
  idle,
  preparing,
  connecting,
  connected,
  failed,
  ended,
}

extension CallMediaStageX on CallMediaStage {
  /// What the call screen shows under the peer's name.
  String get label => switch (this) {
        CallMediaStage.idle => 'Preparing...',
        CallMediaStage.preparing => 'Starting camera and microphone...',
        CallMediaStage.connecting => 'Connecting...',
        CallMediaStage.connected => 'Connected',
        CallMediaStage.failed => 'Could not connect',
        CallMediaStage.ended => 'Call ended',
      };

  /// True while the user should wait rather than hang up in frustration.
  bool get isBusy =>
      this == CallMediaStage.preparing || this == CallMediaStage.connecting;
}

class Call {
  const Call({
    required this.id,
    required this.conversationId,
    required this.callerId,
    required this.calleeId,
    required this.kind,
    required this.state,
    required this.createdAt,
    this.acceptedAt,
    this.endedAt,
    this.endedBy,
    this.offerSdp,
    this.answerSdp,
  });

  final String id;
  final String conversationId;
  final String callerId;

  /// The person being called. Named `calleeId` to match the column; the UI calls
  /// them the receiver.
  final String calleeId;

  /// `voice` or `video`.
  final String kind;
  final CallState state;
  final DateTime createdAt;
  final DateTime? acceptedAt;
  final DateTime? endedAt;
  final String? endedBy;
  final String? offerSdp;
  final String? answerSdp;

  bool get isVideo => kind == 'video';
  bool get isRinging => state == CallState.ringing;
  bool get isOngoing => state == CallState.ongoing;
  bool get isFinished => state.isTerminal;

  /// Kept for call sites that used the pre-signalling field name.
  String get receiverId => calleeId;

  /// How long the call was connected, once it has ended. Null unless it was
  /// accepted: a declined or missed call has no duration, and reporting zero
  /// would be a small lie.
  Duration? get duration {
    final started = acceptedAt;
    if (started == null) return null;
    final finished = endedAt;
    if (finished == null) return null;
    final span = finished.difference(started);
    return span.isNegative ? Duration.zero : span;
  }

  // ---- permissions, mirroring the trigger ---------------------------------

  /// Only the callee may accept, and only while it is ringing.
  bool canAccept(String userId) =>
      userId == calleeId && state == CallState.ringing;

  /// Only the callee may decline.
  bool canDecline(String userId) =>
      userId == calleeId && state == CallState.ringing;

  /// Either participant may end a connected call.
  bool canEnd(String userId) =>
      (userId == callerId || userId == calleeId) && state == CallState.ongoing;

  /// Either participant may report that media never connected.
  bool canReportFailure(String userId) =>
      (userId == callerId || userId == calleeId) &&
      !state.isTerminal &&
      state != CallState.declined;

  /// Only the caller writes the offer; only the callee writes the answer.
  bool canSetOffer(String userId) =>
      userId == callerId && state == CallState.ringing;
  bool canSetAnswer(String userId) =>
      userId == calleeId && state == CallState.ongoing;

  factory Call.fromJson(Map<String, dynamic> json) {
    return Call(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String,
      callerId: json['caller_id'] as String,
      calleeId: json['callee_id'] as String,
      kind: json['kind'] as String? ?? 'voice',
      state: stateFromWire(json['status'] as String?),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      acceptedAt: json['accepted_at'] != null
          ? DateTime.tryParse(json['accepted_at'] as String)
          : null,
      endedAt: json['ended_at'] != null
          ? DateTime.tryParse(json['ended_at'] as String)
          : null,
      endedBy: json['ended_by'] as String?,
      offerSdp: json['offer_sdp'] as String?,
      answerSdp: json['answer_sdp'] as String?,
    );
  }

  /// Maps the stored status onto [CallState]. An unknown value becomes [failed]
  /// rather than throwing: a call the client cannot classify is not a call it
  /// should pretend to understand.
  static CallState stateFromWire(String? status) {
    switch (status) {
      case 'ringing':
        return CallState.ringing;
      case 'accepted':
        return CallState.ongoing;
      case 'ended':
        return CallState.ended;
      case 'missed':
        return CallState.missed;
      case 'declined':
        return CallState.declined;
      case 'failed':
        return CallState.failed;
      default:
        return CallState.failed;
    }
  }

  Call copyWith({CallState? state, String? answerSdp, DateTime? endedAt}) {
    return Call(
      id: id,
      conversationId: conversationId,
      callerId: callerId,
      calleeId: calleeId,
      kind: kind,
      state: state ?? this.state,
      createdAt: createdAt,
      acceptedAt: acceptedAt,
      endedAt: endedAt ?? this.endedAt,
      endedBy: endedBy,
      offerSdp: offerSdp,
      answerSdp: answerSdp ?? this.answerSdp,
    );
  }
}

/// Everything that is exchanged over the signalling channel but never stored:
/// nothing at present, since SDP lives on the row and ICE candidates live in
/// `call_ice_candidates`. Kept as the documented shape for future ephemeral
/// signals (for example "still ringing" heartbeats).
class CallSignal {
  const CallSignal({
    required this.type,
    required this.callId,
    required this.from,
    this.payload,
  });

  /// `answer` | `ice-candidate` | `hangup` | `ringing`
  final String type;
  final String callId;
  final String from;
  final Map<String, dynamic>? payload;

  Map<String, dynamic> toJson() => {
        'type': type,
        'call_id': callId,
        'from': from,
        if (payload != null) 'payload': payload,
      };
}

/// How long a ringing row may still interrupt someone.
///
/// A call left ringing because a tab closed, or a hang-up write failed, used
/// to ring again every time the other person opened MailChat. Forty-five
/// seconds is long enough for a real ring and short enough that an old row
/// is not a call.
const Duration incomingCallWindow = Duration(seconds: 45);

/// A call this user placed is not cleared on the same short window. Clearing
/// it at 45 seconds would hang up a ring they are still waiting on.
const Duration outgoingRingClearAfter = Duration(minutes: 3);

/// True when [createdAt] is a ring that should still be shown.
bool incomingCallIsFresh(DateTime createdAt, DateTime now) {
  final age = now.toUtc().difference(createdAt.toUtc());
  if (age.isNegative) return age.abs() <= const Duration(minutes: 2);
  return age <= incomingCallWindow;
}

/// True when a leftover ringing row should be marked missed.
///
/// Incoming leftovers are cleared as soon as they are too old to show.
/// Outgoing leftovers wait [outgoingRingClearAfter], so this user's own
/// ring is not ended while they are still on the call screen.
bool incomingCallShouldClear({
  required DateTime createdAt,
  required DateTime now,
  required bool isCallee,
}) {
  final age = now.toUtc().difference(createdAt.toUtc());
  if (age.isNegative) return false;
  if (isCallee) return age > incomingCallWindow;
  return age > outgoingRingClearAfter;
}
