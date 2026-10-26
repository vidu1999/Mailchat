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

void main() {
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
      for (final match
          in RegExp(r'alter publication [a-z0-9_]+ add table',
                  caseSensitive: false)
              .allMatches(code)) {
        _fail(
          name,
          'unguarded `alter publication ... add table` aborts with 42710 on '
          're-run',
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
