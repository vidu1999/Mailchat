import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:mailchat/core/logging/app_logger.dart';

/// Delivers incoming links to the app.
///
/// Supabase's verification email ends in a redirect to a URL the operating
/// system hands to an app. On Android and iOS that requires native code, so the
/// platform side is a small channel implemented in
/// `tool/enable_deep_links.sh` (which patches the generated project):
///
///  * `getInitialLink` — the link that cold-started the app, or null.
///  * `incomingLink` — links received while the app is already running.
///
/// A platform channel is used instead of a plugin because this project cannot
/// fetch packages from pub.dev (`docs/running.md` §1). If the native side is not
/// installed — a plain `flutter run -d windows`, or a unit test — every method
/// returns null / never fires, and the app keeps working: the callback simply
/// has to be opened inside the app by signing in normally.
class AppLinks {
  AppLinks._();

  static const MethodChannel _channel = MethodChannel('mailchat/links');

  static final StreamController<String> _controller =
      StreamController<String>.broadcast();
  static bool _initialized = false;

  /// Links received while the app is running. Never completes.
  static Stream<String> get links => _controller.stream;

  /// Whether the platform side can deliver links at all.
  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  /// Fetches the link that launched the app, and starts listening for later
  /// ones. Safe to call more than once.
  static Future<String?> initialLink() async {
    if (!isSupported) return null;
    if (!_initialized) {
      _initialized = true;
      _channel.setMethodCallHandler(_handleCall);
    }
    try {
      final link = await _channel.invokeMethod<String>('getInitialLink');
      if (link != null && link.isNotEmpty) {
        AppLogger.info('deeplink_initial', details: {'length': link.length});
        return link;
      }
    } on MissingPluginException {
      // No native handler installed; not an error worth surfacing.
    } on PlatformException catch (e) {
      AppLogger.warning('deeplink_initial_failed', details: {'error': e.code});
    }
    return null;
  }

  /// Entry point for the native side. Public so tests can drive it directly.
  @visibleForTesting
  static Future<dynamic> handleNativeCall(MethodCall call) =>
      _handleCall(call);

  static Future<dynamic> _handleCall(MethodCall call) async {
    if (call.method != 'incomingLink') return null;
    final link = call.arguments;
    if (link is String && link.isNotEmpty) {
      // Never log the link itself: it carries session tokens.
      AppLogger.info('deeplink_received', details: {'length': link.length});
      _controller.add(link);
    }
    return null;
  }

  /// Closes the stream. Test support only.
  @visibleForTesting
  static Future<void> reset() async {
    _initialized = false;
    _channel.setMethodCallHandler(null);
  }
}
