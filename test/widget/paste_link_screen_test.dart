import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/theme/app_theme.dart';
import 'package:mailchat/features/auth/presentation/screens/paste_link_screen.dart';

/// The paste screen is the fallback when a confirmation link opens on another
/// device, so it has to render and explain itself without any configuration or
/// network — its submit path talks to Supabase and is covered by the unit tests
/// around AuthDeepLink instead.
void main() {
  Widget harness() => MaterialApp(
        theme: AppTheme.lightTheme,
        home: const PasteLinkScreen(),
      );

  testWidgets('explains what it is for and offers the two actions',
      (tester) async {
    await tester.pumpWidget(harness());

    expect(find.text('Paste the link from the email'), findsOneWidget);
    // Substring chosen to avoid the apostrophe, which the screen escapes.
    expect(find.textContaining('another device'), findsOneWidget);
    expect(find.text('Paste from clipboard'), findsOneWidget);
    expect(find.text('Confirm'), findsOneWidget);
  });

  testWidgets('refuses to submit an empty field', (tester) async {
    await tester.pumpWidget(harness());

    await tester.tap(find.text('Confirm'));
    await tester.pump();

    expect(find.text('Paste the link from the email first.'), findsOneWidget);
  });

  testWidgets('rejects text that is not a MailChat link', (tester) async {
    await tester.pumpWidget(harness());

    await tester.enterText(find.byType(TextFormField), 'https://example.com');
    await tester.tap(find.text('Confirm'));
    await tester.pump();

    expect(find.textContaining('does not look like a MailChat link'),
        findsOneWidget);
  });
}
