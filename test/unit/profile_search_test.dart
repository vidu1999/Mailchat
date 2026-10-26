import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/network/postgrest_error_messages.dart';
import 'package:mailchat/shared/models/profile_search.dart';

/// User search accepts an email address as well as a username. The matching
/// itself happens in the database (`public.search_users`), but two things are
/// decided on the client and are worth pinning:
///
///  * when typing becomes a search at all — one keystroke must not fire a
///    request that probes the whole directory;
///  * what an empty result says, because "no results" for an address is the
///    normal outcome when that person has email discovery switched off, and it
///    must not read like a bug.
void main() {
  group('SearchQuery classification', () {
    test('recognises an email address', () {
      expect(const SearchQuery('jane@example.com').looksLikeEmail, isTrue);
      expect(const SearchQuery('  Jane@Example.COM  ').normalised().looksLikeEmail,
          isTrue);
      expect(const SearchQuery('first.last+tag@sub.example.co.uk').looksLikeEmail,
          isTrue);
    });

    test('treats usernames and names as profile queries', () {
      expect(const SearchQuery('jane.doe').looksLikeEmail, isFalse);
      expect(const SearchQuery('Jane Doe').looksLikeEmail, isFalse);
      expect(const SearchQuery('').looksLikeEmail, isFalse);
    });

    test('rejects almost-addresses rather than guessing', () {
      // The server matches addresses with `=`, so a malformed one simply finds
      // nobody. Classification only affects wording, and must not claim an
      // address was searched for when it clearly was not.
      expect(const SearchQuery('@example.com').looksLikeEmail, isFalse);
      expect(const SearchQuery('jane@').looksLikeEmail, isFalse);
      expect(const SearchQuery('jane@example').looksLikeEmail, isFalse);
      expect(const SearchQuery('jane@.com').looksLikeEmail, isFalse);
      expect(const SearchQuery('jane@example.com.').looksLikeEmail, isFalse);
      expect(const SearchQuery('a@b@example.com').looksLikeEmail, isFalse);
    });

    test('a single character is not searchable', () {
      expect(const SearchQuery('a').isSearchable, isFalse);
      expect(const SearchQuery('  a  ').isSearchable, isFalse);
      expect(const SearchQuery('ab').isSearchable, isTrue);
      expect(const SearchQuery(' jane@example.com ').isSearchable, isTrue);
    });

    test('empty input is reported as empty after trimming', () {
      expect(const SearchQuery('   ').isEmpty, isTrue);
      expect(const SearchQuery('   ').normalised().text, isEmpty);
      expect(const SearchQuery('  jane  ').normalised().text, 'jane');
    });

    test('normalising keeps case, so the field is not rewritten under the user', () {
      // Matching is case-insensitive server-side; the UI echoes what was typed.
      expect(const SearchQuery('  Jane@Example.COM ').normalised().text,
          'Jane@Example.COM');
    });
  });

  group('Empty-result wording', () {
    test('an address search explains the discoverability rule', () {
      final message = const SearchQuery('jane@example.com').emptyResultMessage;

      expect(message, contains('email'));
      expect(message.toLowerCase(), contains('account'));
      // The common case is that the person turned email discovery off, and the
      // message points at the alternative that still works.
      expect(message.toLowerCase(), contains('username'));
    });

    test('a handle search points at the email option', () {
      final message = const SearchQuery('jane').emptyResultMessage;

      expect(message, contains('jane'));
      expect(message.toLowerCase(), contains('email address'));
    });

    test('the idle hint mentions both ways to search', () {
      expect(const SearchQuery('').hintMessage.toLowerCase(),
          contains('username'));
      expect(const SearchQuery('').hintMessage.toLowerCase(), contains('email'));

      final emailHint = const SearchQuery('jane@example.com').hintMessage;
      // Typing an address should warn that discovery is opt-out, so an empty
      // result is not mistaken for a typo.
      expect(emailHint.toLowerCase(), contains('discovery'));
    });
  });

  group('Schema drift for user search', () {
    test('a missing search_users function names migration 0005', () {
      // PostgREST answers 404 PGRST202 when the RPC itself is absent, which is
      // what a project that has not applied 0005 returns.
      final message = PostgrestErrorMessages.forBody(
        '{"code":"PGRST202","message":"Could not find the function '
        'public.search_users(p_limit, p_query) in the schema cache"}',
      );

      expect(message, isNotNull);
      expect(message, contains('schema is out of date'));
      expect(message, contains('0005'));
    });

    test('a missing column still names the migrations', () {
      final message = PostgrestErrorMessages.forBody(
        '{"code":"42703","message":"column profiles.discoverable_by_email '
        'does not exist"}',
      );

      expect(message, contains('0005'));
      expect(message, contains('discoverable_by_email'));
    });
  });
}
