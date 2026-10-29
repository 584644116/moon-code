import 'package:baocode/bots/bot.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bot_pacer.dart';
import 'package:baocode/bots/bot_prompt.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/link/chat_codec.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/claude_code/mock_claude_code_transport.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BotPacer', () {
    final start = DateTime(2026, 10, 29, 14);
    BotEvent event(String chat, BotEventKind kind, DateTime at) => BotEvent(
      chat: chat,
      title: 'Agent $chat',
      project: 'monad',
      kind: kind,
      at: at,
    );
    const often = BotProactive(perDay: 3, quietFrom: 0, quietTo: 0);

    test('what comes close together is told at once, what needs the user '
        'first', () {
      final pacer = BotPacer();
      pacer
        ..add(event('a', BotEventKind.done, start))
        ..add(event('b', BotEventKind.failed, start.add(seconds(20))))
        ..add(event('c', BotEventKind.waiting, start.add(seconds(40))));
      expect(pacer.take(often, start.add(seconds(60))), isNull);
      final told = pacer.take(often, start.add(seconds(90)))!;
      expect(told.map((e) => e.chat), ['c', 'b', 'a']);
      expect(pacer.hasPending, isFalse);
    });

    test('an agent\'s latest only', () {
      final pacer = BotPacer()
        ..add(event('a', BotEventKind.waiting, start))
        ..add(event('a', BotEventKind.done, start.add(seconds(10))));
      final told = pacer.take(often, start.add(const Duration(minutes: 5)))!;
      expect(told.single.kind, BotEventKind.done);
    });

    test('apart, and only so many a day', () {
      final pacer = BotPacer();
      var now = start;
      final sent = <DateTime>[];
      for (var i = 0; i < 6; i++) {
        pacer.add(event('$i', BotEventKind.failed, now));
        final due = pacer.dueAt(often, now)!;
        expect(pacer.take(often, due), isNotNull);
        sent.add(due);
        now = due;
      }
      expect(sent[1].difference(sent[0]), greaterThanOrEqualTo(minutes(20)));
      // The fourth, a day after the first.
      expect(
        sent[3].difference(sent[0]),
        greaterThanOrEqualTo(const Duration(days: 1)),
      );
    });

    test('never in the quiet hours, nor at all when set to none', () {
      const quiet = BotProactive(
        perDay: 5,
        quietFrom: 23 * 60,
        quietTo: 8 * 60,
      );
      final night = DateTime(2026, 10, 29, 23, 30);
      final pacer = BotPacer()..add(event('a', BotEventKind.failed, night));
      expect(pacer.dueAt(quiet, night), DateTime(2026, 10, 30, 8));
      expect(pacer.dueAt(const BotProactive(perDay: 0), night), isNull);
      expect(pacer.take(const BotProactive(perDay: 0), night), isNull);
    });

    test('what was done long ago is not worth telling', () {
      final pacer = BotPacer()
        ..add(event('a', BotEventKind.done, start))
        ..add(event('b', BotEventKind.waiting, start));
      final told = pacer.take(often, start.add(const Duration(hours: 7)))!;
      expect(told.map((e) => e.chat), ['b']);
    });
  });

  group('what a bot is told', () {
    const bot = Bot(
      id: 'b',
      name: 'Mia',
      folder: '/bots/b',
      gender: 'female',
      signature: 'Tea first.',
      identity: 'An old friend, playful and kind.',
      style: 'Lowercase, lots of emoji.',
      abilities: {BotAbility.viewChats},
    );

    test('the rules first, then who the user made it', () {
      final told = botInstructions(bot, memory: 'Likes tea.');
      expect(told.indexOf('<bot_rules>'), 0);
      expect(told, contains('say you are an AI'));
      expect(told, contains('No sexual or explicit content'));
      expect(told, contains('12356'));
      expect(told, contains('cannot approve or deny'));
      expect(
        told.indexOf('<bot_rules>'),
        lessThan(told.indexOf('An old friend')),
      );
      expect(told, contains('Your name is Mia.'));
      expect(told, contains('Your gender, as the user put it: female.'));
      expect(told, contains('Tea first.'));
      expect(told, contains('How you talk, in the user\'s words:'));
      expect(told, contains('Lowercase, lots of emoji.'));
      expect(told, contains('Likes tea.'));
    });

    test('what it may do, and may not', () {
      final told = botAbilities(bot);
      expect(told, contains('bot_list_chats'));
      expect(told, contains('You cannot stop, retry or archive agents.'));
      expect(told, contains('You cannot use the browser.'));
    });
  });

  group('Bots', () {
    final launches = <ClaudeLaunch>[];
    late KernelDescriptor kernel;
    kernel = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      icon: Icons.auto_awesome_rounded,
      description: '',
      create: (context) => ClaudeCodeKernel(
        kernel,
        context,
        start: (launch) {
          launches.add(launch);
          return MockClaudeCodeTransport.start(launch);
        },
      ),
    );
    late Workspace workspace;
    late Bots bots;
    late MemoryBotFolders folders;
    late MemoryPreferenceStore store;
    late DateTime now;

    setUp(() async {
      launches.clear();
      workspace = Workspace(
        kernels: [kernel],
        projects: const [Project('app', '/tmp/app')],
      );
      folders = MemoryBotFolders();
      store = MemoryPreferenceStore();
      now = DateTime(2026, 10, 29, 14);
      bots = Bots(
        workspace: workspace,
        folders: folders,
        store: store,
        chinese: true,
        clock: () => now,
      );
      await bots.start();
    });

    tearDown(() {
      bots.dispose();
      workspace.dispose();
    });

    Future<List<String>> offered(String cwd) async {
      final answer = await ClaudeSdkTools.handle({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
      }, ClaudeSdkCall(cwd: cwd));
      return [
        for (final tool
            in ((answer['result'] as Map)['tools'] as List).cast<Map>())
          tool['name'] as String,
      ];
    }

    test('start with the assistant, every ability on, kept', () async {
      final assistant = bots.bots.single;
      expect(assistant.assistant, isTrue);
      expect(assistant.name, '小宝');
      expect(assistant.abilities, BotAbility.values.toSet());
      expect(folders.folders, contains(assistant.folder));
      await pumpEventQueue();
      expect(
        (store.preferences['bots'] as List).single,
        containsPair('id', 'assistant'),
      );
    });

    test('a bot\'s folder is no project of the sidebar\'s', () {
      final bot = bots.bots.single;
      final thread = bots.threadFor(bot);
      expect(workspace.isHidden(thread.project), isTrue);
      expect(workspace.listsInSidebar(thread), isFalse);
      expect(bots.threadFor(bot), same(thread));
      expect(workspace.agentSetup!(bot.folder)!.settings, Bots.settings);
      // Named by none of what it is told.
      thread.session.send(const ComposerMessage(text: '<bao-event>x'));
      workspace.notifyListeners();
      expect(thread.title, isNot(contains('bao-event')));
      expect(workspace.agentSetup!('/tmp/app'), isNull);
    });

    test('its agent is told who it is, with its own tools only', () async {
      final bot = bots.bots.single;
      bots.threadFor(bot).session.send(const ComposerMessage(text: '在吗'));
      for (var i = 0; i < 50 && launches.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final launch = launches.single;
      expect(launch.cwd, bot.folder);
      expect(launch.instructions, contains('<bot_rules>'));
      expect(launch.instructions, contains('小宝'));
      expect(launch.permissionMode, 'dontAsk');
      expect(launch.sdkServers, [ClaudeSdkTools.server]);
      // The browser's tool search, as it may use it; no other.
      expect(launch.tools, ['ToolSearch']);
      expect(launch.arguments, containsAllInOrder(['--tools', 'ToolSearch']));
      // None of the user's MCP servers: their notices are not its to tell.
      expect(launch.arguments, contains('--strict-mcp-config'));
    });

    test(
      'a bot is offered its abilities\' tools; a project\'s agent none',
      () async {
        final assistant = bots.bots.single;
        expect(
          await offered(assistant.folder),
          containsAll(['bot_list_chats', 'bot_stop_chat', 'bot_remember']),
        );
        expect(await offered('/tmp/app'), isNot(contains('bot_list_chats')));
        expect(ClaudeSdkTools.serversFor('/tmp/app'), isEmpty);

        // A new one may do nothing until the user says.
        final mia = bots.save(
          name: 'Mia',
          identity: '',
          abilities: {BotAbility.viewChats},
        );
        final hers = await offered(mia.folder);
        expect(hers, containsAll(['bot_list_chats', 'bot_show_chat']));
        expect(hers, isNot(contains('bot_stop_chat')));
        expect(hers, isNot(contains('bot_read_file')));
        final none = bots.save(name: 'Quiet', identity: '', abilities: {});
        expect(await offered(none.folder), ['bot_remember']);
        // Nor called, though named.
        final refused = await ClaudeSdkTools.handle({
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'tools/call',
          'params': {
            'name': 'bot_list_chats',
            'arguments': <String, Object?>{},
          },
        }, ClaudeSdkCall(cwd: none.folder));
        expect((refused['result'] as Map)['isError'], isTrue);
      },
    );

    test('bots are changed and deleted; the assistant stays', () {
      final mia = bots.save(name: ' Mia ', identity: 'x', abilities: {});
      expect(mia.name, 'Mia');
      final changed = bots.save(
        id: mia.id,
        name: 'Mia',
        avatar: '🌸',
        identity: 'y',
        abilities: {BotAbility.proactive},
        proactive: const BotProactive(perDay: 0),
      );
      expect(changed.avatar, '🌸');
      expect(bots.byId(mia.id)!.proactive.perDay, 0);
      bots.delete(mia.id);
      expect(bots.byId(mia.id), isNull);
      expect(folders.folders, isNot(contains(mia.folder)));
      expect(() => bots.delete('assistant'), throwsStateError);
      expect(
        () => bots.save(name: ' ', identity: '', abilities: {}),
        throwsArgumentError,
      );
    });

    test('who it is, all the user wrote, kept; its model too', () async {
      final mia = bots.save(
        name: 'Mia',
        gender: ' female ',
        signature: 'Tea first.',
        identity: 'An old friend.',
        style: 'Short.',
        abilities: {},
      );
      expect(
        (mia.gender, mia.signature, mia.style),
        ('female', 'Tea first.', 'Short.'),
      );
      bots.setModel(mia, 'opus');
      expect(workspace.agentSetup!(mia.folder)!.settings, {
        ...Bots.settings,
        'model': 'opus',
      });
      await pumpEventQueue();
      final kept = Bot.fromJson(
        (store.preferences['bots'] as List).last,
        root: folders.root!,
      )!;
      expect(
        (kept.gender, kept.signature, kept.style, kept.model),
        ('female', 'Tea first.', 'Short.', 'opus'),
      );
    });

    test('what it remembers: kept by it, seen, changed and cleared', () async {
      final bot = bots.bots.single;
      Future<void> remember(String action, String text) =>
          ClaudeSdkTools.handle({
            'jsonrpc': '2.0',
            'id': 3,
            'method': 'tools/call',
            'params': {
              'name': 'bot_remember',
              'arguments': {'action': action, 'text': text},
            },
          }, ClaudeSdkCall(cwd: bot.folder));
      await remember('add', 'Name is Leo');
      await remember('add', 'Likes tea');
      expect(bots.memory(bot), '- Name is Leo\n- Likes tea');
      bots.setMemory(bot, 'Name is Leo');
      expect(bots.memory(bot), 'Name is Leo');
      bots.setMemory(bot, '');
      expect(bots.memory(bot), '');
    });

    test('it writes first of an agent done, in a note of the app\'s', () async {
      final bot = bots.bots.single;
      final agent = workspace.startAgent(workspace.projects.single);
      agent.session.send(const ComposerMessage(text: 'build it'));
      for (var i = 0; i < 300 && !agent.session.isStreaming; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      workspace.notifyListeners();
      // Its turn over (stopped, not to wait for the mock's whole script).
      agent.session.stop();
      for (var i = 0; i < 300 && agent.session.isStreaming; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      workspace.notifyListeners();
      now = now.add(const Duration(minutes: 2));
      bots.deliver();
      final note = bots.threadOf(bot)!.session.itemAt(0);
      expect(note, isA<UserMessageItem>());
      expect(
        ChatCodec.botEvent(note as UserMessageItem),
        contains('done: "${agent.title}"'),
      );
    });

    test('it tells of an agent at work a long while, once', () async {
      final bot = bots.bots.single;
      final agent = workspace.startAgent(workspace.projects.single);
      agent.session.send(const ComposerMessage(text: 'build it'));
      for (var i = 0; i < 300 && !agent.session.isStreaming; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      workspace.notifyListeners();
      addTearDown(agent.session.stop);
      now = now.add(const Duration(minutes: 29));
      bots.checkRunning();
      now = now.add(const Duration(minutes: 2));
      bots.checkRunning();
      now = now.add(const Duration(minutes: 2));
      bots.deliver();
      final session = bots.threadOf(bot)!.session;
      expect(
        ChatCodec.botEvent(session.itemAt(0) as UserMessageItem),
        contains('running: "${agent.title}"'),
      );
      expect(
        ChatCodec.botEvent(session.itemAt(0) as UserMessageItem),
        contains('running for 31 min'),
      );
      // Not again, while it runs on.
      now = now.add(const Duration(hours: 1));
      bots.checkRunning();
      now = now.add(const Duration(hours: 1));
      bots.deliver();
      expect([
        for (var i = 0; i < session.itemCount; i++)
          if (session.itemAt(i) case final UserMessageItem item
              when ChatCodec.botEvent(item) != null)
            item,
      ], hasLength(1));
    });
  });
}

Duration seconds(int n) => Duration(seconds: n);
Duration minutes(int n) => Duration(minutes: n);
