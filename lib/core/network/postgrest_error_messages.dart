/// Turns PostgREST error bodies into messages that say what to fix.
///
/// A raw body reaches the user as:
///
/// ```
/// Request failed (400): {"code":"42703","details":null,"hint":null,
///   "message":"column conversation_list.updated_at does not exist"}
/// ```
///
/// The SQLSTATE in `code` is the part that matters, because it distinguishes
/// "your database is not set up" from "you are not allowed" from "that value is
/// invalid" — three problems with three different fixes. Schema drift is the most
/// common of them: the app ships ahead of the migrations being applied.
///
/// Flutter-free so it can be unit tested.
library;

import 'dart:convert';

class PostgrestErrorMessages {
  PostgrestErrorMessages._();

  /// SQLSTATEs worth naming explicitly. Anything else falls back to Postgres's
  /// own sentence, which is usually already specific.
  static const Map<String, String> _sqlStates = {
    '42P01': 'the database is missing a table',
    '42703': 'the database is missing a column',
    '42883': 'a database function is missing',
    '42501': 'the database refused the operation (permission or RLS)',
    '23505': 'that value already exists',
    '23503': 'that refers to something that does not exist',
    '23514': 'that value is not allowed',
    '22P02': 'that value has the wrong format',
    'PGRST116': 'nothing matched',
    'PGRST301': 'the session has expired',
  };

  /// A user-facing message for [body], or null when it is not a PostgREST error.
  static String? forBody(String? body) {
    if (body == null || body.trim().isEmpty) return null;
    final decoded = _tryDecode(body);
    if (decoded == null) return null;

    final code = decoded['code']?.toString().trim() ?? '';
    final message = (decoded['message'] ?? decoded['msg'] ?? '')
        .toString()
        .trim();
    final details = decoded['details']?.toString().trim() ?? '';

    // Not PostgREST: no SQLSTATE, and no message at all.
    if (code.isEmpty && message.isEmpty) return null;

    switch (code) {
      case '42P01':
      case '42703':
      case '42883':
        return 'The database schema is out of date: $message. '
            'Apply the migrations in supabase/migrations in order (0001 → 0005) '
            '— or, if they were applied already, re-run the one that creates '
            'the missing object. See docs/running.md §2.';
      case '42501':
        if (message.contains('"calls"') || message.contains('table calls')) {
          return 'The server refused to save this call. It is a permission '
              'rule on the calls table, not a broken screen. In Supabase, open '
              'SQL Editor, paste supabase/migrations/0010_call_write.sql, run '
              'it, then call again.';
        }
        return 'The database refused this action: $message. This is a '
            'row-level security decision, not a bug in the screen — check the '
            'policy for your user in docs/security.md.';
      case 'PGRST202':
        // PostgREST raises this when the RPC itself does not exist: a project
        // that has not applied 0005 yet, which is what user search calls.
        return 'The database schema is out of date: $message. '
            'Apply the migrations in supabase/migrations in order '
            '(0001 → 0005) — or, if they were applied already, re-run the one '
            'that creates the missing object. See docs/running.md §2.';
      case 'PGRST301':
      case 'PGRST302':
        return 'Your session has expired. Please sign in again.';
      case 'PGRST116':
        return 'Nothing was found.';
      default:
    }

    if (message.isEmpty) return null;
    final hint = decoded['hint']?.toString().trim() ?? '';
    final suffix = hint.isNotEmpty ? ' ($hint)' : '';
    final detail = details.isNotEmpty ? ' ($details)' : '';
    final known = _sqlStates[code];
    // Postgres's own sentence is kept: it names the table or column, which is
    // exactly what is needed to fix the schema.
    return known == null ? '$message$suffix$detail' : '$message$detail';
  }

  /// True when PostgREST has not loaded the function yet.
  ///
  /// A call then falls back to writing the table directly. Any other error is
  /// a real refusal and must not be retried as a direct write.
  static bool missingFunction(String? body) {
    if (body == null || body.isEmpty) return false;
    final code = codeIn(body);
    if (code == 'PGRST202' || code == '42883') return true;
    final lower = body.toLowerCase();
    return lower.contains('could not find the function') ||
        lower.contains('schema cache');
  }

  /// The SQLSTATE in [body], or null. Useful for logging without the body.
  static String? codeIn(String? body) {
    final decoded = _tryDecode(body ?? '');
    final code = decoded?['code']?.toString().trim();
    return code == null || code.isEmpty ? null : code;
  }

  static Map<String, dynamic>? _tryDecode(String body) {
    try {
      final value = jsonDecode(body);
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }
}
