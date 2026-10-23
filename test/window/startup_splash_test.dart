import 'package:baocode/window/startup_splash.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => StartupSplash.played = false);

  Future<void> start(WidgetTester tester, {bool motion = true}) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: !motion);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
      const MaterialApp(home: StartupSplash(child: Text('workbench'))),
    );
  }

  /// The mark on its tile: the tile is the only box that scales.
  final mark = find.descendant(
    of: find.byType(StartupSplash),
    matching: find.byType(ScaleTransition),
  );

  testWidgets('the mark is over the app until it goes', (tester) async {
    await start(tester);
    // The app is behind it from the first frame — nothing is waited for —
    // and the mark is over it, unscaled and unseen at the start.
    expect(find.text('workbench'), findsOneWidget);
    expect(mark, findsOneWidget);
    expect(tester.widget<ScaleTransition>(mark).scale.value, lessThan(1));

    // The pop runs its length, then the app comes through in 160ms.
    await tester.pump(const Duration(milliseconds: 720));
    expect(mark, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();
    expect(mark, findsNothing);
    expect(find.text('workbench'), findsOneWidget);
  });

  testWidgets('the app at once with motion turned down', (tester) async {
    await start(tester, motion: false);
    await tester.pump();
    expect(mark, findsNothing);
    expect(find.text('workbench'), findsOneWidget);
  });

  testWidgets('a window opened later shows none of it', (tester) async {
    StartupSplash.played = true;
    await start(tester);
    expect(mark, findsNothing);
    expect(find.text('workbench'), findsOneWidget);
  });
}
