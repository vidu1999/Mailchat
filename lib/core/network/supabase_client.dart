import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mailchat/core/config/app_config.dart';
import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';

/// Minimal Supabase client implemented on top of the Supabase REST API
/// (PostgREST) and GoTrue Auth API.
///
/// This keeps the core dependency-free so it compiles without pub.dev.
/// Endpoints used:
///   POST /auth/v1/signup, /auth/v1/token?grant_type=password,
///   /auth/v1/logout, /auth/v1/recover, /auth/v1/otp
///   GET/POST/PATCH/DELETE /rest/v1/{table}?...
///   POST /storage/v1/object/{bucket}/{path}
class SupabaseClient {
  SupabaseClient._();
  static final SupabaseClient instance = SupabaseClient._();

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30);

  String? _accessToken;
  String? _refreshToken;

  /// Currently authenticated user id, or null when not signed in.
  String? get userId => _currentUser?.id;

  /// Current access token. Needed by the Realtime client: channel joins must
  /// carry the JWT or Postgres changes are not filtered by RLS.
  String? get accessToken => _accessToken;

  /// Current refresh token, kept for the token-refresh flow.
  ///
  /// NOT used yet: when an access token expires the user is signed out rather
  /// than silently refreshed. Implementing refresh (POST /auth/v1/token with
  /// grant_type=refresh_token) is tracked in docs/security.md.
  String? get refreshToken => _refreshToken;

  /// When the current access token stops being accepted, as reported by
  /// GoTrue. Used to refresh *before* a request fails, rather than after.
  DateTime? _expiresAt;

  /// Called with the new token pair after a silent refresh, so the persisted
  /// session is updated too. Without this the app would keep a dead token on
  /// disk and ask for a password on the next launch.
  Future<void> Function(Session session)? onSessionRefreshed;

  AuthUser? _currentUser;

  /// Current session user, or null.
  AuthUser? get currentUser => _currentUser;

  /// Stream emitting the current auth user on login/logout/token refresh.
  final StreamController<AuthUser?> _authStateController =
      StreamController<AuthUser?>.broadcast();
  Stream<AuthUser?> get authStateChanges => _authStateController.stream;

  Map<String, String> _headers({bool authRequired = false}) {
    final headers = <String, String>{
      'apikey': AppConfig.instance.supabaseAnonKey,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Prefer': 'return=representation',
    };
    if (authRequired && _accessToken != null) {
      headers['Authorization'] = 'Bearer $_accessToken';
    }
    return headers;
  }

  /// Sets the session from an existing access/refresh token pair (session
  /// restoration on app start).
  Future<void> setSession({
    required String accessToken,
    String? refreshToken,
    DateTime? expiresAt,
  }) async {
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _expiresAt = expiresAt;
    await _loadCurrentUser();
  }

  /// True when the access token is expired or about to expire.
  ///
  /// A minute of slack: a request that starts just before expiry would
  /// otherwise fail in flight.
  bool get _accessTokenStale {
    final expiry = _expiresAt;
    if (expiry == null) return false;
    return DateTime.now().toUtc()
        .isAfter(expiry.subtract(const Duration(minutes: 1)));
  }

  /// Exchanges the refresh token for a new session.
  ///
  /// Returns false when there is nothing to refresh with, or GoTrue rejected
  /// the refresh token (revoked, reused, or a password change). A false result
  /// means the user must sign in again — which the caller turns into a clean
  /// sign-out rather than an error screen.
  Future<bool> refreshSession() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) return false;
    try {
      final data = await _post(
        '/auth/v1/token?grant_type=refresh_token',
        body: {'refresh_token': refreshToken},
        authRequired: false,
      );
      final session = Session.fromJson(data);
      _accessToken = session.accessToken;
      _refreshToken = session.refreshToken ?? refreshToken;
      _expiresAt = session.expiresAt;
      await _loadCurrentUser();
      await onSessionRefreshed?.call(session);
      AppLogger.info('supabase_session_refreshed');
      return true;
    } on SupabaseException catch (e) {
      AppLogger.warning('supabase_session_refresh_rejected',
          details: {'status': e.code, 'body': e.original.toString()});
      await clearSession();
      return false;
    } catch (e) {
      // A network failure is not a dead session: keep the tokens so the next
      // launch can try again rather than forcing a password.
      AppLogger.warning('supabase_session_refresh_failed',
          details: {'error': e.toString()});
      return false;
    }
  }

  /// Drops the local session without calling the network. Used when GoTrue
  /// tells us the session is no longer valid.
  Future<void> clearSession() async {
    _accessToken = null;
    _refreshToken = null;
    _expiresAt = null;
    _currentUser = null;
    _authStateController.add(null);
  }

  Future<void> _loadCurrentUser() async {
    if (_accessToken == null) {
      _currentUser = null;
      _authStateController.add(null);
      return;
    }
    try {
      final user = await _get('/auth/v1/user', authRequired: true);
      _currentUser = AuthUser.fromJson(user);
      _authStateController.add(_currentUser);
    } catch (e, st) {
      AppLogger.warning('supabase_load_user_failed', details: {
        'error': e.toString(),
        'stack': st.toString(),
      });
      _currentUser = null;
      _authStateController.add(null);
    }
  }

  // ------------------------------------------------------------------
  // Auth
  // ------------------------------------------------------------------

  /// Registers a new account with email and password. Supabase sends a
  /// confirmation email when email confirmations are enabled on the project.
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    Map<String, dynamic>? metadata,
  }) async {
    final body = <String, dynamic>{
      'email': email.trim().toLowerCase(),
      'password': password,
      'options': {
        'email_redirect_to': AppConfig.instance.authRedirectUrl,
        'data': metadata,
      },
    };
    if (metadata != null) body['data'] = metadata;

    Map<String, dynamic> data;
    try {
      data = await _post('/auth/v1/signup', body: body, authRequired: false);
    } on SupabaseException catch (e) {
      // Depending on project configuration GoTrue reports a duplicate address
      // as HTTP 422 `user_already_exists` instead of the 200 placeholder user.
      // Map both shapes onto the same typed error so the UI can offer sign-in.
      final raw = e.original?.toString().toLowerCase() ?? '';
      if (raw.contains('user_already_exists') ||
          raw.contains('already registered') ||
          raw.contains('already been registered')) {
        AppLogger.warning('signup_existing_account_http',
            details: {'body': e.original.toString()});
        throw EmailAlreadyRegisteredException(
          'This email is already registered. Sign in instead, or use '
          '"Forgot password" if you do not remember it.',
        );
      }
      rethrow;
    }

    // GoTrue does not use one response shape for signup. See
    // [normalizeSignupPayload]; reading only `data['user']` threw away valid
    // responses whose user object sat at the top level.
    final payload = normalizeSignupPayload(data);
    final userJson = payload['user'];
    if (userJson is! Map) {
      // GoTrue returned neither a user nor an error. Surface everything it did
      // say instead of a bare "please try again" — without the response shape
      // there is nothing to act on.
      AppLogger.warning('signup_no_user', details: {
        'keys': data.keys.toList(),
        'msg': data['msg'] ?? data['message'] ?? data['error_description'],
      });
      throw AppException(_signupFailureMessage(data));
    }

    // When email confirmation is enabled GoTrue returns the user with a null
    // session. That is a success, not a failure. _handleAuthResponse stores the
    // tokens only when a session is actually present.
    return _handleAuthResponse(payload);
  }

  /// Normalises the three shapes `POST /auth/v1/signup` can return.
  ///
  /// 1. `{user: {...}, session: null|{...}}` — the documented shape, and what
  ///    GoTrue returns once confirmations are involved.
  /// 2. A **bare user object**: `{id, aud, role, email, identities, ...}` with
  ///    no wrapper at all — returned with confirmation required. Reading only
  ///    `data['user']` treats this valid response as "no user", which is the
  ///    bug this method exists to fix.
  /// 3. A session-ish object with the access token at the top level and the
  ///    user nested (`{access_token, refresh_token, user: {...}}`) — older
  ///    GoTrue with confirmations disabled.
  ///
  /// Anything else is returned unchanged so the caller can report it.
  /// Public so the mapping is unit-testable without a network call.
  @visibleForTesting
  static Map<String, dynamic> normalizeSignupPayload(
      Map<String, dynamic> data) {
    final nested = data['user'];
    if (nested is Map) {
      // Shape 1. jsonDecode produces Map<String, dynamic>, but a
      // Map<dynamic, dynamic> is accepted defensively.
      final user = Map<String, dynamic>.from(nested);
      final session = data['session'];
      if (session is Map) {
        return {'user': user, 'session': session};
      }
      // Shape 3: the token fields are siblings of `user`, not inside a
      // `session` object.
      if (data['access_token'] is String) {
        return {
          'user': user,
          'session': {
            'access_token': data['access_token'],
            'refresh_token': data['refresh_token'],
            'expires_in': data['expires_in'],
            'token_type': data['token_type'],
          },
        };
      }
      return {'user': user, 'session': null};
    }

    // Shape 2: the payload *is* the user. `id` plus a known user field is
    // specific enough not to mistake an error body for a user.
    if (data['id'] is String &&
        (data['identities'] is List ||
            data['email'] is String ||
            data['aud'] is String)) {
      return {'user': data, 'session': null};
    }

    return data;
  }

  /// Signs in with email + password.
  Future<AuthResponse> signInWithPassword({
    required String email,
    required String password,
  }) async {
    final body = <String, dynamic>{
      'grant_type': 'password',
      'email': email.trim().toLowerCase(),
      'password': password,
    };
    final data = await _post('/auth/v1/token?grant_type=password', body: body);
    return _handleAuthResponse(data);
  }

  /// Exchanges a `{{ .TokenHash }}` email token for a session.
  ///
  /// Used when the email template passes `token_hash` instead of a session in
  /// the redirect fragment. `type` is the template's type (`signup`, `recovery`,
  /// `magiclink`, `invite`, `email_change`); GoTrue rejects a mismatch.
  Future<AuthResponse> verifyTokenHash({
    required String tokenHash,
    required String type,
  }) async {
    final data = await _post('/auth/v1/verify', body: {
      'token_hash': tokenHash,
      'type': type,
    }, authRequired: false);
    // Same shape problem as signup: the session is usually wrapped, but the
    // bare user is possible. normalizeSignupPayload handles both.
    return _handleAuthResponse(normalizeSignupPayload(data));
  }

  /// Sets a new password for the currently authenticated user.
  ///
  /// Requires a session: either the short-lived one a recovery link carries, or
  /// an existing signed-in session.
  Future<void> updatePassword(String newPassword) async {
    await _putAuthUser({'password': newPassword});
  }

  Future<void> _putAuthUser(Map<String, dynamic> body) async {
    final uri = Uri.parse('${AppConfig.instance.supabaseUrl}/auth/v1/user');
    try {
      final request = await _http.putUrl(uri);
      _applyHeaders(request, authRequired: true);
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      await _decodeResponse(response);
    } on SocketException catch (e) {
      throw _networkError('supabase_put_user', uri, e);
    } on TimeoutException catch (e) {
      throw _networkError('supabase_put_user_timeout', uri, e);
    } catch (e, st) {
      if (e is AppException) rethrow;
      AppLogger.error(e, st, {'where': 'supabase_put_user'});
      rethrow;
    }
  }

  /// Sends a password-reset email.
  Future<void> resetPasswordForEmail(String email) async {
    await _post('/auth/v1/recover', body: {
      'email': email.trim().toLowerCase(),
      'options': {'email_redirect_to': AppConfig.instance.authRedirectUrl},
    });
  }

  /// Signs out and clears the local session.
  Future<void> signOut() async {
    try {
      await _post('/auth/v1/logout', body: {}, authRequired: true);
    } catch (e) {
      // Logout is best-effort locally: clear the session even if the
      // network call fails.
      AppLogger.warning('supabase_signout_network_error', details: {'error': e.toString()});
    }
    _accessToken = null;
    _refreshToken = null;
    _currentUser = null;
    _authStateController.add(null);
  }

  // ------------------------------------------------------------------
  // REST (PostgREST)
  // ------------------------------------------------------------------

  /// Inserts a row into [table] and returns the inserted record(s).
  Future<List<Map<String, dynamic>>> insert(
    String table, {
    required Map<String, dynamic> data,
    bool authRequired = true,
    String? select,
  }) async {
    final uri = Uri.parse('$_restUrl/$table${select != null ? '?select=$select' : ''}');
    final response = await _postUri(uri, body: data, authRequired: authRequired);
    return _asRowList(response);
  }

  /// Calls a Postgres function through PostgREST (`POST /rest/v1/rpc/<fn>`).
  ///
  /// Used for SECURITY DEFINER functions where the logic must run
  /// server-side (e.g. atomic get-or-create of a direct conversation, which
  /// RLS would otherwise block because it inserts another user's membership).
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async {
    final uri = Uri.parse('$_restUrl/rpc/$function');
    return _postUri(uri, body: params ?? const {}, authRequired: true);
  }

  /// Selects rows from [table] with optional filters, ordering and pagination.
  ///
  /// [filter] entries use the compact `{operator: 'column,value,...'}` form,
  /// e.g. `{'eq': 'id,abc'}` or `{'eq': 'conversation_id,c1,user_id,u1'}`.
  /// They are expanded to proper PostgREST params (`id=eq.abc`).
  /// [order] e.g. `'created_at.desc'`. [limit] / [offset] for pagination.
  Future<List<Map<String, dynamic>>> select(
    String table, {
    String? select,
    Map<String, String>? filter,
    String? order,
    int? limit,
    int? offset,
    bool authRequired = true,
  }) async {
    final params = <String, String>{};
    if (select != null) params['select'] = select;
    if (filter != null) params.addAll(_expandFilter(filter));
    if (order != null) params['order'] = order;
    if (limit != null) params['limit'] = limit.toString();
    if (offset != null) params['offset'] = offset.toString();

    final uri = Uri.parse('$_restUrl/$table').replace(queryParameters: params);
    final response = await _getRawUri(uri, authRequired: authRequired);
    return _asRowList(response);
  }

  /// Updates rows matching [filter].
  Future<List<Map<String, dynamic>>> update(
    String table, {
    required Map<String, String> filter,
    required Map<String, dynamic> data,
    bool authRequired = true,
  }) async {
    final uri = Uri.parse('$_restUrl/$table')
        .replace(queryParameters: _expandFilter(filter));
    final response = await _patchUri(uri, body: data, authRequired: authRequired);
    return _asRowList(response);
  }

  /// Deletes rows matching [filter].
  Future<void> delete(String table,
      {required Map<String, String> filter, bool authRequired = true}) async {
    final uri = Uri.parse('$_restUrl/$table')
        .replace(queryParameters: _expandFilter(filter));
    await _deleteUri(uri, authRequired: authRequired);
  }

  /// Uploads a file to Supabase Storage and returns the object path.
  Future<String> uploadFile({
    required String bucket,
    required String path,
    required List<int> bytes,
    required String contentType,
    bool upsert = false,
  }) async {
    final url = '${AppConfig.instance.supabaseUrl}/storage/v1/object/$bucket/$path';
    final uri = Uri.parse(url);
    final request = await _http.openUrl('POST', uri);
    _applyHeaders(request, authRequired: true);
    request.headers.add('Content-Type', contentType);
    request.headers.add('x-upsert', upsert.toString());
    request.add(bytes);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return path;
    }
    throw StorageException('Upload failed (${response.statusCode}): $body',
        original: body);
  }

  /// Generates a short-lived signed URL for a private object.
  Future<String> createSignedUrl({
    required String bucket,
    required String path,
    int expiresIn = 300,
  }) async {
    final uri = Uri.parse(
      '${AppConfig.instance.supabaseUrl}/storage/v1/object/sign/$bucket/$path',
    );
    final data = await _postUri(uri, body: {'expires_in': expiresIn}, authRequired: true);
    final signedUrl = data['signedUrl'] ?? data['signedURL'];
    if (signedUrl == null) {
      throw StorageException('Failed to create signed URL', original: data);
    }
    return signedUrl as String;
  }

  // ------------------------------------------------------------------
  // Internal HTTP
  // ------------------------------------------------------------------

  String get _restUrl => '${AppConfig.instance.supabaseUrl}/rest/v1';

  Future<Map<String, dynamic>> _get(String path, {bool authRequired = false}) async {
    final uri = Uri.parse('${AppConfig.instance.supabaseUrl}$path');
    return _getUri(uri, authRequired: authRequired);
  }


  /// Explains a signup response that contained no usable user.
  static String _signupFailureMessage(Map<String, dynamic> data) {
    final serverMessage = (data['msg'] ??
            data['message'] ??
            data['error_description'] ??
            data['error'])
        ?.toString();
    const base = 'Registration could not be completed.';
    if (serverMessage != null && serverMessage.isNotEmpty) {
      return '$base $serverMessage';
    }
    return '$base Supabase returned no user. This usually means the address is '
        'already registered, or sign-ups are disabled for this project '
        '(Authentication > Providers > Email).';
  }

  /// Builds an actionable error for a transport failure.
  ///
  /// A bare "Network request failed" gives the user nothing to act on: it can
  /// mean a wrong project URL, no connectivity, a blocked network, or a missing
  /// INTERNET permission. The message names the host being contacted and the
  /// OS-level cause, and never includes the API key.
  NetworkException _networkError(String where, Uri uri, Object cause) {
    final host = uri.host.isEmpty ? AppConfig.instance.supabaseUrl : uri.host;
    final detail = cause is SocketException
        ? (cause.osError?.message ?? cause.message)
        : cause.toString();

    AppLogger.error(cause, StackTrace.current, {
      'where': where,
      'host': host,
      'detail': detail,
    });

    return NetworkException(
      'Could not reach $host. Check your internet connection, and confirm '
      'SUPABASE_URL points at a live Supabase project. ($detail)',
      original: cause,
    );
  }

  /// Applies the request headers. [HttpHeaders] exposes `add`, not `addAll`.
  void _applyHeaders(HttpClientRequest request, {bool authRequired = false}) {
    _headers(authRequired: authRequired).forEach((key, value) {
      request.headers.add(key, value);
    });
  }

  /// Map-returning GET, used by the auth endpoints (single-object payloads).
  /// Refreshes proactively when the token is about to expire.
  ///
  /// Called before every authenticated request. Silently doing nothing when a
  /// refresh is not possible keeps the request honest: it either succeeds or
  /// fails with its own error, rather than being skipped.
  Future<void> _refreshIfStale({required bool authRequired}) async {
    if (!authRequired || _accessToken == null) return;
    if (!_accessTokenStale) return;
    await refreshSession();
  }

  Future<Map<String, dynamic>> _getUri(Uri uri, {bool authRequired = false}) async {
    await _refreshIfStale(authRequired: authRequired);
    return _asMap(await _getRawUri(uri, authRequired: authRequired));
  }

  /// GET returning the decoded JSON exactly as sent (object or array).
  Future<dynamic> _getRawUri(Uri uri, {bool authRequired = false}) async {
    try {
      final request = await _http.getUrl(uri);
      _applyHeaders(request, authRequired: authRequired);
      final response = await request.close();
      return await _decodeResponse(response);
    } on SocketException catch (e) {
      throw _networkError('supabase_get', uri, e);
    } on TimeoutException catch (e) {
      throw _networkError('supabase_get_timeout', uri, e);
    } catch (e, st) {
      if (e is AppException) rethrow;
      AppLogger.error(e, st, {'where': 'supabase_get', 'uri': uri.toString()});
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _post(String path,
      {required Map<String, dynamic> body, bool authRequired = false}) async {
    final uri = Uri.parse('${AppConfig.instance.supabaseUrl}$path');
    return _postUri(uri, body: body, authRequired: authRequired);
  }

  Future<Map<String, dynamic>> _postUri(Uri uri,
      {required Map<String, dynamic> body, bool authRequired = false}) async {
    await _refreshIfStale(authRequired: authRequired);
    try {
      final request = await _http.postUrl(uri);
      _applyHeaders(request, authRequired: authRequired);
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      return _asMap(await _decodeResponse(response));
    } on SocketException catch (e) {
      throw _networkError('supabase_post', uri, e);
    } on TimeoutException catch (e) {
      throw _networkError('supabase_post_timeout', uri, e);
    } catch (e, st) {
      if (e is AppException) rethrow;
      AppLogger.error(e, st, {'where': 'supabase_post', 'uri': uri.toString()});
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _patchUri(Uri uri,
      {required Map<String, dynamic> body, bool authRequired = false}) async {
    await _refreshIfStale(authRequired: authRequired);
    try {
      final request = await _http.postUrl(uri);
      _applyHeaders(request, authRequired: authRequired);
      request.headers.add('X-HTTP-Method-Override', 'PATCH');
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      return _asMap(await _decodeResponse(response));
    } on SocketException catch (e) {
      throw _networkError('supabase_patch', uri, e);
    } on TimeoutException catch (e) {
      throw _networkError('supabase_patch_timeout', uri, e);
    } catch (e, st) {
      if (e is AppException) rethrow;
      AppLogger.error(e, st, {'where': 'supabase_patch', 'uri': uri.toString()});
      rethrow;
    }
  }

  Future<void> _deleteUri(Uri uri, {bool authRequired = false}) async {
    await _refreshIfStale(authRequired: authRequired);
    try {
      final request = await _http.deleteUrl(uri);
      _applyHeaders(request, authRequired: authRequired);
      final response = await request.close();
      await _decodeResponse(response);
    } on SocketException catch (e) {
      throw _networkError('supabase_delete', uri, e);
    } on TimeoutException catch (e) {
      throw _networkError('supabase_delete_timeout', uri, e);
    } catch (e, st) {
      if (e is AppException) rethrow;
      AppLogger.error(e, st, {'where': 'supabase_delete', 'uri': uri.toString()});
      rethrow;
    }
  }

  /// Decodes a response body. PostgREST returns either an object or an array
  /// depending on the endpoint, so the caller decides how to narrow the result.
  Future<dynamic> _decodeResponse(HttpClientResponse response) async {
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (body.isEmpty) return null;
      return jsonDecode(body);
    }
    throw SupabaseException(
      'Request failed (${response.statusCode}): $body',
      statusCode: response.statusCode,
      original: body,
    );
  }

  AuthResponse _handleAuthResponse(Map<String, dynamic> data) {
    final user = data['user'] != null ? AuthUser.fromJson(data['user']) : null;
    final session = data['session'] != null ? Session.fromJson(data['session']) : null;
    if (session != null) {
      _accessToken = session.accessToken;
      _refreshToken = session.refreshToken;
      _expiresAt = session.expiresAt;
    }
    // Only an authenticated session counts as a signed-in user. Signup with
    // email confirmation enabled returns a user and no session; treating that
    // as "signed in" would report an authenticated client with no token.
    _currentUser = session != null ? user : null;
    _authStateController.add(_currentUser);
    return AuthResponse(user: user, session: session);
  }

  /// Expands MailChat's compact filter form into PostgREST query params.
  ///
  /// Input:  `{'eq': 'conversation_id,c1,user_id,u1', 'is': 'deleted_at,null'}`
  /// Output: `{'conversation_id': 'eq.c1', 'user_id': 'eq.u1',
  ///           'deleted_at': 'is.null'}`
  ///
  /// A single `column,value` pair and multiple comma-separated pairs are both
  /// accepted. Malformed entries are passed through untouched so the server
  /// returns an explicit error instead of the client silently dropping a
  /// filter (which could widen what a query returns).
  /// Operators whose values are a simple `column,value` list. Structural
  /// operators (`and`, `or`, `not`) carry their own comma-separated grammar
  /// and must be forwarded untouched.
  static const Set<String> _scalarOperators = {
    'eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'like', 'ilike', 'is',
  };

  static Map<String, String> _expandFilter(Map<String, String> filter) {
    final expanded = <String, String>{};
    filter.forEach((operator, rawValue) {
      if (!_scalarOperators.contains(operator)) {
        expanded[operator] = rawValue;
        return;
      }
      final parts = rawValue.split(',');
      if (parts.length < 2 || parts.length.isOdd) {
        // Not a column/value list (e.g. a raw PostgREST expression) — keep it.
        expanded[operator] = rawValue;
        return;
      }
      for (var i = 0; i < parts.length; i += 2) {
        expanded[parts[i].trim()] = '$operator.${parts[i + 1]}';
      }
    });
    return expanded;
  }

  /// Normalises a decoded payload into a single object.
  static Map<String, dynamic> _asMap(dynamic decoded) {
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
      return _asMap(decoded.first);
    }
    return <String, dynamic>{};
  }

  /// Normalises a PostgREST payload into a list of rows.
  static List<Map<String, dynamic>> _asRowList(dynamic decoded) {
    if (decoded == null) return const [];
    if (decoded is List) {
      return decoded.whereType<Map>().map((row) {
        return row.map((key, value) => MapEntry(key.toString(), value));
      }).toList();
    }
    if (decoded is Map) {
      return [decoded.map((key, value) => MapEntry(key.toString(), value))];
    }
    return const [];
  }
}

/// Authenticated user returned by Supabase Auth.
class AuthUser {
  final String id;
  final String email;
  final String? phone;
  final bool emailConfirmed;
  final Map<String, dynamic>? userMetadata;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// When GoTrue sent the confirmation email, if it did.
  ///
  /// Distinguishes "email dispatched" from "waiting for a confirmation that was
  /// never sent" — otherwise both look identical to the user: no session.
  final DateTime? confirmationSentAt;

  /// Number of linked identities reported by GoTrue.
  ///
  /// A brand-new signup returns one identity. When the address already exists,
  /// GoTrue returns a placeholder user with **zero** identities so callers
  /// cannot enumerate accounts. That is the only signal available.
  final int identityCount;

  AuthUser({
    required this.id,
    required this.email,
    this.phone,
    this.emailConfirmed = false,
    this.userMetadata,
    this.createdAt,
    this.updatedAt,
    this.confirmationSentAt,
    this.identityCount = 1,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: json['id'] as String,
      email: json['email'] as String? ?? '',
      phone: json['phone'] as String?,
      emailConfirmed: json['email_confirmed_at'] != null,
      userMetadata: json['user_metadata'] as Map<String, dynamic>?,
      identityCount: json['identities'] is List
          ? (json['identities'] as List).length
          : 1,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)
          : null,
      confirmationSentAt: json['confirmation_sent_at'] != null
          ? DateTime.tryParse(json['confirmation_sent_at'] as String)
          : null,
    );
  }

  String? get username => userMetadata?['username'] as String?;
  String? get displayName => userMetadata?['display_name'] as String?;
  String? get avatarUrl => userMetadata?['avatar_url'] as String?;

  /// True when GoTrue returned its anti-enumeration placeholder, meaning the
  /// address already has an account.
  bool get isPlaceholderForExistingAccount => identityCount == 0;
}

/// Session returned by Supabase Auth.
class Session {
  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;

  Session({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
  });

  factory Session.fromJson(Map<String, dynamic> json) {
    return Session(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      expiresAt: _parseExpiry(json['expires_at'], json['expires_in']),
    );
  }

  /// Reads the expiry from whichever form GoTrue used.
  ///
  /// `expires_at` is an **integer** of Unix epoch seconds in the JSON body (and
  /// a string when it arrives in a redirect fragment). Casting it to String
  /// threw a TypeError on the first successful sign-in — a crash that could not
  /// show up during signup, because signup returns no session.
  static DateTime? _parseExpiry(Object? expiresAt, Object? expiresIn) {
    if (expiresAt is int) {
      return DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000, isUtc: true);
    }
    if (expiresAt is num) {
      return DateTime.fromMillisecondsSinceEpoch(
          (expiresAt * 1000).round(),
          isUtc: true);
    }
    if (expiresAt is String && expiresAt.isNotEmpty) {
      // Epoch seconds first. `DateTime.tryParse` happily accepts a bare digit
      // string and reads it as a year, which turns 1792987203 into a date
      // thousands of years out and makes the token look permanently stale.
      final epoch = int.tryParse(expiresAt.trim());
      if (epoch != null) {
        return DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true);
      }
      final parsed = DateTime.tryParse(expiresAt);
      if (parsed != null) return parsed;
    }
    if (expiresIn is int) {
      return DateTime.now().toUtc().add(Duration(seconds: expiresIn));
    }
    if (expiresIn is String) {
      final seconds = int.tryParse(expiresIn);
      if (seconds != null) {
        return DateTime.now().toUtc().add(Duration(seconds: seconds));
      }
    }
    return null;
  }
}

/// Result of an authentication operation.
class AuthResponse {
  final AuthUser? user;
  final Session? session;

  AuthResponse({this.user, this.session});

  bool get isAuthenticated => user != null && session != null;


}