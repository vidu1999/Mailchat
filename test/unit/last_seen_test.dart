import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/utils/formatters.dart';
import 'package:mailchat/shared/models/peer_presence.dart';
import 'package:mailchat/shared/services/presence_service.dart';

/// Online status is now two things at once: a live Realtime signal for "are they
/// in this chat right now", and a durable heartbeat row (`user_presence`,
/// migration 0008) that says when this user was last seen anywhere.
///
/// These tests pin the durable half's contract, because it is the half that can
/// state something false about a person:
///   * a heartbeat inside the window is "Online";
///   * an older one is "last seen ...";
///   * a row with both fields null means the owner hid their status, and the UI
///     must say nothing rather than guess "Offline".
void main() {
  PeerPresence presence({
    bool? online,
    DateTime? lastSeenAt,
  }) =>
      PeerPresence(
        userId: 'u1',
        online: online,
        lastSeenAt: lastSeenAt,
        hidden: online == null,
      );

  group('PeerPresence.fromJson', () {
    test('reads an online verdict and its timestamp', () {
      final peer = PeerPresence.fromJson({
        'user_id': 'u1',
        'online': true,
        'last_seen_at': '2026-10-26T10:41:00Z',
      });
      expect(peer.userId, 'u1');
      expect(peer.online, isTrue);
      expect(peer.isOnline, isTrue);
      expect(peer.hidden, isFalse);
      expect(peer.lastSeenAt, isNotNull);
      // Parsed as UTC, shown as local: the server always speaks UTC.
      expect(peer.lastSeenAt!.isUtc, isFalse);
    });

    test('an offline verdict keeps the timestamp', () {
      final peer = PeerPresence.fromJson({
        'user_id': 'u1',
        'online': false,
        'last_seen_at': '2026-10-20T08:00:00Z',
      });
      expect(peer.isOnline, isFalse);
      expect(peer.hidden, isFalse);
      expect(peer.lastSeenAt, isNotNull);
    });

    test('a masked row is hidden, not offline', () {
      // get_presence() nulls both columns when the owner turned sharing off.
      final peer = PeerPresence.fromJson({
        'user_id': 'u1',
        'online': null,
        'last_seen_at': null,
      });
      expect(peer.online, isNull);
      expect(peer.isOnline, isFalse);
      expect(peer.hidden, isTrue);
      expect(peer.label(), isNull);
    });

    test('a null user id cannot become a map key', () {
      final peer = PeerPresence.fromJson({'user_id': null});
      expect(peer.userId, 'null');
    });
  });

  group('label', () {
    final now = DateTime(2026, 10, 26, 12, 0);

    test('a live heartbeat is Online', () {
      expect(presence(online: true).label(now: now), 'Online');
      // Even with a stale-looking timestamp, the server said online.
      expect(
        presence(online: true, lastSeenAt: now).label(now: now),
        'Online',
      );
    });

    test('seen earlier today shows the clock time', () {
      expect(
        presence(online: false, lastSeenAt: DateTime(2026, 10, 26, 10, 41))
            .label(now: now),
        'last seen 10:41 AM',
      );
    });

    test('seen yesterday says so', () {
      expect(
        presence(online: false, lastSeenAt: DateTime(2026, 10, 25, 22, 5))
            .label(now: now),
        'last seen yesterday',
      );
    });

    test('seen earlier in the month shows the date', () {
      expect(
        presence(online: false, lastSeenAt: DateTime(2026, 10, 24, 9, 0))
            .label(now: now),
        'last seen Oct 24',
      );
    });

    test('offline with no timestamp is Offline, not hidden', () {
      expect(presence(online: false).label(now: now), 'Offline');
    });

    test('hidden says nothing at all', () {
      expect(presence().label(now: now), isNull);
    });
  });

  group('heartbeat window', () {
    test('the window is longer than one heartbeat', () {
      // Otherwise a single dropped beat would flicker every online user to
      // "offline" and straight back.
      expect(
        PresenceService.onlineWindow,
        greaterThan(PresenceService.heartbeatInterval),
      );
    });

    test('the window tolerates a couple of missed beats, not a dead app', () {
      expect(
        PresenceService.onlineWindow,
        lessThanOrEqualTo(PresenceService.heartbeatInterval * 3),
      );
    });

    test('sanity: 30s beat, 75s window', () {
      expect(PresenceService.heartbeatInterval, const Duration(seconds: 30));
      expect(PresenceService.onlineWindow, const Duration(seconds: 75));
    });
  });

  group('AppFormatters.lastSeen', () {
    final now = DateTime(2026, 10, 26, 12, 0);

    test('today is a time', () {
      expect(
        AppFormatters.lastSeen(DateTime(2026, 10, 26, 0, 5), now: now),
        '12:05 AM',
      );
    });

    test('yesterday is the word', () {
      expect(
        AppFormatters.lastSeen(DateTime(2026, 10, 25, 23, 59), now: now),
        'yesterday',
      );
    });

    test('older is a short date', () {
      expect(
        AppFormatters.lastSeen(DateTime(2026, 3, 2), now: now),
        'Mar 2',
      );
    });
  });
}
