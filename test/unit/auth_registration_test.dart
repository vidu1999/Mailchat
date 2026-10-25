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
