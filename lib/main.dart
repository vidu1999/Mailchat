import 'package:flutter/material.dart';
import 'package:mailchat/app.dart';
import 'package:mailchat/core/config/app_config.dart';
import 'package:mailchat/core/logging/app_logger.dart';

/// Entry point of the MailChat application.
///
/// Initialization order:
/// 1. Ensure the Flutter binding is initialized.
/// 2. Load application configuration (environment / dart-defines).
/// 3. Initialize structured logging.
/// 4. Run the application widget.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AppConfig.load();
  AppLogger.init();

  runApp(const MailChatApp());
}
