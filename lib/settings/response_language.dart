/// Settings → Region & Language: the language the agent answers in
/// (`chat.responseLanguage`), as Claude Code's `language` setting
/// ("english", "japanese"...). None leaves the choice to the agent, which
/// answers as the conversation does.
///
/// Named in English as Claude Code names them: the setting is read by the
/// model, not shown to the user under these names (the page shows each in
/// its own language, see [nativeName]).
enum ResponseLanguage {
  english('english', 'English'),
  chinese('chinese', '简体中文'),
  japanese('japanese', '日本語'),
  korean('korean', '한국어'),
  spanish('spanish', 'Español'),
  french('french', 'Français'),
  german('german', 'Deutsch'),
  portuguese('portuguese', 'Português'),
  russian('russian', 'Русский'),
  arabic('arabic', 'العربية');

  const ResponseLanguage(this.cliName, this.nativeName);

  /// The setting's value, as Claude Code reads it.
  final String cliName;

  /// How the language names itself in the list.
  final String nativeName;

  static const settingKey = 'chat.responseLanguage';

  static ResponseLanguage? parse(Object? setting) => switch (setting) {
    final String name when name.trim().isNotEmpty => [
      for (final language in values)
        if (language.cliName == name.trim().toLowerCase()) language,
    ].firstOrNull,
    _ => null,
  };

  /// Read as each agent starts, after the user's settings.json changes;
  /// none where there are no settings (tests), or when it is not set.
  static ResponseLanguage? Function()? current;

  static ResponseLanguage? now() => current?.call();
}
