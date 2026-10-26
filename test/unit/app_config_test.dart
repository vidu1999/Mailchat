import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/config/app_config.dart';

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
  });
}
