import 'dart:async';

import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/mock_conversation.dart';
import 'package:baocode/chat/composer/composer.dart';
import 'package:baocode/chat/composer/composer_controller.dart';
import 'package:baocode/chat/composer/composer_embeds.dart';
import 'package:baocode/chat/composer/composer_polish.dart';
import 'package:baocode/ide/ide_hover.dart';
import 'package:baocode/ide/ide_notifications.dart';
import 'package:baocode/kernel/claude_code/claude_haiku.dart'
    show ClaudeHaikuTools;
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final file = ComposerTokenEmbed.file('/w/lib/main.dart');

  String content() =>
      'fix teh bug in ${file.atom}'
      ', see https://x.dev/a?b=1 and `fooBar()`:\n```\nlet x = 1\n```\n'
      'the log is in /tmp/run/out.log';

  group('composerPolishText', () {
    test('tags, code, links and paths are markers; the words stay', () {
      final asked = composerPolishText(content());
      expect(
        asked.text,
        'fix teh bug in ⟦1⟧, see ⟦2⟧ and ⟦3⟧:\n⟦4⟧\nthe log is in ⟦5⟧',
      );
      expect(asked.kept[0], file);
      expect(asked.kept.sublist(1), [
        'https://x.dev/a?b=1',
        '`fooBar()`',
        '```\nlet x = 1\n```',
        '/tmp/run/out.log',
      ]);
      expect(asked.hasWords, isTrue);
    });

    test('a marker typed by the user is kept as one too', () {
      final asked = composerPolishText('look at ⟦1⟧ here');
      expect(asked.text, 'look at ⟦1⟧ here');
      expect(asked.kept, ['⟦1⟧']);
    });

    test('tags alone: no words to polish', () {
      final asked = composerPolishText('${file.atom}  ');
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
      expect(
        back,
        'Fix the bug in ${file.atom}'
        ' (see https://x.dev/a?b=1 and `fooBar()`):\n```\nlet x = 1\n```\n'
        'The log is in /tmp/run/out.log.',
      );
    });

    test('a marker lost or made up: not taken', () {
      final asked = composerPolishText(content());
      expect(
        composerPolishContent('Fix the bug ⟦1⟧ ⟦2⟧ ⟦3⟧ ⟦4⟧', asked),
        isNull,
      );
      expect(composerPolishContent('⟦1⟧ ⟦2⟧ ⟦3⟧ ⟦4⟧ ⟦5⟧ ⟦6⟧', asked), isNull);
    });

    test('a marker written again is the embed\'s plain text the second '
        'time, so a picture goes once', () {
      final asked = composerPolishText(content());
      // The file goes in as its atom; said again, as the path it is.
      final back = composerPolishContent(
        'Fix ⟦1⟧, then ⟦1⟧ again, and ⟦2⟧ ⟦3⟧ ⟦4⟧ ⟦5⟧.',
        asked,
      )!;
      expect(back, contains(file.atom));
      expect(back, contains(file.plainText));
      expect(
        file.atom == file.plainText,
        isFalse,
        reason: 'the embed needs an atom unlike its plain text to test this',
      );
    });
  });

  group('polishComposerText', () {
    tearDown(() => composerPolishAsker = null);

    test('the answer thrown away is kept, and why', () async {
      composerPolishAsker = (
        system,
        prompt, {
        model,
        exact = false,
        location,
        tools,
      }) async => '## Fix it\n\nFix the typo.';
      try {
        await polishComposerText(composerPolishText('fix it'));
        fail('no exception');
      } on ComposerPolishRejected catch (rejected) {
        expect(rejected.reason, 'heading');
        // Kept, not lost: it is the person's to read, even though it is
        // not the message (see the composer's Show the answer).
        expect(rejected.raw, '## Fix it\n\nFix the typo.');
      }
    });

    test('what it waits on is told as it goes', () async {
      composerPolishAsker = (
        system,
        prompt, {
        model,
        exact = false,
        location,
        tools,
      }) async => 'Fix it.';
      final stages = <ComposerPolishStage>[];
      await polishComposerText(
        composerPolishText('fix it'),
        onStage: stages.add,
      );
      // Claude Code's own Haiku, asked as it is: no tier of an upstream's
      // to wait on first.
      expect(stages, [ComposerPolishStage.model]);
    });

    test('a reply far longer (written on), or empty, is not taken', () async {
      final asked = composerPolishText('fix it');
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
        polishComposerText(composerPolishText('fix it')),
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
        ModelProviders.current = ModelProviders.memory(providers: [upstream]);
      });

      tearDown(() {
        ModelProviders.current = previous;
        forgetFailedPolishTiers();
      });

      test('gives no answer: the model itself asked, and asked first from '
          'then on', () async {
        final asked = <({bool exact})>[];
        composerPolishAsker =
            (system, prompt, {model, exact = false, location, tools}) async {
              asked.add((exact: exact));
              if (exact) return 'Fix it.';
              throw Exception("There's an issue with the selected model");
            };
        final content = await polishComposerText(
          composerPolishText('fix it'),
          model: '@up/big',
        );
        expect(content, 'Fix it.');
        expect(asked.map((ask) => ask.exact), [false, true]);

        // Once is enough to know the tier is not served.
        await polishComposerText(
          composerPolishText('fix it'),
          model: '@up/big',
        );
        expect(asked.map((ask) => ask.exact), [false, true, true]);
      });

      test('what it waits on is told as it goes, the tier and then the '
          'model itself', () async {
        composerPolishAsker =
            (system, prompt, {model, exact = false, location, tools}) async {
              if (exact) return 'Fix it.';
              throw Exception("There's an issue with the selected model");
            };
        final stages = <ComposerPolishStage>[];
        await polishComposerText(
          composerPolishText('fix it'),
          model: '@up/big',
          onStage: stages.add,
        );
        expect(stages, [
          ComposerPolishStage.tier,
          ComposerPolishStage.fallback,
        ]);
      });

      test('Enhance with the project to read: the project first, and the '
          'tier after it', () async {
        composerPolishAsker =
            (system, prompt, {model, exact = false, location, tools}) async =>
                'Fix the typo.';
        final stages = <ComposerPolishStage>[];
        await enhanceComposerText(
          composerPolishText('fix it'),
          model: '@up/big',
          location: r'C:\w\app',
          onStage: stages.add,
        );
        expect(stages, [ComposerPolishStage.project]);
      });

      test('a model picked for the app\'s own jobs is asked as it is, and '
          'not asked again', () async {
        await ModelProviders.current.setAuxiliaryModel('@up/small');
        final asked = <({bool exact})>[];
        composerPolishAsker =
            (system, prompt, {model, exact = false, location, tools}) async {
              asked.add((exact: exact));
              throw Exception('Out of quota');
            };
        await expectLater(
          polishComposerText(
            composerPolishText('fix it'),
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

    Future<ComposerController> pumpComposer(
      WidgetTester tester, {
      IdeNotifications? notifications,
      int historyCount = 0,
    }) async {
      final session = ChatSession(historyCount: historyCount);
      addTearDown(session.dispose);
      final composer = ChatComposer(session: session, draft: session.draft);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          localizationsDelegates: const [
            AppLocalizations.delegate,
          ],
          home: Scaffold(
            body: notifications == null
                ? composer
                : IdeNotificationsScope(
                    notifications: notifications,
                    child: composer,
                  ),
          ),
        ),
      );
      await tester.pump();
      return tester.widget<MarkdownEditor>(find.byType(MarkdownEditor))
              .controller
          as ComposerController;
    }

    Finder polishButton() => find.byWidgetPredicate(
      (widget) =>
          widget is IdeHover &&
          (widget.message == englishLocalizations.composerPolishHint ||
              widget.message == englishLocalizations.composerPolishing),
    );

    Finder undoButton() => find.byWidgetPredicate(
      (widget) =>
          widget is IdeHover &&
          (widget.message == englishLocalizations.composerPolishUndo ||
              widget.message == englishLocalizations.composerEnhanceUndo),
    );

    testWidgets('Polish puts the reply in, its tag as it was; Undo takes '
        'it back', (tester) async {
      final reply = Completer<String>();
      String? prompt;
      composerPolishAsker =
          (system, asked, {model, exact = false, location, tools}) {
            prompt = asked;
            return reply.future;
          };
      final controller = await pumpComposer(tester);
      controller.replace(
        0,
        0,
        'fix teh bug in ${file.atom} plz',
        selection: const TextSelection.collapsed(offset: 0),
      );
      await tester.pump();
      final before = controller.text;

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
      expect(controller.text, 'Please fix the bug in ${file.atom}.');
      expect(controller.embeds.single.embed, file);

      controller.undo();
      await tester.pump();
      expect(controller.text, before);
    });

    testWidgets('the Undo button puts back what was written, and goes', (
      tester,
    ) async {
      final reply = Completer<String>();
      composerPolishAsker =
          (system, asked, {model, exact = false, location, tools}) =>
              reply.future;
      final controller = await pumpComposer(tester);
      controller.replace(
        0,
        0,
        'fix teh bug',
        selection: const TextSelection.collapsed(offset: 0),
      );
      await tester.pump();
      await tester.tap(polishButton());
      await tester.pump();
      reply.complete('Fix the bug.');
      await tester.pumpAndSettle();
      expect(controller.text, 'Fix the bug.');

      // Its own button, for the change the rewrite made alone: the
      // editor's own undo would take back whatever was typed since as
      // well.
      expect(undoButton(), findsOneWidget);
      await tester.tap(undoButton());
      await tester.pumpAndSettle();
      expect(controller.text, 'fix teh bug');
      // Nothing left to take back: no button.
      expect(undoButton(), findsNothing);
    });

    testWidgets('typed on after the reply, no Undo button', (tester) async {
      final reply = Completer<String>();
      composerPolishAsker =
          (system, asked, {model, exact = false, location, tools}) =>
              reply.future;
      final controller = await pumpComposer(tester);
      controller.replace(
        0,
        0,
        'fix teh bug',
        selection: const TextSelection.collapsed(offset: 0),
      );
      await tester.pump();
      await tester.tap(polishButton());
      await tester.pump();
      reply.complete('Fix the bug.');
      await tester.pumpAndSettle();
      expect(undoButton(), findsOneWidget);

      controller.replace(12, 12, ' now');
      await tester.pumpAndSettle();
      // Edited by hand: what the rewrite left is no longer the message,
      // so taking it back would throw that away too.
      expect(undoButton(), findsNothing);
    });

    testWidgets('a reply thrown away: said why, and the answer kept to read', (
      tester,
    ) async {
      final notifications = IdeNotifications();
      addTearDown(notifications.dispose);
      composerPolishAsker = (
        system,
        asked, {
        model,
        exact = false,
        location,
        tools,
      }) async => '## Fix it\n\nFix the typo.';
      final controller = await pumpComposer(
        tester,
        notifications: notifications,
      );
      controller.replace(
        0,
        0,
        'fix teh bug',
        selection: const TextSelection.collapsed(offset: 0),
      );
      await tester.pump();
      await tester.tap(polishButton());
      await tester.pumpAndSettle();

      // The text is left as it was, and the notification says why.
      expect(controller.text, 'fix teh bug');
      final shown = notifications.notifications.single;
      expect(
        shown.message,
        englishLocalizations.composerPolishFailed(
          englishLocalizations.stashAiNoAnswer,
        ),
      );
      // The answer is theirs to read, not lost.
      expect(
        shown.primary.map((action) => action.label),
        [englishLocalizations.composerPolishShowResult],
      );
      shown.primary.single.run();
      await tester.pumpAndSettle();
      // The reason, and what the model wrote under it.
      expect(
        find.textContaining(
          englishLocalizations.composerPolishRejectedHeading,
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Fix the typo.'),
        findsOneWidget,
        reason: 'what the model wrote, shown to be read',
      );
    });

    testWidgets('an input method still composing: not asked, and the '
        'letters kept', (tester) async {
      final asked = <String>[];
      composerPolishAsker = (
        system,
        prompt, {
        model,
        exact = false,
        location,
        tools,
      }) async {
        asked.add(prompt);
        return 'Fix it.';
      };
      final controller = await pumpComposer(tester);
      controller.replace(
        0,
        0,
        'fix teh bug',
        selection: const TextSelection.collapsed(offset: 0),
      );
      // The person is still choosing the letters (pinyin, kana…): what is
      // in the text is not yet what they mean.
      controller.composing = const TextRange(start: 0, end: 3);
      await tester.pump();
      await tester.tap(polishButton());
      await tester.pumpAndSettle();
      expect(asked, isEmpty);
      expect(controller.text, 'fix teh bug');

      // Done composing: it is asked as it is.
      controller.composing = TextRange.empty;
      await tester.pump();
      await tester.tap(polishButton());
      await tester.pumpAndSettle();
      expect(asked, hasLength(1));
      expect(controller.text, 'Fix it.');
    });

    testWidgets('while it waits, a notification says what it waits on', (
      tester,
    ) async {
      final notifications = IdeNotifications();
      addTearDown(notifications.dispose);
      final reply = Completer<String>();
      composerPolishAsker = (
        system,
        asked, {
        model,
        exact = false,
        location,
        tools,
      }) => reply.future;
      final controller = await pumpComposer(
        tester,
        notifications: notifications,
      );
      controller.replace(
        0,
        0,
        'fix teh bug',
        selection: const TextSelection.collapsed(offset: 0),
      );
      await tester.pump();
      await tester.tap(polishButton());
      await tester.pump();

      final shown = notifications.notifications.single;
      expect(shown.message, startsWith('Asking the model'));
      expect(shown.progress?.infinite, isTrue);

      reply.complete('Fix the bug.');
      await tester.pumpAndSettle();
      // Gone once answered, and the text is the reply.
      expect(notifications.notifications, isEmpty);
      expect(controller.text, 'Fix the bug.');
    });

    testWidgets('typed on meanwhile, the reply is not taken', (tester) async {
      final reply = Completer<String>();
      composerPolishAsker = (
        system,
        asked, {
        model,
        exact = false,
        location,
        tools,
      }) => reply.future;
      final controller = await pumpComposer(tester);
      controller.replace(0, 0, 'fix it');
      await tester.pump();
      await tester.tap(polishButton());
      await tester.pump();
      controller.replace(6, 6, ' now');
      reply.complete('Fix it.');
      await tester.pumpAndSettle();
      expect(controller.text, 'fix it now');
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
      composerPolishAsker =
          (s, asked, {model, exact = false, location, tools}) {
            system = s;
            seen = tools;
            return reply.future;
          };
      final controller = await pumpComposer(tester);
      controller.replace(
        0,
        0,
        'fix teh bug in ${file.atom}',
        selection: const TextSelection.collapsed(offset: 0),
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
      expect(
        controller.text,
        'Fix the bug in ${file.atom}: correct the typo, then run the tests.',
      );
      expect(controller.embeds.single.embed, file);
    });

    testWidgets('Enhance is told what the agent said last, the composer '
        'sending it the conversation\'s own last turn', (tester) async {
      String? prompt;
      composerPolishAsker = (system, asked, {
        model,
        exact = false,
        location,
        tools,
      }) {
        prompt = asked;
        return Future.value('Do the second option.');
      };
      final controller = await pumpComposer(tester, historyCount: 16);
      controller.replace(
        0,
        0,
        'do option 2',
        selection: const TextSelection.collapsed(offset: 0),
      );
      await tester.pump();
      await tester.tap(enhanceButton());
      await tester.pumpAndSettle();
      // The mock conversation's last turn: the agent's texts at 12 and 15.
      final lastTurn = [
        (MockConversation.itemAt(12) as AssistantTextItem).text.trim(),
        (MockConversation.itemAt(15) as AssistantTextItem).text.trim(),
      ].join('\n\n');
      expect(prompt, contains('<agent_reply>\n$lastTurn\n</agent_reply>'));
    });

    testWidgets('Enhance turned off in the settings, no button', (
      tester,
    ) async {
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
      composerPolishAsker =
          (system, asked, {model, exact = false, location, tools}) {
            prompt = asked;
            seen = tools;
            return Future.value('Fix it.');
          };
      await enhanceComposerText(
        composerPolishText('fix it'),
        location: r'C:\w\app',
      );
      expect(seen?.readable, [r'C:\w\app']);
      expect(seen?.directory, r'C:\w\app');
      expect(prompt, contains('<project>\nC:\\w\\app\n</project>'));
      expect(prompt, contains('<message>\nfix it\n</message>'));
    });

    test('what the agent said last goes before the message, that a "do '
        'option 2" can be made specific', () async {
      String? prompt;
      String? system;
      composerPolishAsker = (askedSystem, asked, {
        model,
        exact = false,
        location,
        tools,
      }) {
        system = askedSystem;
        prompt = asked;
        return Future.value('Do the second option.');
      };
      await enhanceComposerText(
        composerPolishText('do option 2'),
        reply: '1. Rename the file.\n2. Move the class.',
        location: r'C:\w\app',
      );
      expect(
        prompt,
        contains(
          '<agent_reply>\n1. Rename the file.\n2. Move the class.\n'
          '</agent_reply>',
        ),
      );
      // It is before the message, and the message is still last.
      expect(
        prompt!.indexOf('<agent_reply>'),
        lessThan(prompt!.indexOf('<message>')),
      );
      expect(system, contains('<agent_reply>'));
    });

    test('no reply, or one of whitespace alone: nothing said', () async {
      final prompts = <String>[];
      composerPolishAsker = (system, asked, {
        model,
        exact = false,
        location,
        tools,
      }) {
        prompts.add(asked);
        return Future.value('Fix it.');
      };
      await enhanceComposerText(composerPolishText('fix it'));
      await enhanceComposerText(
        composerPolishText('fix it'),
        reply: '   \n\n ',
      );
      expect(prompts, hasLength(2));
      for (final prompt in prompts) {
        expect(prompt, isNot(contains('<agent_reply>')));
      }
    });

    test('a long reply is cut to its end, where the message answers it', () async {
      String? prompt;
      composerPolishAsker = (system, asked, {
        model,
        exact = false,
        location,
        tools,
      }) {
        prompt = asked;
        return Future.value('Fix it.');
      };
      final long = 'a' * (composerPolishReplyLimit + 5000) + 'THE END';
      await enhanceComposerText(composerPolishText('fix it'), reply: long);
      final said = RegExp(
        r'<agent_reply>\n([\s\S]*)\n</agent_reply>',
      ).firstMatch(prompt!)!.group(1)!;
      expect(said, endsWith('THE END'));
      expect(said, startsWith('…'));
      // The ellipsis is not counted: what is given is the limit at most.
      expect(said.length, lessThanOrEqualTo(composerPolishReplyLimit + 1));
    });

    test('it went looking and came back without the message: asked again, '
        'the message alone', () async {
      final seen = <ClaudeHaikuTools?>[];
      composerPolishAsker =
          (system, asked, {model, exact = false, location, tools}) async {
            seen.add(tools);
            if (tools != null) {
              throw Exception('Reached maximum number of turns');
            }
            return 'Fix it.';
          };
      final content = await enhanceComposerText(
        composerPolishText('fix it'),
        location: r'C:\w\app',
      );
      expect(content, 'Fix it.');
      expect(seen, hasLength(2));
      expect(seen.first?.directory, r'C:\w\app');
      expect(seen.last, isNull);
    });

    test('the project made it run long: asked again, the message alone', () async {
      // A folder with nothing in it leaves the model nothing to name, so
      // it writes a plan instead of the message: far longer than what was
      // said. Asked without it, the message is all there is to go on.
      final seen = <ClaudeHaikuTools?>[];
      composerPolishAsker =
          (system, asked, {model, exact = false, location, tools}) async {
            seen.add(tools);
            return tools == null ? 'Fix it.' : 'x' * 3000;
          };
      final content = await enhanceComposerText(
        composerPolishText('fix it'),
        location: r'C:\w\app',
      );
      expect(content, 'Fix it.');
      expect(seen, hasLength(2));
      expect(seen.first?.directory, r'C:\w\app');
      expect(seen.last, isNull);
    });

    test('a project on a host: the message alone, no tools', () async {
      ClaudeHaikuTools? seen;
      String? prompt;
      composerPolishAsker =
          (system, asked, {model, exact = false, location, tools}) {
            prompt = asked;
            seen = tools;
            return Future.value('Fix it.');
          };
      await enhanceComposerText(
        composerPolishText('fix it'),
        location: 'ssh://box/home/me/app',
      );
      expect(seen, isNull);
      expect(prompt, contains('<project>\n/home/me/app\n</project>'));
    });

    test(
      'what it found and how to check it: several times the words taken',
      () async {
        composerPolishAsker =
            (system, asked, {model, exact = false, location, tools}) async =>
                'Fix the typo in lib/main.dart, where the button is built, then run '
                'flutter test test/chat/composer_polish_test.dart and check that the '
                'reply is still taken as one change.';
        final content = await enhanceComposerText(
          composerPolishText('fix it'),
        );
        expect(
          content,
          contains('lib/main.dart'),
        );
      },
    );

    test('a whole file written out: not taken', () async {
      composerPolishAsker = (
        system,
        asked, {
        model,
        exact = false,
        location,
        tools,
      }) async => 'x' * 3000;
      await expectLater(
        enhanceComposerText(composerPolishText('fix it')),
        throwsA(isA<ComposerPolishException>()),
      );
    });

    test('a reply that wrote around the message: not taken', () async {
      Future<void> rejects(String reply) async {
        composerPolishAsker = (
          system,
          asked, {
          model,
          exact = false,
          location,
          tools,
        }) async => reply;
        await expectLater(
          polishComposerText(composerPolishText('fix it')),
          throwsA(isA<ComposerPolishRejected>()),
        );
      }

      // A heading, a preamble in either language, or the whole in a fence.
      await rejects('## Fix it\n\nFix the typo.');
      await rejects('Sure, fix the typo.');
      await rejects('好的，修复这个错字。');
      await rejects('```\nFix the typo.\n```');
    });

    test('a heading or a preamble the message itself had is kept', () async {
      composerPolishAsker = (
        system,
        asked, {
        model,
        exact = false,
        location,
        tools,
      }) async => '## Fix the typo\n\nFix the typo in the label.';
      await polishComposerText(
        composerPolishText('## Fix the typo\n\nIt is wrong.'),
      );

      composerPolishAsker = (
        system,
        asked, {
        model,
        exact = false,
        location,
        tools,
      }) async => '好的，修复这个错字，并运行测试。';
      await polishComposerText(
        composerPolishText('好的，修复这个错字。'),
      );
    });

    test('a reply that is not the message is not asked again without the '
        'project', () async {
      final seen = <ClaudeHaikuTools?>[];
      composerPolishAsker =
          (system, asked, {model, exact = false, location, tools}) async {
            seen.add(tools);
            return '## Fix it\n\nFix the typo.';
          };
      await expectLater(
        enhanceComposerText(
          composerPolishText('fix it'),
          location: r'C:\w\app',
        ),
        throwsA(isA<ComposerPolishRejected>()),
      );
      // The answer was wrong, not missing: the message alone would be
      // answered the same way.
      expect(seen, hasLength(1));
    });

    test('the prompts ask for no padding, and show what that means', () async {
      final systems = <String>[];
      composerPolishAsker =
          (system, asked, {model, exact = false, location, tools}) async {
            systems.add(system);
            return 'Fix it.';
          };

      await enhanceComposerText(
        composerPolishText('fix it'),
        location: r'C:\w\app',
      );
      await enhanceComposerText(composerPolishText('fix it'));

      final [withTools, alone] = systems;
      for (final system in systems) {
        expect(system, contains('Add only what changes what the agent does'));
        expect(system, contains('nothing before or after it'));
        // Given to Claude Code as a command-line argument: one line, and
        // no quoting a shell would take apart.
        expect(system, isNot(contains('\n')));
        expect(system, isNot(contains('"')));
      }
      expect(withTools, contains('not a wish to improve performance'));
      expect(withTools, contains('the page\'s build path'));
      expect(alone, contains('You cannot look at the project here'));
      expect(alone, contains('what to measure'));
    });
  });
}
