import 'dart:async';
import 'dart:io';

/// Why a request to Supabase could not be made, in terms the user can act on.
enum TransportFailure {
  /// The device could not turn the hostname into an IP address.
  ///
  /// This is the one that gets misdiagnosed: it looks like "the server is
  /// down", but no packet ever left the phone, and the server is usually fine.
  dnsLookup,

  /// The host answered with a refusal — nothing is listening on that port.
  refused,

  /// The connection was accepted and then went quiet.
  timeout,

  /// TLS failed: wrong clock, a proxy, or a captive-portal interception.
  certificate,

  /// No route at all (airplane mode, no SIM data, Wi-Fi without internet).
  unreachable,

  /// Anything else.
  unknown,
}

/// Classifies a transport-layer exception.
///
/// Dart gives almost nothing structured here — on Android, `SocketException`
/// carries an `OSError` whose code comes from the platform C library, and the
/// message text differs between Android, iOS and desktop. The codes are checked
/// first because they are stable, with message matching as a fallback for
/// platforms that omit them.
TransportFailure classifyTransportFailure(Object cause) {
  if (cause is TimeoutException) return TransportFailure.timeout;
  if (cause is HandshakeException || cause is TlsException) {
    return TransportFailure.certificate;
  }

  final message = _messageOf(cause).toLowerCase();

  // Android's getaddrinfo returns EAI_NONAME (7) / EAI_AGAIN (-3) for "cannot
  // resolve". Dart additionally says "Failed host lookup" on every platform.
  if (message.contains('failed host lookup') ||
      message.contains('no address associated with hostname') ||
      message.contains('nodename nor servname') ||
      message.contains('name or service not known') ||
      message.contains('temporary failure in name resolution')) {
    return TransportFailure.dnsLookup;
  }
  if (_osCode(cause) == 7 && cause is SocketException) {
    // Linux/Android EAI_NONAME. Checked only for a SocketException so an
    // unrelated `errno = 7` cannot masquerade as a DNS problem.
    return TransportFailure.dnsLookup;
  }

  if (message.contains('connection refused') || _osCode(cause) == 111) {
    return TransportFailure.refused;
  }
  if (message.contains('connection timed out') ||
      message.contains('timed out')) {
    return TransportFailure.timeout;
  }
  if (message.contains('network is unreachable') ||
      message.contains('no route to host') ||
      _osCode(cause) == 101 ||
      _osCode(cause) == 113) {
    return TransportFailure.unreachable;
  }
  if (message.contains('certificate') ||
      message.contains('handshake') ||
      message.contains('ssl')) {
    return TransportFailure.certificate;
  }
  return TransportFailure.unknown;
}

/// A message that names the cause and the next thing to check.
///
/// [where] is kept out: it is a log field, and a screen that says
/// `chat_peer_presence` to a user has spent a line saying nothing.
String describeTransportFailure({
  required String host,
  required Object cause,
}) {
  final failure = classifyTransportFailure(cause);
  final detail = _messageOf(cause);

  // A switch expression rather than a statement: the enum is exhaustive by
  // construction, so a future cause cannot be added without giving it advice.
  return switch (failure) {
    // The single most useful thing to say: the phone cannot resolve the name,
    // so no request was even attempted — and the host may well be healthy from
    // any other device, which is why this must not blame the project or key.
    TransportFailure.dnsLookup => 'This device could not look up "$host". No '
        'request left the phone, so this is a name-resolution problem, not a '
        'bad key: check that the phone itself has internet (Wi-Fi or mobile '
        'data), turn off any VPN or "Private DNS" setting, then try again.',
    TransportFailure.refused => 'The connection to "$host" was refused. The '
        'domain resolved, but nothing accepted the connection — usually a '
        'firewall, a proxy or a wrong port.',
    TransportFailure.timeout => '"$host" did not answer in time. The '
        'connection may be very slow or blocked by a firewall.',
    TransportFailure.certificate => 'The secure connection to "$host" failed. '
        'This is often a wrong device clock, or a Wi-Fi network that intercepts '
        'HTTPS (a hotel or airport login page). ($detail)',
    TransportFailure.unreachable => 'There is no network route to "$host". The '
        'device appears to be offline — check Wi-Fi or mobile data.',
    TransportFailure.unknown => 'Could not reach "$host". Check the internet '
        'connection, and that SUPABASE_URL points at a live Supabase project. '
        '($detail)',
  };
}

/// How long to wait before reconnect attempt number [attempt] (1-based).
///
/// The old behaviour retried every 5 seconds forever, which on a device with no
/// network meant two log lines and a failed socket every 5 seconds, indefinitely
/// — thousands of lines an hour, all saying the same thing. This backs off to a
/// minute and stays there: a phone that regains connectivity is picked up within
/// a minute, and the log stays readable while it waits.
Duration reconnectDelay(int attempt) {
  const base = Duration(seconds: 5);
  const ceiling = Duration(seconds: 60);
  if (attempt <= 1) return base;
  // 5, 10, 20, 40, 60, 60, ... The shift is capped at five so a device left
  // offline overnight cannot overflow it. (`num.clamp` returns num, so the
  // bound is applied with a plain comparison rather than a cast.)
  final step = attempt > 6 ? 5 : attempt - 1;
  final seconds = base.inSeconds * (1 << step);
  return seconds >= ceiling.inSeconds ? ceiling : Duration(seconds: seconds);
}

String _messageOf(Object cause) {
  if (cause is SocketException) {
    return cause.osError?.message ?? cause.message;
  }
  if (cause is HandshakeException) return cause.message;
  return cause.toString();
}

int? _osCode(Object cause) {
  if (cause is SocketException) return cause.osError?.errorCode;
  if (cause is OSError) return cause.errorCode;
  return null;
}
