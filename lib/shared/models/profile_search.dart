/// How a user-search query should be read, and how an empty result should be
/// explained.
///
/// Pure on purpose: the interesting decisions here — when a query is an email
/// address rather than a handle, and what to tell someone whose search found
/// nothing — are worth testing without a network or a database.
///
/// The server does the matching (see `public.search_users` in
/// `supabase/migrations/0005_email_discovery.sql`); this only classifies input.
class SearchQuery {
  const SearchQuery(this.text);

  /// Trimmed input as typed. Not lowercased: display names and usernames are
  /// matched case-insensitively by the server, and the UI echoes this back.
  final String text;

  static const int minLength = 2;

  SearchQuery normalised() => SearchQuery(text.trim());

  bool get isEmpty => text.trim().isEmpty;

  /// True when [minLength] characters have been typed and a search is worth
  /// sending. Avoids a request per keystroke on the first character, which
  /// also keeps a single-letter prefix from probing for matches.
  bool get isSearchable => text.trim().length >= minLength;

  /// True when the input looks like an email address.
  ///
  /// This only decides wording and, in the UI, which field to hint at. It is
  /// not a validator — the server compares addresses exactly, so a malformed
  /// address simply matches nothing.
  bool get looksLikeEmail {
    final value = text.trim();
    final at = value.indexOf('@');
    if (at <= 0 || at != value.lastIndexOf('@')) return false;
    if (at == value.length - 1) return false;
    final domain = value.substring(at + 1);
    return domain.contains('.') &&
        !domain.startsWith('.') &&
        !domain.endsWith('.');
  }

  /// Wording for the "no results" state, naming what was actually searched for.
  String get emptyResultMessage => looksLikeEmail
      ? 'No MailChat account uses that email address. Ask them to check it, or '
          'try their username instead.'
      : 'No one matches "$text". Try their username, display name, or their '
          'full email address.';

  /// Wording for the idle state above the results.
  String get hintMessage => looksLikeEmail
      ? 'Searching by email address. Only people who allow email discovery can '
          'be found this way.'
      : 'Search by username, display name, or full email address.';
}
