import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/deeplink/app_links.dart';
import 'package:mailchat/core/deeplink/auth_deep_link.dart';

/// Every case here comes from a real redirect or a documented GoTrue shape.
///
/// The link that exposed the gap: clicking the confirmation email on Android
/// opened a browser tab reading "null is unreachable", because the redirect went
/// nowhere and the app had no handler at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('custom scheme with a session in the fragment', () {
    const raw = 'mailchat://auth/callback#access_token=abc.def.ghi'
        '&refresh_token=r3fr3sh&expires_in=3600&token_type=bearer&type=signup';

    test('parses as a confirmation link carrying tokens', () {
      final link = AuthDeepLink.parse(raw)!;

      expect(link.kind, AuthLinkKind.confirmation);
      expect(link.accessToken, 'abc.def.ghi');
      expect(link.refreshToken, 'r3fr3sh');
      expect(link.type, 'signup');
      expect(link.isActionable, isTrue);
    });

    test('percent-encoded token values are decoded', () {
      final link = AuthDeepLink.parse(
        'mailchat://auth/callback#access_token=a%2Bb%3Dc&type=signup',
      )!;

      expect(link.accessToken, 'a+b=c');
    });

    test('a recovery link is told apart from a confirmation', () {
      final link = AuthDeepLink.parse(
        'mailchat://auth/callback#access_token=token&type=recovery',
      )!;

      expect(link.kind, AuthLinkKind.recovery);
    });
  });

  group('token_hash templates', () {
    test('parses token_hash out of the query string', () {
      final link = AuthDeepLink.parse(
        'https://auth.example.com/auth/callback?token_hash=pkce_hash&type=signup',
      )!;

      expect(link.kind, AuthLinkKind.confirmation);
      expect(link.tokenHash, 'pkce_hash');
      expect(link.accessToken, isNull);
      expect(link.isActionable, isTrue);
    });

    test('query string values are decoded', () {
      final link = AuthDeepLink.parse(
        'https://auth.example.com/auth/callback?token_hash=a%20b&type=recovery',
      )!;

      expect(link.tokenHash, 'a b');
      expect(link.kind, AuthLinkKind.recovery);
    });
  });

  group('failure links', () {
    test('an expired link is reported with GoTrue’s own message', () {
      final link = AuthDeepLink.parse(
        'https://auth.example.com/auth/callback?error=access_denied'
        '&error_code=otp_expired'
        '&error_description=Email+link+is+invalid+or+has+expired',
      )!;

      expect(link.kind, AuthLinkKind.error);
      expect(link.errorCode, 'otp_expired');
      expect(link.errorMessage, contains('invalid or has expired'));
      expect(link.isActionable, isTrue);
    });

    test('an error without a description still says something useful', () {
      final link = AuthDeepLink.parse(
        'mailchat://auth/callback?error_code=otp_expired',
      )!;

      expect(link.kind, AuthLinkKind.error);
      expect(
        link.errorMessage.toLowerCase(),
        anyOf(contains('expired'), contains('no longer valid')),
      );
    });

    test('a callback with no token at all is an error, not a silent no-op', () {
      final link = AuthDeepLink.parse('mailchat://auth/callback')!;

      expect(link.kind, AuthLinkKind.error);
      expect(link.errorCode, 'missing_token');
      expect(link.isActionable, isTrue);
    });
  });

  group('links that are not auth callbacks', () {
    test('an unrelated URL is ignored', () {
      expect(AuthDeepLink.parse('https://example.com/pricing'), isNull);
      expect(AuthDeepLink.parse('mailchat://settings'), isNull);
    });

    test('null and empty input are ignored', () {
      expect(AuthDeepLink.parse(null), isNull);
      expect(AuthDeepLink.parse('   '), isNull);
    });

    test('a whitespace-padded link is still parsed', () {
      final link = AuthDeepLink.parse(
        '  mailchat://auth/callback#access_token=t&type=signup\n',
      );

      expect(link?.accessToken, 't');
    });
  });

  group('route arguments', () {
    test('carries everything the handling screen needs', () {
      final link = AuthDeepLink.parse(
        'mailchat://auth/callback#access_token=t&refresh_token=r&type=recovery',
      )!;

      expect(link.routeArguments['accessToken'], 't');
      expect(link.routeArguments['refreshToken'], 'r');
      expect(link.routeArguments['type'], 'recovery');
    });
  });

  group('AppLinks platform bridge', () {
    test('a native incomingLink call reaches the Dart stream', () async {
      final received = <String>[];
      final sub = AppLinks.links.listen(received.add);

      await AppLinks.handleNativeCall(const MethodCall(
        'incomingLink',
        'mailchat://auth/callback#access_token=t&type=signup',
      ));
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(AuthDeepLink.parse(received.single)?.accessToken, 't');
      await sub.cancel();
    });

    test('unknown methods and non-string arguments are ignored', () async {
      final received = <String>[];
      final sub = AppLinks.links.listen(received.add);

      await AppLinks.handleNativeCall(const MethodCall('somethingElse'));
      await AppLinks.handleNativeCall(const MethodCall('incomingLink', 42));
      await Future<void>.delayed(Duration.zero);

      expect(received, isEmpty);
      await sub.cancel();
    });
  });
}
