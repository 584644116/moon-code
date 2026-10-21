/// Which conversations hold which words, so that searching starts from
/// those that hold all of a query's rather than from every conversation.
/// Words here are ASCII runs (lowercased), and Chinese ones as pairs of
/// characters; a query with any other shape is left to a scan.
///
/// Not a source of truth: whatever it says is checked against the
/// conversation's text before a hit is reported.
class SessionIndex {
  final Map<String, Set<String>> _postings = {};
  final Map<String, Set<String>> _ofSession = {};

  /// Replaces what [id]'s conversation holds with [text]'s words.
  void set(String id, String text) {
    remove(id);
    final words = tokensOf(text);
    _ofSession[id] = words;
    for (final word in words) {
      _postings.putIfAbsent(word, () => <String>{}).add(id);
    }
  }

  /// Forgets [id].
  void remove(String id) {
    for (final word in _ofSession.remove(id) ?? const <String>{}) {
      final ids = _postings[word];
      if (ids == null) continue;
      ids.remove(id);
      if (ids.isEmpty) _postings.remove(word);
    }
  }

  /// The conversations that may hold [query]: those holding all of its
  /// words, or null when a scan is needed (a word none holds, part of a
  /// word, or the index has nothing to go on).
  Set<String>? candidates(String query) {
    final words = tokensOf(query);
    if (words.isEmpty) return null;
    Set<String>? found;
    for (final word in words) {
      final ids = _postings[word];
      // A part of a word (`ogin`), or a word no conversation has: only
      // scanning can tell.
      if (ids == null) return null;
      found = found == null ? {...ids} : found.intersection(ids);
      if (found.isEmpty) return found;
    }
    return found;
  }

  /// The words [text] is indexed by.
  static Set<String> tokensOf(String text) {
    final lower = text.toLowerCase();
    final words = <String>{};
    for (final match in _ascii.allMatches(lower)) {
      words.add(match[0]!);
    }
    for (final match in _han.allMatches(lower)) {
      final run = match[0]!;
      if (run.length == 1) {
        words.add(run);
        continue;
      }
      for (var i = 0; i + 1 < run.length; i++) {
        words.add(run.substring(i, i + 2));
      }
    }
    return words;
  }

  static final _ascii = RegExp(r'[a-z0-9_]+');
  static final _han = RegExp(r'[㐀-鿿]+');
}
