/// Parsing for the `.env`-syntax file that supplies configuration.
///
/// Kept free of Flutter imports so command-line tooling
/// (`tool/check_config.dart`) can share exactly one implementation with the app.
/// Two parsers would eventually disagree, and the disagreement would show up as
/// a build that passes validation and an app that cannot read its own config.
library;

/// Parses `.env` syntax into a map of upper-cased keys.
///
/// Supported: `KEY=value`, `export KEY=value`, `#` comments, blank lines, CRLF
/// endings, and values wrapped in matching single or double quotes (with
/// anything after the closing quote, such as an inline comment, discarded).
/// Lines without `=` are ignored rather than treated as errors: a stray line
/// should not take down startup.
class EnvFile {
  EnvFile._();

  /// Parses [raw] into a case-insensitive (upper-cased) key/value map.
  static Map<String, String> parse(String raw) {
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
        value = closing == -1 ? value.substring(1) : value.substring(1, closing);
      }
      result[key] = value.trim();
    }
    return result;
  }

  /// True when [key]'s value is missing, blank, or still an example.
  ///
  /// [placeholders] are the substrings that mark a template value; matching is
  /// case-insensitive so `YOUR-ANON-KEY` is caught the same as `your-anon-key`.
  static bool isUnset(
    Map<String, String> values,
    String key, {
    List<String> placeholders = const [],
  }) {
    final value = values[key]?.trim() ?? '';
    if (value.isEmpty) return true;
    final lowered = value.toLowerCase();
    return placeholders.any((p) => lowered.contains(p.toLowerCase()));
  }
}
