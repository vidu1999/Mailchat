import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/features/calls/domain/call_model.dart';

void main() {
  final now = DateTime.utc(2026, 10, 27, 12);

  test('an active incoming call is never cleared by the background poll', () {
    expect(
      incomingCallMayBeCleared(callId: 'active-call', activeCallId: 'active-call'),
      isFalse,
    );
    expect(
      incomingCallMayBeCleared(callId: 'old-call', activeCallId: 'active-call'),
      isTrue,
    );
    expect(
      incomingCallMayBeCleared(callId: 'old-call', activeCallId: null),
      isTrue,
    );
  });

  test('a ring from the last few seconds is shown', () {
    expect(
      incomingCallIsFresh(now.subtract(const Duration(seconds: 10)), now),
      isTrue,
    );
  });

  test('a leftover ringing row is not a new call', () {
    final old = now.subtract(const Duration(minutes: 30));
    expect(incomingCallIsFresh(old, now), isFalse);
    expect(
      incomingCallShouldClear(createdAt: old, now: now, isCallee: true),
      isTrue,
    );
  });

  test('the caller is not hung up during a normal ring', () {
    final placed = now.subtract(const Duration(seconds: 50));
    expect(
      incomingCallShouldClear(createdAt: placed, now: now, isCallee: false),
      isFalse,
    );
    expect(
      incomingCallShouldClear(
        createdAt: now.subtract(const Duration(minutes: 4)),
        now: now,
        isCallee: false,
      ),
      isTrue,
    );
  });
}
