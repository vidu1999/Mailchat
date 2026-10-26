import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Application configuration, resolved from two sources.
///
/// Priority, highest first:
///  1. `--dart-define` / `--dart-define-from-file` build arguments.
///  2. The env file bundled as the `assets/config/env` asset.
///  3. The development defaults below.
///
/// Why the file is an *asset*: `String.fromEnvironment` is resolved by the
/// compiler, so it can only ever see `--dart-define`. A plain `.env` sitting in
/// the project root is invisible to the running app — nothing reads it. To make
/// `flutter run` work with no flags at all, the values have to be bundled and
/// read at runtime through `rootBundle`, which is what [load] does.
///
/// Consequences worth knowing:
///  * Editing `assets/config/env` needs a **restart**, not a hot reload: the
///    asset is baked into the bundle at build time.
///  * The anon key ends up inside the APK. That is acceptable — it is a
///    publishable key and every table is behind RLS — but it does mean the app
///    must never be given the `service_role` key.
///  * CI has no env file, so the defaults below are used and [validate] fails
///    loudly instead of the app silently contacting a placeholder host.
///
/// Never hard-code real secrets here.
class AppConfig {
  AppConfig._();

  /// Bundled env file, in `.env` syntax. Not dot-prefixed on purpose: Flutter's
  /// asset bundler skips dotfiles, so `assets/config/.env` would be silently
  /// missing at runtime.
  static const String envAssetPath = 'assets/config/env';

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

  /// Whether [load] actually found a bundled env file.
  ///
  /// Diagnostic only: it says where configuration came from without revealing
  /// any value.
  bool get loadedEnvFile => _loadedEnvFile;
  bool _loadedEnvFile = false;

  /// Reads the bundled env file (if present) and resolves every setting.
  ///
  /// Never throws: a missing or malformed env file falls back to `--dart-define`
  /// values and then to the defaults, so [validate] can report the problem in
  /// terms the user can act on.
  static Future<void> load() async {
    final fromFile = await _readEnvAsset();
    _instance = AppConfig._()
      .._loadedEnvFile = fromFile.isNotEmpty
      .._resolve(fromFile);
    if (kDebugMode) {
      _instance!._logConfiguration();
    }
  }

  /// Loads and parses [envAssetPath], returning an empty map when it is absent.
  ///
  /// `rootBundle` throws a `FlutterError` (an `Error`, not an `Exception`) for a
  /// missing asset, so this uses a bare `catch`.
  static Future<Map<String, String>> _readEnvAsset() async {
    try {
      final raw = await rootBundle.loadString(envAssetPath);
      return parseEnvFile(raw);
    } catch (e) {
      debugPrint('[AppConfig] no bundled env file at $envAssetPath ($e)');
      return const <String, String>{};
    }
  }

  /// Parses `.env` syntax into a map of upper-cased keys.
  ///
  /// Supported: `KEY=value`, `export KEY=value`, `#` comments, blank lines,
  /// CRLF endings, and values wrapped in matching single or double quotes (with
  /// anything after the closing quote, such as an inline comment, discarded).
  /// Lines without `=` are ignored rather than treated as errors: a stray line
  /// should not take down startup.
  ///
  /// Public so it can be unit tested — the real file only exists on a developer
  /// machine, so this is the only part of the env pipeline that is testable.
  @visibleForTesting
  static Map<String, String> parseEnvFile(String raw) {
    final result = <String, String>{};
    for (final line in raw.split('\n')) {
      var entry = line.trim();
      if (entry.isEmpty || entry.startsWith('#')) continue;
      if (entry.startsWith('export ')) {
        entry = entry.substring('export '.length).trim();
      }
      final separator = entry.indexOf('=');
      if (separator <= 0) continue;

      final key = entry.substring(0, separator).trim().toUpperCase();
      if (key.isEmpty) continue;

      var value = entry.substring(separator + 1).trim();
      if (value.startsWith('"') || value.startsWith("'")) {
        final quote = value[0];
        final closing = value.indexOf(quote, 1);
        value = closing == -1
            ? value.substring(1)
            : value.substring(1, closing);
      }
      result[key] = value.trim();
    }
    return result;
  }

  /// Resolves every configuration value, assigning each field exactly once.
  ///
  /// Deliberately a single pass. The previous implementation layered
  /// `_loadDefaults()` then `_loadFromEnvironment()` on top of `late final`
  /// fields, which threw `LateInitializationError: Field 'supabaseUrl' has
  /// already been initialized` as soon as a `--dart-define` actually supplied
  /// a value — i.e. on every correctly configured build.
  void _resolve(Map<String, String> file) {
    environment = _pick(
      const String.fromEnvironment('APP_ENV'),
      file,
      'APP_ENV',
      'development',
    );

    appName = _pick(
      const String.fromEnvironment('APP_NAME'),
      file,
      'APP_NAME',
      'MailChat',
    );

    supabaseUrl = normalizeUrl(_pick(
      const String.fromEnvironment('SUPABASE_URL'),
      file,
      'SUPABASE_URL',
      _defaultSupabaseUrl,
    ));

    // Keys are long, are often pasted with a trailing newline, and are never
    // allowed to carry whitespace.
    supabaseAnonKey = _pick(
      const String.fromEnvironment('SUPABASE_ANON_KEY'),
      file,
      'SUPABASE_ANON_KEY',
      _defaultSupabaseAnonKey,
    ).trim();

    // Absent unless explicitly provided; never required by the client.
    supabaseServiceRoleKey = _pickNullable(
      const String.fromEnvironment('SUPABASE_SERVICE_ROLE_KEY'),
      file,
      'SUPABASE_SERVICE_ROLE_KEY',
    );

    authRedirectUrl = _pick(
      const String.fromEnvironment('AUTH_REDIRECT_URL'),
      file,
      'AUTH_REDIRECT_URL',
      'mailchat://auth/callback',
    );

    fcmProjectId = _pickNullable(
      const String.fromEnvironment('FCM_PROJECT_ID'),
      file,
      'FCM_PROJECT_ID',
    );

    fcmVapidKey = _pickNullable(
      const String.fromEnvironment('FCM_VAPID_KEY'),
      file,
      'FCM_VAPID_KEY',
    );

    avatarsBucket = _pick(
      const String.fromEnvironment('STORAGE_BUCKET_AVATARS'),
      file,
      'STORAGE_BUCKET_AVATARS',
      'avatars',
    );

    attachmentsBucket = _pick(
      const String.fromEnvironment('STORAGE_BUCKET_ATTACHMENTS'),
      file,
      'STORAGE_BUCKET_ATTACHMENTS',
      'attachments',
    );

    // Read as a string rather than with `bool.fromEnvironment` so "absent" and
    // "explicitly false" stay distinguishable — a bool define cannot express
    // "not provided" once a non-null default exists.
    emailConfirmationRequired = _parseBool(
      const String.fromEnvironment('EMAIL_CONFIRMATION_REQUIRED'),
      file['EMAIL_CONFIRMATION_REQUIRED'],
      fallback: true,
    );
  }

  /// Compile-time value first, then the env file, then [fallback].
  ///
  /// An empty define is treated as "not provided": `--dart-define=KEY=` should
  /// not blank out a value that the env file supplies.
  static String _pick(
    String defineValue,
    Map<String, String> file,
    String key,
    String fallback,
  ) {
    if (defineValue.trim().isNotEmpty) return defineValue;
    final fromFile = file[key]?.trim();
    if (fromFile != null && fromFile.isNotEmpty) return fromFile;
    return fallback;
  }

  /// Same order as [_pick], but "not provided" is null rather than a default.
  static String? _pickNullable(
    String defineValue,
    Map<String, String> file,
    String key,
  ) {
    final picked = _pick(defineValue, file, key, '');
    return picked.isEmpty ? null : picked;
  }

  static bool _parseBool(String defineValue, String? fileValue,
      {required bool fallback}) {
    final raw = defineValue.trim().isNotEmpty
        ? defineValue.trim()
        : (fileValue ?? '').trim();
    switch (raw.toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
      case 'on':
        return true;
      case 'false':
      case '0':
      case 'no':
      case 'off':
        return false;
      default:
        return fallback;
    }
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

  /// Where the configuration came from, for the startup log and error screen.
  String get sourceLabel => _loadedEnvFile
      ? 'env file ($envAssetPath) and --dart-define'
      : '--dart-define and built-in defaults';

  void _logConfiguration() {
    debugPrint(
      '[AppConfig] environment=$environment appName=$appName '
      'supabaseHost=$supabaseHost emailConfirmationRequired=$emailConfirmationRequired '
      'source=$sourceLabel',
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
    if (supabaseAnonKey.isEmpty || supabaseAnonKey.contains('placeholder')) {
      errors.add('SUPABASE_ANON_KEY is not configured');
    }
    if (authRedirectUrl.isEmpty) {
      errors.add('AUTH_REDIRECT_URL is not configured');
    }
    if (errors.isNotEmpty) {
      throw ConfigurationException(
        '${errors.join('; ')}.\n\nConfiguration was read from $sourceLabel. '
        'Copy assets/config/env.example to assets/config/env and fill it in '
        '(see docs/running.md §1), or pass the values as --dart-define.',
      );
    }
  }

}

/// Thrown when application configuration is missing or invalid.
class ConfigurationException implements Exception {
  final String message;
  ConfigurationException(this.message);

  @override
  String toString() => 'ConfigurationException: $message';
}
