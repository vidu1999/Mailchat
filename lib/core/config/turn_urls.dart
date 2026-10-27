/// Parses the value of `TURN_URL` into the relay addresses it contains.
///
/// Why this is not just "the string": a hosted TURN provider does not give you
/// one URL. It gives you four to six, all sharing one credential —
///
/// ```text
/// turn:global.relay.example.ca:80                       (UDP)
/// turn:global.relay.example.ca:80?transport=tcp         (TCP, port 80)
/// turn:global.relay.example.ca:443                      (UDP, port 443)
/// turns:global.relay.example.ca:443?transport=tcp       (TLS)
/// ```
///
/// and the TCP/TLS entries are the ones that get a call through a network that
/// drops UDP — which is most mobile networks and every restrictive Wi-Fi. A
/// user who pastes only the first line has a relay that works at home and fails
/// on mobile data, with nothing on screen to explain it. So `TURN_URL` accepts
/// the whole list, in whichever shape the dashboard copied it.
///
/// Deliberately free of `package:flutter` imports: `tool/check_config.dart` is a
/// plain `dart run` script, and it has to validate exactly the addresses the app
/// will hand to `RTCPeerConnection`.
class TurnUrls {
  const TurnUrls._();

  /// Anything that starts with a scheme, optionally followed by `//`.
  ///
  /// One pattern covers every shape worth accepting, because they all reduce to
  /// "scheme, then address": a bare `turn:host:3478`, a comma- or newline-
  /// separated list, a pasted `iceServers` JSON snippet, and a list of quoted
  /// strings. Characters that only ever appear as separators (`"`, `'`, `,`,
  /// `;`, brackets) are excluded from the address itself.
  static final RegExp _address = RegExp(
    r'''[A-Za-z][A-Za-z0-9+.\-]*:\/{0,2}[^\s"',;\[\]{}]+''',
  );

  /// Every relay address in [raw], in the order given, de-duplicated.
  ///
  /// `stun:` is intentionally not a relay — it discovers an address but cannot
  /// forward media, which is the whole reason TURN exists — so `stun:` entries
  /// and outright nonsense are dropped rather than passed on:
  /// an ICE server list containing one invalid entry fails silently, so a bad
  /// paste would look exactly like a network that will not connect.
  ///
  /// A URL with a port but no transport is kept as-is; only the scheme is
  /// rewritten, and only when it cannot be used as-is (see [_normalise]).
  static List<String> parse(String? raw) {
    if (raw == null) return const <String>[];
    final urls = <String>[];
    final seen = <String>{};
    for (final match in _address.allMatches(raw)) {
      final url = _normalise(match.group(0)!);
      if (url == null || !seen.add(url)) continue;
      urls.add(url);
    }
    return List<String>.unmodifiable(urls);
  }

  /// The host and port of each relay in [raw], without scheme, query or
  /// credentials.
  ///
  /// Why not just print the URL: `turn:user:secret@relay.example.com:3478` is a
  /// valid TURN URL, and this list goes into a log line the user is asked to
  /// paste into a bug report. The host is the part that answers "is a relay
  /// configured at all, and which one?"; the rest is the shared secret.
  static List<String> hosts(String? raw) {
    final result = <String>[];
    for (final url in parse(raw)) {
      final host = _hostOf(url);
      if (host != null && !result.contains(host)) result.add(host);
    }
    return List<String>.unmodifiable(result);
  }

  /// True when at least one relay can carry media over TCP or TLS.
  ///
  /// This is the difference between a relay that works and one that works only
  /// where UDP is allowed: mobile networks and restrictive Wi-Fi routinely drop
  /// UDP, and a UDP-only relay then fails exactly like no relay at all.
  static bool hasFallback(String? raw) => parse(raw).any(
        (url) => url.startsWith('turns:') || url.contains('transport=tcp'),
      );

  static String? _hostOf(String url) {
    var rest = url.substring(url.indexOf(':') + 1);
    final at = rest.lastIndexOf('@');
    if (at >= 0) rest = rest.substring(at + 1);
    final query = rest.indexOf('?');
    if (query >= 0) rest = rest.substring(0, query);
    rest = rest.replaceFirst(RegExp(r'^/+'), '');
    return rest.isEmpty ? null : rest;
  }

  /// Rewrites [raw] to a scheme `RTCPeerConnection` accepts, or returns null.
  ///
  /// The `http(s)://` translation is not pedantry: `RTCPeerConnection` only
  /// understands `turn:` and `turns:`, and some dashboards and most tutorials
  /// copied from a web example print the port-443 entry as `https://host:443`.
  /// Left alone, that entry is an ICE server the native stack rejects, and the
  /// failure surfaces as "could not connect" with no clue why.
  static String? _normalise(String raw) {
    var value = raw.trim();
    while (value.isNotEmpty &&
        (value.endsWith(',') ||
            value.endsWith(';') ||
            value.endsWith('"') ||
            value.endsWith("'"))) {
      value = value.substring(0, value.length - 1).trim();
    }
    if (value.isEmpty) return null;

    final lower = value.toLowerCase();
    final String scheme;
    final String rest;
    if (lower.startsWith('turns:')) {
      scheme = 'turns';
      rest = value.substring('turns:'.length);
    } else if (lower.startsWith('turn:')) {
      scheme = 'turn';
      rest = value.substring('turn:'.length);
    } else if (lower.startsWith('https:')) {
      scheme = 'turns';
      rest = value.substring('https:'.length);
    } else if (lower.startsWith('http:')) {
      scheme = 'turn';
      rest = value.substring('http:'.length);
    } else {
      return null;
    }

    // `turn://host` and `turn:host` mean the same thing to every TURN client;
    // collapse to the canonical single-colon form.
    final host = rest.replaceFirst(RegExp(r'^/+'), '').replaceFirst(
          RegExp(r'/+$'),
          '',
        );
    if (host.isEmpty) return null;
    return '$scheme:$host';
  }
}
