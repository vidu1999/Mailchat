import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/network/connection_status.dart';
import 'package:mailchat/shared/widgets/offline_banner.dart';

/// The banner is the only place the app admits it is offline. Two properties
/// matter: it is invisible while things work (no permanent clutter), and it
/// disappears again by itself once a request succeeds (no stuck "offline" that
/// would make a working app look broken).
void main() {
  const dnsFailure = SocketException(
    'Failed host lookup: example.supabase.co',
    osError: OSError('No address associated with hostname', 7),
  );

  setUp(() {
    // The status is a singleton the real client feeds, so each test starts from
    // a known state.
    ConnectionStatus.instance.reportSuccess();
  });

  Future<void> pumpBanner(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: OfflineBanner()),
      ),
    );
  }

  testWidgets('shows nothing while online', (tester) async {
    await pumpBanner(tester);
    expect(find.byIcon(Icons.cloud_off_outlined), findsNothing);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('appears with the cause in words after a failed request',
      (tester) async {
    await pumpBanner(tester);

    ConnectionStatus.instance.reportFailure(dnsFailure);
    await tester.pump();

    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
    expect(find.textContaining('look up'), findsOneWidget);
    // The message has to say what happens to the user's messages, not just that
    // something failed.
    expect(find.textContaining('will not send'), findsOneWidget);
  });

  testWidgets('goes away again when a request succeeds', (tester) async {
    await pumpBanner(tester);

    ConnectionStatus.instance.reportFailure(dnsFailure);
    await tester.pump();
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);

    ConnectionStatus.instance.reportSuccess();
    await tester.pump();
    expect(find.byIcon(Icons.cloud_off_outlined), findsNothing);
  });
}
