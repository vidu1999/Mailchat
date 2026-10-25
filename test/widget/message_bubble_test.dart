import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailchat/core/theme/app_theme.dart';
import 'package:mailchat/shared/models/message.dart';
import 'package:mailchat/shared/widgets/message_bubble.dart';

Message _message({
  String text = 'Hello',
  String senderId = 'u1',
  String status = 'sent',
  DateTime? createdAt,
  DateTime? deletedAt,
}) {
  return Message(
    id: 'm1',
    conversationId: 'c1',
    senderId: senderId,
    type: 'text',
    text: text,
    createdAt: createdAt ?? DateTime(2026, 1, 1, 12),
    status: status,
    deletedAt: deletedAt,
  );
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('renders message text', (tester) async {
    await tester.pumpWidget(_wrap(MessageBubble(message: _message(), isMe: true)));

    expect(find.text('Hello'), findsOneWidget);
  });

  testWidgets('renders deleted placeholder instead of original text',
      (tester) async {
    await tester.pumpWidget(
      _wrap(MessageBubble(
        message: _message(text: 'secret', deletedAt: DateTime(2026, 1, 1, 13)),
        isMe: true,
      )),
    );

    expect(find.text('secret'), findsNothing);
  });

  testWidgets('shows a delivery status icon only for own messages',
      (tester) async {
    await tester.pumpWidget(
      _wrap(MessageBubble(
          message: _message(status: 'read'), isMe: true, showStatus: true)),
    );
    final ownIcons = tester.widgetList<Icon>(find.byType(Icon)).length;

    await tester.pumpWidget(
      _wrap(MessageBubble(
          message: _message(status: 'read'), isMe: false, showStatus: false)),
    );
    final otherIcons = tester.widgetList<Icon>(find.byType(Icon)).length;

    expect(ownIcons, greaterThan(otherIcons));
  });

  testWidgets('does not overflow on a long unbroken message', (tester) async {
    await tester.pumpWidget(
      _wrap(MessageBubble(
        message: _message(text: 'a' * 500),
        isMe: false,
      )),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('long press invokes the callback', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _wrap(MessageBubble(
        message: _message(),
        isMe: true,
        onLongPress: () => tapped = true,
      )),
    );

    await tester.longPress(find.text('Hello'));
    await tester.pump();

    expect(tapped, isTrue);
  });
}
