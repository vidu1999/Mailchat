import 'package:flutter/foundation.dart';

/// Structured application logging.
///
/// Logs are written to the debug console in development. In production they
/// should be forwarded to a crash reporting service (e.g. Firebase Crashlytics)
/// — see docs/monitoring.md. Sensitive data (passwords, tokens, message
/// content) must never be logged.
class AppLogger {
  AppLogger._();

  static bool _initialized = false;

  static void init() {
    if (_initialized) return;
    _initialized = true;
  }

  /// Log an informational event. `details` must not contain secrets.
  static void info(String message, {Map<String, dynamic>? details}) {
    _write('INFO', message, details: details);
  }

  /// Log a warning.
  static void warning(String message, {Map<String, dynamic>? details}) {
    _write('WARNING', message, details: details);
  }

  /// Log an error. `error` and `stackTrace` are forwarded from catch blocks.
  static void error(Object error, [StackTrace? stackTrace, Map<String, dynamic>? details]) {
    _write('ERROR', error.toString(), details: details);
    if (stackTrace != null) {
      debugPrint(stackTrace.toString());
    }
  }

  static void _write(String level, String message, {Map<String, dynamic>? details}) {
    final buffer = StringBuffer('$level $message');
    if (details != null && details.isNotEmpty) {
      buffer.write(' $details');
    }
    debugPrint(buffer.toString());
  }
}
