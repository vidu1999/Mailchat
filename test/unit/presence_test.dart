import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/shared/services/presence_service.dart';

/// The *ephemeral* half of presence: who is in this conversation right now, and
/// who is typing. Both are Realtime events, never rows — a stored "online" flag
/// would be wrong the moment a phone loses signal, which is why the durable half
/// is a heartbeat instead (see last_seen_test.dart and migration 0008).
///
/// These tests pin the two things that are pure — how a presence payload is read,
/// and how long a typing event is believable — because the join config itself can
/// only be proved against a live project.
void main() {
  group('PresenceService.parsePresenceState', () {
    test('reads keys whose value carries phoenix metadata', () {
      final ids = PresenceService.parsePresenceState({
        'u1': {
          'metas': [
            {'phx_ref': 'ref1'}
          ]
        },
        'u2': {
          'metas': [
            {'phx_ref': 'ref2'},
            {'phx_ref': 'ref3'}
          ]
        },
      });

      expect(ids, {'u1', 'u2'});
    });

    test('ignores entries with empty metas', () {
      final ids = PresenceService.parsePresenceState({
        'u1': {'metas': []},
        'u2': {
          'metas': [
            {'phx_ref': 'ref'}
          ]
        },
      });

      expect(ids, {'u2'});
    });

    test('accepts a bare key shape from other server versions', () {
      final ids = PresenceService.parsePresenceState({'u1': null});
      expect(ids, {'u1'});
    });

    test('an empty state means nobody is present', () {
      expect(PresenceService.parsePresenceState(const {}), isEmpty);
    });

    test('metadata without phx_ref does not count as present', () {
      final ids = PresenceService.parsePresenceState({
        'u1': {
          'metas': [
            {'online_at': '2026-01-01'}
          ]
        },
      });
      expect(ids, isEmpty);
    });
  });

  group('typing lifetime', () {
    test('the TTL is short enough to stop lying', () {
      // If a socket drops mid-word, this is how long the indicator lingers.
      expect(PresenceService.typingTtl.inSeconds, lessThanOrEqualTo(5));
      expect(PresenceService.typingTtl.inSeconds, greaterThanOrEqualTo(3));
    });
  });
}
