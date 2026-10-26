import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/network/auth_error_messages.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/shared/services/auth_service.dart';

/// Signup has two successful shapes and one impersonation trap. These tests pin
/// down how each GoTrue response is interpreted.
///
/// GoTrue never says "this email is taken". For an existing address it returns a
/// placeholder user whose `identities` array is empty, so that response shape is
/// the only available signal.
void main() {
  Map<String, dynamic> userJson({required bool withIdentity}) => {
        'id': '11111111-1111-4111-8111-111111111111',
        'email': 'jane@example.com',
        'email_confirmed_at': null,
        'user_metadata': {
          'username': 'jane',
          'display_name': 'Jane',
        },
        'identities': withIdentity
            ? [
                {'id': 'x', 'provider': 'email'},
              ]
            : <Map<String, dynamic>>[],
      };

  group('normalizeAuthPayload', () {
    /// Copied from a real response captured on device: GoTrue returned the bare
    /// user object, with no `{user, session}` wrapper. Reading only
    /// `data['user']` reported "no user" for a valid signup.
    Map<String, dynamic> bareUser() => {
          'id': '0f1e2d3c-4b5a-4968-8776-655443322110',
          'aud': 'authenticated',
          'role': 'authenticated',
          'email': 'jane@example.com',
          'phone': '',
          'confirmation_sent_at': '2026-10-26T05:12:03.123456789Z',
          'app_metadata': {'provider': 'email', 'providers': ['email']},
          'user_metadata': {'username': 'jane', 'display_name': 'Jane'},
          'identities': [
            {'id': 'x', 'provider': 'email'},
          ],
          'created_at': '2026-10-26T05:12:02.987654Z',
          'updated_at': '2026-10-26T05:12:03.123456Z',
          'is_anonymous': false,
        };

    test('accepts a bare user object as a user with no session', () {
      final payload = SupabaseClient.normalizeAuthPayload(bareUser());

      expect(payload['user'], isA<Map>());
      expect(payload['session'], isNull);
    });

    test('the bare object still carries identity and confirmation data', () {
      final payload = SupabaseClient.normalizeAuthPayload(bareUser());
      final user = AuthUser.fromJson(payload['user'] as Map<String, dynamic>);

      expect(user.isPlaceholderForExistingAccount, isFalse);
      expect(user.confirmationSentAt, isNotNull);
      expect(user.username, 'jane');
    });

    test('an existing address is still detected in the bare shape', () {
      final json = bareUser()
        ..['identities'] = <Map<String, dynamic>>[]
        ..remove('confirmation_sent_at');
      final payload = SupabaseClient.normalizeAuthPayload(json);
      final user = AuthUser.fromJson(payload['user'] as Map<String, dynamic>);

      expect(user.isPlaceholderForExistingAccount, isTrue);
    });

    test('the documented wrapped shape is passed through', () {
      final payload = SupabaseClient.normalizeAuthPayload({
        'user': bareUser(),
        'session': null,
      });

      expect(payload['user'], isA<Map>());
      expect(payload['session'], isNull);
    });

    test('a session payload keeps its session', () {
      final payload = SupabaseClient.normalizeAuthPayload({
        'user': bareUser(),
        'session': {'access_token': 'token'},
      });

      expect(payload['session'], {'access_token': 'token'});
    });

    test('rebuilds a session from sibling token fields', () {
      // Older GoTrue puts the tokens next to `user` rather than in `session`.
      final payload = SupabaseClient.normalizeAuthPayload({
        'user': bareUser(),
        'access_token': 'access',
        'refresh_token': 'refresh',
      });

      expect(payload['session'], {
        'access_token': 'access',
        'refresh_token': 'refresh',
        'expires_in': null,
        'token_type': null,
      });
    });

    test('an error body is not mistaken for a user', () {
      // `id` is the discriminator; without it the payload is left alone so the
      // caller reports it instead of inventing a user.
      final error = {'msg': 'Signups not allowed for this instance', 'code': 400};
      expect(SupabaseClient.normalizeAuthPayload(error), error);
    });
  });

  group('AuthUser placeholder detection', () {
    test('a real new signup has one identity', () {
      final user = AuthUser.fromJson(userJson(withIdentity: true));

      expect(user.identityCount, 1);
      expect(user.isPlaceholderForExistingAccount, isFalse);
    });

    test('an existing address returns zero identities', () {
      final user = AuthUser.fromJson(userJson(withIdentity: false));

      expect(user.identityCount, 0);
      expect(user.isPlaceholderForExistingAccount, isTrue);
    });

    test('a response without an identities field is treated as real', () {
      // Some GoTrue versions omit the field entirely; assuming "existing
      // account" then would block legitimate signups.
      final json = userJson(withIdentity: true)..remove('identities');
      final user = AuthUser.fromJson(json);

      expect(user.isPlaceholderForExistingAccount, isFalse);
    });

    test('reads the signup metadata used by the profile trigger', () {
      final user = AuthUser.fromJson(userJson(withIdentity: true));

      expect(user.username, 'jane');
      expect(user.displayName, 'Jane');
    });
  });

  group('password sign-in payload', () {
    /// The shape `POST /auth/v1/token?grant_type=password` actually returns:
    /// tokens as siblings of `user`, no `session` object. Reading only
    /// `data['session']` reported a successful 200 sign-in as "Invalid email or
    /// password" while Supabase's own logs showed 200.
    Map<String, dynamic> flatGrant() => {
          'access_token': 'header.payload.signature',
          'token_type': 'bearer',
          'expires_in': 3600,
          'expires_at': 1792987203,
          'refresh_token': 'r3fr3sh',
          'user': userJson(withIdentity: true),
        };

    test('a session is recovered from the flat grant', () {
      final payload = SupabaseClient.normalizeAuthPayload(flatGrant());

      expect(payload['session'], isA<Map>());
      final session = Session.fromJson(payload['session'] as Map<String, dynamic>);
      expect(session.accessToken, 'header.payload.signature');
      expect(session.refreshToken, 'r3fr3sh');
      expect(session.expiresAt, isNotNull);
    });

    test('the user survives alongside the rebuilt session', () {
      final payload = SupabaseClient.normalizeAuthPayload(flatGrant());
      final user = AuthUser.fromJson(payload['user'] as Map<String, dynamic>);

      expect(user.email, 'jane@example.com');
      expect(user.isPlaceholderForExistingAccount, isFalse);
    });

    test('a wrapped session is still preferred when both are present', () {
      final payload = SupabaseClient.normalizeAuthPayload({
        'user': userJson(withIdentity: true),
        'session': {'access_token': 'wrapped', 'refresh_token': 'r'},
        'access_token': 'top-level',
      });

      expect((payload['session'] as Map)['access_token'], 'wrapped');
    });
  });

  group('AuthErrorMessages', () {
    // Every one of these used to reach the user as
    // `Request failed (400): {"code":400,...}`.
    test('invalid credentials read as a sentence', () {
      expect(
        AuthErrorMessages.forBody(
            '{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}'),
        'Invalid email or password.',
      );
    });

    test('an unconfirmed address is distinguished from a wrong password', () {
      final message = AuthErrorMessages.forBody(
          '{"code":400,"error_code":"email_not_confirmed","msg":"Email not confirmed"}');

      expect(message, contains('Confirm your email'));
    });

    test('rate limiting says to wait', () {
      expect(
        AuthErrorMessages.forBody(
            '{"code":429,"error_code":"over_email_send_rate_limit","msg":"Email rate limit exceeded"}'),
        contains('Wait a minute'),
      );
    });

    test('an unknown code falls back to the server sentence', () {
      expect(
        AuthErrorMessages.forBody(
            '{"code":500,"error_code":"boom","msg":"Something specific went wrong"}'),
        'Something specific went wrong',
      );
    });

    test('a JSON body with nothing readable yields null, not a blob', () {
      expect(AuthErrorMessages.forBody('{"code":500}'), isNull);
      expect(AuthErrorMessages.forBody(''), isNull);
      expect(AuthErrorMessages.forBody(null), isNull);
    });

    test('codeIn exposes the machine-readable code', () {
      expect(
        AuthErrorMessages.codeIn('{"error_code":"otp_expired"}'),
        'otp_expired',
      );
      expect(AuthErrorMessages.codeIn('not json'), isNull);
    });
  });

  group('Session expiry parsing', () {
    // GoTrue sends `expires_at` as an INTEGER of Unix epoch seconds. The old
    // code cast it to String, which throws `_TypeError` the first time a
    // session is parsed — i.e. on the first successful sign-in. Signup never
    // showed it, because signup returns no session.
    test('accepts expires_at as an epoch integer', () {
      final session = Session.fromJson({
        'access_token': 'token',
        'refresh_token': 'refresh',
        'expires_at': 1792987203,
        'expires_in': 3600,
      });

      expect(session.accessToken, 'token');
      expect(session.expiresAt, isNotNull);
      expect(session.expiresAt!.isUtc, isTrue);
      expect(session.expiresAt!.millisecondsSinceEpoch, 1792987203000);
    });

    test('accepts expires_at as a numeric string from a redirect fragment', () {
      final session = Session.fromJson({
        'access_token': 'token',
        'expires_at': '1792987203',
      });

      expect(session.expiresAt!.millisecondsSinceEpoch, 1792987203000);
    });

    test('computes the expiry from expires_in when expires_at is absent', () {
      final before = DateTime.now().toUtc();
      final session = Session.fromJson({
        'access_token': 'token',
        'expires_in': 3600,
      });

      final delta = session.expiresAt!.difference(before).inMinutes;
      expect(delta, inInclusiveRange(59, 61));
    });

    test('a session without expiry information still parses', () {
      final session = Session.fromJson({'access_token': 'token'});

      expect(session.expiresAt, isNull);
    });
  });

  group('RegistrationResult', () {
    final user = AuthUser.fromJson(userJson(withIdentity: true));

    test('confirmationRequired reports requiresConfirmation', () {
      final result = RegistrationResult(
        user: user,
        outcome: RegistrationOutcome.confirmationRequired,
        email: 'jane@example.com',
      );

      expect(result.requiresConfirmation, isTrue);
      expect(result.profile, isNull);
    });

    test('signedIn does not require confirmation', () {
      final result = RegistrationResult(
        user: user,
        outcome: RegistrationOutcome.signedIn,
        email: 'jane@example.com',
      );

      expect(result.requiresConfirmation, isFalse);
    });
  });

  group('EmailAlreadyRegisteredException', () {
    test('carries its own code so the UI can branch on type', () {
      final error = EmailAlreadyRegisteredException('taken');

      expect(error, isA<AppException>());
      expect(error.code, 'email_taken');
    });
  });
}
