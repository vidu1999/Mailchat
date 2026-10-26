import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/constants/app_constants.dart';
import 'package:mailchat/shared/models/message.dart';
import 'package:mailchat/shared/models/receipt_state.dart';

/// Ticks are only worth drawing if they mean something. Before this existed,
/// nothing wrote `message_receipts` and nothing read them, so every message
/// showed the same single grey tick regardless of what the other person had
/// done.
void main() {
  group('ReceiptState.statusFrom', () {
    test('no rows means sent, not delivered', () {
      expect(ReceiptState.statusFrom(null),
          AppConstants.messageStatusSent);
      expect(ReceiptState.statusFrom(const []),
          AppConstants.messageStatusSent);
    });

    test('a row with neither timestamp is still only sent', () {
      // The row is written when the message reaches the server, before the
      // recipient's device has acknowledged anything.
      expect(
        ReceiptState.statusFrom([
          {'message_id': 'm1', 'delivered_at': null, 'read_at': null}
        ]),
        AppConstants.messageStatusSent,
      );
    });

    test('delivered_at gives a delivered tick', () {
      expect(
        ReceiptState.statusFrom([
          {'message_id': 'm1', 'delivered_at': '2026-01-01T00:00:00Z', 'read_at': null}
        ]),
        AppConstants.messageStatusDelivered,
      );
    });

    test('read_at wins over delivered in the same row', () {
      expect(
        ReceiptState.statusFrom([
          {
            'message_id': 'm1',
            'delivered_at': '2026-01-01T00:00:00Z',
            'read_at': '2026-01-01T00:00:05Z',
          }
        ]),
        AppConstants.messageStatusRead,
      );
    });

    test('one reader out of several is enough for read', () {
      expect(
        ReceiptState.statusFrom([
          {'message_id': 'm1', 'delivered_at': '2026-01-01T00:00:00Z', 'read_at': null},
          {'message_id': 'm1', 'delivered_at': '2026-01-01T00:00:00Z', 'read_at': '2026-01-01T00:00:05Z'},
        ]),
        AppConstants.messageStatusRead,
      );
    });

    test('malformed rows are ignored rather than throwing', () {
      expect(
        ReceiptState.statusFrom(['nope', 42, null]),
        AppConstants.messageStatusSent,
      );
    });

    test('a non-list payload is treated as no receipts', () {
      expect(ReceiptState.statusFrom({'read_at': 'x'}),
          AppConstants.messageStatusSent);
    });
  });

  group('ReceiptState.isUnseen', () {
    test('true when nothing has been acknowledged', () {
      expect(ReceiptState.isUnseen(null), isTrue);
      expect(ReceiptState.isUnseen(const []), isTrue);
      expect(
        ReceiptState.isUnseen([
          {'delivered_at': null, 'read_at': null}
        ]),
        isTrue,
      );
    });

    test('false once either timestamp exists', () {
      expect(
        ReceiptState.isUnseen([
          {'delivered_at': '2026-01-01T00:00:00Z', 'read_at': null}
        ]),
        isFalse,
      );
      expect(
        ReceiptState.isUnseen([
          {'delivered_at': null, 'read_at': '2026-01-01T00:00:00Z'}
        ]),
        isFalse,
      );
    });
  });

  group('Message.fromJson', () {
    test('takes the status from embedded receipts', () {
      final message = Message.fromJson({
        'id': 'm1',
        'conversation_id': 'c1',
        'sender_id': 'u1',
        'type': 'text',
        'text': 'hi',
        'created_at': '2026-01-01T00:00:00Z',
        'message_receipts': [
          {'message_id': 'm1', 'delivered_at': '2026-01-01T00:00:01Z', 'read_at': '2026-01-01T00:00:02Z'}
        ],
      });

      expect(message.status, AppConstants.messageStatusRead);
    });

    test('falls back to sent when receipts are not embedded', () {
      final message = Message.fromJson({
        'id': 'm1',
        'conversation_id': 'c1',
        'sender_id': 'u1',
        'type': 'text',
        'text': 'hi',
        'created_at': '2026-01-01T00:00:00Z',
      });

      expect(message.status, AppConstants.messageStatusSent);
    });

    test('an explicit status still wins, so optimistic states survive', () {
      final message = Message.fromJson({
        'id': 'm1',
        'conversation_id': 'c1',
        'sender_id': 'u1',
        'type': 'text',
        'text': 'hi',
        'created_at': '2026-01-01T00:00:00Z',
        'status': AppConstants.messageStatusPending,
        'message_receipts': [
          {'message_id': 'm1', 'delivered_at': 'x', 'read_at': 'y'}
        ],
      });

      expect(message.status, AppConstants.messageStatusPending);
    });

    test('keeps the reply target', () {
      final message = Message.fromJson({
        'id': 'm2',
        'conversation_id': 'c1',
        'sender_id': 'u1',
        'type': 'text',
        'text': 're',
        'created_at': '2026-01-01T00:00:00Z',
        'reply_to_message_id': 'm1',
      });

      expect(message.replyToMessageId, 'm1');
    });
  });
}
