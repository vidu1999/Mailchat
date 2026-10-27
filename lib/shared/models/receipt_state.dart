import 'package:mailchat/core/constants/app_constants.dart';

/// Derives a sent/delivered/read tick from the receipt rows embedded on a
/// message (`message_receipts(*)`).
///
/// Pure, because the rules are worth pinning and because this is the difference
/// between three ticks that mean something and three ticks that are decoration.
/// Until now nothing wrote receipts and nothing read them, so every message
/// showed a single grey tick regardless of what the other person had done.
///
/// Rules:
///   * read wins — one recipient having read it is enough for a direct chat;
///   * otherwise delivered if any recipient has a `delivered_at`;
///   * otherwise `sent`, which is the honest state once the server has the row;
///   * a message still in flight (pending) is never downgraded here; the caller
///     only applies this to rows that came back from the server.
class ReceiptState {
  const ReceiptState._();

  static String statusFrom(dynamic rows) {
    if (rows is! List || rows.isEmpty) return AppConstants.messageStatusSent;

    var delivered = false;
    for (final row in rows) {
      if (row is! Map) continue;
      // A non-null timestamp is the only evidence that counts; the columns are
      // nullable, and a row is written before either state is true.
      if (row['read_at'] != null) return AppConstants.messageStatusRead;
      if (row['delivered_at'] != null) delivered = true;
    }
    return delivered
        ? AppConstants.messageStatusDelivered
        : AppConstants.messageStatusSent;
  }

  /// True when nobody has received the message yet. Used to decide whether it
  /// is worth asking the server for receipts at all.
  static bool isUnseen(dynamic rows) {
    if (rows is! List || rows.isEmpty) return true;
    return rows.every((row) =>
        row is! Map || (row['read_at'] == null && row['delivered_at'] == null));
  }

  /// Keeps the better tick when a newer row has no receipt embed.
  ///
  /// A realtime `messages` update is the message row alone. Building a
  /// [status] from that row always looks like "sent", and replacing the
  /// bubble with it used to wipe a seen double tick.
  static String keepStatus({
    required String previous,
    required String incoming,
  }) {
    return _rank(incoming) >= _rank(previous) ? incoming : previous;
  }

  static int _rank(String status) {
    switch (status) {
      case AppConstants.messageStatusRead:
        return 3;
      case AppConstants.messageStatusDelivered:
        return 2;
      case AppConstants.messageStatusSent:
        return 1;
      default:
        return 0;
    }
  }
}
