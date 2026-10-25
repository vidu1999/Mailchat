import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  AuthUser? _currentUser;

  /// Current session user, or null.
  AuthUser? get currentUser => _currentUser;

  /// Stream emitting the current auth user on login/logout/token refresh.
  final StreamController<AuthUser?> _authStateController =
      StreamController<AuthUser?>.broadcast();
  Stream<AuthUser?> get authStateChanges => _authStateController.stream;

  /// Base auth URL.
  String get _authUrl => '${AppConfig.instance.supabaseUrl}/auth/v1';

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
  void setSession({required String accessToken, String? refreshToken}) {
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _loadCurrentUser();
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
      AppLogger.warning('supabase_load_user_failed', details: {'error': e.toString()});
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
    final data = await _post('/auth/v1/signup', body: body, authRequired: false);
    return AuthResponse(
      user: data['user'] != null ? AuthUser.fromJson(data['user']) : null,
      session: data['session'] != null ? Session.fromJson(data['session']) : null,
    );
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
    final data = await _postUri(uri, body: data, authRequired: authRequired);
    return (data as List).cast<Map<String, dynamic>>();
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
    final data = await _getUri(uri, authRequired: authRequired);
    return (data as List).cast<Map<String, dynamic>>();
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
    final data = await _patchUri(uri, body: data, authRequired: authRequired);
    return (data as List).cast<Map<String, dynamic>>();
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
    final request = await _http.openUrl('POST', uri)
      ..headers.addAll(_headers(authRequired: true))
      ..headers.add('Content-Type', contentType)
      ..headers.add('x-upsert', upsert.toString());
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

  Future<Map<String, dynamic>> _getUri(Uri uri, {bool authRequired = false}) async {
    try {
      final request = await _http.getUrl(uri)..headers.addAll(_headers(authRequired: authRequired));
      final response = await request.close();
      return await _decodeResponse(response);
    } on SocketException catch (e) {
      throw NetworkException('Network request failed', original: e);
    } on TimeoutException catch (e) {
      throw NetworkException('Request timed out', original: e);
    } catch (e, st) {
      if (e is AppException) rethrow;
      AppLogger.error(e, st, details: {'where': 'supabase_get', 'uri': uri.toString()});
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
    try {
      final request = await _http.postUrl(uri)
        ..headers.addAll(_headers(authRequired: authRequired));
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      return await _decodeResponse(response);
    } on SocketException catch (e) {
      throw NetworkException('Network request failed', original: e);
    } on TimeoutException catch (e) {
      throw NetworkException('Request timed out', original: e);
    } catch (e, st) {
      if (e is AppException) rethrow;
      AppLogger.error(e, st, details: {'where': 'supabase_post', 'uri': uri.toString()});
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _patchUri(Uri uri,
      {required Map<String, dynamic> body, bool authRequired = false}) async {
    try {
      final request = await _http.postUrl(uri)
        ..headers.addAll(_headers(authRequired: authRequired))
        ..headers.add('X-HTTP-Method-Override', 'PATCH');
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      return await _decodeResponse(response);
    } on SocketException catch (e) {
      throw NetworkException('Network request failed', original: e);
    } on TimeoutException catch (e) {
      throw NetworkException('Request timed out', original: e);
    } catch (e, st) {
      if (e is AppException) rethrow;
      AppLogger.error(e, st, details: {'where': 'supabase_patch', 'uri': uri.toString()});
      rethrow;
    }
  }

  Future<void> _deleteUri(Uri uri, {bool authRequired = false}) async {
    try {
      final request = await _http.deleteUrl(uri)
        ..headers.addAll(_headers(authRequired: authRequired));
      final response = await request.close();
      await _decodeResponse(response);
    } on SocketException catch (e) {
      throw NetworkException('Network request failed', original: e);
    } on TimeoutException catch (e) {
      throw NetworkException('Request timed out', original: e);
    } catch (e, st) {
      if (e is AppException) rethrow;
      AppLogger.error(e, st, details: {'where': 'supabase_delete', 'uri': uri.toString()});
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _decodeResponse(HttpClientResponse response) async {
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (body.isEmpty) return {};
      return jsonDecode(body) as Map<String, dynamic>;
    }
    throw SupabaseException(
      'Request failed (${response.statusCode}): $body',
      statusCode: response.statusCode,
      original: body,
    );
  }

  Future<AuthResponse> _handleAuthResponse(Map<String, dynamic> data) {
    final user = data['user'] != null ? AuthUser.fromJson(data['user']) : null;
    final session = data['session'] != null ? Session.fromJson(data['session']) : null;
    if (session != null) {
      _accessToken = session.accessToken;
      _refreshToken = session.refreshToken;
    }
    _currentUser = user;
    _authStateController.add(user);
    return AuthResponse(user: user, session: session);
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

  AuthUser({
    required this.id,
    required this.email,
    this.phone,
    this.emailConfirmed = false,
    this.userMetadata,
    this.createdAt,
    this.updatedAt,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: json['id'] as String,
      email: json['email'] as String? ?? '',
      phone: json['phone'] as String?,
      emailConfirmed: json['email_confirmed_at'] != null,
      userMetadata: json['user_metadata'] as Map<String, dynamic>?,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)
          : null,
    );
  }

  String? get username => userMetadata?['username'] as String?;
  String? get displayName => userMetadata?['display_name'] as String?;
  String? get avatarUrl => userMetadata?['avatar_url'] as String?;
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
      expiresAt: json['expires_at'] != null
          ? DateTime.tryParse(json['expires_at'] as String)
          : null,
    );
  }
}

/// Result of an authentication operation.
class AuthResponse {
  final AuthUser? user;
  final Session? session;

  AuthResponse({this.user, this.session});

  bool get isAuthenticated => user != null && session != null;

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
  static Map<String, String> _expandFilter(Map<String, String> filter) {
    final expanded = <String, String>{};
    filter.forEach((operator, rawValue) {
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
}
