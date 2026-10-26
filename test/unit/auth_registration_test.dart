import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/errors/app_exception.dart';
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

  group('normalizeSignupPayload', () {
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
      final payload = SupabaseClient.normalizeSignupPayload(bareUser());

      expect(payload['user'], isA<Map>());
      expect(payload['session'], isNull);
    });

    test('the bare object still carries identity and confirmation data', () {
      final payload = SupabaseClient.normalizeSignupPayload(bareUser());
      final user = AuthUser.fromJson(payload['user'] as Map<String, dynamic>);

      expect(user.isPlaceholderForExistingAccount, isFalse);
      expect(user.confirmationSentAt, isNotNull);
      expect(user.username, 'jane');
    });

    test('an existing address is still detected in the bare shape', () {
      final json = bareUser()
        ..['identities'] = <Map<String, dynamic>>[]
        ..remove('confirmation_sent_at');
      final payload = SupabaseClient.normalizeSignupPayload(json);
      final user = AuthUser.fromJson(payload['user'] as Map<String, dynamic>);

      expect(user.isPlaceholderForExistingAccount, isTrue);
    });

    test('the documented wrapped shape is passed through', () {
      final payload = SupabaseClient.normalizeSignupPayload({
        'user': bareUser(),
        'session': null,
      });

      expect(payload['user'], isA<Map>());
      expect(payload['session'], isNull);
    });

    test('a session payload keeps its session', () {
      final payload = SupabaseClient.normalizeSignupPayload({
        'user': bareUser(),
        'session': {'access_token': 'token'},
      });

      expect(payload['session'], {'access_token': 'token'});
    });

    test('rebuilds a session from sibling token fields', () {
      // Older GoTrue puts the tokens next to `user` rather than in `session`.
      final payload = SupabaseClient.normalizeSignupPayload({
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
      expect(SupabaseClient.normalizeSignupPayload(error), error);
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
