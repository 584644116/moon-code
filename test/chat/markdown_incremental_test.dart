import 'package:baocode/chat/widgets/code_citation.dart';
import 'package:baocode/chat/widgets/markdown_view.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String chunk(int i) =>
    'Paragraph $i: the quick brown fox jumps over the lazy dog, and '
    '`inlineCode($i)` is here, with **strong** and _em_ text.\n\n';

Future<void> pumpText(WidgetTester tester, String text) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(body: SingleChildScrollView(child: MarkdownView(text))),
  ),
);

String plainText(WidgetTester tester) => [
  for (final text in tester.widgetList<RichText>(find.byType(RichText)))
    text.text.toPlainText(),
].join('\n');

void main() {
  testWidgets('a reply streaming in reads as it does whole', (tester) async {
    final text = [for (var i = 0; i < 40; i++) chunk(i)].join();
    await pumpText(tester, text);
    final whole = plainText(tester);

    // A fresh view, given the same text a few characters at a time.
    await tester.pumpWidget(const SizedBox());
    await pumpText(tester, text.substring(0, 10));
    for (var end = 50; end <= text.length; end += 40) {
      await pumpText(tester, text.substring(0, end));
    }
    await pumpText(tester, text);
    expect(plainText(tester), whole);
  });

  testWidgets('a code block still being written is not cut in two', (
    tester,
  ) async {
    const start = 'Before it.\n\n```dart\nvoid main() {\n';
    const rest = '\n  run();\n}\n```\n\nAfter it.\n';
    final text = start + rest;
    await pumpText(tester, text.substring(0, start.length));
    for (var end = start.length + 1; end <= text.length; end += 5) {
      await pumpText(tester, text.substring(0, end));
    }
    // The blank line inside the fence did not end it.
    expect(find.byType(MarkdownCodeBlock), findsOneWidget);
    expect(plainText(tester), contains('run();'));
  });

  testWidgets('a tag section still being written is not cut in two', (
    tester,
  ) async {
    const text =
        'Intro.\n\n<note>\n\nA reason.\n\nAnother.\n</note>\n\nDone.\n';
    await pumpText(tester, text.substring(0, 20));
    for (var end = 20; end <= text.length; end += 4) {
      await pumpText(tester, text.substring(0, end));
    }
    await pumpText(tester, text);
    expect(plainText(tester), contains('Note'));
    expect(plainText(tester), contains('A reason.'));
    expect(plainText(tester), contains('Another.'));
  });

  testWidgets('a reference link defined at the end still links', (
    tester,
  ) async {
    const text =
        'See [one][ref] and more.\n\nAnother paragraph.\n\n'
        '[ref]: https://example.com\n';
    await pumpText(tester, text.substring(0, 10));
    for (var end = 10; end <= text.length; end += 8) {
      await pumpText(tester, text.substring(0, end));
    }
    await pumpText(tester, text);
    // Read as a link, not left as its written form.
    expect(plainText(tester), isNot(contains('][ref]')));
  });

  testWidgets('an edit is not read as the old text', (tester) async {
    final first = [for (var i = 0; i < 20; i++) chunk(i)].join();
    await pumpText(tester, first);
    // Wholly different, sharing no prefix.
    const second = 'Something else.\n\nAnd more.\n';
    await pumpText(tester, second);
    expect(plainText(tester), contains('Something else.'));
    expect(plainText(tester), isNot(contains('Paragraph 0')));
  });
}
