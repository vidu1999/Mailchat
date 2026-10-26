import 'package:mailchat/core/utils/formatters.dart';

/// What the UI is allowed to know about one other user's presence.
///
/// Produced by `public.get_presence()` (migration 0008), which returns null for
/// both fields when that user has turned offline status sharing off. Null is
/// therefore "unknown", not "offline" — a distinction the UI must respect
/// rather than filling in with a grey dot.
class PeerPresence {
  final String userId;

  /// True when the last heartbeat is inside the online window, null when the
  /// owner hides their status.
  final bool? online;

  /// The last heartbeat, null when hidden or unknown.
  final DateTime? lastSeenAt;

  /// The owner has status sharing off, so this app has nothing to show.
  final bool hidden;

  const PeerPresence({
    required this.userId,
    this.online,
    this.lastSeenAt,
    this.hidden = false,
  });

  /// Rows carry `user_id`, `online` (nullable) and `last_seen_at` (nullable).
  factory PeerPresence.fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'];
    final rawOnline = json['online'];
    final rawSeen = json['last_seen_at'];
    final online = rawOnline is bool ? rawOnline : null;
    final seen = rawSeen is String ? DateTime.tryParse(rawSeen)?.toLocal() : null;
    return PeerPresence(
      userId: userId is String ? userId : '$userId',
      online: online,
      lastSeenAt: seen,
      // The server masks both fields together, so a row with no verdict is a
      // row whose owner asked not to be described.
      hidden: online == null,
    );
  }

  bool get isOnline => online == true;

  /// The subtitle to show under a name, or null when there is nothing to say.
  ///
  /// Returning null (instead of "Offline") for a hidden user is the point: the
  /// absence of information must not be rendered as a claim about them.
  String? label({DateTime? now}) {
    if (online == true) return 'Online';
    final seen = lastSeenAt;
    if (seen == null) return hidden ? null : 'Offline';
    return 'last seen ${AppFormatters.lastSeen(seen, now: now)}';
  }
}
