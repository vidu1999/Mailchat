/// UI formatting helpers.
class AppFormatters {
  AppFormatters._();

  /// Formats a [DateTime] as a short time (e.g. "10:41 AM").
  static String timeOfDay(DateTime dateTime) {
    // 0 -> 12 AM, 12 -> 12 PM, 13 -> 1 PM
    final int hour12 = dateTime.hour % 12 == 0 ? 12 : dateTime.hour % 12;
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final period = dateTime.hour >= 12 ? 'PM' : 'AM';
    return '$hour12:$minute $period';
  }

  /// Formats a [DateTime] as a relative-ish chat timestamp:
  /// today -> time, yesterday -> "Yesterday", older -> short date.
  static String chatTimestamp(DateTime dateTime, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final today = DateTime(reference.year, reference.month, reference.day);
    final messageDay = DateTime(dateTime.year, dateTime.month, dateTime.day);
    final yesterday = today.subtract(const Duration(days: 1));

    if (messageDay == today) {
      return timeOfDay(dateTime);
    }
    if (messageDay == yesterday) {
      return 'Yesterday';
    }
    return '${_monthName(dateTime.month)} ${dateTime.day}, ${dateTime.year}';
  }

  /// Formats a last-seen timestamp for a presence line.
  ///
  /// Today shows the clock time ("10:41 AM"), yesterday the word, anything
  /// older the short date. Deliberately relative only to the day: "3 hours
  /// ago" on a heartbeat that is two minutes stale reads worse than a time.
  static String lastSeen(DateTime dateTime, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final today = DateTime(reference.year, reference.month, reference.day);
    final seenDay = DateTime(dateTime.year, dateTime.month, dateTime.day);
    if (seenDay == today) return timeOfDay(dateTime);
    if (seenDay == today.subtract(const Duration(days: 1))) return 'yesterday';
    return '${_monthName(dateTime.month)} ${dateTime.day}';
  }

  /// Formats a [DateTime] as a compact date (e.g. "Oct 25").
  static String shortDate(DateTime dateTime) {
    return '${_monthName(dateTime.month)} ${dateTime.day}';
  }

  static String _monthName(int month) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return months[month - 1];
  }

  /// Formats bytes into a human readable size.
  static String fileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
