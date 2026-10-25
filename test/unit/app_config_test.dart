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
}
