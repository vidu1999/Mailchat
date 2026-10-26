import 'package:mailchat/shared/models/message.dart';

/// One emoji chip under a message: how many people picked it, and whether the
/// current user is one of them.
class ReactionChip {
  const ReactionChip({
    required this.emoji,
    required this.count,
    required this.mine,
  });

  final String emoji;
  final int count;
  final bool mine;

  @override
  String toString() => 'ReactionChip($emoji x$count${mine ? ", mine" : ""})';
}

/// Turns the raw reaction rows into the chips shown under a bubble.
///
/// Pure, because the rules are easy to get subtly wrong and worth pinning:
///
///  * one row per (message, user) is the intended model — the UI replaces a
///    user's reaction rather than stacking them, so a duplicate from an older
///    client must not inflate a count;
///  * the current user's emoji is highlighted, and shown first, so a tap feels
///    like it landed;
///  * order is stable: count descending, then emoji, so chips do not jump
///    around between rebuilds.
class ReactionSummary {
  const ReactionSummary._();

  static List<ReactionChip> chips(
    List<MessageReaction> reactions,
    String currentUserId,
  ) {
    if (reactions.isEmpty) return const [];

    // userId -> emoji, so a duplicate row cannot be counted twice.
    final byUser = <String, String>{};
    for (final reaction in reactions) {
      if (reaction.userId.isEmpty || reaction.reaction.isEmpty) continue;
      byUser[reaction.userId] = reaction.reaction;
    }

    final counts = <String, int>{};
    for (final entry in byUser.entries) {
      counts[entry.value] = (counts[entry.value] ?? 0) + 1;
    }

    final mine = currentUserId.isEmpty ? null : byUser[currentUserId];

    final chips = counts.entries
        .map((e) => ReactionChip(
              emoji: e.key,
              count: e.value,
              mine: e.key == mine,
            ))
        .toList()
      ..sort((a, b) {
        if (a.mine != b.mine) return a.mine ? -1 : 1;
        final byCount = b.count.compareTo(a.count);
        if (byCount != 0) return byCount;
        return a.emoji.compareTo(b.emoji);
      });
    return chips;
  }

  /// The emoji this user already picked, or null. Used by the picker to show a
  /// tick and by the service to decide between add and remove.
  static String? myReaction(
    List<MessageReaction> reactions,
    String userId,
  ) {
    for (final reaction in reactions) {
      if (reaction.userId == userId) return reaction.reaction;
    }
    return null;
  }

  /// Accessibility label: screen readers get "2 people reacted 👍", not a bare
  /// emoji.
  static String describe(List<ReactionChip> chips) {
    if (chips.isEmpty) return 'No reactions';
    return chips
        .map((c) =>
            '${c.count} ${c.count == 1 ? "reaction" : "reactions"} ${c.emoji}${c.mine ? ", including you" : ""}')
        .join(', ');
  }
}
