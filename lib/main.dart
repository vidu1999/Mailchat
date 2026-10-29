import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:mailchat/app.dart';
import 'package:mailchat/core/config/app_config.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/features/calls/domain/call_trace.dart';
import 'package:mailchat/shared/services/android_notification_controller.dart';
import 'package:mailchat/shared/services/push_notification_service.dart';

/// Entry point of the MailChat application.
///
/// Initialization order:
/// 1. Ensure the Flutter binding is initialized.
/// 2. Load application configuration: the bundled `assets/config/env` file
///    first, with `--dart-define` values taking priority over it.
/// 3. Validate it. Supabase cannot be reached with placeholder values, so
///    failing here produces an actionable message instead of every request
///    failing later with a confusing network error.
/// 4. Initialize structured logging.
/// 5. Run the application widget.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AppConfig.load();
  AppLogger.init();

  // Firebase is optional until the Android app's google-services.json is
  // configured. Missing Firebase setup must not prevent normal chat startup.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(mailChatFcmBackgroundHandler);
      await AndroidNotificationController.instance.initialize();
    } catch (error, stack) {
      AppLogger.warning('firebase_push_not_configured', details: {
        'error': error.toString(),
      });
      AppLogger.error(error, stack, {'where': 'firebase_initialize'});
    }
  }

  // A trace left behind means the previous process died during a call — the one
  // piece of evidence a native kill leaves. Logged once, then removed.
  await CallTraceStore().reportPreviousIfAny();

  try {
    AppConfig.instance.validate();
  } on ConfigurationException catch (error) {
    AppLogger.error(error, StackTrace.current, {'where': 'startup_config'});
    runApp(_ConfigurationErrorApp(message: error.message));
    return;
  }

  runApp(const MailChatApp());
}

/// Shown instead of the app when required configuration is missing.
///
/// This exists so a misconfigured build says exactly what is wrong. Without it
/// the app launched fine and then failed on every network call, which reads as
/// a bug in the app rather than a missing `--dart-define`.
class _ConfigurationErrorApp extends StatelessWidget {
  final String message;

  const _ConfigurationErrorApp({required this.message});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6366F1)),
      ),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.settings_suggest_outlined, size: 64),
                  const SizedBox(height: 16),
                  const Text(
                    'Configuration required',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'Pass the values at build time, for example:\n\n'
                      'flutter run \\\n'
                      '  --dart-define=SUPABASE_URL=https://xxx.supabase.co \\\n'
                      '  --dart-define=SUPABASE_ANON_KEY=eyJ...',
                      style: TextStyle(fontSize: 12, height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
