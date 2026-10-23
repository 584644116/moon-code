import 'package:baocode/chat/panels/interaction_panel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// An approval card says what the call is about before the user says yes.
void main() {
  testWidgets('a destructive, irreversible call says so', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: InteractionPanel(
            request: ApprovalRequest(
              id: 'a1',
              title: 'Run this command?',
              toolName: 'Bash',
              preview: const TextPreview('rm -rf build'),
              risk: ApprovalRisk.destructive,
              reversible: false,
            ),
            onAnswer: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Destructive · Not reversible'), findsOneWidget);
  });

  testWidgets('the chip says what, and the reason says what in it said so', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: InteractionPanel(
            request: ApprovalRequest(
              id: 'a3',
              title: 'Run this command?',
              toolName: 'Bash',
              preview: const TextPreview('rm -rf build'),
              risk: ApprovalRisk.destructive,
              reversible: false,
              why:
                  'Removes files or folders in a way that skips the recycle '
                  'bin.',
            ),
            onAnswer: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Destructive · Not reversible'), findsOneWidget);
    expect(find.textContaining('skips the recycle bin'), findsOneWidget);
  });

  testWidgets('a read only call says so', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: InteractionPanel(
            request: ApprovalRequest(
              id: 'a2',
              title: 'Read this file?',
              toolName: 'Read',
              preview: const TextPreview('a.txt'),
              risk: ApprovalRisk.read,
              reversible: true,
            ),
            onAnswer: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Read only · Reversible'), findsOneWidget);
  });
}
