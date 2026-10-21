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
