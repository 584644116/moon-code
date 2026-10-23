import 'dart:async';

import 'package:flutter/material.dart';

import '../../ide/ide_menu.dart';
import '../../l10n/l10n.dart';
import '../app_locale.dart';
import '../response_language.dart';
import '../user_settings.dart';
import 'settings_dropdown.dart';
import 'settings_widgets.dart';

/// Settings → Region & Language: the display language, VS Code's
/// Configure Display Language, and the language the agent answers in.
///
/// Each language is named in its own language; a display choice applies at
/// once, a reply language from the next chat (the agent reads it when it
/// starts).
class LanguageSettingsPage extends StatelessWidget {
  const LanguageSettingsPage({super.key, required this.locale, this.settings});

  final AppLocale locale;

  /// settings.json; none under test, where choices are not kept.
  final UserSettings? settings;

  /// Each language in its own language.
  static const nativeNames = {
    AppLocale.english: 'English',
    AppLocale.simplifiedChinese: '简体中文',
  };

  void _write(Object? value) {
    final settings = this.settings;
    if (settings == null) return;
    final key = ResponseLanguage.settingKey;
    unawaited(
      settings.update(key, value).catchError((Object error) {
        debugPrint('$key not kept: $error');
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: settings ?? Listenable.merge(const []),
      builder: (context, _) {
        final setting = locale.setting;
        final system = AppLocale.systemLocale(
          View.maybeOf(context)?.platformDispatcher.locales,
        );
        final systemSetting = AppLocale.normalize(system.toLanguageTag());
        final followSystem = l10n.languageSettingsFollowSystemCurrent(
          nativeNames[systemSetting] ?? nativeNames.values.first,
        );
        final current = nativeNames[setting] ?? followSystem;
        final reply = ResponseLanguage.parse(
          settings?[ResponseLanguage.settingKey],
        );
        final replyShown =
            reply?.nativeName ?? l10n.languageSettingsResponseLanguageFollow;
        return SettingsPage(
          title: l10n.languageSettingsTitle,
          children: [
            SettingsCard(
              children: [
                SettingsRow(
                  label: l10n.languageSettingsDisplayLanguage,
                  description: l10n.languageSettingsDescription,
                  trailing: SettingsDropdown(
                    current: current,
                    semanticLabel: l10n.languageSettingsDisplayLanguageLabel(
                      current,
                    ),
                    entries: () => [
                      IdeMenuAction(
                        followSystem,
                        checked: setting == null,
                        onSelected: () => locale.select(null),
                      ),
                      const IdeMenuSeparator(),
                      for (final option in AppLocale.settings)
                        IdeMenuAction(
                          nativeNames[option]!,
                          checked: setting == option,
                          onSelected: () => locale.select(option),
                        ),
                    ],
                  ),
                ),
                SettingsRow(
                  label: l10n.languageSettingsResponseLanguage,
                  description: l10n.languageSettingsResponseLanguageDescription,
                  trailing: SettingsDropdown(
                    current: replyShown,
                    semanticLabel:
                        '${l10n.languageSettingsResponseLanguage}: $replyShown',
                    entries: () => [
                      IdeMenuAction(
                        l10n.languageSettingsResponseLanguageFollow,
                        checked: reply == null,
                        onSelected: () => _write(null),
                      ),
                      const IdeMenuSeparator(),
                      for (final language in ResponseLanguage.values)
                        IdeMenuAction(
                          language.nativeName,
                          checked: language == reply,
                          onSelected: () => _write(language.cliName),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
