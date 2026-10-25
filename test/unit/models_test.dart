import 'package:flutter_test/flutter_test.dart';
import 'package:mailchat/shared/models/conversation.dart';
import 'package:mailchat/shared/models/message.dart';
import 'package:mailchat/shared/models/profile.dart';
import 'package:mailchat/shared/models/user_device.dart';

void main() {
  group('Profile.fromJson', () {
    test('parses all fields', () {
      final profile = Profile.fromJson({
        'id': 'u1',
        'username': 'jane.doe',
        'display_name': 'Jane Doe',
        'avatar_path': 'avatars/u1/profile.jpg',
        'bio': 'Hello',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-02T00:00:00Z',
      });

      expect(profile.id, 'u1');
      expect(profile.username, 'jane.doe');
      expect(profile.displayName, 'Jane Doe');
      expect(profile.displayNameOrUsername, 'Jane Doe');
      expect(profile.avatarPath, 'avatars/u1/profile.jpg');
    });

    test('falls back to username when display name is empty', () {
      final profile = Profile.fromJson({
        'id': 'u1',
        'username': 'jane.doe',
        'display_name': '',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      });
      expect(profile.displayNameOrUsername, 'jane.doe');
    });
  });

  group('Message.fromJson', () {
    test('parses a text message', () {
      final message = Message.fromJson({
        'id': 'm1',
        'conversation_id': 'c1',
        'sender_id': 'u1',
        'type': 'text',
        'text': 'Hi there',
        'created_at': '2026-01-01T10:00:00Z',
      });

      expect(message.id, 'm1');
      expect(message.conversationId, 'c1');
      expect(message.senderId, 'u1');
      expect(message.text, 'Hi there');
      expect(message.isDeleted, isFalse);
      expect(message.isEdited, isFalse);
    });

    test('treats deleted_at as deleted and edited_at as edited', () {
      final message = Message.fromJson({
        'id': 'm2',
        'conversation_id': 'c1',
        'sender_id': 'u1',
        'type': 'text',
        'text': 'gone',
        'created_at': '2026-01-01T10:00:00Z',
        'deleted_at': '2026-01-01T11:00:00Z',
        'edited_at': '2026-01-01T10:30:00Z',
      });

      expect(message.isDeleted, isTrue);
      expect(message.isEdited, isTrue);
    });
  });

  group('Conversation.isGroup', () {
    test('is true only for type group', () {
      final group = Conversation.fromJson({
        'id': 'c1',
        'type': 'group',
        'name': 'Team',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      });
      final direct = Conversation.fromJson({
        'id': 'c2',
        'type': 'direct',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      });

      expect(group.isGroup, isTrue);
      expect(direct.isGroup, isFalse);
    });
  });

  group('ConversationListItem.fromJson', () {
    test('parses the conversation_list view row', () {
      final item = ConversationListItem.fromJson({
        'conversation': {
          'id': 'c1',
          'type': 'direct',
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': '2026-01-01T00:00:00Z',
        },
        'other_participant': {
          'id': 'u2',
          'username': 'sam',
          'display_name': 'Sam',
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': '2026-01-01T00:00:00Z',
        },
        'last_message_text': 'See you soon',
        'last_message_at': '2026-01-02T09:00:00Z',
        'unread_count': 3,
        'is_muted': true,
      });

      expect(item.title, 'Sam');
      expect(item.subtitle, 'See you soon');
      expect(item.unreadCount, 3);
      expect(item.isMuted, isTrue);
    });
  });

  group('UserDevice', () {
    test('parses platform and push token', () {
      final device = UserDevice.fromJson({
        'id': 'd1',
        'user_id': 'u1',
        'device_id': 'device-abc',
        'platform': 'android',
        'push_token': 'token',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      });

      expect(device.platform, 'android');
      expect(device.pushToken, 'token');
    });
  });
}
