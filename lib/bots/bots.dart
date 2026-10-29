import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chat/chat_models.dart';
import '../chat/chat_session.dart';
import '../kernel/agent_kernel.dart';
import '../kernel/claude_code/claude_sdk_tools.dart';
import '../kernel/kernel_registry.dart';
import '../workspace/preference_store.dart';
import '../workspace/workspace.dart';
import 'bot.dart';
import 'bot_folders.dart';
import 'bot_pacer.dart';
import 'bot_prompt.dart';
import 'bot_tools.dart';

/// The user's bots: agents of their own making that chat as a person does
/// (see bot.dart), each a conversation in a folder of its own, which the
/// sidebar does not list. Their tools are theirs ([ClaudeSdkGate]): those
/// of the abilities the user turned on; and they write first of what
/// happens to the agents, paced ([BotPacer]).
class Bots extends ChangeNotifier implements ClaudeSdkGate {
  Bots({
    required this.workspace,
    BotFolders? folders,
    this.store,
    DateTime Function()? clock,
    this.chinese = false,
  }) : folders = folders ?? BotFolders.data(),
       _clock = clock ?? DateTime.now;

  final Workspace workspace;
  final BotFolders folders;

  /// Where the list of them is kept.
  final PreferenceStore? store;
  final DateTime Function() _clock;

  /// Whether the assistant made at first is named and told in Chinese.
  final bool chinese;

  /// The settings its agent runs with: it asks nothing (its tools are
  /// allowed, all else refused), and works as an agent, not in Plan.
  static const settings = {'mode': 'agent', 'permission': 'dontAsk'};

  List<Bot> _bots = [];
  List<Bot> get bots => List.unmodifiable(_bots);

  final Map<String, BotPacer> _pacers = {};
  Timer? _timer;

  /// The last turn end of each bot's the user has seen, by its id.
  final Map<String, int> _seen = {};

  /// How each agent stood when last looked at, to tell what changed.
  final Map<AgentThread, ThreadStatus> _statuses = {};

  bool _started = false;

  Future<void> start() async {
    final root = folders.root;
    if (root == null || _started) return;
    _started = true;
    final kept = await store?.read() ?? const {};
    _bots = [
      for (final json in (kept['bots'] as List?) ?? const [])
        ?Bot.fromJson(json, root: root),
    ];
    if (!_bots.any((bot) => bot.assistant)) {
      final defaults = assistantDefaults(chinese: chinese);
      _bots.insert(
        0,
        Bot(
          id: 'assistant',
          name: defaults.name,
          folder: p.join(root, 'assistant'),
          identity: defaults.identity,
          abilities: BotAbility.values.toSet(),
          assistant: true,
        ),
      );
      _save();
    }
    for (final bot in _bots) {
      folders.make(bot.folder);
    }
    workspace.agentSetup = _setup;
    ClaudeSdkTools.gate = this;
    BotTools.register(this);
    workspace.addListener(_watch);
    _watch();
    notifyListeners();
  }

  @override
  void dispose() {
    if (_started) {
      workspace.removeListener(_watch);
      if (identical(ClaudeSdkTools.gate, this)) ClaudeSdkTools.gate = null;
      BotTools.unregister();
      workspace.agentSetup = null;
    }
    _timer?.cancel();
    super.dispose();
  }

  void _save() => unawaited(
    store?.write({
      'bots': [for (final bot in _bots) bot.toJson()],
    }),
  );

  Bot? byId(String id) => _bots.where((bot) => bot.id == id).firstOrNull;

  /// The bot whose folder [cwd] is.
  Bot? botAt(String cwd) => _bots.where((bot) => bot.folder == cwd).firstOrNull;

  AgentSetup? _setup(String path) => switch (botAt(path)) {
    final bot? => AgentSetup(
      workspace: () => KernelWorkspace(
        folders: const [],
        instructions: botInstructions(
          bot,
          memory: folders.readMemory(bot.folder),
          now: _clock(),
        ),
        // Its own tools only; the tool search, for the browser's, which
        // are deferred.
        tools: bot.can(BotAbility.browser) ? const ['ToolSearch'] : const [],
      ),
      settings: settings,
      kernel: KernelRegistry.claudeCode.id,
    ),
    null => null,
  };

  // --- What a bot is offered -------------------------------------------------

  @override
  bool offersTool(String cwd, String tool) {
    final bot = botAt(cwd);
    final ability = BotTools.abilityOf(tool);
    if (bot == null) return ability == null;
    if (ability != null) return ability.allows(bot);
    // The app's other tools: the browser's, if it may use it.
    return bot.can(BotAbility.browser) &&
        ClaudeSdkTools.called('mcp__${ClaudeSdkTools.server}__$tool')?.kind ==
            ToolKind.browser;
  }

  @override
  bool tellsFeature(String cwd, String feature) => switch (botAt(cwd)) {
    null => true,
    final bot => feature == 'browser' && bot.can(BotAbility.browser),
  };

  // --- Its conversation --------------------------------------------------

  /// [bot]'s conversation, if it has one.
  AgentThread? threadOf(Bot bot) {
    AgentThread? latest;
    for (final thread in workspace.threads) {
      if (thread.project.path != bot.folder || thread.archived) continue;
      if (latest == null || thread.updatedAt.isAfter(latest.updatedAt)) {
        latest = thread;
      }
    }
    return latest;
  }

  /// [bot]'s conversation, started if it has none.
  AgentThread threadFor(Bot bot) {
    if (threadOf(bot) case final thread?) return thread;
    folders.make(bot.folder);
    return workspace.startAgent(workspace.projectAt(bot.folder));
  }

  /// Has [bot]'s agent start again on its conversation, to be told what
  /// changed (its identity, abilities, memory) from its next message.
  void _restart(Bot bot) {
    final thread = threadOf(bot);
    if (thread == null || !thread.isOpen) return;
    final session = thread.session;
    if (!session.isStreaming && session.sessionId != null) session.restart();
  }

  /// How many of [bot]'s turns ended since the user last read it.
  int unread(Bot bot) {
    final thread = threadOf(bot);
    if (thread == null || !thread.isOpen) return 0;
    final seq = thread.session.lastTurnEndSeq;
    final seen = _seen[bot.id] ??= seq;
    return seq > seen ? seq - seen : 0;
  }

  /// The user has read all [bot] said.
  void seen(Bot bot) {
    final thread = threadOf(bot);
    if (thread == null || !thread.isOpen) return;
    _seen[bot.id] = thread.session.lastTurnEndSeq;
    notifyListeners();
  }

  /// The last [bot] said: its first line.
  String? lastLine(Bot bot) {
    final thread = threadOf(bot);
    if (thread == null || !thread.isOpen) return null;
    final session = thread.session;
    for (var i = session.itemCount - 1; i >= 0; i--) {
      if (session.itemAt(i) case AssistantTextItem(:final text)) {
        final line = text
            .split('\n')
            .map((l) => l.trim())
            .firstWhere((l) => l.isNotEmpty, orElse: () => '');
        if (line.isNotEmpty) {
          return line.length > 120 ? '${line.substring(0, 120)}…' : line;
        }
      }
    }
    return null;
  }

  // --- Made, changed, deleted -----------------------------------------------

  /// [id]'s bot changed as given, or a new one (no [id]).
  Bot save({
    String? id,
    required String name,
    String? avatar,
    required String identity,
    required Set<BotAbility> abilities,
    BotProactive proactive = const BotProactive(),
  }) {
    final root = folders.root;
    if (root == null) throw StateError('No bots here');
    name = name.trim();
    if (name.isEmpty) throw ArgumentError('A bot needs a name');
    avatar = avatar?.trim();
    if (avatar?.isEmpty ?? false) avatar = null;
    final Bot bot;
    if (id == null) {
      bot = Bot(
        id: _newId(),
        name: name,
        folder: '',
        avatar: avatar,
        identity: identity.trim(),
        abilities: abilities,
        proactive: proactive,
      );
      final made = Bot.fromJson(bot.toJson(), root: root)!;
      folders.make(made.folder);
      _bots.add(made);
      _save();
      notifyListeners();
      return made;
    }
    final index = _bots.indexWhere((b) => b.id == id);
    if (index < 0) throw StateError('No bot $id');
    bot = _bots[index] = _bots[index].copyWith(
      name: name,
      avatar: avatar,
      clearAvatar: avatar == null,
      identity: identity.trim(),
      abilities: abilities,
      proactive: proactive,
    );
    if (proactive.perDay <= 0 || !bot.can(BotAbility.proactive)) {
      _pacers.remove(bot.id);
    }
    _save();
    _restart(bot);
    notifyListeners();
    return bot;
  }

  String _newId() {
    final now = _clock().microsecondsSinceEpoch.toRadixString(36);
    var id = 'b$now';
    for (var n = 2; byId(id) != null; n++) {
      id = 'b$now-$n';
    }
    return id;
  }

  /// Deletes [id]'s bot, its conversation and memory: not the assistant's.
  void delete(String id) {
    final bot = byId(id);
    if (bot == null) return;
    if (bot.assistant) throw StateError('The assistant stays');
    workspace.deleteAll([
      for (final thread in workspace.threads)
        if (thread.project.path == bot.folder) thread,
    ]);
    folders.delete(bot.folder);
    _bots.remove(bot);
    _pacers.remove(id);
    _seen.remove(id);
    _save();
    notifyListeners();
  }

  String memory(Bot bot) => folders.readMemory(bot.folder);

  void setMemory(Bot bot, String text) {
    folders.writeMemory(bot.folder, text.trim().isEmpty ? '' : text);
    _restart(bot);
    notifyListeners();
  }

  // --- Writing first ------------------------------------------------------

  /// What changed for the agents the sidebar lists, told the bots that
  /// write first.
  void _watch() {
    final gone = {..._statuses.keys};
    final events = <BotEvent>[];
    for (final thread in workspace.threads) {
      if (thread.archived || isBotThread(thread)) continue;
      if (!workspace.listsInSidebar(thread)) continue;
      gone.remove(thread);
      final now = thread.status;
      final was = _statuses[thread];
      _statuses[thread] = now;
      if (was == null || was == now) continue;
      final kind = switch ((was, now)) {
        (_, ThreadStatus.needsInput) => BotEventKind.waiting,
        (ThreadStatus.running, ThreadStatus.idle || ThreadStatus.unread)
            when _failed(thread) =>
          BotEventKind.failed,
        (ThreadStatus.running, ThreadStatus.idle || ThreadStatus.unread) =>
          BotEventKind.done,
        _ => null,
      };
      if (kind == null) continue;
      events.add(
        BotEvent(
          chat: BotTools.idOf(thread),
          title: thread.title,
          project: thread.project.name,
          kind: kind,
          at: _clock(),
          detail: kind == BotEventKind.failed ? _error(thread) : null,
        ),
      );
    }
    for (final thread in gone) {
      _statuses.remove(thread);
    }
    if (events.isEmpty) return;
    for (final bot in _bots) {
      if (!bot.can(BotAbility.proactive) || bot.proactive.perDay <= 0) {
        continue;
      }
      final pacer = _pacers[bot.id] ??= BotPacer();
      events.forEach(pacer.add);
    }
    _schedule();
  }

  bool isBotThread(AgentThread thread) => botAt(thread.project.path) != null;

  static bool _failed(AgentThread thread) => _error(thread) != null;

  static String? _error(AgentThread thread) {
    if (!thread.isOpen) return null;
    final session = thread.session;
    for (var i = session.itemCount - 1; i >= 0; i--) {
      switch (session.itemAt(i)) {
        case NoticeItem(kind: NoticeKind.error, :final text):
          return text.split('\n').first;
        case UserMessageItem() || AssistantTextItem():
          return null;
        default:
      }
    }
    return null;
  }

  void _schedule() {
    _timer?.cancel();
    final now = _clock();
    DateTime? next;
    for (final bot in _bots) {
      final due = _pacers[bot.id]?.dueAt(bot.proactive, now);
      if (due != null && (next == null || due.isBefore(next))) next = due;
    }
    if (next == null) return;
    _timer = Timer(next.difference(now), deliver);
  }

  /// Tells each bot what is due: a message of the app's in its
  /// conversation, which it answers as it writes first.
  @visibleForTesting
  void deliver() {
    final now = _clock();
    for (final bot in _bots) {
      final pacer = _pacers[bot.id];
      if (pacer == null) continue;
      final thread = threadFor(bot);
      // Not while it is answering: after.
      if (thread.isOpen && thread.session.isStreaming) continue;
      final events = pacer.take(bot.proactive, now);
      if (events == null) continue;
      thread.session.send(
        ComposerMessage(text: botEventMessage(botEventText(events))),
      );
    }
    if (_pacers.values.any((p) => p.hasPending)) {
      _timer?.cancel();
      _timer = Timer(const Duration(seconds: 30), _schedule);
    }
  }
}
