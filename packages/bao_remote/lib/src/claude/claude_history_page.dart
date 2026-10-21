/// Some of a kept session's conversation, along the branch it ended on:
/// its last turns, or those before others already read.
class ClaudeHistoryPage {
  const ClaudeHistoryPage(this.entries, {this.earlier});

  /// The whole of it: nothing before.
  const ClaudeHistoryPage.whole(this.entries) : earlier = null;

  /// What [json] says of a page. Read off the wire — from a host that may
  /// run another version of this code — so a line not shaped as one is
  /// left out and the rest of the page kept.
  factory ClaudeHistoryPage.fromJson(Map<String, Object?> json) =>
      ClaudeHistoryPage([
        for (final entry in switch (json['entries']) {
          final List<Object?> entries => entries,
          _ => const <Object?>[],
        })
          if (entry is Map) entry.cast<String, Object?>(),
      ], earlier: switch (json['earlier']) {
        final String earlier => earlier,
        _ => null,
      });

  /// Its lines, oldest first.
  final List<Map<String, Object?>> entries;

  /// What to read the turns before it by (`before`); null when it begins
  /// the conversation.
  final String? earlier;

  Map<String, Object?> toJson() => {'entries': entries, 'earlier': earlier};
}
