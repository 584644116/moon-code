/// Settings → General → Chat: how the model's thinking comes back, and so
/// whether the chat shows it (`chat.thinkingDisplay`).
///
/// Claude Code's `--thinking-display`: `summarized` (a short account of
/// the thinking) or `omitted` (none). The models think either way — what
/// their effort is set to decides that — this only decides what of it
/// reaches the chat.
enum ThinkingDisplay {
  summarized,
  omitted;

  static const settingKey = 'chat.thinkingDisplay';
  static const fallback = ThinkingDisplay.summarized;

  static ThinkingDisplay parse(Object? setting) => switch (setting) {
    'omitted' => ThinkingDisplay.omitted,
    _ => fallback,
  };

  /// Read as each agent starts, after the user's settings.json changes;
  /// none where there are no settings (tests), the fallback then.
  static ThinkingDisplay Function()? current;

  static ThinkingDisplay now() => current?.call() ?? fallback;

  /// Whether the chat shows it.
  bool get shown => this == ThinkingDisplay.summarized;
}
