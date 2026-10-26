/// Translates GoTrue's error bodies into messages a user can act on.
///
/// GoTrue answers with a JSON object such as:
///
/// ```json
/// {"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}
/// ```
///
/// Rendering `e.message` directly therefore showed the user
/// `Request failed (400): {"code":400,...}` — technically accurate, useless in
/// practice, and indistinguishable from the "no session returned" bug that made
/// a successful sign-in look like a wrong password.
///
/// Flutter-free so it can be unit tested; the network layer calls it when a
/// request fails.
library;

import 'dart:convert';

class AuthErrorMessages {
  AuthErrorMessages._();

  /// A user-facing message for [body], or null when nothing useful can be said
  /// (the caller then rethrows the original error rather than inventing one).
  static String? forBody(String? body) {
    if (body == null || body.trim().isEmpty) return null;

    final decoded = _tryDecode(body);
    if (decoded == null) {
      // Not JSON: a plain-text body is GoTrue's own wording in some versions.
      final text = body.trim();
      return text.length > 200 || text.startsWith('{') ? null : text;
    }

    final code = _firstNonEmpty([
      decoded['error_code'],
      decoded['code'],
      decoded['error'],
    ]);
    final serverMessage = _firstNonEmpty([
      decoded['msg'],
      decoded['message'],
      decoded['error_description'],
    ]);

    switch (code) {
      case 'invalid_credentials':
        return 'Invalid email or password.';
      case 'email_not_confirmed':
        return 'Confirm your email address first. Open the link we emailed you, '
            'then sign in — or paste the link on the login screen if it opened '
            'somewhere else.';
      case 'email_address_invalid':
        return 'That email address is not valid.';
      case 'user_already_exists':
      case 'email_exists':
        return 'This email is already registered. Sign in instead, or use '
            '"Forgot password".';
      case 'signup_disabled':
      case 'email_provider_disabled':
        return 'Sign-ups are disabled for this project. Enable the Email '
            'provider in Supabase → Authentication → Providers.';
      case 'weak_password':
        return 'That password is too weak. Use at least 8 characters with a '
            'mix of letters and numbers.';
      case 'same_password':
        return 'The new password must be different from the current one.';
      case 'otp_expired':
      case 'token_expired':
        return 'That link has expired or was already used. Request a new email.';
      case 'over_email_send_rate_limit':
      case 'over_request_rate_limit':
        return 'Too many attempts. Wait a minute before trying again.';
      case 'session_not_found':
      case 'refresh_token_not_found':
        return 'Your session has ended. Please sign in again.';
      default:
        // Fall back to GoTrue's own sentence, but never to a JSON blob.
        if (serverMessage.isEmpty || serverMessage.startsWith('{')) return null;
        return serverMessage;
    }
  }

  /// The machine-readable code in [body], or null. Used for logging and for
  /// branching without string matching.
  static String? codeIn(String? body) {
    if (body == null) return null;
    final decoded = _tryDecode(body);
    if (decoded == null) return null;
    return _firstNonEmpty([
      decoded['error_code'],
      decoded['code'],
      decoded['error'],
    ]);
  }

  static Map<String, dynamic>? _tryDecode(String body) {
    try {
      final value = jsonDecode(body);
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }

  static String _firstNonEmpty(List<Object?> candidates) {
    for (final candidate in candidates) {
      if (candidate == null) continue;
      final text = candidate.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }
}
