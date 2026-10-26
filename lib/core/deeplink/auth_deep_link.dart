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
  /// Accepts the custom scheme (`mailchat://auth/callback`) and a web URL whose
  /// path ends in `auth/callback`, so an https app link configured against a
  /// real domain works the same way.
  static AuthDeepLink? parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;

    // Match on scheme + host + path together. For `mailchat://auth/callback`
    // the "auth" segment is the *host*; for an https app link it is part of the
    // path — so neither alone identifies a callback. Anything else the scheme
    // can address (`mailchat://settings`) must not be treated as one.
    final signature = '${uri.scheme}://${uri.host}${uri.path}';
    final isCallback = signature.contains('mailchat://auth/callback') ||
        signature.contains('/auth/callback') ||
        signature.contains('/auth/v1/verify');
    if (!isCallback) return null;

    // Query parameters first, then the fragment wins for any repeated key: when
    // both are present the fragment carries the session and the query carries
    // context such as `type`.
    final params = <String, String>{};
    params.addAll(uri.queryParameters);
    params.addAll(_parseFragment(uri.fragment));

    final errorCode = params['error_code'] ?? params['error'];
    final errorDescription = params['error_description'];
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
