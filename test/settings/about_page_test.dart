import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/platform/app_identity.dart';
import 'package:baocode/settings/pages/about_page.dart';
import 'package:baocode/update/version.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> show(WidgetTester tester, Locale locale) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: AboutSettingsPage()),
      ),
    );
    await tester.pump();
  }

  testWidgets('says what this app is, and which build', (tester) async {
    await show(tester, const Locale('zh'));
    expect(find.text('关于'), findsOneWidget);
    expect(find.text(AppIdentity.name), findsOneWidget);
    expect(
      find.text(
        '版本 ${currentAppVersion.marketing}（${currentAppVersion.build}）',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('links nowhere: the site and repository were not this app\'s', (
    tester,
  ) async {
    await show(tester, const Locale('zh'));
    // What an older build offered: BaoCode's site, its repository, its
    // changelog, its issue tracker. None of it is this app's to send
    // anyone to.
    expect(find.text('去 GitHub 点 Star'), findsNothing);
    expect(find.text('更新日志'), findsNothing);
    expect(find.text('反馈问题'), findsNothing);
    expect(find.text('baocode.dev'), findsNothing);
    expect(find.text('github.com/baocode-dev/baocode'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
