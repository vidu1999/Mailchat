import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/network/rpc_payload.dart';

/// `rpc()` used to return `_asMap(payload)`, which reduces a scalar to `{}` and
/// a table to its first row. That made starting a 1:1 chat impossible: the
/// conversation id came back as an empty map, the follow-up lookup found
/// nothing, and the user saw "Failed to open the conversation" for every person
/// except the one they already had a thread with.
///
/// These tests pin the shapes PostgREST actually sends.
void main() {
  group('RpcPayload.scalar', () {
    test('reads a bare uuid string (function returns uuid)', () {
      expect(
        RpcPayload.scalar('8f14e45f-ceea-467a-9d1f-0e2e5f2b1a11'),
        '8f14e45f-ceea-467a-9d1f-0e2e5f2b1a11',
      );
    });

    test('reads an array holding one scalar (function returns setof uuid)', () {
      expect(RpcPayload.scalar(['abc-123']), 'abc-123');
    });

    test('reads a single-column row', () {
      expect(
        RpcPayload.scalar([
          {'get_or_create_direct_conversation': 'abc-123'}
        ]),
        'abc-123',
      );
    });

    test('reads a bare object with one value', () {
      expect(RpcPayload.scalar({'id': 'abc-123'}), 'abc-123');
    });

    test('returns null rather than guessing when there is no value', () {
      expect(RpcPayload.scalar(null), isNull);
      expect(RpcPayload.scalar(const <String, dynamic>{}), isNull);
      expect(RpcPayload.scalar(const []), isNull);
      expect(RpcPayload.scalar('   '), isNull);
    });

    test('refuses a multi-column row, which is not a scalar function', () {
      // Returning one of these would silently pick the wrong id.
      expect(RpcPayload.scalar({'id': 'abc-123', 'type': 'direct'}), isNull);
    });

    test('ignores non-string values', () {
      expect(RpcPayload.scalar(42), isNull);
      expect(RpcPayload.scalar([1, 2, 3]), isNull);
      expect(RpcPayload.scalar([null]), isNull);
    });
  });

  group('RpcPayload.rows', () {
    test('reads a table of rows (function returns table)', () {
      final rows = RpcPayload.rows([
        {'id': 'u1', 'username': 'alice'},
        {'id': 'u2', 'username': 'bob'},
      ]);

      expect(rows, hasLength(2));
      expect(rows.first['username'], 'alice');
    });

    test('accepts a single object as one row', () {
      expect(RpcPayload.rows({'id': 'u1'}), hasLength(1));
    });

    test('an empty array is an empty result, not an error', () {
      // This is what "nobody matched your search" looks like.
      expect(RpcPayload.rows(const []), isEmpty);
    });

    test('ignores non-map entries rather than throwing', () {
      expect(RpcPayload.rows(['oops', {'id': 'u1'}]), hasLength(1));
      expect(RpcPayload.rows('nonsense'), isEmpty);
      expect(RpcPayload.rows(null), isEmpty);
    });

    test('copies rows into a string-keyed map', () {
      final rows = RpcPayload.rows([
        <dynamic, dynamic>{'id': 'u1'}
      ]);
      expect(rows.single['id'], 'u1');
    });
  });

  group('RpcPayload.integer', () {
    // `mark_conversation_read` returns an integer, and its zero is meaningful:
    // "nothing unread". A parser that returned 0 for an unreadable reply would
    // hide exactly the failure the badge is complaining about.
    test('reads a bare JSON number (returns integer)', () {
      expect(RpcPayload.integer(0), 0);
      expect(RpcPayload.integer(3), 3);
    });

    test('reads a one-element array (returns setof)', () {
      expect(RpcPayload.integer([0]), 0);
      expect(RpcPayload.integer([2]), 2);
    });

    test('reads a single-column row', () {
      expect(RpcPayload.integer([
        {'mark_conversation_read': 1}
      ]), 1);
    });

    test('reads a double that is whole, and the string form', () {
      expect(RpcPayload.integer(0.0), 0);
      expect(RpcPayload.integer('2'), 2);
      expect(RpcPayload.integer(' 4 '), 4);
    });

    test('refuses to guess', () {
      expect(RpcPayload.integer(null), isNull);
      expect(RpcPayload.integer('not a number'), isNull);
      expect(RpcPayload.integer(1.5), isNull);
      expect(RpcPayload.integer(const []), isNull);
      expect(RpcPayload.integer(const <String, dynamic>{}), isNull);
      // Two values is not a scalar reply.
      expect(RpcPayload.integer({'a': 1, 'b': 2}), isNull);
    });
  });
}
