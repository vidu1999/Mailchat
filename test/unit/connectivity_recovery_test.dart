import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/network/connectivity_signal.dart';

/// Background: the on-device log showed the realtime client retrying a dead
/// network every five seconds, forever. Two things were wrong with that, and
/// only one of them was cosmetic:
///
///  * the flood hid everything else (fixed by the backoff in
///    transport_failure.dart), and
///  * after the network came back the client could sit for up to a minute
///    before trying again — for a messaging app, a minute of silence after
///    reconnecting looks exactly like "messages are broken".
///
/// The signal below is the trigger that fixes the second: a successful HTTPS
/// request is proof the network is up right now, so the realtime client can
/// stop waiting.
void main() {
  group('ConnectivitySignal', () {
    test('broadcasts once per recorded success', () async {
      final signal = ConnectivitySignal.instance;
      final seen = <int>[];
      final subscription = signal.activity.listen((_) => seen.add(seen.length));

      signal.recordSuccess();
      signal.recordSuccess();
      signal.recordSuccess();
      // The stream is asynchronous; one turn of the event loop is enough.
      await Future<void>.delayed(Duration.zero);

      await subscription.cancel();
      expect(seen, hasLength(3));
    });

    test('an idle signal emits nothing', () async {
      // The listener is registered for the whole app lifetime, so a spurious
      // emission would open a socket for no reason.
      final signal = ConnectivitySignal.instance;
      var count = 0;
      final subscription = signal.activity.listen((_) => count++);

      await Future<void>.delayed(const Duration(milliseconds: 20));

      await subscription.cancel();
      expect(count, 0);
    });

    test('is a single shared instance', () {
      // Both the HTTP client and the realtime client look it up, so it has to
      // be the same object or the trigger would never fire.
      expect(identical(ConnectivitySignal.instance, ConnectivitySignal.instance),
          isTrue);
    });
  });
}
