import 'dart:async';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/core/network/supabase_realtime.dart';
import 'package:mailchat/features/calls/domain/call_model.dart';

/// Call signalling: placing, ringing, accepting, declining, ending, and the
/// SDP/ICE exchange.
///
/// This is the half of calling that is a database and a websocket. The other
/// half is media, which is **not implemented** — no audio or video is captured
/// or transmitted, and [mediaConnected] is always false. See docs/calls.md for
/// the exact remaining step and what it needs (a TURN server plus two devices).
///
/// Deliberately thin on policy: every transition is re-checked by
/// `enforce_call_transitions` in the database, so a modified client cannot
/// accept its own call or end someone else's.
class CallService {
  CallService();

  final SupabaseClient _supabase = SupabaseClient.instance;
  final SupabaseRealtimeClient _realtime = SupabaseRealtimeClient.instance;

  /// False until a WebRTC peer connection exists; see [callMediaConnected].
  static const bool mediaConnected = callMediaConnected;

  final StreamController<Call> _incomingController =
      StreamController<Call>.broadcast();
  Channel? _channel;

  /// Calls ringing for this user, delivered by Realtime.
  Stream<Call> get incomingCalls => _incomingController.stream;

  /// Places a call and returns the row, so both sides agree on the id.
  ///
  /// [offerSdp] is passed through when a WebRTC implementation exists; without
  /// one the call still rings, which is what makes the rest of the flow
  /// testable before media lands.
  Future<Call> placeCall({
    required String conversationId,
    required String callerId,
    required String calleeId,
    required bool isVideo,
    String? offerSdp,
  }) async {
    if (callerId == calleeId) {
      throw ValidationException('You cannot call yourself');
    }

    final inserted = await _supabase.insert(
      'calls',
      data: {
        'conversation_id': conversationId,
        'caller_id': callerId,
        'callee_id': calleeId,
        'kind': isVideo ? 'video' : 'voice',
        'status': 'ringing',
        if (offerSdp != null) 'offer_sdp': offerSdp,
      },
      select: '*',
    );
    if (inserted.isEmpty) {
      throw AppException('The call was not created');
    }
    final call = Call.fromJson(inserted.first);
    AppLogger.info('call_placed', details: {
      'callId': call.id,
      'kind': call.kind,
      'media': mediaConnected,
    });
    return call;
  }

  /// Reads one call. Used to resync after a reconnect, since a dropped socket
  /// can miss the events that matter.
  Future<Call?> fetch(String callId) async {
    final rows = await _supabase.select(
      'calls',
      filter: {'eq': 'id,$callId'},
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Call.fromJson(rows.first);
  }

  /// The callee accepts, optionally publishing its SDP answer.
  Future<Call> accept(String callId, {String? answerSdp}) {
    return _update(callId, {
      'status': 'accepted',
      if (answerSdp != null) 'answer_sdp': answerSdp,
    });
  }

  Future<Call> decline(String callId) =>
      _update(callId, {'status': 'declined'});

  /// Ends a connected call. The trigger records who ended it and when.
  Future<Call> end(String callId) => _update(callId, {'status': 'ended'});

  /// Marks a call that never connected. Distinct from [end]: nothing was
  /// connected, so reporting a duration would be wrong.
  Future<Call> reportFailure(String callId) =>
      _update(callId, {'status': 'failed'});

  /// Marks a ringing call the callee never answered.
  Future<Call> markMissed(String callId) =>
      _update(callId, {'status': 'missed'});

  /// Publishes this side's ICE candidate.
  Future<void> sendIceCandidate({
    required String callId,
    required String senderId,
    required String candidate,
    String? sdpMid,
    int? sdpMlineIndex,
  }) async {
    await _supabase.insert(
      'call_ice_candidates',
      data: {
        'call_id': callId,
        'sender_id': senderId,
        'candidate': candidate,
        if (sdpMid != null) 'sdp_mid': sdpMid,
        if (sdpMlineIndex != null) 'sdp_mline_index': sdpMlineIndex,
      },
    );
  }

  /// The other side's candidates, oldest first. The WebRTC layer feeds these to
  /// `addCandidate` in order.
  Future<List<Map<String, dynamic>>> iceCandidates({
    required String callId,
    required String excludeUserId,
  }) async {
    final rows = await _supabase.select(
      'call_ice_candidates',
      select: 'candidate, sdp_mid, sdp_mline_index, sender_id, created_at',
      filter: {'eq': 'call_id,$callId', 'neq': 'sender_id,$excludeUserId'},
      order: 'created_at.asc',
    );
    return rows;
  }

  /// Subscribes to calls belonging to [userId] so a ringing call can be shown.
  ///
  /// Realtime filters are single-column equality, so this listens to the
  /// callee's side only; the caller already knows about its own call. Accepts
  /// and ends arrive on the same channel as updates.
  void listenForCalls(String userId) {
    _channel?.unsubscribe();
    _channel = _realtime.join(
      'realtime:mailchat:calls:$userId',
      (type, payload) {
        final record = payload['record'];
        if (record is! Map) return;
        final row = Map<String, dynamic>.from(record);
        // Mixed types (JSON, possible nulls) — skip anything unreadable rather
        // than throwing inside a socket callback.
        if (row['id'] is! String ||
            row['conversation_id'] is! String ||
            row['caller_id'] is! String ||
            row['callee_id'] is! String) {
          return;
        }
        final call = Call.fromJson(row);
        if (!_incomingController.isClosed) {
          _incomingController.add(call);
        }
        AppLogger.info('call_event', details: {
          'callId': call.id,
          'status': call.state.wire,
          'type': type,
        });
      },
      config: {
        'postgres_changes': [
          {
            'event': '*',
            'schema': 'public',
            'table': 'calls',
            'filter': 'callee_id=eq.$userId',
          },
        ],
      },
    );
  }

  Future<Call> _update(String callId, Map<String, dynamic> data) async {
    final rows = await _supabase.update(
      'calls',
      filter: {'eq': 'id,$callId'},
      data: data,
    );
    if (rows.isEmpty) {
      // RLS returns no rows when the caller is not a participant; the trigger
      // raises for a wrong transition. Either way the state did not change.
      throw AuthorizationException('That call could not be updated');
    }
    return Call.fromJson(rows.first);
  }

  void dispose() {
    _channel?.unsubscribe();
    _channel = null;
    _incomingController.close();
  }
}
