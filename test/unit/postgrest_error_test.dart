import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/network/auth_error_messages.dart';
import 'package:mailchat/core/network/postgrest_error_messages.dart';

/// Schema drift is the most common runtime failure in this project, because the
/// app ships ahead of the migrations being applied. These tests pin the messages
/// that turn a raw SQLSTATE into an instruction.
///
/// The bodies are copied from real responses: this exact one appeared on device
/// as `column conversation_list.updated_at does not exist`.
void main() {
  group('PostgrestErrorMessages', () {
    test('a missing column names the migration', () {
      final message = PostgrestErrorMessages.forBody(
        '{"code":"42703","details":null,"hint":null,'
        '"message":"column conversation_list.updated_at does not exist"}',
      );

      expect(message, isNotNull);
      expect(message, contains('schema is out of date'));
      expect(message, contains('conversation_list.updated_at'));
      expect(message, contains('0001'));
    });

    test('a missing table is the same class of problem', () {
      final message = PostgrestErrorMessages.forBody(
        '{"code":"42P01","details":null,"hint":null,'
        '"message":"relation \\"public.messages\\" does not exist"}',
      );

      expect(message, contains('schema is out of date'));
      expect(message, contains('messages'));
    });

    test('a missing function is reported as schema drift, not a crash', () {
      expect(
        PostgrestErrorMessages.forBody(
          '{"code":"42883","message":"function get_or_create_direct_conversation does not exist"}',
        ),
        contains('out of date'),
      );
    });

    test('an RLS refusal is explained as a policy decision', () {
      final message = PostgrestErrorMessages.forBody(
        '{"code":"42501","message":"new row violates row-level security policy"}',
      );

      expect(message, contains('refused'));
      expect(message, contains('security.md'));
    });

    test('duplicate and foreign-key violations keep Postgres wording', () {
      expect(
        PostgrestErrorMessages.forBody(
          '{"code":"23505","message":"duplicate key value violates unique constraint"}',
        ),
        contains('duplicate key value'),
      );
      expect(
        PostgrestErrorMessages.forBody(
          '{"code":"23503","message":"insert or update violates foreign key constraint"}',
        ),
        contains('foreign key'),
      );
    });

    test('an expired session says to sign in again', () {
      expect(
        PostgrestErrorMessages.forBody('{"code":"PGRST301","message":"JWT expired"}'),
        contains('sign in again'),
      );
    });

    test('the SQLSTATE is exposed for logging', () {
      expect(
        PostgrestErrorMessages.codeIn('{"code":"42703","message":"x"}'),
        '42703',
      );
      expect(PostgrestErrorMessages.codeIn('{"nope":1}'), isNull);
      expect(PostgrestErrorMessages.codeIn('not json'), isNull);
    });

    test('ordinary prose is not mistaken for a SQLSTATE', () {
      // GoTrue bodies have `msg`, not `message`; nothing here should match.
      expect(
        PostgrestErrorMessages.forBody(
            '{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}'),
        'Invalid login credentials',
      );
    });
  });

  group('dispatcher shape rules', () {
    // The client picks a translator by payload shape. Getting this wrong would
    // show an auth error as a schema error, so the discriminators are pinned.
    test('GoTrue bodies carry error_code and are handled by the auth mapper', () {
      const body =
          '{"code":400,"error_code":"email_not_confirmed","msg":"Email not confirmed"}';
      expect(AuthErrorMessages.forBody(body), contains('Confirm your email'));
    });

    test('PostgREST bodies carry a SQLSTATE string', () {
      expect(
        PostgrestErrorMessages.codeIn('{"code":"42703","message":"x"}'),
        '42703',
      );
      expect(AuthErrorMessages.codeIn('{"code":"42703","message":"x"}'), '42703');
    });
  });
}
