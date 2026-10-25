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

class FileSessionStore implements SessionStore {
  static const _fileName = '.mailchat_session.json';
  final File _file = File('${Directory.current.path}/$_fileName');

  @override
  Future<String?> getAccessToken() async => _read()?['access_token'] as String?;

  @override
  Future<void> saveAccessToken(String token) async => _write(
        {'access_token': token, 'refresh_token': await getRefreshToken()},
      );

  @override
  Future<String?> getRefreshToken() async =>
      _read()?['refresh_token'] as String?;

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
