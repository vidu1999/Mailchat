import 'dart:async';

/// A one-way message from "an HTTPS request succeeded" to "the realtime socket
/// may be able to reconnect now".
///
/// Why it exists: a phone that loses its network and gets it back is the normal
/// case, not an edge case — switching between Wi-Fi and mobile data does it, and
/// so does a lift, a tunnel or a dozing screen. The realtime client retries on
/// its own, but with backoff it can wait up to a minute after connectivity is
/// already back. Any successful REST call is proof the network works *right now*,
/// so it is the cheapest possible reconnect trigger — no polling, and no
/// connectivity package (there is no pub.dev access in this project's CI).
///
/// Deliberately a plain singleton with a broadcast stream: it lives below both
/// the HTTP client and the realtime client, so neither has to import the other
/// (which would be a cycle), and it cannot be forgotten when the app is
/// constructed.
class ConnectivitySignal {
  ConnectivitySignal._();

  static final ConnectivitySignal instance = ConnectivitySignal._();

  final StreamController<void> _controller = StreamController<void>.broadcast();

  /// Emits once per successful request. Nothing is emitted while the app is
  /// offline, so an idle listener costs nothing.
  Stream<void> get activity => _controller.stream;

  /// Called by the HTTP client after a 2xx response.
  ///
  /// Deliberately not called for an error response: a 401 or a 404 proves the
  /// network is up, but it also means the failure was *not* the network, and a
  /// retry loop driven by it would be noise.
  void recordSuccess() {
    if (!_controller.isClosed) _controller.add(null);
  }

  Future<void> dispose() => _controller.close();
}
