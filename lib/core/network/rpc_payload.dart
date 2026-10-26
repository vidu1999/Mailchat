/// Normalises what PostgREST returns from `POST /rest/v1/rpc/<fn>`.
///
/// The shape depends on the function's return type, and three are in use here:
///
/// | SQL return type | PostgREST body |
/// | --- | --- |
/// | `uuid` / `text` | a bare JSON string: `"8f14e45f-…"` |
/// | `returns table (...)` | an array of objects |
/// | `returns jsonb` | whatever the function built |
///
/// Everything arrives as one decoded JSON value, so it must be read
/// shape-first. Coercing to a map — which is what a "give me the body as a
/// map" helper does — silently turns a scalar into `{}` and a table into its
/// first row. That is not hypothetical: it made every attempt to start a 1:1
/// chat fail with "Failed to open the conversation", because the conversation
/// id came back as `{}` and the lookup that followed found nothing.
///
/// Pure and network-free, so the shapes can be pinned by unit tests.
class RpcPayload {
  const RpcPayload._();

  /// Rows from a set-returning function. Accepts an array of objects, a single
  /// object, or nothing.
  static List<Map<String, dynamic>> rows(dynamic payload) {
    if (payload is List) {
      return payload
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
    }
    if (payload is Map) return [Map<String, dynamic>.from(payload)];
    return const [];
  }

  /// A single scalar value from a function returning one value.
  ///
  /// Handles a bare string, an array holding one scalar (which PostgREST uses
  /// when the function returns `setof`), and a single-column row such as
  /// `[{"get_or_create_direct_conversation": "8f14e45f-…"}]`.
  ///
  /// Returns null when there is nothing usable, so callers can raise a clear
  /// error instead of querying with a broken id.
  static String? scalar(dynamic payload) {
    final direct = _asScalar(payload);
    if (direct != null) return direct;

    if (payload is List && payload.isNotEmpty) {
      final first = _asScalar(payload.first);
      if (first != null) return first;
      if (payload.first is Map) {
        final values = (payload.first as Map).values
            .map(_asScalar)
            .whereType<String>()
            .toList();
        if (values.length == 1) return values.first;
      }
      return null;
    }

    if (payload is Map) {
      final values =
          payload.values.map(_asScalar).whereType<String>().toList();
      // Only unambiguous when the row holds exactly one value; an RPC that
      // returns several columns is not a scalar function and must not be
      // guessed at.
      if (values.length == 1) return values.first;
    }
    return null;
  }

  /// A whole number from a function returning an integer.
  ///
  /// PostgREST sends a bare JSON number for `returns integer`, but a gateway or
  /// a `setof` return wraps it (`[3]`, `[{"mark_conversation_read": 3}]`), so
  /// all of those are accepted. Returns null when the reply cannot be read:
  /// unlike [scalar], zero is a meaningful answer here ("nothing unread") and
  /// must not be confused with "no answer".
  static int? integer(dynamic payload) {
    final direct = _asInt(payload);
    if (direct != null) return direct;

    if (payload is List && payload.isNotEmpty) {
      final first = _asInt(payload.first);
      if (first != null) return first;
      if (payload.first is Map) {
        final values =
            (payload.first as Map).values.map(_asInt).whereType<int>().toList();
        if (values.length == 1) return values.first;
      }
      return null;
    }

    if (payload is Map) {
      final values =
          payload.values.map(_asInt).whereType<int>().toList();
      if (values.length == 1) return values.first;
    }
    return null;
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    // A JSON number that arrived as a double (some gateways do this for
    // numeric types), and the string form PostgREST uses for bigint.
    if (value is double && value == value.roundToDouble()) {
      return value.toInt();
    }
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static String? _asScalar(dynamic value) {
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return null;
  }
}
