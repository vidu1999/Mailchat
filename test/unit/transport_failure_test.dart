import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/network/transport_failure.dart';

/// Background: the first on-device run after the app finally built reported
///
/// ```text
/// SocketException: Failed host lookup: 'xyz.supabase.co'
/// (OS Error: No address associated with hostname, errno = 7)
/// ```
///
/// under four different call sites, each with the same advice — "check your
/// internet connection, and confirm SUPABASE_URL points at a live project". That
/// advice is wrong in the common case: the project was healthy and resolvable
/// from every other machine; the *phone* had no working DNS, so no packet ever
/// left it. These tests pin the mapping from OS error to cause, and the advice
/// that follows, so the message cannot drift back into blaming the server.
void main() {
  group('classifyTransportFailure', () {
    test("Android's DNS failure is a lookup problem", () {
      // The exact exception seen on the device: osError code 7 (EAI_NONAME)
      // and the message Android builds from it.
      final error = const SocketException(
        'Failed host lookup: \'xcokviruqhnxbshadahp.supabase.co\'',
        osError: OSError('No address associated with hostname', 7),
      );
      expect(classifyTransportFailure(error), TransportFailure.dnsLookup);
    });

    test('a lookup failure is recognised from the message alone', () {
      // Not every platform fills in osError, and the desktop wording differs.
      expect(
        classifyTransportFailure(
          const SocketException('Failed host lookup: \'example.com\''),
        ),
        TransportFailure.dnsLookup,
      );
      expect(
        classifyTransportFailure(
          const SocketException(
            'nodename nor servname provided, or not known',
          ),
        ),
        TransportFailure.dnsLookup,
      );
    });

    test('an unrelated errno 7 is not mistaken for a DNS problem', () {
      // Only a SocketException may be classified by code 7 -- otherwise a
      // generic OSError would be reported as "the phone cannot resolve names".
      expect(
        classifyTransportFailure(const OSError('Bad file descriptor', 7)),
        TransportFailure.unknown,
      );
    });

    test('refused, unreachable, timeout and TLS are distinct', () {
      expect(
        classifyTransportFailure(
          const SocketException(
            'Connection refused',
            osError: OSError('Connection refused', 111),
          ),
        ),
        TransportFailure.refused,
      );
      expect(
        classifyTransportFailure(
          const SocketException(
            'Network is unreachable',
            osError: OSError('Network is unreachable', 101),
          ),
        ),
        TransportFailure.unreachable,
      );
      expect(
        classifyTransportFailure(TimeoutException('Connection timed out')),
        TransportFailure.timeout,
      );
      expect(
        classifyTransportFailure(
          const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
        ),
        TransportFailure.certificate,
      );
    });

    test('anything unrecognised stays unknown rather than inventing a cause', () {
      expect(
        classifyTransportFailure(StateError('something odd')),
        TransportFailure.unknown,
      );
    });
  });

  group('describeTransportFailure', () {
    test('a lookup failure points at the device, not at the project', () {
      final message = describeTransportFailure(
        host: 'xyz.supabase.co',
        cause: const SocketException(
          'Failed host lookup: \'xyz.supabase.co\'',
          osError: OSError('No address associated with hostname', 7),
        ),
      );
      // Names the host and the actual layer.
      expect(message, contains('xyz.supabase.co'));
      expect(message.toLowerCase(), contains('look up'));
      expect(message, contains('No request left the phone'));
      // And offers the two settings that actually cause it.
      expect(message.toLowerCase(), contains('internet'));
      expect(message.toLowerCase(), contains('vpn'));
      // It must not tell the user their project or key is wrong: that was the
      // misdirection that made this take a support round-trip.
      expect(message.toLowerCase(), isNot(contains('supabase_url')));
    });

    test('a refusal does not blame name resolution', () {
      final message = describeTransportFailure(
        host: 'xyz.supabase.co',
        cause: const SocketException('Connection refused'),
      );
      expect(message, contains('refused'));
      expect(message.toLowerCase(), isNot(contains('look up')));
    });

    test('an unknown failure still names the host and the URL setting', () {
      final message = describeTransportFailure(
        host: 'xyz.supabase.co',
        cause: StateError('boom'),
      );
      expect(message, contains('xyz.supabase.co'));
      expect(message, contains('SUPABASE_URL'));
    });

    test('no message leaks a key or a URL path', () {
      for (final cause in <Object>[
        const SocketException('Failed host lookup: \'xyz.supabase.co\''),
        const SocketException('Connection refused'),
        TimeoutException('slow'),
        StateError('boom'),
      ]) {
        final message =
            describeTransportFailure(host: 'xyz.supabase.co', cause: cause);
        expect(message, isNot(contains('apikey')));
        expect(message, isNot(contains('Authorization')));
        expect(message, isNot(contains('/rest/v1')));
      }
    });
  });

  group('reconnectDelay', () {
    test('starts at five seconds and backs off', () {
      expect(reconnectDelay(1), const Duration(seconds: 5));
      expect(reconnectDelay(2), const Duration(seconds: 10));
      expect(reconnectDelay(3), const Duration(seconds: 20));
      expect(reconnectDelay(4), const Duration(seconds: 40));
    });

    test('caps at a minute and stays there', () {
      // A long outage must not produce an ever-growing timer or an unbounded
      // shift; the old code retried every five seconds forever instead.
      for (final attempt in [5, 6, 7, 50, 1000]) {
        expect(reconnectDelay(attempt), const Duration(seconds: 60));
      }
    });

    test('nonsense attempts do not throw', () {
      expect(reconnectDelay(0), const Duration(seconds: 5));
      expect(reconnectDelay(-3), const Duration(seconds: 5));
    });
  });
}
