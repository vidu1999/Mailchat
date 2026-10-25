import 'dart:convert';
import 'dart:io';

import 'package:mailchat/core/logging/app_logger.dart';

/// Persists the Supabase auth session between app launches.
///
/// [MemorySessionStore] keeps the session only in RAM (lost on restart).
/// [FileSessionStore] writes a small JSON file next to the app working
/// directory — useful for desktop/dev builds. For production mobile builds,
/// replace this with `shared_preferences` / `flutter_secure_storage` (both
/// require pub.dev access, which is unavailable in this sandbox).
abstract class SessionStore {
  Future<String?> getAccessToken();
  Future<void> saveAccessToken(String token);
  Future<String?> getRefreshToken();
  Future<void> saveRefreshToken(String? token);
  Future<void> clear();
}

class MemorySessionStore implements SessionStore {
  String? _accessToken;
  String? _refreshToken;

  @override
  Future<String?> getAccessToken() async => _accessToken;

  @override
  Future<void> saveAccessToken(String token) async => _accessToken = token;

  @override
  Future<String?> getRefreshToken() async => _refreshToken;

  @override
  Future<void> saveRefreshToken(String? token) async => _refreshToken = token;

  @override
  Future<void> clear() async {
    _accessToken = null;
    _refreshToken = null;
  }
}

/// Stores the session as a JSON file in an app-private, writable directory.
///
/// IMPORTANT: this is a stop-gap, not production storage.
///  * The file is plaintext, not encrypted.
///  * `Directory.current` is NOT writable on Android/iOS (it is often `/`),
///    so the previous implementation silently failed to persist anything and
///    every launch sent the user back to the login screen. `Directory.systemTemp`
///    maps to the app's private cache directory on Android, which is writable,
///    but the OS may clear it.
///
/// Before shipping, replace this with a keychain/keystore-backed store
/// (`flutter_secure_storage`). See docs/security.md.
class FileSessionStore implements SessionStore {
  static const _fileName = 'mailchat_session.json';

  /// Resolved lazily and cached: `Directory.systemTemp` is created on demand
  /// and throws on platforms without a temp dir.
  File? _resolved;

  File get _file {
    final cached = _resolved;
    if (cached != null) return cached;
    Directory base;
    try {
      base = Directory.systemTemp;
    } catch (_) {
      base = Directory.current;
    }
    final file = File('${base.path}${Platform.pathSeparator}$_fileName');
    _resolved = file;
    return file;
  }

  @override
  Future<String?> getAccessToken() async =>
      (await _read())?['access_token'] as String?;

  @override
  Future<void> saveAccessToken(String token) async => _write(
        {'access_token': token, 'refresh_token': await getRefreshToken()},
      );

  @override
  Future<String?> getRefreshToken() async =>
      (await _read())?['refresh_token'] as String?;

  @override
  Future<void> saveRefreshToken(String? token) async => _write(
        {'access_token': await getAccessToken(), 'refresh_token': token},
      );

  @override
  Future<void> clear() async {
    try {
      if (await _file.exists()) await _file.delete();
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _read() async {
    try {
      if (!(await _file.exists())) return null;
      final contents = await _file.readAsString();
      return jsonDecode(contents) as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(Map<String, dynamic> data) async {
    try {
      await _file.writeAsString(jsonEncode(data), mode: FileMode.write);
    } catch (e) {
      AppLogger.warning('session_store_write_failed', details: {'error': e.toString()});
    }
  }
}
