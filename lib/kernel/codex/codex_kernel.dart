import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../chat/chat_models.dart';
import '../../models/model_provider.dart';
import '../../models/model_providers.dart';
import '../agent_kernel.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import 'codex_transport.dart';

/// Adapts `codex app-server` to [AgentKernel]. Codex keeps no background
/// commands and cannot put files back, so it does not declare
/// [RunsBackgroundTasks] or [RevertsChanges]: those parts of the UI are not
/// shown for it.
class CodexKernel
    with KernelEventSource
    implements
        AgentKernel,
        SelectsModel,
        SelectsMode,
        SelectsEffort,
        ProvidesCommands,
        ReportsContext,
        RewindsConversation,
        AcceptsImages {
  CodexKernel(this.descriptor, this._transport, {Map<String, String> settings = const {}}) {
    _subscription = _transport.messages.listen(_receive);
    _effort = settings[KernelChoiceKind.effort.name];
    final efforts = '${KernelChoiceKind.effort.name}@';
    for (final MapEntry(:key, :value) in settings.entries) {
      if (key.startsWith(efforts)) {
        _pickedEfforts[key.substring(efforts.length)] = value;
      }
    }
  }

  @override
  final KernelDescriptor descriptor;
  final CodexTransport _transport;
  late final StreamSubscription<Map<String, Object?>> _subscription;

  @override
  late final KernelChoiceSource model = LocalChoice.fresh(
    _modelsOf,
    onChanged: (_) => emitInfoChanged(),
  );

  @override
  late final KernelChoiceSource mode = LocalChoice(
    _modes,
    onChanged: (_) => emitInfoChanged(),
  );

  @override
  KernelHealth get health => KernelHealth.ready;

  @override
  String? get sessionId => null;

  @override
  Future<void> get stopped => Future.value();

  @override
  void prepare() {}

  @override
  void release() {}

  @override
  void restart() {}

  /// The models on offer: every model turned on in Settings → Models, on
  /// any upstream, named as Codex is told them (`<provider>/<model>`); the
  /// proxy reads that name to find the upstream.
  static List<KernelOption> _modelsOf() => [
    for (final provider in ModelProviders.current.enabled)
      for (final model in provider.enabledModels)
        KernelOption(
          '${provider.id}/${model.id}',
          model.displayName,
          Icons.bolt_rounded,
          [
            provider.name,
            model.id,
            if (model.contextWindow case final tokens?) formatTokens(tokens),
          ].join(' · '),
        ),
  ];

  /// Modes are its approval and sandbox policies.
  static const _modes = [
    KernelOption(
      'agent',
      'Agent',
      Icons.all_inclusive_rounded,
      'Edit the workspace, ask before commands',
    ),
    KernelOption(
      'ask',
      'Ask',
      Icons.chat_bubble_outline_rounded,
      'Read-only: answer questions',
    ),
  ];

  @override
  final List<KernelCommand> commands = const [
    KernelCommand(
      'review',
      'Review uncommitted changes',
      Icons.rate_review_outlined,
    ),
    KernelCommand(
      'compact',
      'Summarize the conversation',
      Icons.compress_rounded,
    ),
    KernelCommand(
      'init',
      'Write an AGENTS.md for this project',
      Icons.description_outlined,
    ),
    KernelCommand('diff', 'Show the git diff', Icons.difference_outlined),
    KernelCommand('new', 'Start a new chat', Icons.add_comment_outlined),
  ];

  @override
  int get contextWindow => 272000;

  /// How much it thinks before answering: as picked, else as the model's
  /// own. Codex's levels are its own (`none` through `persistent`), and the
  /// proxy reads one back as Claude's thinking budget.
  @override
  late final ModelSetting effort = _EffortSetting(
    selected: () => _effort,
    selectedFor: (model) => _pickedEfforts[model] ?? _effort,
    select: (model, id) {
      _pickedEfforts[model] = id;
      _effort = id;
      emitInfoChanged();
    },
  );

  String? _effort;
  final Map<String, String> _pickedEfforts = {};

  int _requests = 0;
  final Map<Object, Completer<Map<String, Object?>>> _responses = {};
  bool _initialized = false;
  String? _threadId;

  /// Ours, and the server's for the same turn once it says.
  String? _turn;
  String? _serverTurn;

  /// The server's turns, in order: `thread/revert` asks for the one to
  /// drop everything from.
  final List<String> _serverTurns = [];

  /// When [_turn] began, to time it.
  DateTime? _turnStarted;
  final Set<String> _sentTurns = {};

  final Map<String, int> _textLength = {};
  final Map<String, StringBuffer> _reasoning = {};
  final Map<String, Stopwatch> _reasoningClock = {};

  /// The part of each summary streaming in.
  final Map<String, int> _reasoningPart = {};
  final Map<String, DateTime> _startedAt = {};

  /// Commands started and not completed yet, as they started.
  final Map<String, Map<String, Object?>> _commands = {};

  /// Pending approvals: our request id → the server's JSON-RPC id, and
  /// the prefix it proposed if it proposed one.
  final Map<String, ({Object? id, List<Object?>? amendment})> _approvals = {};

  // --- Commands -------------------------------------------------------------

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) {
    final id = ++_requests;
    final response = Completer<Map<String, Object?>>();
    _responses[id] = response;
    _transport.write({'id': id, 'method': method, 'params': params});
    return response.future;
  }

  @override
  void send(KernelTurn turn) {
    if (!_sentTurns.add(turn.id)) return;
    _turn = turn.id;
    _turnStarted = DateTime.now();
    emit(TurnStarted(nextSeq, turn.id));
    emit(
      ItemUpserted(
        nextSeq,
        turn.id,
        UserMessageItem(text: turn.text, images: turn.images),
      ),
    );
    unawaited(_start(turn));
  }

  Future<void> _start(KernelTurn turn) async {
    try {
      if (!_initialized) {
        _initialized = true;
        await _request('initialize', {
          'clientInfo': {
            'name': 'baocode',
            'title': 'BaoCode',
            'version': '1.0.0',
          },
          // Nothing here is experimental: what this adapter reads is the
          // protocol's stable part (`plan`, `steer` and friends are not).
          'capabilities': {'experimentalApi': false},
        });
      }
      if (_threadId == null) {
        final started = await _request('thread/start', {
          'model': model.selected,
        });
        _threadId = (started['thread'] as Map)['id'] as String;
      }
      final readOnly = mode.selected == 'ask';
      final started = await _request('turn/start', {
        'threadId': _threadId,
        'input': [
          {'type': 'text', 'text': turn.text},
          for (final note in turn.notes) {'type': 'text', 'text': note},
        ],
        'model': model.selected,
        // Its thinking, as the level picked; the proxy reads it back as
        // Claude's thinking budget for the upstream.
        'effort': ?effort.selected,
        'approvalPolicy': readOnly ? 'never' : 'on-request',
        'sandboxPolicy': {'type': readOnly ? 'readOnly' : 'workspaceWrite'},
      });
      final serverId = (started['turn'] as Map)['id'] as String;
      _serverTurn ??= serverId;
      if (!_serverTurns.contains(serverId)) _serverTurns.add(serverId);
      // Stopped before the server knew the turn: stop it there too.
      if (_turn != turn.id) _interrupt();
    } on Object catch (error) {
      // The server refused the turn, or is gone: say so rather than wait.
      if (_turn == turn.id) {
        emit(
          ItemUpserted(
            nextSeq,
            'codex-error:${turn.id}',
            NoticeItem(NoticeKind.error, '$error'),
          ),
        );
        _endTurn(turn.id, interrupted: true);
      }
    }
  }

  void _interrupt() {
    final serverTurn = _serverTurn;
    if (serverTurn == null || _threadId == null) return;
    unawaited(
      _request('turn/interrupt', {'threadId': _threadId, 'turnId': serverTurn}),
    );
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {
    final pending = _approvals.remove(requestId);
    if (pending == null) return;
    emit(InteractionResolved(nextSeq, requestId));
    final amendment = pending.amendment;
    final Object decision = switch (answer) {
      ApprovalAnswer(decision: ApprovalDecision.allowOnce) => 'accept',
      // "Always allow": the server's own proposal is narrower than a
      // session-wide yes — it names the prefix it would approve — so use
      // it when it made one.
      ApprovalAnswer(decision: ApprovalDecision.allowAlways)
          when amendment != null =>
        {
          'acceptWithExecpolicyAmendment': {'execpolicy_amendment': amendment},
        },
      ApprovalAnswer(decision: ApprovalDecision.allowAlways) =>
        'acceptForSession',
      _ => 'decline',
    };
    _transport.write({
      'id': pending.id,
      'result': {'decision': decision},
    });
  }

  @override
  void cancel() {
    final turn = _turn;
    if (turn == null) return;
    _interrupt();
    _endTurn(turn, interrupted: true);
  }

  @override
  Future<bool> rewind({
    required String itemId,
    required int index,
    required int turns,
    String? lastSeen,
  }) async {
    final threadId = _threadId;
    if (threadId != null && turns > 0) {
      // The server keeps the history, and drops whole turns: the turn to
      // drop from is the one `turns` back.
      final at = _serverTurns.length - turns;
      if (at < 0 || at >= _serverTurns.length) return false;
      try {
        await _request('thread/revert', {
          'threadId': threadId,
          'beforeTurnId': _serverTurns[at],
        });
        _serverTurns.removeRange(at, _serverTurns.length);
      } on Object {
        return false;
      }
    }
    emit(Rewound(nextSeq, itemId: itemId, index: index));
    return true;
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    _transport.close();
    closeEvents();
  }

  // --- Translation ------------------------------------------------------------

  void _receive(Map<String, Object?> message) {
    final method = message['method'] as String?;
    final params = (message['params'] as Map?)?.cast<String, Object?>();
    if (method == null) {
      final response = _responses.remove(message['id']);
      if (response == null) return;
      // An error is an answer too: the caller waits for one either way.
      if (message['error'] case final Map<Object?, Object?> error) {
        response.completeError(
          CodexRequestError(
            '${error['message'] ?? 'the request failed'}',
            code: error['code'] as int?,
          ),
        );
        return;
      }
      final result = (message['result'] as Map?)?.cast<String, Object?>();
      response.complete(result ?? const {});
      return;
    }
    if (message.containsKey('id')) {
      _serverRequest(message['id'], method, params ?? const {});
      return;
    }
    switch (method) {
      case 'turn/started':
        final id = (params!['turn'] as Map)['id'] as String;
        _serverTurn = id;
        if (!_serverTurns.contains(id)) _serverTurns.add(id);
      case 'turn/completed':
        final turn = params!['turn'] as Map;
        if (turn['id'] != _serverTurn) return;
        _serverTurn = null;
        if (_turn case final ours?) {
          _endTurn(ours, interrupted: turn['status'] == 'interrupted');
        }
      case 'item/started':
        _itemStarted((params!['item'] as Map).cast<String, Object?>());
      case 'item/completed':
        _itemCompleted((params!['item'] as Map).cast<String, Object?>());
      case 'item/commandExecution/outputDelta':
        // What a command prints as it prints it, not only at the end.
        final id = params!['itemId'] as String;
        final item = _commands[id];
        if (item == null) return;
        final output =
            '${item['aggregatedOutput'] ?? ''}'
            '${params['delta'] ?? ''}';
        item['aggregatedOutput'] = output;
        emit(ItemUpserted(nextSeq, id, _commandItem(item)));
      case 'turn/plan/updated':
        // The model's own plan: the same list the todo panel shows.
        final plan = params!['plan'] as List? ?? const [];
        emit(
          TodosReported(nextSeq, [
            for (final raw in plan)
              if (raw is Map)
                TodoEntry('${raw['step'] ?? ''}', switch (raw['status']) {
                  'inProgress' => TodoStatus.inProgress,
                  'completed' => TodoStatus.completed,
                  _ => TodoStatus.pending,
                }),
          ]),
        );
      case 'thread/compacted':
        emit(
          ItemUpserted(
            nextSeq,
            'compaction:${params!['turnId']}',
            const NoticeItem(
              NoticeKind.compaction,
              'The conversation was summarized to free the context.',
            ),
          ),
        );
      case 'serverRequest/resolved':
        // Answered somewhere else (a timeout, another view): close it here.
        final id = params!['requestId'];
        if (_approvals.remove('approval:$id') == null) return;
        emit(InteractionResolved(nextSeq, 'approval:$id'));
      case 'warning' || 'configWarning' || 'guardianWarning':
        final said = params!['message'] ?? params['text'];
        final text = said is String && said.isNotEmpty ? said : '$params';
        // Every upstream model is one Codex has no metadata for: it says so
        // each thread, and its fallback is what the turn runs on either way.
        if (text.startsWith('Model metadata for `')) return;
        emit(
          ItemUpserted(
            nextSeq,
            'warning:$nextSeq',
            NoticeItem(NoticeKind.warning, text),
          ),
        );
      case 'item/reasoning/summaryTextDelta':
        final id = params!['itemId'] as String;
        final buffer = _reasoning[id];
        if (buffer == null) return;
        // Each part of the summary (its own bold title and text) apart from
        // the one before.
        final part = params['summaryIndex'] as int?;
        final separate =
            part != null && buffer.isNotEmpty && part != _reasoningPart[id];
        if (part != null) _reasoningPart[id] = part;
        final delta = '${separate ? '\n\n' : ''}${params['delta'] as String}';
        final offset = buffer.length;
        buffer.write(delta);
        emit(TextDelta(nextSeq, id, offset, delta, tokens: buffer.length));
      case 'item/agentMessage/delta':
        final id = params!['itemId'] as String;
        final offset = _textLength[id];
        if (offset == null) return;
        final delta = params['delta'] as String;
        _textLength[id] = offset + delta.length;
        emit(TextDelta(nextSeq, id, offset, delta));
      case 'thread/tokenUsage/updated':
        final usage = params!['tokenUsage'] as Map;
        emit(
          UsageReported(
            nextSeq,
            ContextUsage(
              window: usage['modelContextWindow'] as int? ?? contextWindow,
              // The last request's, which is what the context holds; the
              // total adds up every request, and never drops on compacting.
              used: (usage['last'] as Map)['totalTokens'] as int,
            ),
          ),
        );
    }
  }

  /// Every request the server can make while a turn runs has an answer:
  /// one left unanswered stops the turn where it stands.
  void _serverRequest(
    Object? rpcId,
    String method,
    Map<String, Object?> params,
  ) {
    switch (method) {
      case 'item/commandExecution/requestApproval' ||
          'item/fileChange/requestApproval':
        final title = method == 'item/commandExecution/requestApproval'
            ? 'Run command'
            : 'Apply changes';
        final preview = method == 'item/commandExecution/requestApproval'
            ? CommandPreview('${params['command']}') as ApprovalPreview?
            : null;
        final amendment = [
          for (final token
              in params['proposedExecpolicyAmendment'] as List? ?? const [])
            '$token',
        ];
        final id = 'approval:$rpcId';
        _approvals[id] = (
          id: rpcId,
          amendment: amendment.isEmpty ? null : amendment,
        );
        emit(
          InteractionRequested(
            nextSeq,
            ApprovalRequest(
              id: id,
              title: title,
              toolName: method.split('/')[1],
              reason: params['reason'] as String?,
              preview: preview,
              // What "always allow" would allow, when the server said.
              alwaysAllowLabel: amendment.isEmpty
                  ? 'Approve for this session'
                  : 'Always allow ${amendment.join(' ')}',
            ),
          ),
        );
      case 'item/permissions/requestApproval':
        // More than the turn was given: not offered from here. The model
        // is told, and carries on without it.
        _refuse(rpcId, 'BaoCode does not widen permissions mid-turn.');
      case 'item/tool/requestUserInput':
        _refuse(rpcId, 'BaoCode cannot put that question right now.');
      case 'mcpServer/elicitation/request':
        _transport.write({
          'id': rpcId,
          'result': {'action': 'decline'},
        });
      case 'item/tool/call':
        _transport.write({
          'id': rpcId,
          'result': {'contentItems': const [], 'success': false},
        });
      case 'execCommandApproval' || 'applyPatchApproval':
        // The older turn API's approval: a request it made is refused
        // rather than left waiting.
        _transport.write({
          'id': rpcId,
          'result': {'decision': 'denied'},
        });
      default:
        _refuse(rpcId, 'BaoCode does not handle $method.');
    }
  }

  void _refuse(Object? rpcId, String message) => _transport.write({
    'id': rpcId,
    'error': {'code': -32601, 'message': message},
  });

  void _itemStarted(Map<String, Object?> item) {
    final id = item['id'] as String;
    switch (item['type']) {
      case 'reasoning':
        _reasoning[id] = StringBuffer();
        _reasoningClock[id] = Stopwatch()..start();
        emit(
          ItemUpserted(
            nextSeq,
            id,
            ThinkingItem(text: '', tokens: 0, startedAt: DateTime.now()),
            streaming: true,
          ),
        );
      case 'agentMessage':
        _textLength[id] = 0;
        emit(
          ItemUpserted(
            nextSeq,
            id,
            const AssistantTextItem(''),
            streaming: true,
          ),
        );
      case 'commandExecution':
        _startedAt[id] = DateTime.now();
        _commands[id] = item;
        emit(ItemUpserted(nextSeq, id, _commandItem(item)));
    }
  }

  void _itemCompleted(Map<String, Object?> item) {
    final id = item['id'] as String;
    switch (item['type']) {
      case 'reasoning':
        final buffer = _reasoning.remove(id);
        final clock = _reasoningClock.remove(id)?..stop();
        _reasoningPart.remove(id);
        final text =
            buffer?.toString() ??
            (item['summary'] as List<Object?>? ?? const []).join('\n\n');
        emit(
          ItemCompleted(
            nextSeq,
            id,
            item: ThinkingItem(
              text: text,
              tokens: text.length,
              seconds: math.max(
                1,
                ((clock?.elapsedMilliseconds ?? 0) / 1000).round(),
              ),
            ),
          ),
        );
      case 'agentMessage':
        _textLength.remove(id);
        emit(
          ItemCompleted(
            nextSeq,
            id,
            item: AssistantTextItem(item['text'] as String),
          ),
        );
      case 'commandExecution':
        emit(ItemUpserted(nextSeq, id, _commandItem(item)));
        _startedAt.remove(id);
        _commands.remove(id);
      case 'fileChange':
        final changes = item['changes'] as List<Object?>;
        for (final (index, raw) in changes.indexed) {
          final change = raw as Map;
          _fileChange(
            '$id:$index',
            change['path'] as String,
            change['diff'] as String,
            kind: (change['kind'] as Map?)?['type'] as String?,
          );
        }
    }
  }

  /// A command as the history shows it: reads and searches as tool rows,
  /// anything else as a terminal.
  ChatItem _commandItem(Map<String, Object?> item) {
    final actions = [
      for (final action in item['commandActions'] as List<Object?>? ?? const [])
        (action as Map).cast<String, Object?>(),
    ];
    final output = item['aggregatedOutput'] as String?;
    final done = item['status'] == 'completed' || item['status'] == 'failed';
    if (actions.isNotEmpty && actions.every((a) => a['type'] == 'read')) {
      final path = actions.first['path'] as String;
      return ToolCallItem(
        kind: ToolKind.read,
        target: path.split('/').last,
        path: path,
      );
    }
    if (actions.isNotEmpty && actions.every((a) => a['type'] == 'search')) {
      final matches = [
        for (final line in (output ?? '').split('\n'))
          if (line.isNotEmpty) line.split(':').take(2).join(':'),
      ];
      return ToolCallItem(
        kind: ToolKind.grep,
        target: actions.first['query'] as String,
        detail: done ? '${matches.length} results' : null,
        results: matches,
      );
    }
    return TerminalItem(
      command: item['command'] as String,
      output: output ?? '',
      status: !done
          ? CommandStatus.running
          : item['exitCode'] == 0
          ? CommandStatus.succeeded
          : CommandStatus.failed,
      startedAt: _startedAt[item['id']],
    );
  }

  /// A unified diff as a diff card and a pending change. A file added or
  /// deleted ([kind]) has its whole text for a diff.
  void _fileChange(String id, String path, String diff, {String? kind}) {
    final lines = <DiffLine>[];
    var added = 0;
    var removed = 0;
    var oldLine = 1;
    var newLine = 1;
    final hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
    for (final line in diff.split('\n')) {
      if (hunk.firstMatch(line) case final match?) {
        oldLine = int.parse(match.group(1)!);
        newLine = int.parse(match.group(2)!);
        continue;
      }
      if (line.isEmpty) continue;
      final text = line.substring(1);
      switch (line[0]) {
        case '+':
          lines.add(DiffLine(DiffLineType.added, newLine++, text));
          added++;
        case '-':
          lines.add(DiffLine(DiffLineType.removed, oldLine++, text));
          removed++;
        default:
          lines.add(DiffLine(DiffLineType.context, newLine++, text));
          oldLine++;
      }
    }
    final slash = path.lastIndexOf('/');
    emit(
      ItemUpserted(
        nextSeq,
        id,
        CodeDiffItem(
          fileName: path.substring(slash + 1),
          directory: slash < 0 ? '' : path.substring(0, slash),
          lines: lines,
        ),
      ),
    );
    emit(
      FileEdited(
        nextSeq,
        FileChange(path: path, added: added, removed: removed),
        original: switch (kind) {
          'add' => const OriginalText(null),
          'delete' => OriginalText(diff),
          _ => OriginalByPatch(diff),
        },
      ),
    );
  }

  void _endTurn(String turn, {required bool interrupted}) {
    _turn = null;
    for (final id in [..._reasoning.keys]) {
      _itemCompleted({'type': 'reasoning', 'id': id});
    }
    for (final id in [..._textLength.keys]) {
      _textLength.remove(id);
      emit(ItemCompleted(nextSeq, id));
    }
    // A command stopped with its turn: it will not report its end.
    for (final item in [..._commands.values]) {
      _itemCompleted({...item, 'status': 'failed'});
    }
    for (final id in _approvals.keys) {
      emit(InteractionResolved(nextSeq, id));
    }
    _approvals.clear();
    emit(
      TurnEnded(
        nextSeq,
        turn,
        interrupted: interrupted,
        worked: switch (_turnStarted) {
          final started? => DateTime.now().difference(started),
          null => null,
        },
      ),
    );
  }
}

/// The thinking levels a model is offered, and the one in effect. Codex
/// takes an effort of its own (`turn/start`'s `effort`), which the proxy
/// reads back as Claude's thinking budget, so what an upstream model offers
/// is what Settings → Models says it does.
class _EffortSetting implements ModelSetting {
  _EffortSetting({
    required this._selected,
    required this._selectedFor,
    required this._select,
  });

  final String? Function() _selected;
  final String? Function(String model) _selectedFor;
  final void Function(String model, String id) _select;

  @override
  List<KernelOption> optionsFor(String model) {
    // The model's own levels, as Settings → Models has them: the id here is
    // Codex's (`<provider>/<model>`), which a model ref adds an `@` to.
    final levels = switch (ModelProviders.current.resolve('@$model')) {
      (_, final info) => info.effortLevels,
      null => const <String>[],
    };
    return [
      for (final level in levels)
        KernelOption(
          level,
          effortLabel(level),
          Icons.speed_rounded,
          switch (level) {
            'none' => 'No thinking',
            'minimal' => 'Least thinking',
            'low' => 'Fastest, least thinking',
            'medium' => 'Balanced',
            'high' => 'Thinks more',
            'xhigh' => 'Thinks a lot more',
            'max' => 'Most thinking',
            _ => '',
          },
        ),
    ];
  }

  @override
  String? get selected => _selected();

  @override
  String? selectedFor(String model) => _selectedFor(model);

  @override
  void select(String model, String id) => _select(model, id);

  @override
  bool get toggle => false;
}

/// What the server answered a request with: a JSON-RPC error, which the
/// protocol's own shapes say is an answer like any other.
class CodexRequestError implements Exception {
  const CodexRequestError(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => code == null ? message : '$message (code $code)';
}
