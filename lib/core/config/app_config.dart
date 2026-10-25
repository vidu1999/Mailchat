import 'package:flutter/foundation.dart';

/// Application configuration resolved from `--dart-define` build arguments.
///
/// Values are resolved once, in a single pass: each setting uses the compile
/// time constant when provided, otherwise the development default below.
/// `String.fromEnvironment` only reads `--dart-define` values — process
/// environment variables and `.env` files are NOT consulted at runtime, so a
/// credential must reach the build as a define (or through CI secrets that are
/// passed as defines).
///
/// Never hard-code real secrets here.
class AppConfig {
  AppConfig._();

  /// Placeholder kept so a misconfigured build produces a clear validation
  /// error instead of contacting a random host.
  static const String _defaultSupabaseUrl =
      'https://your-project-ref.supabase.co';
  static const String _defaultSupabaseAnonKey = 'dev-anon-key-placeholder';

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
    _instance = AppConfig._().._resolve();
    if (kDebugMode) {
      _instance!._logConfiguration();
    }
  }

  /// Resolves every configuration value, assigning each field exactly once.
  ///
  /// Deliberately a single pass. The previous implementation layered
  /// `_loadDefaults()` then `_loadFromEnvironment()` on top of `late final`
  /// fields, which threw `LateInitializationError: Field 'supabaseUrl' has
  /// already been initialized` as soon as a `--dart-define` actually supplied
  /// a value — i.e. on every correctly configured build.
  void _resolve() {
    const envValue = String.fromEnvironment('APP_ENV');
    environment = envValue.isEmpty ? 'development' : envValue;

    const nameValue = String.fromEnvironment('APP_NAME');
    appName = nameValue.isEmpty ? 'MailChat' : nameValue;

    const urlValue = String.fromEnvironment('SUPABASE_URL');
    supabaseUrl = normalizeUrl(
      urlValue.isEmpty ? _defaultSupabaseUrl : urlValue,
    );

    const keyValue = String.fromEnvironment('SUPABASE_ANON_KEY');
    supabaseAnonKey =
        keyValue.isEmpty ? _defaultSupabaseAnonKey : keyValue.trim();

    // Absent unless explicitly provided; never required by the client.
    supabaseServiceRoleKey = _emptyToNull(
      const String.fromEnvironment('SUPABASE_SERVICE_ROLE_KEY'),
    );

    const redirectValue = String.fromEnvironment('AUTH_REDIRECT_URL');
    authRedirectUrl =
        redirectValue.isEmpty ? 'mailchat://auth/callback' : redirectValue;

    fcmProjectId = _emptyToNull(const String.fromEnvironment('FCM_PROJECT_ID'));
    fcmVapidKey = _emptyToNull(const String.fromEnvironment('FCM_VAPID_KEY'));

    const avatarsValue = String.fromEnvironment('STORAGE_BUCKET_AVATARS');
    avatarsBucket = avatarsValue.isEmpty ? 'avatars' : avatarsValue;

    const attachmentsValue =
        String.fromEnvironment('STORAGE_BUCKET_ATTACHMENTS');
    attachmentsBucket =
        attachmentsValue.isEmpty ? 'attachments' : attachmentsValue;

    emailConfirmationRequired = const bool.fromEnvironment(
      'EMAIL_CONFIRMATION_REQUIRED',
      defaultValue: true,
    );
  }

  /// Normalises the base URL so every request path is appended safely.
  ///
  /// Handles the three mistakes that produce an opaque "Network request
  /// failed": a missing scheme, a trailing slash (which yields `//auth/v1/...`),
  /// and stray whitespace from copy-paste.
  ///
  /// Public (rather than private) so it can be unit tested directly; the
  /// values it normalises are compile-time constants and cannot be injected.
  static String normalizeUrl(String raw) {
    var url = raw.trim();

    // Strip trailing slashes: 'https://x.supabase.co/' + '/auth/v1' would
    // otherwise become 'https://x.supabase.co//auth/v1'.
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }

    // A host without a scheme is parsed as a relative reference, so
    // HttpClient throws instead of connecting.
    if (url.isNotEmpty && !url.contains('://')) {
      url = 'https://$url';
    }
    return url;
  }

  /// Host[:port] of the configured Supabase project, for diagnostics.
  /// Safe to display and to log: it contains no credential.
  String get supabaseHost {
    final uri = Uri.tryParse(supabaseUrl);
    if (uri == null || uri.host.isEmpty) return supabaseUrl;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  void _logConfiguration() {
    debugPrint(
      '[AppConfig] environment=$environment appName=$appName '
      'supabaseHost=$supabaseHost emailConfirmationRequired=$emailConfirmationRequired',
    );
    // Secrets are intentionally never logged: only the host, not the URL or key.
  }

  /// Validates that required configuration is present before the app starts.
  /// Throws [ConfigurationException] if critical values are missing or invalid.
  void validate() {
    final errors = <String>[];
    if (supabaseUrl.isEmpty || supabaseUrl.contains('your-project-ref')) {
      errors.add('SUPABASE_URL is not configured');
    } else {
      final uri = Uri.tryParse(supabaseUrl);
      if (uri == null ||
          !(uri.scheme == 'https' || uri.scheme == 'http') ||
          uri.host.isEmpty ||
          !uri.host.contains('.')) {
        // Catches 'xyz' or 'xyz.supabase.co' style mistakes and typos that
        // would otherwise surface as an unexplained SocketException.
        errors.add(
          'SUPABASE_URL is not a valid URL (got "$supabaseUrl"; expected '
          'https://YOUR-PROJECT.supabase.co)',
        );
      }
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
