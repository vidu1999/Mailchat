import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/shared/models/message.dart';
import 'package:mailchat/shared/models/reaction_summary.dart';

MessageReaction _reaction(String userId, String emoji) => MessageReaction(
      id: 'r-$userId-$emoji',
      messageId: 'm1',
      userId: userId,
      reaction: emoji,
      createdAt: DateTime(2026, 1, 1),
    );

/// Reactions are per user, one at a time. The old toggle only removed a row
/// when the *same* emoji was tapped twice, so picking a second emoji left both
/// behind and counts inflated — "can't react properly". These tests pin the
/// grouping the UI depends on.
void main() {
  group('ReactionSummary.chips', () {
    test('groups identical emoji and counts them', () {
      final chips = ReactionSummary.chips(
        [_reaction('u1', '👍'), _reaction('u2', '👍'), _reaction('u3', '❤️')],
        'u1',
      );

      expect(chips, hasLength(2));
      expect(chips.first.emoji, '👍');
      expect(chips.first.count, 2);
      expect(chips.first.mine, isTrue);
    });

    test('puts the current user first even when theirs is rarer', () {
      final chips = ReactionSummary.chips(
        [
          _reaction('u1', '❤️'),
          _reaction('u2', '❤️'),
          _reaction('u3', '❤️'),
          _reaction('u9', '😂'),
        ],
        'u9',
      );

      expect(chips.first.emoji, '😂');
      expect(chips.first.mine, isTrue);
      expect(chips.last.emoji, '❤️');
    });

    test('one user cannot be counted twice', () {
      // A duplicate row from an older client must not inflate the badge.
      final chips = ReactionSummary.chips(
        [_reaction('u1', '👍'), _reaction('u1', '👍')],
        'u2',
      );

      expect(chips, hasLength(1));
      expect(chips.single.count, 1);
      expect(chips.single.mine, isFalse);
    });

    test('the last reaction wins when a duplicate is inconsistent', () {
      final chips = ReactionSummary.chips(
        [_reaction('u1', '👍'), _reaction('u1', '❤️')],
        'u1',
      );

      expect(chips, hasLength(1));
      expect(chips.single.emoji, '❤️');
      expect(chips.single.mine, isTrue);
    });

    test('no reactions renders nothing', () {
      expect(ReactionSummary.chips(const [], 'u1'), isEmpty);
    });

    test('skips blank rows instead of rendering an empty chip', () {
      final chips = ReactionSummary.chips(
        [_reaction('', '👍'), _reaction('u1', '')],
        'u1',
      );

      expect(chips, isEmpty);
    });

    test('order is stable for equal counts', () {
      final chips = ReactionSummary.chips(
        [_reaction('u1', '😂'), _reaction('u2', '👍')],
        'nobody',
      );

      expect(chips.map((c) => c.emoji).toList(), ['😂', '👍']);
      expect(chips.every((c) => !c.mine), isTrue);
    });
  });

  group('ReactionSummary.myReaction', () {
    test('finds the emoji the user already picked', () {
      expect(
        ReactionSummary.myReaction(
          [_reaction('u1', '👍'), _reaction('u2', '❤️')],
          'u2',
        ),
        '❤️',
      );
    });

    test('is null when the user has not reacted', () {
      expect(ReactionSummary.myReaction([_reaction('u1', '👍')], 'u2'), isNull);
      expect(ReactionSummary.myReaction(const [], 'u1'), isNull);
    });
  });

  group('ReactionSummary.describe', () {
    test('describes chips for screen readers, singular and plural', () {
      final chips = ReactionSummary.chips(
        [_reaction('u1', '👍'), _reaction('u2', '👍')],
        'u1',
      );

      final label = ReactionSummary.describe(chips);
      expect(label, contains('2 reactions'));
      expect(label, contains('including you'));
    });

    test('says one reaction for one', () {
      final chips = ReactionSummary.chips([_reaction('u1', '❤️')], 'u2');
      expect(ReactionSummary.describe(chips), contains('1 reaction ❤️'));
      expect(ReactionSummary.describe(chips), isNot(contains('including you')));
    });

    test('says so when there are none', () {
      expect(ReactionSummary.describe(const []), 'No reactions');
    });
  });
}
