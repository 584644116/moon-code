import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/widgets/tool_call_row.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpRow(
    WidgetTester tester, {
    required ToolStatus status,
    Duration? duration,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      localizationsDelegates: const [AppLocalizations.delegate],
      home: Scaffold(
        body: ToolCallRow(
          kind: ToolKind.command,
          target: 'flutter test',
          status: status,
          duration: duration,
        ),
      ),
    ),
  );

  testWidgets('a tool that took a second says how long', (tester) async {
    await pumpRow(
      tester,
      status: ToolStatus.succeeded,
      duration: const Duration(milliseconds: 1240),
    );
    expect(find.text('1.2s'), findsOneWidget);
  });

  Finder took() => find.byWidgetPredicate(
    (widget) =>
        widget is Text &&
        RegExp(r'^\d+(?:\.\d)?s$').hasMatch(widget.data ?? ''),
  );

  testWidgets('one under a second says nothing', (tester) async {
    await pumpRow(
      tester,
      status: ToolStatus.succeeded,
      duration: const Duration(milliseconds: 300),
    );
    expect(took(), findsNothing);
  });

  testWidgets('one still running says nothing', (tester) async {
    await pumpRow(tester, status: ToolStatus.running);
    expect(took(), findsNothing);
  });

  testWidgets('a long one is said in whole seconds', (tester) async {
    await pumpRow(
      tester,
      status: ToolStatus.succeeded,
      duration: const Duration(seconds: 42),
    );
    expect(find.text('42s'), findsOneWidget);
  });
}
