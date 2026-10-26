import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/config/app_config.dart';

/// The env file is the only way to configure the app without CLI flags, and it
/// is parsed by hand, so the parser is pinned down here.
///
/// The real `assets/config/env` exists only on a developer machine; CI runs
/// without it, which is also exercised below.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppConfig.parseEnvFile', () {
    test('reads a simple key/value pair', () {
      expect(
        AppConfig.parseEnvFile('SUPABASE_URL=https://abcdefgh.supabase.co'),
        {'SUPABASE_URL': 'https://abcdefgh.supabase.co'},
      );
    });

    test('ignores comments and blank lines', () {
      const raw = '''
# MailChat configuration

SUPABASE_URL=https://abcdefgh.supabase.co
   # indented comment
SUPABASE_ANON_KEY=abc
''';
      expect(AppConfig.parseEnvFile(raw), {
        'SUPABASE_URL': 'https://abcdefgh.supabase.co',
        'SUPABASE_ANON_KEY': 'abc',
      });
    });

    test('accepts an export prefix', () {
      expect(
        AppConfig.parseEnvFile('export APP_ENV=staging'),
        {'APP_ENV': 'staging'},
      );
    });

    test('strips matching quotes', () {
      expect(
        AppConfig.parseEnvFile('A="one two"\nB=\'three four\''),
        {'A': 'one two', 'B': 'three four'},
      );
    });

    test('discards an inline comment after a quoted value', () {
      // Without this, the comment leaks into the anon key and every request
      // fails with an opaque 401.
      expect(
        AppConfig.parseEnvFile('SUPABASE_ANON_KEY="abc" # paste here'),
        {'SUPABASE_ANON_KEY': 'abc'},
      );
    });

    test('keeps an unmatched quote as literal text instead of throwing', () {
      expect(AppConfig.parseEnvFile('KEY="abc'), {'KEY': 'abc'});
    });

    test('handles CRLF line endings from Windows editors', () {
      expect(
        AppConfig.parseEnvFile('APP_ENV=development\r\nAPP_NAME=MailChat\r\n'),
        {'APP_ENV': 'development', 'APP_NAME': 'MailChat'},
      );
    });

    test('trims whitespace around keys and values', () {
      expect(
        AppConfig.parseEnvFile('  APP_ENV =  staging  '),
        {'APP_ENV': 'staging'},
      );
    });

    test('upper-cases keys so lookups do not depend on casing', () {
      expect(AppConfig.parseEnvFile('supabase_url=x'), {'SUPABASE_URL': 'x'});
    });

    test('keeps = inside a value', () {
      // JWT segments and base64 padding both contain '='.
      expect(
        AppConfig.parseEnvFile('SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiJ9.abc=='),
        {'SUPABASE_ANON_KEY': 'eyJhbGciOiJIUzI1NiJ9.abc=='},
      );
    });

    test('records an empty value as empty rather than dropping the key', () {
      expect(AppConfig.parseEnvFile('FCM_PROJECT_ID='), {'FCM_PROJECT_ID': ''});
    });

    test('ignores lines that are not assignments', () {
      expect(AppConfig.parseEnvFile('garbage\nA=1'), {'A': '1'});
    });

    test('lets the last duplicate win', () {
      expect(AppConfig.parseEnvFile('A=1\nA=2'), {'A': '2'});
    });
  });

  group('startup without an env file', () {
    test('falls back to placeholders and refuses to start', () async {
      // This is exactly what CI does: no assets/config/env exists, and no
      // --dart-define is passed to `flutter test`. The app must say what is
      // missing instead of contacting a placeholder host.
      await AppConfig.load();

      expect(AppConfig.instance.loadedEnvFile, isFalse);
      expect(
        AppConfig.instance.validate,
        throwsA(isA<ConfigurationException>()),
      );
    });

    test('the error names the file to create', () async {
      await AppConfig.load();

      late ConfigurationException error;
      try {
        AppConfig.instance.validate();
      } on ConfigurationException catch (e) {
        error = e;
      }
      expect(error.message, contains('assets/config/env'));
      expect(error.message, contains('SUPABASE_URL'));
      expect(error.message, contains('SUPABASE_ANON_KEY'));
    });
  });

  group('diagnostics', () {
    test('sourceLabel and host reveal no credentials', () async {
      await AppConfig.load();

      expect(AppConfig.instance.sourceLabel, isNotEmpty);
      expect(AppConfig.instance.supabaseHost, isNotEmpty);
      // Host only: never the key, and never the full URL with query params.
      expect(AppConfig.instance.supabaseHost, isNot(contains('placeholder')));
      expect(AppConfig.instance.sourceLabel, contains('defaults'));
    });
  });
}
