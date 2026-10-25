import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/theme/app_theme.dart';
import 'package:mailchat/shared/widgets/app_button.dart';
import 'package:mailchat/shared/widgets/app_error.dart';

/// Smoke tests for the design system.
///
/// This file deliberately replaces the `flutter create` template test, which
/// referenced a `MyApp` widget that does not exist in this project. Keeping a
/// real test at this path means `flutter create` will not regenerate the
/// broken template on a fresh clone.
///
/// It avoids pumping the root app so the test needs no Supabase configuration
/// and no network.
Widget _harness(Widget child) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    home: Scaffold(body: child),
  );
}

void main() {
  group('AppButton', () {
    testWidgets('renders its label and fires onPressed', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_harness(
        AppButton(text: 'Continue', onPressed: () => taps++),
      ));

      expect(find.text('Continue'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('shows a spinner and ignores taps while loading',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(_harness(
        AppButton(text: 'Continue', isLoading: true, onPressed: () => taps++),
      ));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Continue'), findsNothing);

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(taps, 0);
    });

    testWidgets('is disabled when onPressed is null', (tester) async {
      await tester.pumpWidget(_harness(const AppButton(text: 'Disabled')));

      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNull);
    });
  });

  group('AppEmptyState', () {
    testWidgets('renders title and subtitle', (tester) async {
      await tester.pumpWidget(_harness(const AppEmptyState(
        icon: Icons.forum_outlined,
        title: 'No conversations yet',
        subtitle: 'Start a chat by searching for a username.',
      )));

      expect(find.text('No conversations yet'), findsOneWidget);
      expect(
        find.text('Start a chat by searching for a username.'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.forum_outlined), findsOneWidget);
    });

    testWidgets('renders the optional action', (tester) async {
      await tester.pumpWidget(_harness(AppEmptyState(
        icon: Icons.forum_outlined,
        title: 'Empty',
        subtitle: 'Nothing here',
        action: AppButton(text: 'Reload', onPressed: () {}),
      )));

      expect(find.text('Reload'), findsOneWidget);
    });
  });
}
