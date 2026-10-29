import 'package:flutter_test/flutter_test.dart';
import 'package:mailchat/features/status/domain/user_status.dart';

void main() {
  group('UserStatus', () {
    test('maps an expiring text update and the viewer state', () {
      final status = UserStatus.fromJson(
        {
          'id': 'status-id',
          'user_id': 'owner-id',
          'status_type': 'text',
          'text': 'Hello from Colombo',
          'media_path': null,
          'background_color': 4284704497,
          'created_at': '2026-10-29T06:00:00.000Z',
          'expires_at': '2026-10-30T06:00:00.000Z',
        },
        viewerCount: 2,
        viewedByMe: true,
      );

      expect(status.isImage, isFalse);
      expect(status.text, 'Hello from Colombo');
      expect(status.viewerCount, 2);
      expect(status.viewedByMe, isTrue);
      expect(status.expiresAt.isAfter(status.createdAt), isTrue);
    });

    test('maps photo statuses without a text payload', () {
      final status = UserStatus.fromJson({
        'id': 'photo-id',
        'user_id': 'owner-id',
        'status_type': 'image',
        'text': null,
        'media_path': 'owner-id/photo-id/photo.jpg',
        'created_at': '2026-10-29T06:00:00.000Z',
        'expires_at': '2026-10-30T06:00:00.000Z',
      });

      expect(status.isImage, isTrue);
      expect(status.mediaPath, 'owner-id/photo-id/photo.jpg');
      expect(status.backgroundColor, 0xFF6366F1);
    });
  });
}
