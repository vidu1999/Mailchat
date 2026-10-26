import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/features/calls/domain/call_model.dart';

/// The call lifecycle is enforced by a trigger (`enforce_call_transitions`,
/// migration 0007). These tests pin the client's mirror of those rules, so the
/// UI greys out the button the database would reject rather than letting a user
/// tap into a 42501.
void main() {
  Call call({
    String status = 'ringing',
    String caller = 'alice',
    String callee = 'bob',
    String? acceptedAt,
    String? endedAt,
  }) =>
      Call.fromJson({
        'id': 'c1',
        'conversation_id': 'conv1',
        'caller_id': caller,
        'callee_id': callee,
        'kind': 'video',
        'status': status,
        'created_at': '2026-01-01T10:00:00Z',
        if (acceptedAt != null) 'accepted_at': acceptedAt,
        if (endedAt != null) 'ended_at': endedAt,
      });

  group('status mapping', () {
    test('every stored status maps to a state', () {
      expect(Call.stateFromWire('ringing'), CallState.ringing);
      expect(Call.stateFromWire('accepted'), CallState.ongoing);
      expect(Call.stateFromWire('ended'), CallState.ended);
      expect(Call.stateFromWire('missed'), CallState.missed);
      expect(Call.stateFromWire('declined'), CallState.declined);
      expect(Call.stateFromWire('failed'), CallState.failed);
    });

    test('an unknown status is treated as failed, not ringing', () {
      // Guessing "ringing" would show a live call UI for something the client
      // does not understand.
      expect(Call.stateFromWire('weird'), CallState.failed);
      expect(Call.stateFromWire(null), CallState.failed);
    });

    test('state and wire round-trip', () {
      for (final state in CallState.values) {
        expect(Call.stateFromWire(state.wire), state);
      }
    });

    test('terminal states are the four that cannot move again', () {
      expect(CallState.ended.isTerminal, isTrue);
      expect(CallState.missed.isTerminal, isTrue);
      expect(CallState.declined.isTerminal, isTrue);
      expect(CallState.failed.isTerminal, isTrue);
      expect(CallState.ringing.isTerminal, isFalse);
      expect(CallState.ongoing.isTerminal, isFalse);
    });
  });

  group('who may do what', () {
    test('only the callee can accept, and only while ringing', () {
      final ringing = call();
      expect(ringing.canAccept('bob'), isTrue);
      expect(ringing.canAccept('alice'), isFalse);
      expect(ringing.canAccept('carol'), isFalse);
      expect(call(status: 'accepted').canAccept('bob'), isFalse);
    });

    test('only the callee can decline', () {
      final ringing = call();
      expect(ringing.canDecline('bob'), isTrue);
      expect(ringing.canDecline('alice'), isFalse);
    });

    test('either participant can end a connected call', () {
      final ongoing = call(status: 'accepted');
      expect(ongoing.canEnd('alice'), isTrue);
      expect(ongoing.canEnd('bob'), isTrue);
      expect(ongoing.canEnd('carol'), isFalse);
    });

    test('a ringing call is declined or missed, not ended', () {
      // "Ended" implies it connected; the trigger refuses it too.
      expect(call().canEnd('alice'), isFalse);
    });

    test('a finished call cannot be ended again', () {
      for (final status in ['ended', 'declined', 'missed', 'failed']) {
        expect(call(status: status).canEnd('alice'), isFalse, reason: status);
      }
    });

    test('a third party can do nothing', () {
      final ringing = call();
      expect(ringing.canAccept('carol'), isFalse);
      expect(ringing.canEnd('carol'), isFalse);
      expect(ringing.canReportFailure('carol'), isFalse);
    });

    test('only the caller writes the offer and only the callee the answer', () {
      final ringing = call();
      expect(ringing.canSetOffer('alice'), isTrue);
      expect(ringing.canSetOffer('bob'), isFalse);

      final ongoing = call(status: 'accepted');
      expect(ongoing.canSetAnswer('bob'), isTrue);
      expect(ongoing.canSetAnswer('alice'), isFalse);
    });
  });

  group('duration', () {
    test('is null unless the call actually connected', () {
      expect(call(status: 'declined').duration, isNull);
      expect(call(status: 'missed').duration, isNull);
      expect(
        call(
          status: 'accepted',
          acceptedAt: '2026-01-01T10:00:00Z',
        ).duration,
        isNull,
        reason: 'still in progress',
      );
    });

    test('measures from acceptance to end', () {
      final finished = call(
        status: 'ended',
        acceptedAt: '2026-01-01T10:00:00Z',
        endedAt: '2026-01-01T10:02:30Z',
      );
      expect(finished.duration, const Duration(minutes: 2, seconds: 30));
    });

    test('never reports a negative duration from clock skew', () {
      final skewed = call(
        status: 'ended',
        acceptedAt: '2026-01-01T10:00:10Z',
        endedAt: '2026-01-01T10:00:00Z',
      );
      expect(skewed.duration, Duration.zero);
    });
  });

  group('media', () {
    test('is declared absent, so no screen can claim a connected call', () {
      // Signal that a call rang and was accepted — and that no audio or video
      // was ever carried. Flipping this constant is the last step of the
      // feature, not a cosmetic flag; docs/calls.md lists what it requires.
      expect(callMediaConnected, isFalse);

      final ongoing = call(status: 'accepted');
      expect(ongoing.isOngoing, isTrue);
      expect(ongoing.duration, isNull);
    });
  });
}
