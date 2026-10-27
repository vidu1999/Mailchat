import 'package:flutter/foundation.dart';

import 'package:mailchat/core/network/transport_failure.dart';

/// Whether the app can currently reach the server, in the one place the UI can
/// listen to.
///
/// Why this exists: when the phone loses its network the app looks *frozen*.
/// The chat list keeps showing the last rows it loaded, the realtime socket
/// retries silently every 60 seconds, and the only sign of trouble is a stack
/// trace in the console that the person holding the phone never sees. Worse,
/// they blame the app — the report that produced this class was "calls and
/// messages are broken", and the actual cause was a phone that could not resolve
/// any hostname.
///
/// Fed by two existing choke points rather than a connectivity plugin (there is
/// no pub.dev access in this project's CI):
///
///   * [SupabaseClient] calls [reportSuccess] on every 2xx response and
///     [reportFailure] on every transport failure;
///   * the realtime client does the same as it connects and retries.
///
/// Deliberately optimistic in one direction: only a *successful request* marks
/// the app online again. A dropped socket or a failed retry never does, because
/// that is exactly the state where saying "back online" would be a lie.
class ConnectionStatus extends ChangeNotifier {
  ConnectionStatus();

  /// The instance the app uses.
  static final ConnectionStatus instance = ConnectionStatus();

  bool _offline = false;
  TransportFailure? _cause;
  int _consecutiveFailures = 0;

  /// True once a request has failed and none has succeeded since.
  bool get isOffline => _offline;

  /// The classified reason for the last failure, or null while online.
  TransportFailure? get cause => _cause;

  /// How many failures have arrived since the last success. Used to keep a
  /// flapping connection from turning the banner on and off every second.
  int get consecutiveFailures => _consecutiveFailures;

  /// What to show the user: the cause, in words that point at a fix.
  ///
  /// Every sentence names something the person can actually check. "Network
  /// error" does not, and the four causes here have four different fixes — a
  /// name-resolution problem is never fixed by reinstalling the app.
  String get advice => switch (_cause) {
        TransportFailure.dnsLookup =>
          'This phone cannot look up addresses right now. Messages will not '
              'send until it can — check Wi-Fi or mobile data, then turn off '
              'Data saver or Private DNS.',
        TransportFailure.unreachable =>
          'This phone has no route to the network. Messages will not send until '
              'it does — check that mobile data or Wi-Fi is actually on.',
        TransportFailure.timeout =>
          'The connection is accepted and then goes quiet — usually a captive '
              'portal, a VPN or a very weak signal.',
        TransportFailure.certificate =>
          'Something is intercepting HTTPS — a corporate proxy, a VPN or a '
              'captive portal. Messages cannot be secured through it.',
        TransportFailure.refused =>
          'The server refused the connection. If this project URL is correct, '
              'check the network for a blocking firewall.',
        TransportFailure.unknown || null =>
          'The server cannot be reached right now. Messages will not send until '
              'the connection is back.',
      };

  /// A request the app needed could not be made.
  ///
  /// Notifies only when the state changes: during an outage every heartbeat and
  /// every retry fails, and rebuilding the banner for each one is pointless work
  /// in the middle of a problem.
  void reportFailure(Object cause) {
    final kind = classifyTransportFailure(cause);
    final wasOffline = _offline;
    _offline = true;
    _cause = kind;
    _consecutiveFailures++;
    if (!wasOffline) notifyListeners();
  }

  /// A request succeeded. The only way back to online.
  void reportSuccess() {
    _consecutiveFailures = 0;
    if (!_offline) return;
    _offline = false;
    _cause = null;
    notifyListeners();
  }
}
