// Static checks on supabase/migrations — the parts that can be verified without
// a database.
//
//   dart run tool/check_migrations.dart
//
// Why: this project's users apply migrations by hand in the Supabase SQL editor,
// so a file that is not re-runnable strands them halfway. A trigger without a
// preceding `drop trigger if exists` aborts the whole file with 42710 the second
// time it is applied — which is exactly what happened with 0001.
//
// Checks, per file:
//   1. every `create trigger X` has a `drop trigger if exists X` in the file
//   2. `create table` / `create index` use `if not exists`
//   3. functions use `create or replace function`
//   4. every `create policy X` is preceded by `drop policy if exists X`
//   5. `alter publication ... add table` is guarded inside a DO block
//   6. the file is not empty
//
// Exits 1 when anything fails.

import 'dart:io';

void main(List<String> args) {
  final dir = Directory('supabase/migrations');
  if (!dir.existsSync()) {
    stderr.writeln('No supabase/migrations directory; run from the project root.');
    exit(1);
  }

  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.sql'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (args.contains('--write-apply-all')) {
    _writeApplyAll(files);
    return;
  }

  var problems = 0;

  for (final file in files) {
    final name = file.uri.pathSegments.last;
    // Comments describe the checks; they must not satisfy them.
    final code = _stripComments(file.readAsStringSync());

    if (code.trim().isEmpty) {
      _fail(name, 'file is empty (or entirely comments)');
      problems++;
      continue;
    }

    for (final match in RegExp(r'create trigger\s+([a-z0-9_]+)',
            caseSensitive: false)
        .allMatches(code)) {
      final trigger = match.group(1)!;
      final guarded =
          RegExp('drop trigger if exists\\s+$trigger\\b',
                  caseSensitive: false)
              .hasMatch(code);
      if (!guarded) {
        _fail(
          name,
          'create trigger $trigger has no `drop trigger if exists $trigger` '
          '(re-running the file aborts with 42710)',
        );
        problems++;
      }
    }

    for (final match in RegExp(r'create (?:unique )?index (?!if not exists)',
            caseSensitive: false)
        .allMatches(code)) {
      _fail(name, 'index without `if not exists`: ${_lineOf(code, match.start)}');
      problems++;
    }

    for (final match in RegExp(r'create table (?!if not exists)',
            caseSensitive: false)
        .allMatches(code)) {
      _fail(
          name, 'table without `if not exists`: ${_lineOf(code, match.start)}');
      problems++;
    }

    for (final match
        in RegExp(r'create function', caseSensitive: false).allMatches(code)) {
      _fail(name,
          'function without `or replace`: ${_lineOf(code, match.start)}');
      problems++;
    }

    for (final match in RegExp(r'create policy\s+([a-z0-9_]+)',
            caseSensitive: false)
        .allMatches(code)) {
      final policy = match.group(1)!;
      final guarded =
          RegExp('drop policy if exists\\s+$policy\\b',
                  caseSensitive: false)
              .hasMatch(code);
      if (!guarded) {
        _fail(name,
            'create policy $policy has no `drop policy if exists $policy`');
        problems++;
      }
    }

    // `alter publication ... add table` outside a DO block is not re-runnable.
    final guardedPublication = code.contains('pg_publication_tables');
    if (!guardedPublication) {
      // The line number is the useful part of the report here, so use it.
      for (final match
          in RegExp(r'alter publication [a-z0-9_]+ add table',
                  caseSensitive: false)
              .allMatches(code)) {
        _fail(
          name,
          'unguarded `alter publication ... add table` at '
          '${_lineOf(code, match.start)} aborts with 42710 on re-run',
        );
        problems++;
      }
    }
  }

  // ---- supabase/apply_all.sql must not drift from the migrations -----------
  // It is what users actually paste, so a stale copy is as bad as a bad
  // migration: they would apply last week's schema and never know.
  final verifyFile = File('supabase/verify.sql');
  final bundle = File('supabase/apply_all.sql');
  if (verifyFile.existsSync()) {
    if (!bundle.existsSync()) {
      _fail('supabase/apply_all.sql', 'missing - run --write-apply-all');
      problems++;
    } else {
      final bundled = bundle.readAsStringSync();
      for (final file in files) {
        if (!bundled.contains(file.readAsStringSync().trim())) {
          _fail(
            'supabase/apply_all.sql',
            'does not contain ${file.uri.pathSegments.last} - regenerate with '
            '`dart run tool/check_migrations.dart --write-apply-all`',
          );
          problems++;
        }
      }
      if (!bundled.contains(verifyFile.readAsStringSync().trim())) {
        _fail(
          'supabase/apply_all.sql',
          'does not contain supabase/verify.sql - regenerate',
        );
        problems++;
      }
    }
  }

  if (problems > 0) {
    stderr.writeln('\n$problems problem(s) found in ${files.length} file(s).');
    exit(1);
  }
  stdout.writeln('${files.length} migration files are re-runnable.');
}

/// Rebuilds supabase/apply_all.sql: header, every migration in order, then the
/// health check. The only supported way to produce that file.
void _writeApplyAll(List<File> files) {
  final rule = List.filled(74, '=').join();
  final buffer = StringBuffer();
  buffer.writeln(_applyAllHeader.trim());
  buffer.writeln();

  for (final file in files) {
    buffer.writeln('-- $rule');
    buffer.writeln('-- ${file.uri.pathSegments.last}');
    buffer.writeln('-- $rule');
    buffer.writeln();
    buffer.writeln(file.readAsStringSync().trimRight());
    buffer.writeln();
  }

  buffer.writeln(File('supabase/verify.sql').readAsStringSync().trimRight());
  File('supabase/apply_all.sql').writeAsStringSync(buffer.toString());
  stdout.writeln('Wrote supabase/apply_all.sql from ${files.length} migrations.');
}

const _applyAllHeader = r'''
-- MailChat - complete database setup, in one file.
--
-- Paste this entire file into the Supabase SQL editor and run it once. It is the
-- SQL from supabase/migrations/0001..0004, in order, plus a health check at the
-- end. Safe on a database in any state: empty, half-applied, or complete.
--
-- Why this exists: the migrations must be applied in order and re-run after a
-- failure, and doing that by hand from separate files goes wrong easily - a
-- half-applied file, a stale copy, a step missed. This removes the choices.
--
-- GENERATED by tool/check_migrations.dart --write-apply-all. Do not edit;
-- change supabase/migrations/*.sql or supabase/verify.sql and regenerate.
--
-- The last statement prints a verification table. Every row must read ok.''';

void _fail(String file, String message) => stderr.writeln('$file: $message');

String _lineOf(String code, int offset) {
  final lineStart = code.lastIndexOf('\n', offset) + 1;
  var lineEnd = code.indexOf('\n', offset);
  if (lineEnd == -1) lineEnd = code.length;
  return code.substring(lineStart, lineEnd).trim();
}

/// Removes `--` comments and `/* */` blocks, so prose cannot satisfy a check.
/// Single-quoted literals are copied through: they may contain `--`.
String _stripComments(String sql) {
  final buffer = StringBuffer();
  var i = 0;
  while (i < sql.length) {
    if (sql.startsWith('--', i)) {
      final end = sql.indexOf('\n', i);
      i = end == -1 ? sql.length : end;
    } else if (sql.startsWith('/*', i)) {
      final end = sql.indexOf('*/', i + 2);
      i = end == -1 ? sql.length : end + 2;
    } else if (sql[i] == "'") {
      final end = sql.indexOf("'", i + 1);
      final stop = end == -1 ? sql.length : end + 1;
      buffer.write(sql.substring(i, stop));
      i = stop;
    } else {
      buffer.write(sql[i]);
      i++;
    }
  }
  return buffer.toString();
}
