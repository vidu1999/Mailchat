import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';

/// Registers this Android installation's FCM token in the owner's RLS-protected
/// `user_devices` rows. The token is a routing address, never an FCM credential.
///
/// OS display in the background is handled by Firebase/Android from the
/// notification payload. Foreground behavior remains MailChat's in-app UI.
class PushNotificationService {
  PushNotificationService();

  final SupabaseClient _supabase = SupabaseClient.instance;
  StreamSubscription<String>? _tokenChanges;
  String? _userId;
  String? _token;

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> registerForUser(String userId) async {
    if (!_supported || Firebase.apps.isEmpty || userId.isEmpty) return;
    _userId = userId;
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) await _saveToken(token);
      _tokenChanges ??= FirebaseMessaging.instance.onTokenRefresh.listen(
        (freshToken) => unawaited(_saveToken(freshToken)),
        onError: (Object error, StackTrace stack) {
          AppLogger.error(error, stack, {'where': 'fcm_token_refresh'});
        },
      );
    } catch (error, stack) {
      // Missing/incorrect Firebase Android setup must not block chat startup.
      AppLogger.error(error, stack, {'where': 'fcm_registration'});
    }
  }

  Future<void> _saveToken(String token) async {
    final userId = _userId;
    if (userId == null || token.isEmpty) return;
    try {
      final previous = _token;
      if (previous != null && previous != token) {
        await _supabase.delete(
          'user_devices',
          filter: {'eq': 'user_id,$userId,device_id,$previous'},
        );
      }
      final existing = await _supabase.select(
        'user_devices',
        select: 'id',
        filter: {'eq': 'user_id,$userId,device_id,$token'},
        limit: 1,
      );
      final data = <String, dynamic>{
        'user_id': userId,
        'device_id': token,
        'platform': 'android',
        'push_token': token,
        'last_active_at': DateTime.now().toUtc().toIso8601String(),
      };
      if (existing.isEmpty) {
        await _supabase.insert('user_devices', data: data, select: 'id');
      } else {
        await _supabase.update(
          'user_devices',
          filter: {'eq': 'id,${existing.first['id']}'},
          data: data
            ..remove('user_id')
            ..remove('device_id'),
        );
      }
      _token = token;
      AppLogger.info('fcm_device_registered', details: {'platform': 'android'});
    } catch (error, stack) {
      AppLogger.error(error, stack, {'where': 'fcm_token_store'});
    }
  }

  /// Removes this installation's token before Supabase clears the user session.
  Future<void> unregisterCurrentUser() async {
    final userId = _supabase.userId;
    if (!_supported || Firebase.apps.isEmpty || userId == null) return;
    try {
      final token = _token ?? await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) {
        await _supabase.delete(
          'user_devices',
          filter: {'eq': 'user_id,$userId,device_id,$token'},
        );
      }
    } catch (error, stack) {
      AppLogger.warning(
        'fcm_device_unregister_failed',
        details: {'error': error.toString()},
      );
      AppLogger.error(error, stack, {'where': 'fcm_unregister'});
    }
  }

  void dispose() {
    unawaited(_tokenChanges?.cancel());
    _tokenChanges = null;
  }
}

/// Entry point retained by the VM for FCM background delivery. FCM's
/// notification payload is rendered by Android itself while the app is in the
/// background; this handler intentionally does not create a duplicate alert.
@pragma('vm:entry-point')
Future<void> mailChatFcmBackgroundHandler(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) {
    try {
      await Firebase.initializeApp();
    } catch (_) {
      // Android's native FCM renderer can still show notification payloads.
    }
  }
}
