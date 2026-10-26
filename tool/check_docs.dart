// Documentation checker.
//
// The feature documents claim things about this repository: "this is the code",
// "this is the migration", "this is the test". Those claims are written as paths
// in backticks. When a file is renamed or deleted, the claim silently becomes
// false, and a document that lies is worse than no document.
//
// This script treats every path mentioned in a document as an assertion and
// fails CI when one does not exist. It also enforces the structure that makes the
// set navigable:
//
//   * every `docs/*.md` file is linked from `docs/README.md`;
//   * every relative markdown link resolves;
//   * every feature document declares a **Status:** line.
//
// Run: dart run tool/check_docs.dart
// Exit code 1 if anything is wrong, with one line per problem.

import 'dart:io';

const _docsDir = 'docs';
const _index = 'docs/README.md';

/// Documents that describe process rather than a feature, and so carry no
/// `**Status:**` line.
const _noStatusRequired = {
  'README.md',
  'feature-matrix.md',
  'running.md',
  'any-device.md',
  'testing.md',
  'release.md',
  'architecture.md',
  'security.md',
};

/// Paths that are referenced but are not expected to exist in a checkout: the
/// generated platform folders, and files the user creates.
const _allowedMissing = {
  '.env',
  '.env.example',
  'android/',
  'ios/',
  'google-services.json',
  'GoogleService-Info.plist',
  // Mentioned in running.md to explain why the asset is called `env` and not
  // `.env`: it is a path that must NOT be used, so it will never exist.
  'assets/config/.env',
};

void main() {
  final docs = Directory(_docsDir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.md'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  var problems = 0;

  void fail(String file, String message) {
    stderr.writeln('$file: $message');
    problems++;
  }

  final index = File(_index);
  if (!index.existsSync()) {
    fail(_index, 'missing - it is the entry point for docs/');
  }
  final indexText = index.existsSync() ? index.readAsStringSync() : '';

  for (final doc in docs) {
    final name = _baseName(doc.path);
    final text = doc.readAsStringSync();
    final rel = '$_docsDir/$name';

    // 1. Every document is reachable from the index.
    if (rel != _index && !indexText.contains(name)) {
      fail(rel, 'is not linked from $_index');
    }

    // 2. Status line, for feature documents.
    if (!_noStatusRequired.contains(name) &&
        !RegExp(r'\*\*Status:\*\*').hasMatch(text)) {
      fail(rel, 'has no `**Status:**` line');
    }

    // 3. Relative links resolve.
    for (final match in RegExp(r'\]\(([^)]+)\)').allMatches(text)) {
      final target = match.group(1)!.trim();
      if (target.startsWith('http') ||
          target.startsWith('#') ||
          target.startsWith('mailto:')) {
        continue;
      }
      final path = target.split('#').first;
      final resolved = File('$_docsDir/$path');
      if (!resolved.existsSync()) {
        fail(rel, 'links to $path, which does not exist');
      }
    }

    // 4. Every repository path in backticks exists.
    for (final match in RegExp(r'`([^`\n]+)`').allMatches(text)) {
      final candidate = _repoPath(match.group(1)!);
      if (candidate == null) continue;
      if (_allowedMissing.contains(candidate)) continue;
      final file = File(candidate);
      final dir = Directory(candidate);
      if (!file.existsSync() && !dir.existsSync()) {
        fail(rel, 'mentions `$candidate`, which does not exist');
      }
    }
  }

  if (problems > 0) {
    stderr.writeln('\n$problems documentation problem(s) in ${docs.length} '
        'file(s).');
    exit(1);
  }
  stdout.writeln(
      '${docs.length} documents are linked, structured and refer to real files.');
}

/// Returns the candidate path when [span] looks like a repository path, else
/// null. Deliberately conservative: a false positive here would fail CI on a
/// line of prose.
String? _repoPath(String span) {
  final value = span.trim().split(RegExp(r'[ ,#)]')).first;
  if (value.isEmpty) return null;
  if (value.startsWith('http') || value.startsWith('flutter ') ||
      value.startsWith('dart ')) {
    return null;
  }
  const prefixes = ['lib/', 'test/', 'supabase/', 'tool/', 'assets/', 'docs/'];
  if (!prefixes.any(value.startsWith)) return null;
  // A glob or a placeholder is a description, not a claim.
  if (value.contains('*') || value.contains('…') || value.endsWith('/')) {
    return null;
  }
  // Only paths with an extension are files we can check for.
  final last = value.split('/').last;
  if (!last.contains('.')) return null;
  return value;
}

String _baseName(String path) => path.split(Platform.pathSeparator).last;
