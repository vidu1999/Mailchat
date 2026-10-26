/// Inspection of Supabase API keys without contacting the network.
///
/// Flutter-free on purpose: `tool/check_config.dart` uses this to refuse a build
/// that would ship a privileged key, and the app uses it to describe what it was
/// given. One implementation, so a build cannot pass a check the app disagrees
/// with.
///
/// Supabase still issues two shapes of key:
///
///  * **Legacy JWT keys** — `eyJhbGci…` with a payload claiming `"role": "anon"`
///    or `"role": "service_role"`, plus the project `ref`.
///  * **New API keys** — `sb_publishable_…` / `sb_secret_…`, opaque strings with
///    no readable claims.
///
/// Only the first shape can be verified locally; for the second, a name check is
/// the best available signal.
library;

import 'dart:convert';

class AnonKey {
  AnonKey._();

  /// The `role` claim of a JWT key, or null when [key] is not a readable JWT.
  ///
  /// Returns null rather than throwing for every malformed input: a key that
  /// cannot be parsed is not necessarily invalid (new-style keys are opaque), so
  /// callers must treat null as "unknown", not "bad".
  static String? jwtRole(String? key) {
    final claims = jwtPayload(key);
    final role = claims?['role'];
    return role is String ? role : null;
  }

  /// The project `ref` claim of a JWT key, or null.
  ///
  /// This is the <ref> in `https://<ref>.supabase.co`, which lets tooling tell a
  /// user the exact URL their project needs.
  static String? projectRef(String? key) {
    final claims = jwtPayload(key);
    final ref = claims?['ref'];
    return ref is String && ref.isNotEmpty ? ref : null;
  }

  /// Decoded JWT payload, or null when [key] is not a three-part JWT or the
  /// payload is not JSON.
  static Map<String, dynamic>? jwtPayload(String? key) {
    if (key == null) return null;
    final parts = key.trim().split('.');
    if (parts.length != 3) return null;
    try {
      // JWT segments are base64url without padding; `decode` needs the padding.
      final payload = parts[1];
      final normalised = base64Url.normalize(payload);
      final decoded = utf8.decode(base64Url.decode(normalised));
      final json = jsonDecode(decoded);
      return json is Map<String, dynamic> ? json : null;
    } catch (_) {
      return null;
    }
  }

  /// True when [key] is, or appears to be, a `service_role` key.
  ///
  /// The JWT claim is authoritative when readable. The substring check covers
  /// secrets pasted into the wrong variable and new-style key names — a false
  /// positive there costs the user one confusing message, whereas a false
  /// negative ships a key that bypasses every RLS policy.
  static bool isServiceRole(String? key) {
    if (key == null || key.trim().isEmpty) return false;
    if (jwtRole(key) == 'service_role') return true;
    final lowered = key.toLowerCase();
    return lowered.contains('service_role') || lowered.startsWith('sb_secret');
  }

  /// The URL a project's API lives at, derived from a JWT key.
  ///
  /// Used to tell the user exactly what to put in `SUPABASE_URL` when it is
  /// blank — the most common configuration mistake, and one that is fully
  /// recoverable from the key itself.
  static String? suggestedUrl(String? key) {
    final ref = projectRef(key);
    return ref == null ? null : 'https://$ref.supabase.co';
  }
}
