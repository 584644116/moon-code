
import 'package:flutter/widgets.dart';

import '../../l10n/l10n.dart';
import '../../platform/app_identity.dart';
import '../../theme/app_theme.dart';
import '../../update/version.dart';
import '../../workspace/window_header/about_dialog.dart' show aboutIconAsset;
import 'settings_widgets.dart';

/// Settings → About: what MoonCode is, which build this is, and where it
/// is made in the open: its repository (a star there helps others find
/// it), its site, its changelog, and where to tell of a problem.
class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsPage(
      title: l10n.settingsSectionAbout,
      lead: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Image.asset(
              aboutIconAsset,
              width: 44,
              height: 44,
              filterQuality: FilterQuality.medium,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        AppIdentity.name,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        l10n.aboutVersion(
                          currentAppVersion.marketing,
                          currentAppVersion.build,
                        ),
                        style: TextStyle(
                          color: AppColors.textFaint,
                          fontSize: 12,
                          fontFamily: AppFonts.mono,
                          fontFamilyFallback: AppFonts.monoFallbacks,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(l10n.aboutTagline, style: SettingsText.lead),
                  const SizedBox(height: 6),
                  Text(
                    l10n.starPromptDetail,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      // Nothing here links anywhere: the site, the repository, the
      // changelog and the issue tracker were MoonCode's, and this build is
      // not that project's to send anyone to.
      children: const [],
    );
  }
}
