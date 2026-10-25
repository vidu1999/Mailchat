
import 'package:flutter/foundation.dart';

/// Application configuration loaded from environment variables / dart-defines.
///
/// Values are resolved in this order (lowest to highest priority):
///   1. Development defaults below
///   2. System environment variables
///   3. `--dart-define` build arguments (recommended for CI/CD and releases)
///
/// Never hard-code real secrets here. Use `.env` locally (git-ignored) and
/// CI secrets for staging/production builds.
class AppConfig {
  AppConfig._();

  static AppConfig? _instance;
  static AppConfig get instance => _instance!;

  /// Supabase project URL, e.g. `https://abcdefgh.supabase.co`
  late final String supabaseUrl;

  /// Supabase anonymous (public) key — safe to ship in the mobile app.
  late final String supabaseAnonKey;

  /// Supabase service-role key — server-side / Edge Functions only.
  late final String? supabaseServiceRoleKey;

  /// Environment name: `development`, `staging` or `production`.
  late final String environment;

  /// Application name shown to users.
  late final String appName;

  /// Auth callback URL registered in Supabase Auth URL Configuration.
  /// Example: `mailchat://auth/callback`
  late final String authRedirectUrl;

  /// Firebase project id used for push notifications.
  late final String? fcmProjectId;

  /// VAPID key for web push (optional).
  late final String? fcmVapidKey;

  /// Supabase storage buckets.
  late final String avatarsBucket;
  late final String attachmentsBucket;

  /// Whether the current environment is production.
  bool get isProduction => environment == 'production';

  /// Whether email confirmation is required before signing in.
  /// Controlled on the Supabase project, mirrored here for UI decisions.
  late final bool emailConfirmationRequired;

  static Future<void> load() async {
    _instance = AppConfig._()
      .._loadDefaults()
      .._loadFromEnvironment();
    if (kDebugMode) {
      _instance!._logConfiguration();
    }
  }

  void _loadDefaults() {
    environment = const String.fromEnvironment('APP_ENV', defaultValue: 'development');
    appName = const String.fromEnvironment('APP_NAME', defaultValue: 'MailChat');

    supabaseUrl = const String.fromEnvironment(
      'SUPABASE_URL',
      defaultValue: 'https://your-project-ref.supabase.co',
    );
    supabaseAnonKey = const String.fromEnvironment(
      'SUPABASE_ANON_KEY',
      defaultValue: 'dev-anon-key-placeholder',
    );
    // fromEnvironment cannot hold a null default, so an absent value is
    // mapped to null explicitly.
    supabaseServiceRoleKey = _emptyToNull(
      const String.fromEnvironment('SUPABASE_SERVICE_ROLE_KEY'),
    );

    authRedirectUrl = const String.fromEnvironment(
      'AUTH_REDIRECT_URL',
      defaultValue: 'mailchat://auth/callback',
    );

    fcmProjectId = _emptyToNull(const String.fromEnvironment('FCM_PROJECT_ID'));
    fcmVapidKey = _emptyToNull(const String.fromEnvironment('FCM_VAPID_KEY'));

    avatarsBucket = const String.fromEnvironment(
      'STORAGE_BUCKET_AVATARS',
      defaultValue: 'avatars',
    );
    attachmentsBucket = const String.fromEnvironment(
      'STORAGE_BUCKET_ATTACHMENTS',
      defaultValue: 'attachments',
    );

    emailConfirmationRequired = const bool.fromEnvironment(
      'EMAIL_CONFIRMATION_REQUIRED',
      defaultValue: true,
    );
  }

  void _loadFromEnvironment() {
    // System environment variables override defaults/dart-defines when present.
    final env = const String.fromEnvironment('APP_ENV');
    if (env.isNotEmpty) environment = env;

    final url = const String.fromEnvironment('SUPABASE_URL');
    if (url.isNotEmpty) supabaseUrl = url;

    final key = const String.fromEnvironment('SUPABASE_ANON_KEY');
    if (key.isNotEmpty) supabaseAnonKey = key;

    final redirect = const String.fromEnvironment('AUTH_REDIRECT_URL');
    if (redirect.isNotEmpty) authRedirectUrl = redirect;
  }

  void _logConfiguration() {
    debugPrint(
      '[AppConfig] environment=$environment appName=$appName '
      'supabaseUrl=$supabaseUrl emailConfirmationRequired=$emailConfirmationRequired',
    );
    // Secrets are intentionally never logged.
  }

  /// Validates that required configuration is present before the app starts.
  /// Throws [ConfigurationException] if critical values are missing or invalid.
  void validate() {
    final errors = <String>[];
    if (supabaseUrl.isEmpty ||
        supabaseUrl.contains('your-project-ref')) {
      errors.add('SUPABASE_URL is not configured');
    }
    if (supabaseAnonKey.isEmpty ||
        supabaseAnonKey.contains('placeholder')) {
      errors.add('SUPABASE_ANON_KEY is not configured');
    }
    if (authRedirectUrl.isEmpty) {
      errors.add('AUTH_REDIRECT_URL is not configured');
    }
    if (errors.isNotEmpty) {
      throw ConfigurationException(errors.join('; '));
    }
  }

  /// Treats an empty compile-time constant as "not configured".
  static String? _emptyToNull(String value) =>
      value.trim().isEmpty ? null : value.trim();
}

/// Thrown when application configuration is missing or invalid.
class ConfigurationException implements Exception {
  final String message;
  ConfigurationException(this.message);

  @override
  String toString() => 'ConfigurationException: $message';
}
