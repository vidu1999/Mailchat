import 'package:flutter_test/flutter_test.dart';
import 'package:mailchat/shared/services/notification_service.dart';

void main() {
  group('NotificationPreferences', () {
    test('defaults new message, missed call, and system alerts on', () {
      final preferences = NotificationPreferences.fromJson(const {});
      expect(preferences.messages, isTrue);
      expect(preferences.calls, isTrue);
      expect(preferences.system, isTrue);
      expect(preferences.reactions, isFalse);
    });

    test('round trips all account notification switches', () {
      const preferences = NotificationPreferences(
        messages: false,
        mentions: false,
        reactions: true,
        calls: false,
        system: false,
        muted: true,
      );
      final restored = NotificationPreferences.fromJson(preferences.toJson());
      expect(restored.messages, isFalse);
      expect(restored.mentions, isFalse);
      expect(restored.reactions, isTrue);
      expect(restored.calls, isFalse);
      expect(restored.system, isFalse);
      expect(restored.muted, isTrue);
    });
  });

  test('parses durable event and tap-through payload', () {
    final notification = MailNotification.fromJson({
      'id': 'event-1',
      'notification_type': 'message',
      'title': 'Rhea',
      'body': 'Hello',
      'created_at': '2026-10-29T10:00:00Z',
      'read_at': null,
      'payload': {
        'conversationId': 'conversation-1',
        'conversationType': 'direct',
        'actorId': 'user-2',
      },
    });
    expect(notification.read, isFalse);
    expect(notification.type, 'message');
    expect(notification.payload['conversationId'], 'conversation-1');
    expect(notification.payload['actorId'], 'user-2');
  });
}
