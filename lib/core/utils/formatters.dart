/// UI formatting helpers.
class AppFormatters {
  AppFormatters._();

  /// Formats a [DateTime] as a short time (e.g. "10:41 AM").
  static String timeOfDay(DateTime dateTime) {
    final local = dateTime.toLocal();
    // 0 -> 12 AM, 12 -> 12 PM, 13 -> 1 PM
    final int hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = local.hour >= 12 ? 'PM' : 'AM';
    return '$hour12:$minute $period';
  }

  /// Exact local send time shown inside every message bubble.
  static String messageTime(DateTime dateTime) => timeOfDay(dateTime);

  /// Date heading between message groups, like WhatsApp:
  /// Today, Yesterday, weekday for recent days, then dd/MM/yyyy.
  static String chatDayLabel(DateTime dateTime, {DateTime? now}) {
    final localDate = dateTime.toLocal();
    final reference = (now ?? DateTime.now()).toLocal();
    final today = DateTime.utc(reference.year, reference.month, reference.day);
    final messageDay =
        DateTime.utc(localDate.year, localDate.month, localDate.day);
    final difference = today.difference(messageDay).inDays;
    if (difference == 0) return 'Today';
    if (difference == 1) return 'Yesterday';
    if (difference >= 2 && difference < 7) {
      const weekdays = <String>[
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ];
      return weekdays[messageDay.weekday - 1];
    }
    final day = localDate.day.toString().padLeft(2, '0');
    final month = localDate.month.toString().padLeft(2, '0');
    return '$day/$month/${localDate.year}';
  }

  /// Formats a [DateTime] as a relative-ish chat timestamp:
  /// today -> time, yesterday -> "Yesterday", older -> short date.
  static String chatTimestamp(DateTime dateTime, {DateTime? now}) {
    final reference = (now ?? DateTime.now()).toLocal();
    final localDate = dateTime.toLocal();
    final today = DateTime(reference.year, reference.month, reference.day);
    final messageDay = DateTime(localDate.year, localDate.month, localDate.day);
    final yesterday = today.subtract(const Duration(days: 1));

    if (messageDay == today) {
      return timeOfDay(dateTime);
    }
    if (messageDay == yesterday) {
      return 'Yesterday';
    }
    return '${_monthName(localDate.month)} ${localDate.day}, ${localDate.year}';
  }

  /// Formats a last-seen timestamp for a presence line.
  ///
  /// Today shows the clock time ("10:41 AM"), yesterday the word, anything
  /// older the short date. Deliberately relative only to the day: "3 hours
  /// ago" on a heartbeat that is two minutes stale reads worse than a time.
  static String lastSeen(DateTime dateTime, {DateTime? now}) {
    final reference = (now ?? DateTime.now()).toLocal();
    final localDate = dateTime.toLocal();
    final today = DateTime(reference.year, reference.month, reference.day);
    final seenDay = DateTime(localDate.year, localDate.month, localDate.day);
    if (seenDay == today) return timeOfDay(dateTime);
    if (seenDay == today.subtract(const Duration(days: 1))) return 'yesterday';
    return '${_monthName(localDate.month)} ${localDate.day}';
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
