/// Parsing for the links Supabase Auth redirects back into the app.
///
/// What arrives, and why it is a fragment:
///
///   `mailchat://auth/callback#access_token=...&refresh_token=...&type=signup`
///
/// Supabase verifies the emailed token on its own server, then redirects to the
/// `redirect_to` URL with the session in the **fragment**. A fragment is used
/// so the tokens never reach a server in an HTTP request or a `Referer` header.
/// GoTrue also sends `?error=...&error_description=...` in the query string when
/// verification fails, and newer email templates can send `?token_hash=...`
/// instead of a session.
///
/// This file is deliberately free of `dart:io` and Flutter imports so it can be
/// unit tested on any platform.
library;

/// What a deep link is asking for.
enum AuthLinkKind {
  /// The emailed verification link was followed; the account is confirmed.
  confirmation,

  /// A password-recovery link; the user must choose a new password.
  recovery,

  /// Verification failed, or the link expired or was already used.
  error,
}

/// A parsed Supabase auth deep link.
class AuthDeepLink {
  final AuthLinkKind kind;

  /// Session tokens, present when Supabase verified the token server-side and
  /// redirected with the session in the fragment.
  final String? accessToken;
  final String? refreshToken;

  /// One-time token from `{{ .TokenHash }}` templates, to be exchanged through
  /// `/auth/v1/verify`. Present instead of the tokens above.
  final String? tokenHash;

  /// GoTrue's `type` parameter: `signup`, `recovery`, `email`, `magiclink`,
  /// `invite`, `email_change`.
  final String? type;

  /// `error`, `error_code` or `error_description` from a failed verification.
  final String? errorCode;
  final String? errorDescription;

  const AuthDeepLink({
    required this.kind,
    this.accessToken,
    this.refreshToken,
    this.tokenHash,
    this.type,
    this.errorCode,
    this.errorDescription,
  });

  /// True when there is something usable to act on.
  ///
  /// An error link is still actionable — it carries the message to show.
  bool get isActionable =>
      kind == AuthLinkKind.error ||
      tokenHash != null ||
      accessToken != null;

  /// Human-readable reason for a failed verification.
  ///
  /// GoTrue's messages are terse but accurate; the fallback explains the most
  /// common cause, which is reusing a link after the address was already
  /// confirmed.
  String get errorMessage {
    final detail = errorDescription?.trim();
    if (detail != null && detail.isNotEmpty) return detail;
    final code = errorCode?.trim();
    if (code != null && code.isNotEmpty) return code.replaceAll('_', ' ');
    return 'This link is no longer valid. It may have expired or already been '
        'used — open the newest email, or sign in if the account is active.';
  }

  /// Route arguments handed to the screen that handles this link.
  Map<String, dynamic> get routeArguments => {
        'notice': errorMessage,
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'tokenHash': tokenHash,
        'type': type,
      };

  /// Parses [raw] as an auth deep link, returning null when it is not one.
  ///
  /// Two URL shapes are recognised:
  ///
  ///  * a **callback** — `mailchat://auth/callback`, an https URL ending in
  ///    `/auth/callback`, or GoTrue's `/auth/v1/verify`. This is what a
  ///    correctly allow-listed `redirect_to` produces.
  ///  * a **bare site URL carrying a payload** — `http://localhost:3000/#access_token=…`.
  ///    GoTrue falls back to the project's Site URL whenever `redirect_to` is
  ///    not on its allow-list, so this is the shape most misconfigured projects
  ///    actually produce. Rejecting it means the only link the user ever
  ///    receives is one the app cannot read.
  ///
  /// [allowedHosts] guards the second shape. When it is non-empty, a link that
  /// is not a callback must point at one of those hosts. Callers pass their own
  /// configured hosts; passing an empty set means "the user supplied this link
  /// deliberately", which is the case for the paste-a-link screen.
  ///
  /// A payload is required either way (`access_token`, `token_hash`, or an
  /// error), so an ordinary link such as `mailchat://settings` is still ignored.
  static AuthDeepLink? parse(
    String? raw, {
    Set<String> allowedHosts = const {},
  }) {
    if (raw == null || raw.trim().isEmpty) return null;
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;

    // Match on scheme + host + path together. For `mailchat://auth/callback`
    // the "auth" segment is the *host*; for an https app link it is part of the
    // path — so neither alone identifies a callback.
    final signature = '${uri.scheme}://${uri.host}${uri.path}';
    final isCallback = signature.contains('mailchat://auth/callback') ||
        signature.contains('/auth/callback') ||
        signature.contains('/auth/v1/verify');

    // Query parameters first, then the fragment wins for any repeated key: when
    // both are present the fragment carries the session and the query carries
    // context such as `type`.
    final params = <String, String>{};
    params.addAll(uri.queryParameters);
    params.addAll(_parseFragment(uri.fragment));

    final errorCode = params['error_code'] ?? params['error'];
    final errorDescription = params['error_description'];
    final hasPayload = params.containsKey('access_token') ||
        params.containsKey('token_hash') ||
        (errorCode != null && errorCode.isNotEmpty) ||
        (errorDescription != null && errorDescription.isNotEmpty);

    if (!isCallback) {
      if (!hasPayload) return null;
      if (allowedHosts.isNotEmpty && !allowedHosts.contains(uri.host)) {
        return null;
      }
    }

    if ((errorCode != null && errorCode.isNotEmpty) ||
        (errorDescription != null && errorDescription.isNotEmpty)) {
      return AuthDeepLink(
        kind: AuthLinkKind.error,
        errorCode: errorCode,
        errorDescription: errorDescription,
      );
    }

    final type = params['type'];
    final accessToken = params['access_token'];
    final refreshToken = params['refresh_token'];
    final tokenHash = params['token_hash'];

    final kind = type == 'recovery'
        ? AuthLinkKind.recovery
        : AuthLinkKind.confirmation;

    if (accessToken == null && tokenHash == null) {
      // A callback with neither is a failure even without an explicit error:
      // there is nothing to exchange and no message to show otherwise.
      return AuthDeepLink(
        kind: AuthLinkKind.error,
        type: type,
        errorCode: 'missing_token',
      );
    }

    return AuthDeepLink(
      kind: kind,
      accessToken: accessToken,
      refreshToken: refreshToken,
      tokenHash: tokenHash,
      type: type,
    );
  }

  /// Hosts whose links may be trusted without a callback path.
  ///
  /// Built from configuration: the Supabase project's own host (the Site URL is
  /// normally the project URL or a custom domain) plus the host of
  /// `AUTH_REDIRECT_URL`. `localhost` is included because that is the default
  /// Site URL — and the exact link that lands on a developer's PC.
  static Set<String> trustedHosts({
    required String supabaseUrl,
    required String authRedirectUrl,
    bool includeLocalhost = true,
  }) {
    final hosts = <String>{};
    for (final raw in [supabaseUrl, authRedirectUrl]) {
      final uri = Uri.tryParse(raw.trim());
      if (uri != null && uri.host.isNotEmpty) hosts.add(uri.host);
    }
    if (includeLocalhost) {
      hosts.addAll(['localhost', '127.0.0.1']);
    }
    return hosts;
  }

  /// Parses `a=1&b=2` style fragments, and the legacy bare `#<token>` form.
  static Map<String, String> _parseFragment(String fragment) {
    if (fragment.isEmpty) return const {};
    if (!fragment.contains('=')) {
      // Older templates redirected with `#access_token_only`; keep it as a
      // token rather than dropping the link.
      return {if (fragment.length > 20) 'access_token': fragment};
    }
    final result = <String, String>{};
    for (final pair in fragment.split('&')) {
      final separator = pair.indexOf('=');
      if (separator <= 0) continue;
      final key = pair.substring(0, separator);
      result[key] = Uri.decodeComponent(pair.substring(separator + 1));
    }
    return result;
  }
}
