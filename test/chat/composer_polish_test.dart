import 'dart:async';

import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer.dart';
import 'package:baocode/chat/composer/composer_embeds.dart';
import 'package:baocode/chat/composer/composer_polish.dart';
import 'package:baocode/ide/ide_hover.dart';
import 'package:baocode/kernel/claude_code/claude_haiku.dart'
    show ClaudeHaikuTools;
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final file = ComposerTokenEmbed.file('/w/lib/main.dart');

  Delta content() => Delta()
    ..insert('fix teh bug in ')
    ..insert({file.type: file.data})
    ..insert(
      ', see https://x.dev/a?b=1 and `fooBar()`:\n```\nlet x = 1\n```\n'
      'the log is in /tmp/run/out.log',
    );

  group('composerPolishText', () {
    test('tags, code, links and paths are markers; the words stay', () {
      final asked = composerPolishText(content());
      expect(
        asked.text,
        'fix teh bug in ⟦1⟧, see ⟦2⟧ and ⟦3⟧:\n⟦4⟧\nthe log is in ⟦5⟧',
      );
      expect(asked.kept[0], isA<Operation>());
      expect(asked.kept.sublist(1), [
        'https://x.dev/a?b=1',
        '`fooBar()`',
        '```\nlet x = 1\n```',
        '/tmp/run/out.log',
      ]);
      expect(asked.hasWords, isTrue);
    });

    test('a marker typed by the user is kept as one too', () {
      final asked = composerPolishText(Delta()..insert('look at ⟦1⟧ here'));
      expect(asked.text, 'look at ⟦1⟧ here');
      expect(asked.kept, ['⟦1⟧']);
    });

    test('tags alone: no words to polish', () {
      final asked = composerPolishText(
        Delta()
          ..insert({file.type: file.data})
          ..insert('  '),
      );
      expect(asked.hasWords, isFalse);
    });
  });

  group('composerPolishContent', () {
    test('the markers put back as they were, wherever the reply moved '
        'them', () {
      final asked = composerPolishText(content());
      final back = composerPolishContent(
        'Fix the bug in ⟦1⟧ (see ⟦2⟧ and ⟦3⟧):\n⟦4⟧\nThe log is in ⟦5⟧.',
        asked,
      )!;
      final ops = back.toList();
      expect(ops[0].data, 'Fix the bug in ');
      expect(ops[1].data, {file.type: file.data});
      expect(
        ops.skip(2).map((op) => op.data).join(),
        ' (see https://x.dev/a?b=1 and `fooBar()`):\n```\nlet x = 1\n```\n'
        'The log is in /tmp/run/out.log.',
      );
    });

    test('a marker lost, doubled or made up: not taken', () {
      final asked = composerPolishText(content());
      expect(
        composerPolishContent('Fix the bug ⟦1⟧ ⟦2⟧ ⟦3⟧ ⟦4⟧', asked),
        isNull,
      );
      expect(composerPolishContent('⟦1⟧ ⟦1⟧ ⟦2⟧ ⟦3⟧ ⟦4⟧ ⟦5⟧', asked), isNull);
      expect(composerPolishContent('⟦1⟧ ⟦2⟧ ⟦3⟧ ⟦4⟧ ⟦5⟧ ⟦6⟧', asked), isNull);
    });
  });

  group('polishComposerText', () {
    tearDown(() => composerPolishAsker = null);

    test('a reply far longer (written on), or empty, is not taken', () async {
      final asked = composerPolishText(Delta()..insert('fix it'));
      composerPolishAsker = (
        system,
        prompt, {
        model,
        exact = false,
        location,
        tools,
      }) async => 'x' * 400;
      await expectLater(
        polishComposerText(asked),
        throwsA(isA<ComposerPolishException>()),
      );
      composerPolishAsker = (
        system,
        prompt, {
        model,
        exact = false,
        location,
        tools,
      }) async => '  ';
      await expectLater(
        polishComposerText(asked),
        throwsA(isA<ComposerPolishException>()),
      );
    });

    test('what went wrong asking says why', () async {
      composerPolishAsker = (
        system,
        prompt, {
        model,
        exact = false,
        location,
        tools,
      }) async => throw Exception('Not signed in');
      await expectLater(
        polishComposerText(composerPolishText(Delta()..insert('fix it'))),
        throwsA(
          isA<ComposerPolishException>().having(
            (error) => error.message,
            'message',
            contains('Not signed in'),
          ),
        ),
      );
    });

    group('the Haiku tier', () {
      final upstream = ModelProvider(
        id: 'up',
        name: 'Up',
        models: const [
          ProviderModel(id: 'big'),
          ProviderModel(id: 'small'),
        ],
        roles: const ProviderRoles(main: 'big', haiku: 'small'),
      );
      late ModelProviders previous;

      setUp(() {
        previous = ModelProviders.current;
        ModelProviders.current = ModelProviders.memory(
          providers: [upstream],
        );
      });

      tearDown(() {
        ModelProviders.current = previous;
        forgetFailedPolishTiers();
      });

      test('gives no answer: the model itself asked, and asked first from '
          'then on', () async {
        final asked = <({bool exact})>[];
        composerPolishAsker = (
          system,
          prompt, {
          model,
          exact = false,
          location,
          tools,
        }) async {
          asked.add((exact: exact));
          if (exact) return 'Fix it.';
          throw Exception("There's an issue with the selected model");
        };
        final content = await polishComposerText(
          composerPolishText(Delta()..insert('fix it')),
          model: '@up/big',
        );
        expect(content.toList().first.data, 'Fix it.');
        expect(asked.map((ask) => ask.exact), [false, true]);

        // Once is enough to know the tier is not served.
        await polishComposerText(
          composerPolishText(Delta()..insert('fix it')),
          model: '@up/big',
        );
        expect(asked.map((ask) => ask.exact), [false, true, true]);
      });

      test('a model picked for the app\'s own jobs is asked as it is, and '
          'not asked again', () async {
        await ModelProviders.current.setAuxiliaryModel('@up/small');
        final asked = <({bool exact})>[];
        composerPolishAsker = (
          system,
          prompt, {
          model,
          exact = false,
          location,
          tools,
        }) async {
          asked.add((exact: exact));
          throw Exception('Out of quota');
        };
        await expectLater(
          polishComposerText(
            composerPolishText(Delta()..insert('fix it')),
            model: '@up/big',
          ),
          throwsA(isA<ComposerPolishException>()),
        );
        expect(asked.map((ask) => ask.exact), [true]);
      });
    });
  });

  group('the composer', () {
    tearDown(() {
      composerPolishAsker = null;
      ComposerPolishSetting.current = () => true;
      ComposerEnhanceSetting.current = () => true;
    });

    Future<QuillController> pumpComposer(WidgetTester tester) async {
      final session = ChatSession(historyCount: 0);
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            FlutterQuillLocalizations.delegate,
          ],
          home: Scaffold(
            body: ChatComposer(session: session, draft: session.draft),
          ),
        ),
      );
      await tester.pump();
      return tester.widget<QuillEditor>(find.byType(QuillEditor)).controller;
    }

    Finder polishButton() => find.byWidgetPredicate(
      (widget) =>
          widget is IdeHover &&
          (widget.message == englishLocalizations.composerPolishHint ||
              widget.message == englishLocalizations.composerPolishing),
    );

    testWidgets('Polish puts the reply in, its tag as it was; Undo takes '
        'it back', (tester) async {
      final reply = Completer<String>();
      String? prompt;
      composerPolishAsker = (system, asked, {model, exact = false, location, tools}) {
        prompt = asked;
        return reply.future;
      };
      final controller = await pumpComposer(tester);
      controller.compose(
        Delta()
          ..insert('fix teh bug in ')
          ..insert({file.type: file.data})
          ..insert(' plz'),
        const TextSelection.collapsed(offset: 0),
        ChangeSource.local,
      );
      await tester.pump();
      final before = controller.document.toDelta();

      await tester.tap(polishButton());
      await tester.pump();
      expect(prompt, contains('fix teh bug in ⟦1⟧ plz'));
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is IdeHover &&
              widget.message == englishLocalizations.composerPolishing,
        ),
        findsOneWidget,
      );
      reply.complete('Please fix the bug in ⟦1⟧.');
      await tester.pumpAndSettle();
      final ops = controller.document.toDelta().toList();
      expect(ops[0].data, 'Please fix the bug in ');
      expect(ops[1].data, {file.type: file.data});
      expect(ops[2].data, '.\n');

      controller.undo();
      await tester.pump();
      expect(controller.document.toDelta(), before);
    });

    testWidgets('typed on meanwhile, the reply is not taken', (tester) async {
      final reply = Completer<String>();
      composerPolishAsker = (system, asked, {model, exact = false, location, tools}) =>
          reply.future;
      final controller = await pumpComposer(tester);
      controller.replaceText(0, 0, 'fix it', null);
      await tester.pump();
      await tester.tap(polishButton());
      await tester.pump();
      controller.replaceText(6, 0, ' now', null);
      reply.complete('Fix it.');
      await tester.pumpAndSettle();
      expect(controller.document.toPlainText(), 'fix it now\n');
    });

    testWidgets('turned off in the settings, no button', (tester) async {
      ComposerPolishSetting.current = () => false;
      await pumpComposer(tester);
      expect(polishButton(), findsNothing);
    });

    Finder enhanceButton() => find.byWidgetPredicate(
      (widget) =>
          widget is IdeHover &&
          (widget.message == englishLocalizations.composerEnhanceHint ||
              widget.message == englishLocalizations.composerEnhancing),
    );

    testWidgets('Enhance puts the reply in, its tag as it was', (tester) async {
      final reply = Completer<String>();
      String? system;
      ClaudeHaikuTools? seen;
      composerPolishAsker = (
        s,
        asked, {
        model,
        exact = false,
        location,
        tools,
      }) {
        system = s;
        seen = tools;
        return reply.future;
      };
      final controller = await pumpComposer(tester);
      controller.compose(
        Delta()
          ..insert('fix teh bug in ')
          ..insert({file.type: file.data}),
        const TextSelection.collapsed(offset: 0),
        ChangeSource.local,
      );
      await tester.pump();
      await tester.tap(enhanceButton());
      await tester.pump();
      // No project: nothing to read, and nothing to promise of it.
      expect(seen, isNull);
      expect(system, contains('You cannot look at the project here'));
      reply.complete(
        'Fix the bug in ⟦1⟧: correct the typo, then run the tests.',
      );
      await tester.pumpAndSettle();
      final ops = controller.document.toDelta().toList();
      expect(ops[0].data, 'Fix the bug in ');
      expect(ops[1].data, {file.type: file.data});
      expect(ops[2].data, ': correct the typo, then run the tests.\n');
    });

    testWidgets('Enhance turned off in the settings, no button', (tester) async {
      ComposerEnhanceSetting.current = () => false;
      await pumpComposer(tester);
      expect(enhanceButton(), findsNothing);
      expect(polishButton(), findsOneWidget);
    });
  });

  group('enhanceComposerText', () {
    tearDown(() => composerPolishAsker = null);

    test('the project is read, and named in the prompt', () async {
      ClaudeHaikuTools? seen;
      String? prompt;
      composerPolishAsker = (
        system,
        asked, {
        model,
        exact = false,
        location,
        tools,
      }) {
        prompt = asked;
        seen = tools;
        return Future.value('Fix it.');
      };
      await enhanceComposerText(
        composerPolishText(Delta()..insert('fix it')),
        location: r'C:\w\app',
      );
      expect(seen?.readable, [r'C:\w\app']);
      expect(seen?.directory, r'C:\w\app');
      expect(prompt, contains('<project>\nC:\\w\\app\n</project>'));
      expect(prompt, contains('<message>\nfix it\n</message>'));
    });

    test('it went looking and came back without the message: asked again, '
        'the message alone', () async {
      final seen = <ClaudeHaikuTools?>[];
      composerPolishAsker = (
        system,
        asked, {
        model,
        exact = false,
        location,
        tools,
      }) async {
        seen.add(tools);
        if (tools != null) throw Exception('Reached maximum number of turns');
        return 'Fix it.';
      };
      final content = await enhanceComposerText(
        composerPolishText(Delta()..insert('fix it')),
        location: r'C:\w\app',
      );
      expect(content.toList().first.data, 'Fix it.');
      expect(seen, hasLength(2));
      expect(seen.first?.directory, r'C:\w\app');
      expect(seen.last, isNull);
    });

    test('a project on a host: the message alone, no tools', () async {
      ClaudeHaikuTools? seen;
      String? prompt;
      composerPolishAsker = (
        system,
        asked, {
        model,
        exact = false,
        location,
        tools,
      }) {
        prompt = asked;
        seen = tools;
        return Future.value('Fix it.');
      };
      await enhanceComposerText(
        composerPolishText(Delta()..insert('fix it')),
        location: 'ssh://box/home/me/app',
      );
      expect(seen, isNull);
      expect(prompt, contains('<project>\n/home/me/app\n</project>'));
    });

    test('what it found and how to check it: several times the words taken',
        () async {
      composerPolishAsker = (system, asked, {model, exact = false, location, tools}) async =>
          'Fix the typo in lib/main.dart, where the button is built, then run '
          'flutter test test/chat/composer_polish_test.dart and check that the '
          'reply is still taken as one change.';
      final content = await enhanceComposerText(
        composerPolishText(Delta()..insert('fix it')),
      );
      expect(
        content.toList().map((op) => op.data).join(),
        contains('lib/main.dart'),
      );
    });

    test('a whole file written out: not taken', () async {
      composerPolishAsker = (system, asked, {model, exact = false, location, tools}) async =>
          'x' * 3000;
      await expectLater(
        enhanceComposerText(composerPolishText(Delta()..insert('fix it'))),
        throwsA(isA<ComposerPolishException>()),
      );
    });
  });
}
