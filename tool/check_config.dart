// Validates the configuration an APK will be built with, before spending
// minutes on a build.
//
//   dart run tool/check_config.dart
//   dart run tool/check_config.dart --quiet   # exit code only
//
// Exits 0 when the file is usable, 1 when it is not, and prints why. The parser
// is the same one the app uses (lib/core/config/env_file.dart), so this cannot
// disagree with what the APK will actually read.

import 'dart:io';

import 'package:mailchat/core/config/anon_key.dart';
import 'package:mailchat/core/config/env_file.dart';

const String _envPath = 'assets/config/env';

Future<void> main(List<String> args) async {
  final quiet = args.contains('--quiet');
  final file = File(_envPath);

  if (!file.existsSync()) {
    _report('No $_envPath.\n'
        'Copy the template first:\n'
        '  PowerShell:  Copy-Item assets/config/env.example assets/config/env\n'
        '  bash:        cp assets/config/env.example assets/config/env\n'
        'Then fill in SUPABASE_URL and SUPABASE_ANON_KEY (docs/running.md §1).');
  }

  final values = EnvFile.parse(file.readAsStringSync());
  final problems = <String>[];

  if (EnvFile.isUnset(values, 'SUPABASE_URL', placeholders: ['your-project-ref'])) {
    // The project ref is inside the key, so the fix can be stated exactly
    // rather than described.
    final suggested = AnonKey.suggestedUrl(values['SUPABASE_ANON_KEY']);
    problems.add(suggested == null
        ? 'SUPABASE_URL is missing or still the placeholder.'
        : 'SUPABASE_URL is missing or still the placeholder.\n'
            '  Your key belongs to project '
            '${AnonKey.projectRef(values['SUPABASE_ANON_KEY'])}. Set:\n'
            '  SUPABASE_URL=$suggested');
  } else {
    final raw = values['SUPABASE_URL']!.trim();
    final normalised = raw.contains('://') ? raw : 'https://$raw';
    final uri = Uri.tryParse(normalised);
    if (uri == null ||
        !(uri.scheme == 'https' || uri.scheme == 'http') ||
        uri.host.isEmpty ||
        !uri.host.contains('.')) {
      problems.add('SUPABASE_URL is not a valid URL: "$raw" '
          '(expected https://YOUR-PROJECT.supabase.co).');
    }
    if (uri != null && uri.host == 'localhost') {
      problems.add('SUPABASE_URL points at localhost. A phone cannot reach '
          "your computer's localhost — use the project URL from the dashboard.");
    }
  }

  // A privileged key in the bundled file ends up inside the APK, where anyone
  // who unzips it can read it. This is a hard stop, not a warning.
  final bundledServiceKey = values['SUPABASE_SERVICE_ROLE_KEY']?.trim() ?? '';
  if (bundledServiceKey.isNotEmpty) {
    problems.add('SUPABASE_SERVICE_ROLE_KEY is set in $_envPath. Anything in '
        'that file is compiled into the APK, and this key bypasses every RLS '
        'policy — remove the line and rotate the key in the Supabase dashboard '
        '(Settings → API → JWT settings).');
  }
  for (final name in const ['SMTP_PASS', 'SMTP_USER', 'SMTP_HOST']) {
    final value = values[name]?.trim() ?? '';
    if (value.isNotEmpty) {
      problems.add('$name is set in $_envPath. Mail is sent by Supabase, not by '
          'the app, so this credential would only be bundled into the APK. '
          'Configure SMTP in the Supabase dashboard and remove the line.');
    }
  }

  final anonKey = values['SUPABASE_ANON_KEY']?.trim() ?? '';
  if (EnvFile.isUnset(values, 'SUPABASE_ANON_KEY',
      placeholders: ['placeholder', 'your-anon-key'])) {
    problems.add('SUPABASE_ANON_KEY is missing or still the placeholder.');
  } else {
    if (AnonKey.isServiceRole(anonKey)) {
      problems.add('SUPABASE_ANON_KEY is a service_role key (the JWT payload '
          'says so). It bypasses every RLS policy and must never ship inside an '
          'app — use the anon/public key. Rotate it: it has now been handled by '
          'build tooling and may have been exposed.');
    }
    // A JWT is three dot-separated segments; the publishable keys are shorter
    // opaque strings. Anything much shorter is a truncated paste.
    if (!anonKey.contains('.') && anonKey.length < 20) {
      problems.add('SUPABASE_ANON_KEY looks truncated (${anonKey.length} chars). '
          'Copy the whole key from Project Settings → API.');
    }
    if (anonKey != anonKey.trim() || anonKey.contains(' ')) {
      problems.add('SUPABASE_ANON_KEY contains whitespace or a newline.');
    }
  }

  if (problems.isNotEmpty) {
    _report(problems.join('\n'));
  }

  final host = Uri.tryParse(
        values['SUPABASE_URL']!.contains('://')
            ? values['SUPABASE_URL']!
            : 'https://${values['SUPABASE_URL']}',
      )?.host ??
      values['SUPABASE_URL']!;

  if (!quiet) {
    stdout.writeln('Configuration OK');
    stdout.writeln('  file:  $_envPath');
    stdout.writeln('  host:  $host');
    final role = AnonKey.jwtRole(anonKey) ?? 'not readable (new-style key)';
    stdout.writeln('  key:   present (${anonKey.length} chars, role: $role)');
    stdout.writeln(
        '  email confirmation: ${values['EMAIL_CONFIRMATION_REQUIRED'] ?? 'true (default)'}');
    final redirect = values['AUTH_REDIRECT_URL'] ?? 'mailchat://auth/callback';
    stdout.writeln('  auth redirect: $redirect');
    stdout.writeln('');
    stdout.writeln('Reminder: "$redirect" must be listed under Supabase → '
        'Authentication → URL Configuration → Redirect URLs,\n'
        'or confirmation emails will not return to the app '
        '(docs/auth-links.md).');
  }
}

Never _report(String message) {
  stderr.writeln('Configuration error:\n$message');
  exit(1);
}
