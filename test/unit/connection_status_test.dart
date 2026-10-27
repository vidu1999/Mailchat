import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/network/connection_status.dart';
import 'package:mailchat/core/network/transport_failure.dart';

/// The banner that tells someone their phone is offline comes from this object,
/// so what it says has to be both true and useful. The report that led here was
/// "messages and calls are broken" on a phone that could not resolve a single
/// hostname — an app that had said "no internet" on screen would have saved
/// hours of looking in the wrong place.
void main() {
  const dnsFailure = SocketException(
    'Failed host lookup: example.supabase.co',
    osError: OSError('No address associated with hostname', 7),
  );

  test('starts online and says nothing', () {
    final status = ConnectionStatus();
    expect(status.isOffline, isFalse);
    expect(status.cause, isNull);
    expect(status.advice, isNotEmpty);
  });

  test('a transport failure marks it offline and names the cause', () {
    final status = ConnectionStatus()..reportFailure(dnsFailure);
    expect(status.isOffline, isTrue);
    expect(status.cause, TransportFailure.dnsLookup);
    expect(status.consecutiveFailures, 1);
  });

  test('notifies once per state change, not once per failure', () {
    // An outage produces a failure every retry; rebuilding the banner for each
    // one is pointless and, in the middle of a problem, is the last place to
    // spend work.
    final status = ConnectionStatus();
    var notifications = 0;
    status.addListener(() => notifications++);

    status.reportFailure(dnsFailure);
    status.reportFailure(dnsFailure);
    status.reportFailure(const SocketException('Network is unreachable'));
    expect(notifications, 1);
    expect(status.consecutiveFailures, 3);
    // The latest cause wins: the advice must describe the current failure.
    expect(status.cause, TransportFailure.unreachable);
  });

  test('only a success brings it back online', () {
    final status = ConnectionStatus();
    var notifications = 0;
    status.addListener(() => notifications++);

    status.reportFailure(dnsFailure);
    expect(status.isOffline, isTrue);

    status.reportSuccess();
    expect(status.isOffline, isFalse);
    expect(status.cause, isNull);
    expect(status.consecutiveFailures, 0);
    expect(notifications, 2);

    // A further success while online changes nothing, so it must not notify.
    status.reportSuccess();
    expect(notifications, 2);
  });

  test('the advice names what to check for each cause', () {
    // Four causes, four different fixes. A single "network error" sentence
    // would send a user with a broken DNS setting to reinstall the app.
    String adviceFor(Object cause) =>
        (ConnectionStatus()..reportFailure(cause)).advice;

    final dns = adviceFor(dnsFailure).toLowerCase();
    expect(dns, contains('look up'));
    expect(dns, contains('private dns'));

    final unreachable =
        adviceFor(const SocketException('Network is unreachable')).toLowerCase();
    expect(unreachable, contains('no route'));

    final timeout = adviceFor(TimeoutException('timed out')).toLowerCase();
    expect(timeout, contains('portal'));

    expect(adviceFor(const SocketException('Connection refused')).toLowerCase(),
        contains('refused'));
  });
}
