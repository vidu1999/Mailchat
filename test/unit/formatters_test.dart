import 'package:flutter_test/flutter_test.dart';
import 'package:mailchat/core/utils/formatters.dart';

void main() {
  group('AppFormatters.chatTimestamp', () {
    final now = DateTime(2026, 6, 15, 12, 0);

    test('shows time for messages sent today', () {
      final result = AppFormatters.chatTimestamp(
        DateTime(2026, 6, 15, 9, 30),
        now: now,
      );
      expect(result, contains(':'));
      expect(result.toLowerCase(), anyOf(contains('am'), contains('pm')));
    });

    test('shows "Yesterday" for the previous calendar day', () {
      final result = AppFormatters.chatTimestamp(
        DateTime(2026, 6, 14, 22, 0),
        now: now,
      );
      expect(result.toLowerCase(), contains('yesterday'));
    });

    test('shows a short date for older messages', () {
      final result = AppFormatters.chatTimestamp(
        DateTime(2026, 3, 2, 8, 0),
        now: now,
      );
      expect(result, isNotEmpty);
      expect(result.toLowerCase(), isNot(contains('yesterday')));
    });
  });

  group('AppFormatters.chatDayLabel', () {
    final now = DateTime(2026, 6, 15, 12, 0);

    test('labels today and yesterday', () {
      expect(
        AppFormatters.chatDayLabel(DateTime(2026, 6, 15, 8), now: now),
        'Today',
      );
      expect(
        AppFormatters.chatDayLabel(DateTime(2026, 6, 14, 23), now: now),
        'Yesterday',
      );
    });

    test('uses weekday for recent history and a numeric date for older history', () {
      expect(
        AppFormatters.chatDayLabel(DateTime(2026, 6, 12, 9), now: now),
        'Friday',
      );
      expect(
        AppFormatters.chatDayLabel(DateTime(2026, 5, 1, 9), now: now),
        '01/05/2026',
      );
    });
  });

  test('message time always includes the sent time', () {
    expect(AppFormatters.messageTime(DateTime(2026, 6, 15, 20, 23)), '8:23 PM');
  });

  group('AppFormatters.fileSize', () {
    test('formats bytes, kilobytes and megabytes', () {
      expect(AppFormatters.fileSize(512), contains('B'));
      expect(AppFormatters.fileSize(2048), contains('KB'));
      expect(AppFormatters.fileSize(5 * 1024 * 1024), contains('MB'));
    });

    test('never returns an empty string', () {
      expect(AppFormatters.fileSize(0), isNotEmpty);
    });
  });

  group('AppFormatters.timeOfDay', () {
    test('renders a non-empty time', () {
      expect(AppFormatters.timeOfDay(DateTime(2026, 1, 1, 13, 5)), isNotEmpty);
    });
  });
}
