import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/config/app_config.dart';
import 'package:mailchat/core/config/turn_urls.dart';

/// URL handling is the difference between "works" and an opaque
/// `SocketException`, so it is pinned down here.
///
/// Background: the first on-device run failed with a bare
/// "Network request failed" because `SUPABASE_URL` had been passed as
/// `xyz.supabase.co` (no scheme) and, separately, a trailing slash produced
/// `//auth/v1/signup`. Both are normalised now.
void main() {
  group('AppConfig.normalizeUrl', () {
    test('leaves a correct URL unchanged', () {
      expect(
        AppConfig.normalizeUrl('https://abcdefgh.supabase.co'),
        'https://abcdefgh.supabase.co',
      );
    });

    test('strips a trailing slash', () {
      expect(
        AppConfig.normalizeUrl('https://abcdefgh.supabase.co/'),
        'https://abcdefgh.supabase.co',
      );
    });

    test('strips repeated trailing slashes', () {
      expect(
        AppConfig.normalizeUrl('https://abcdefgh.supabase.co///'),
        'https://abcdefgh.supabase.co',
      );
    });

    test('trims surrounding whitespace from a copy-paste', () {
      expect(
        AppConfig.normalizeUrl('  https://abcdefgh.supabase.co  '),
        'https://abcdefgh.supabase.co',
      );
    });

    test('adds https when the scheme is missing', () {
      expect(
        AppConfig.normalizeUrl('abcdefgh.supabase.co'),
        'https://abcdefgh.supabase.co',
      );
    });

    test('adds https and strips a trailing slash together', () {
      expect(
        AppConfig.normalizeUrl(' abcdefgh.supabase.co/ '),
        'https://abcdefgh.supabase.co',
      );
    });

    test('keeps an explicit http scheme', () {
      expect(
        AppConfig.normalizeUrl('http://localhost:54321'),
        'http://localhost:54321',
      );
    });

    test('preserves a non-default port', () {
      expect(
        AppConfig.normalizeUrl('https://abcdefgh.supabase.co:8443/'),
        'https://abcdefgh.supabase.co:8443',
      );
    });

    test('handles an empty value without throwing', () {
      expect(AppConfig.normalizeUrl(''), '');
      expect(AppConfig.normalizeUrl('   '), '');
    });
  });
  group('AppConfig.buildIceServers', () {
    test('STUN alone by default', () {
      final servers = AppConfig.buildIceServers(
        stunUrl: 'stun:stun.l.google.com:19302',
      );
      expect(servers, hasLength(1));
      expect(servers.single['urls'], 'stun:stun.l.google.com:19302');
    });

    test('TURN is appended with its credentials', () {
      final servers = AppConfig.buildIceServers(
        stunUrl: 'stun:stun.l.google.com:19302',
        turnUrl: 'turn:turn.example.com:3478',
        turnUsername: 'mailchat',
        turnCredential: 'secret',
      );
      expect(servers, hasLength(2));
      expect(servers.last['urls'], 'turn:turn.example.com:3478');
      expect(servers.last['username'], 'mailchat');
      expect(servers.last['credential'], 'secret');
    });

    test('an anonymous relay is allowed (no username, no credential block)', () {
      final servers = AppConfig.buildIceServers(
        stunUrl: 'stun:x',
        turnUrl: 'turn:relay:3478',
      );
      expect(servers.last.containsKey('username'), isFalse);
      expect(servers.last.containsKey('credential'), isFalse);
    });

    test('a blank or padded TURN URL is treated as absent', () {
      expect(
        AppConfig.buildIceServers(stunUrl: 'stun:x', turnUrl: '   '),
        hasLength(1),
      );
      expect(
        AppConfig.buildIceServers(stunUrl: 'stun:x', turnUrl: ' turn:r:3478 ')
            .last['urls'],
        'turn:r:3478',
      );
    });

    test('a pasted provider list becomes one server per address', () {
      // Shape of the array a hosted TURN dashboard hands out: four addresses,
      // one credential, plus the provider's own STUN entry.
      final servers = AppConfig.buildIceServers(
        stunUrl: 'stun:stun.l.google.com:19302',
        turnUrl: 'turn:relay.example.ca:80,'
            'turn:relay.example.ca:80?transport=tcp,'
            'turn:relay.example.ca:443,'
            'turns:relay.example.ca:443?transport=tcp',
        turnUsername: ' user ',
        turnCredential: ' secret ',
      );
      // STUN plus four relays: every address reaches the peer connection.
      expect(servers, hasLength(5));
      expect(servers.first['urls'], 'stun:stun.l.google.com:19302');
      expect(
        servers.skip(1).map((s) => s['urls']).toList(),
        [
          'turn:relay.example.ca:80',
          'turn:relay.example.ca:80?transport=tcp',
          'turn:relay.example.ca:443',
          'turns:relay.example.ca:443?transport=tcp',
        ],
      );
      for (final server in servers.skip(1)) {
        // A relay entry without credentials is silently unusable, so each one
        // carries the trimmed pair rather than only the first.
        expect(server['username'], 'user');
        expect(server['credential'], 'secret');
      }
    });
  });

  group('TurnUrls.parse', () {
    test('keeps a single address unchanged', () {
      expect(
        TurnUrls.parse('turn:turn.example.com:3478'),
        ['turn:turn.example.com:3478'],
      );
    });

    test('splits on commas, semicolons, spaces and newlines', () {
      expect(
        TurnUrls.parse('turn:a:80, turn:b:80; turn:c:80\nturn:d:80'),
        ['turn:a:80', 'turn:b:80', 'turn:c:80', 'turn:d:80'],
      );
    });

    test('reads a pasted iceServers array and drops its STUN entry', () {
      const pasted = '''
        [
          { "urls": "stun:relay.example.ca:80" },
          { "urls": "turn:relay.example.ca:80",
            "username": "u", "credential": "c" },
          { "urls": "turns:relay.example.ca:443?transport=tcp",
            "username": "u", "credential": "c" }
        ]
      ''';
      expect(TurnUrls.parse(pasted), [
        'turn:relay.example.ca:80',
        'turns:relay.example.ca:443?transport=tcp',
      ]);
    });

    test('translates http(s):// addresses to turn(s):', () {
      // RTCPeerConnection accepts only turn:/turns:, so a pasted https://443
      // entry is otherwise an ICE server the native stack throws away.
      expect(
        TurnUrls.parse(
          'https://relay.example.ca:443 http://relay.example.ca:80',
        ),
        ['turns:relay.example.ca:443', 'turn:relay.example.ca:80'],
      );
    });

    test('collapses turn:// to turn: and keeps ?transport=tcp', () {
      expect(
        TurnUrls.parse('turn://relay.example.ca:80?transport=tcp'),
        ['turn:relay.example.ca:80?transport=tcp'],
      );
    });

    test('de-duplicates repeats without reordering', () {
      expect(
        TurnUrls.parse('turn:b:80, turn:a:80, turn:b:80'),
        ['turn:b:80', 'turn:a:80'],
      );
    });

    test('a STUN-only or nonsense value yields no relay', () {
      expect(TurnUrls.parse('stun:stun.l.google.com:19302'), isEmpty);
      expect(TurnUrls.parse('yes'), isEmpty);
      expect(TurnUrls.parse('   '), isEmpty);
      expect(TurnUrls.parse(null), isEmpty);
      expect(TurnUrls.parse('turn:'), isEmpty);
    });
  });

  // The runtime twin of the "relay: UDP only" line that `dart run
  // tool/check_config.dart` prints. A call that never connects looks identical
  // on screen whether the build has no relay or the network is blocking it, so
  // the app logs which case it is at call start — and that line gets pasted into
  // a bug report, which is why the credential must not be in it.
  group('TurnUrls.hosts', () {
    test('lists host and port without scheme or query', () {
      expect(
        TurnUrls.hosts('turn:relay.example.ca:80, '
            'turn:relay.example.ca:80?transport=tcp, '
            'turns:relay.example.ca:443?transport=tcp'),
        ['relay.example.ca:80', 'relay.example.ca:443'],
      );
    });

    test('never exposes a credential embedded in the URL', () {
      // `turn:user:secret@host:3478` is a legal TURN URL, and this list is
      // logged. The host is the useful part; the rest is the shared secret.
      expect(
        TurnUrls.hosts('turn:alice:s3cr3t@relay.example.ca:3478'),
        ['relay.example.ca:3478'],
      );
    });

    test('is empty when there is no relay', () {
      expect(TurnUrls.hosts(null), isEmpty);
      expect(TurnUrls.hosts('stun:stun.l.google.com:19302'), isEmpty);
    });
  });

  group('TurnUrls.hasFallback', () {
    test('a UDP-only relay has no fallback', () {
      // This is the configuration that works at home and fails on mobile data.
      expect(TurnUrls.hasFallback('turn:relay.example.ca:80'), isFalse);
      expect(TurnUrls.hasFallback('turn:relay.example.ca:443'), isFalse);
    });

    test('TCP or TLS entries count as a fallback', () {
      expect(
        TurnUrls.hasFallback(
          'turn:relay.example.ca:80, turns:relay.example.ca:443?transport=tcp',
        ),
        isTrue,
      );
      expect(
        TurnUrls.hasFallback('turn:relay.example.ca:80?transport=tcp'),
        isTrue,
      );
    });

    test('no relay at all is not a fallback', () {
      expect(TurnUrls.hasFallback(null), isFalse);
      expect(TurnUrls.hasFallback('stun:stun.l.google.com:19302'), isFalse);
    });
  });
}
