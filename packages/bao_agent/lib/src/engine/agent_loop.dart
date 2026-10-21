import 'dart:async';
import 'dart:math' as math;

import '../api/message_accumulator.dart';
import '../api/model_catalog.dart';
import '../api/model_client.dart';
import '../config/settings.dart';
import '../hooks/hooks.dart';
import '../permissions/approval_risk.dart';
import '../permissions/decision.dart';
import '../prompts/system_prompt.dart';
import '../prompts/task_prompts.dart';
import '../tools/tool.dart';
import '../util/cancel.dart';
import '../util/ids.dart';
import '../util/json.dart';
import 'agent_run.dart';
import 'approval_audit.dart';
import 'compaction.dart';
import 'compression_blocks.dart';
import 'repeat_guard.dart';
import 'session.dart';
import 'session_store.dart';
import 'transcript.dart';

/// The tools an agent has, by name.
class ToolSet {
  ToolSet(this.tools);

  final List<Tool> tools;

  Tool? find(String name) {
    for (final tool in tools) {
      if (tool.name == name || tool.aliases.contains(name)) return tool;
    }
    return null;
  }

  List<Map<String, Object?>> toApi(AgentSession session) => [
    for (final tool in tools) tool.toApi(session),
  ];
}

/// How an agent's turn ended.
class LoopResult {
  const LoopResult({
    required this.reason,
    required this.lastText,
    required this.requests,
    required this.usage,
    required this.apiDuration,
    this.error,
  });

  /// `end_turn`, `interrupted`, `error`, `max_turns`, `stopped`.
  final String reason;
  final String lastText;
  final int requests;

  /// The turn's tokens, all its requests together.
  final Map<String, Object?> usage;
  final Duration apiDuration;
  final String? error;

  bool get ok => reason == 'end_turn';
}

/// One call of a tool, as the model made it.
class _Call {
  _Call(this.id, this.name, this.input);

  final String id;
  final String name;
  Map<String, Object?> input;
  bool done = false;
}

/// What a request to the model came to.
class _Answer {
  _Answer(this.blocks, this.stopReason, this.usage);

  final List<Map<String, Object?>> blocks;
  final String? stopReason;
  final Map<String, Object?> usage;
}

/// An agent at work: the model asked, its tool calls weighed, run and
/// answered, until it ends its turn. The main agent's events stream to the
/// host; a subagent's messages go to the host under its call.
class AgentLoop {
  AgentLoop({
    required this.run,
    required this.tools,
    required this.system,
    required this.model,
    this.userContext,
    this.maxTurns,
    this.takeQueued,
  });

  /// The session whose services this run shares: its settings, hooks,
  /// permissions, tasks and the host it speaks to. Its context is not
  /// shared: that is [run]'s.
  AgentSession get session => run.session;

  final AgentRun run;
  final ToolSet tools;

  /// The conversation this run is on: its own, never another agent's.
  SessionStore get store => run.store;

  /// The system prompt's blocks.
  final List<String> system;

  /// The model's id.
  String model;

  /// Told the model with the conversation's first message (its memory
  /// files, the date): not kept in it.
  final String? userContext;
  final int? maxTurns;

  /// The messages sent while the turn runs, to be taken up between its
  /// tool calls (the main agent's).
  final List<Map<String, Object?>> Function()? takeQueued;

  bool get isMain => run.isMain;

  String? get _parent => run.parentToolUseId;

  /// The conversation's compaction, sized by the model it is with: a
  /// subagent's own conversation is its own, and is compacted too.
  Compaction _compaction() => Compaction(session, run, model: model);

  /// Goes on from the newest messages, where no summary could be made.
  /// Returns whether there was anything to go on from.
  Future<bool> _fallBack(CancelToken cancel, String reason) async {
    try {
      await _compaction().fallBack(
        trigger: 'auto',
        reason: reason,
        cancel: cancel,
      );
      return true;
    } on Cancelled {
      return false;
    }
  }

  /// What was found not to be taken by the model or its provider, and is
  /// not sent again.
  static final Set<String> _refusedThinking = {};
  static final Set<String> _refusedEffort = {};
  static final Set<String> _refusedDisplay = {};
  static final Set<String> _refusedContextEdits = {};
  static final Set<String> _refusedBetas = {};
  static final Map<String, int> _maxOutput = {};

  /// The betas asked for along with what they are for.
  static const _thinkingBeta = 'interleaved-thinking-2025-05-14';
  static const _contextBeta = 'context-management-2025-06-27';
  static const _effortBeta = 'effort-2025-11-24';

  final Map<String, Object?> _usage = {
    'input_tokens': 0,
    'cache_creation_input_tokens': 0,
    'cache_read_input_tokens': 0,
    'output_tokens': 0,
  };
  int _requests = 0;
  Duration _apiTime = Duration.zero;

  /// The calls refused, as the result reports them.
  final List<Map<String, Object?>> denials = [];
  String _lastText = '';

  /// The same call, over and over: said once at 3, 5 and 8 in a row.
  final RepeatGuard _repeats = RepeatGuard();

  /// Empty answers asked for again in this turn.
  int _emptyAnswers = 0;

  /// Runs the agent until it ends its turn.
  Future<LoopResult> runTurn(CancelToken cancel) async {
    _repeats.reset();
    var stopHookActive = false;
    var overflowRetries = 0;
    while (true) {
      if (cancel.isCancelled) return _interrupted(during: false);
      if (maxTurns != null && _requests >= maxTurns!) {
        return _result('max_turns');
      }
      if (overflowRetries == 0) {
        try {
          await _compaction().autoCompactIfNeeded(cancel);
        } on Cancelled {
          return _interrupted(during: false);
        }
      }
      final _Answer answer;
      try {
        answer = await _ask(cancel);
      } on Cancelled {
        return _interrupted(during: false);
      } on ApiError catch (error) {
        if (error.promptTooLong &&
            overflowRetries < session.settings.contextOverflowRetries) {
          overflowRetries++;
          try {
            if (await _compaction().compact(trigger: 'auto', cancel: cancel)) {
              continue;
            }
          } on Cancelled {
            return _interrupted(during: false);
          } on Object catch (summary) {
            // No summary either: the newest messages are what it goes on
            // from, rather than a turn ended by a conversation too long.
            if (await _fallBack(
              cancel,
              summary is ApiError && !summary.promptTooLong
                  ? 'summary_provider'
                  : 'summary_budget',
            )) {
              continue;
            }
          }
        }
        return _failed(_describe(error));
      } on MissingCredentials {
        return _failed(MissingCredentials.message);
      }
      overflowRetries = 0;
      final calls = [
        for (final block in answer.blocks)
          if (block['type'] == 'tool_use')
            _Call('${block['id']}', '${block['name']}', asMap(block['input'])),
      ];
      if (calls.isEmpty) {
        final saidSomething = answer.blocks.any(
          (block) =>
              block['type'] == 'tool_use' ||
              (block['type'] == 'text' &&
                  '${block['text'] ?? ''}'.trim().isNotEmpty),
        );
        // Nothing at all is worth asking for twice more; a refusal is not.
        if (!saidSomething &&
            answer.stopReason != 'refusal' &&
            answer.stopReason != 'max_tokens' &&
            _emptyAnswers < 2) {
          _emptyAnswers++;
          continue;
        }
        if (!saidSomething) {
          session.emitSystem('informational', {
            'level': 'warning',
            'content': 'The model returned no answer.',
          });
        }
        if (answer.stopReason == 'max_tokens') {
          session.emitSystem('informational', {
            'level': 'warning',
            'content': 'The answer was cut off at the model\'s output limit.',
          });
        }
        if (answer.stopReason == 'refusal') return _result('end_turn');
        final stop = await _stopHooks(stopHookActive, cancel);
        if (stop == null) return _interrupted(during: false);
        if (stop.stop) return _result('stopped');
        if (stop.blocked) {
          stopHookActive = true;
          _appendUser('Stop hook feedback:\n${stop.feedback}', meta: true);
          continue;
        }
        return _result('end_turn');
      }
      final stopped = await _runCalls(calls, cancel);
      if (cancel.isCancelled) return _interrupted(during: true, calls: calls);
      if (stopped) return _result('stopped');
      // Messages sent meanwhile join the turn here.
      for (final message
          in takeQueued?.call() ?? const <Map<String, Object?>>[]) {
        _appendQueued(message);
      }
    }
  }

  // --- Asking the model --------------------------------------------------------

  /// The request as it stands: the conversation, the tools, the system
  /// prompt, the model's settings.
  ModelRequest buildRequest({List<Map<String, Object?>>? messages}) {
    final info = session.catalog.info(model);
    final List<Map<String, Object?>> conversation;
    if (messages != null) {
      conversation = messages;
    } else {
      final view = store.apiConversation(withRefs: true);
      conversation = view.messages;
      run.apiRefs = view.refs;
    }
    _addContext(conversation);
    final cache = !_truthy(session.environment['DISABLE_PROMPT_CACHING']);
    final systemBlocks = [
      for (final (i, text) in system.indexed)
        if (text.trim().isNotEmpty)
          {
            'type': 'text',
            'text': text,
            if (cache && i == system.length - 1)
              'cache_control': {'type': 'ephemeral'},
          },
    ];
    final toolList = tools.toApi(session);
    if (cache && toolList.isNotEmpty) {
      toolList[toolList.length - 1] = {
        ...toolList.last,
        'cache_control': {'type': 'ephemeral'},
      };
    }
    if (cache) _markCache(conversation);
    if (messages == null) _nudgeIfGrown(conversation);
    final maxTokens = _maxTokens(info);
    final body = <String, Object?>{
      'model': model,
      'max_tokens': maxTokens,
      'system': systemBlocks,
      'messages': conversation,
      if (toolList.isNotEmpty) 'tools': toolList,
      ..._thinking(info, maxTokens),
    };
    return ModelRequest(body, betas: _betas(info, body));
  }

  static bool _truthy(String? value) =>
      value != null && value.isNotEmpty && value != '0' && value != 'false';

  int _maxTokens(ModelInfo info) {
    final env = asInt(session.environment['CLAUDE_CODE_MAX_OUTPUT_TOKENS']);
    final asked = env ?? info.outputUnlessAsked;
    final learned = _maxOutput[model];
    final capped = learned != null && learned < asked ? learned : asked;
    return _clampToContext(capped);
  }

  /// [asked], or less where the window leaves less room for it.
  ///
  /// The API refuses a request whose input and output together pass the
  /// window, and it refuses it before the model is asked, so a turn is lost
  /// and asked again smaller. A model's own default is its own size, not
  /// this conversation's, and a long one has less room left than that: what
  /// is sent is what the window has room for after the input, keeping a
  /// reserve free for the window's own slack and rounding.
  int _clampToContext(int asked) {
    // A subagent's window is its own model's.
    final window = session.compactWindowOf(model);
    final input =
        estimateTokens(store.apiMessages()) +
        estimateTokens([
          [
            for (final text in system) {'text': text},
          ],
        ]);
    final reserve = math.max(4096, (window * 0.01).ceil());
    final room = window - input - reserve;
    if (room <= 0) return asked;
    return asked < room ? asked : room;
  }

  Map<String, Object?> _thinking(ModelInfo info, int maxTokens) {
    final out = <String, Object?>{};
    final chosen = run.isMain || run.agentType != 'Explore'
        ? session.effectiveEffort
        : null;
    // None chosen: a known model's own, said (what the API takes for none
    // is higher than some models are best at).
    final effort = chosen ?? info.effortUnlessAsked;
    final thinkingOn = session.settings.alwaysThinkingEnabled;
    if (!_refusedThinking.contains(model)) {
      switch (info.thinking) {
        case ThinkingStyle.adaptive:
          if ((thinkingOn == false || effort == 'none') &&
              info.canDisableThinking) {
            out['thinking'] = {'type': 'disabled'};
          } else if (thinkingOn != false) {
            out['thinking'] = {'type': 'adaptive'};
          }
        case ThinkingStyle.budget:
          // On unless turned off: all the output can spare, unless a
          // lower effort was chosen.
          if (thinkingOn != false && effort != 'none' && maxTokens > 1024) {
            final budget =
                asInt(session.environment['MAX_THINKING_TOKENS']) ??
                switch (chosen) {
                  'low' => 4000,
                  'medium' => 10000,
                  _ => 31999,
                };
            out['thinking'] = {
              'type': 'enabled',
              'budget_tokens': budget.clamp(1024, maxTokens - 1),
            };
          }
        case ThinkingStyle.none:
          // A provider's model: only what the user turned on.
          if (!info.known && thinkingOn == true) {
            out['thinking'] = {
              'type': 'enabled',
              'budget_tokens': (maxTokens ~/ 2).clamp(1024, 16000),
            };
          }
      }
    }
    final thinks = switch (out['thinking']) {
      {'type': final String type} => type != 'disabled',
      _ => false,
    };
    // Its thinking as the host asked to see it (summarized, or left out).
    if (session.options.thinkingDisplay case final display?
        when thinks && info.known && !_refusedDisplay.contains(model)) {
      out['thinking'] = {...asMap(out['thinking']), 'display': display};
    }
    // The thinking of earlier turns kept as it was: what was cached still
    // matches.
    if (thinks &&
        info.known &&
        !_refusedContextEdits.contains(model) &&
        !_refusedBetas.contains(model)) {
      out['context_management'] = {
        'edits': [
          {'type': 'clear_thinking_20251015', 'keep': 'all'},
        ],
      };
    }
    final alwaysEffort = _truthy(
      session.environment['CLAUDE_CODE_ALWAYS_ENABLE_EFFORT'],
    );
    if (effort != null &&
        effort != 'none' &&
        !_refusedEffort.contains(model) &&
        (info.takesEffort(effort) || alwaysEffort)) {
      out['output_config'] = {'effort': effort};
    }
    return out;
  }

  List<String> _betas(ModelInfo info, Map<String, Object?> body) {
    final betas = <String>[
      for (final beta in (session.environment['ANTHROPIC_BETAS'] ?? '').split(
        ',',
      ))
        if (beta.trim().isNotEmpty) beta.trim(),
    ];
    // What the request uses of the API's betas, for a model known (one
    // not may be on a provider that knows none).
    if (info.known && !_refusedBetas.contains(model)) {
      if (body['thinking'] case {'type': final String type}
          when type != 'disabled') {
        betas.add(_thinkingBeta);
      }
      if (body.containsKey('context_management')) betas.add(_contextBeta);
      if (body.containsKey('output_config')) betas.add(_effortBeta);
    }
    // The million-token window of the 4.x models that need asking for it.
    if (session.longContext && isMain && info.asksForLongContext) {
      betas.add('context-1m-2025-08-07');
    }
    return betas;
  }

  /// Tells the model of its context with the first message, and of plan
  /// mode with the last.
  void _addContext(List<Map<String, Object?>> conversation) {
    if (conversation.isEmpty) return;
    final context = userContext;
    if (context != null && context.trim().isNotEmpty) {
      final first = conversation.first;
      conversation[0] = {
        ...first,
        'content': [
          {'type': 'text', 'text': context},
          ..._asBlocks(first['content']),
        ],
      };
    }
    if (isMain && session.permissionMode == 'plan') {
      final last = conversation.last;
      if (last['role'] == 'user') {
        final path = session.planFilePath;
        conversation[conversation.length - 1] = {
          ...last,
          'content': [
            ..._asBlocks(last['content']),
            {
              'type': 'text',
              'text': planModeReminder(
                planFile: path,
                exists: session.planExists,
              ),
            },
          ],
        };
      }
    }
  }

  static List<Map<String, Object?>> _asBlocks(Object? content) =>
      switch (content) {
        final String text => [
          {'type': 'text', 'text': text},
        ],
        final List<Object?> blocks => [for (final b in blocks) asMap(b)],
        _ => const [],
      };

  /// Tells the model, once its context has grown by a good deal, that it
  /// can fold what it no longer needs. It is added to this request only:
  /// the conversation keeps no line of it.
  void _nudgeIfGrown(List<Map<String, Object?>> conversation) {
    final settings = session.settings;
    if (!settings.contextManagementEnabled ||
        !settings.contextCompressEnabled ||
        settings.contextNudgeTokens <= 0 ||
        conversation.isEmpty) {
      return;
    }
    final tokens = estimateTokens(conversation);
    // A fold made the context smaller: measure the next growth from there.
    if (tokens < run.lastNudgeTokens) run.lastNudgeTokens = tokens;
    if (tokens - run.lastNudgeTokens < settings.contextNudgeTokens) return;
    run.lastNudgeTokens = tokens;
    conversation.add({
      'role': 'user',
      'content': [
        {
          'type': 'text',
          'text':
              '<system-reminder>\nThe conversation holds about $tokens '
              'tokens. If earlier turns are no longer needed, fold a range '
              'with compress (the m… refs mark the user messages); '
              'search_context finds words in folded ranges, and acp_status '
              'shows what is folded.\n</system-reminder>',
        },
      ],
    });
  }

  /// Marks where the cache ends: the last message, and the user's message
  /// before it (so the next turn reads what this one wrote).
  static void _markCache(List<Map<String, Object?>> conversation) {
    var marked = 0;
    for (var i = conversation.length - 1; i >= 0 && marked < 2; i--) {
      final message = conversation[i];
      if (i != conversation.length - 1 && message['role'] != 'user') continue;
      final blocks = _asBlocks(message['content']);
      if (blocks.isEmpty) continue;
      final lastIndex = blocks.lastIndexWhere(
        (b) => b['type'] != 'thinking' && b['type'] != 'redacted_thinking',
      );
      if (lastIndex < 0) continue;
      blocks[lastIndex] = {
        ...blocks[lastIndex],
        'cache_control': {'type': 'ephemeral'},
      };
      conversation[i] = {...message, 'content': blocks};
      marked++;
    }
  }

  Future<_Answer> _ask(CancelToken cancel) async {
    var attempts = 0;
    while (true) {
      attempts++;
      final request = buildRequest();
      try {
        return await _stream(request, cancel);
      } on ApiError catch (error) {
        // A model the provider does not have (a subagent's `haiku`): the
        // session's own.
        if (error.status == 404 &&
            model != session.resolvedModel &&
            attempts <= 3) {
          model = session.resolvedModel;
          continue;
        }
        if (attempts > 3 || error.status != 400) {
          if (error.authentication &&
              session.settings.apiKeyHelper != null &&
              attempts == 1) {
            session.resetClient();
            continue;
          }
          rethrow;
        }
        // What this model or provider does not take: asked again without.
        final message = error.message.toLowerCase();
        if (message.contains('beta') &&
            request.betas.any(
              (beta) => const [
                _thinkingBeta,
                _contextBeta,
                _effortBeta,
              ].contains(beta),
            ) &&
            !_refusedBetas.contains(model)) {
          _refusedBetas.add(model);
          continue;
        }
        if ((message.contains('context_management') ||
                message.contains('clear_thinking')) &&
            request.body.containsKey('context_management')) {
          _refusedContextEdits.add(model);
          continue;
        }
        if (message.contains('display') &&
            asMap(request.body['thinking']).containsKey('display')) {
          _refusedDisplay.add(model);
          continue;
        }
        if (message.contains('thinking') && !_refusedThinking.contains(model)) {
          _refusedThinking.add(model);
          continue;
        }
        if ((message.contains('effort') || message.contains('output_config')) &&
            !_refusedEffort.contains(model)) {
          _refusedEffort.add(model);
          continue;
        }
        if (message.contains('max_tokens') &&
            (_maxOutput[model] ?? 1 << 30) > 8192) {
          final limit = RegExp(r'(\d{4,6})')
              .allMatches(error.message)
              .map((m) => int.parse(m[1]!))
              .where(
                (n) => n >= 1024 && n < (request.body['max_tokens'] as int),
              )
              .fold<int?>(null, (a, b) => a == null || b < a ? b : a);
          _maxOutput[model] = limit ?? 8192;
          continue;
        }
        rethrow;
      }
    }
  }

  Future<_Answer> _stream(ModelRequest request, CancelToken cancel) async {
    if (isMain) session.emitSystem('status', {'status': 'requesting'});
    final started = DateTime.now();
    var accumulator = MessageAccumulator();
    final written = <String>[];
    final blocks = <Map<String, Object?>>[];
    try {
      await for (final event in session.client.stream(
        request,
        cancel: cancel,
        onRetry: (info) => session.emitSystem('api_retry', {
          'attempt': info.attempt,
          'max_retries': info.maxRetries,
          'retry_delay_ms': info.delay.inMilliseconds,
          'error_status': ?info.status,
          'error': ?info.message,
        }),
      )) {
        if (event['type'] == 'stream_restart') {
          // What was kept of the answer cut off is gone with it.
          if (written.isNotEmpty) store.rewindTo(written.first);
          written.clear();
          blocks.clear();
          accumulator = MessageAccumulator();
          continue;
        }
        if (isMain) {
          session.emit({
            'type': 'stream_event',
            'event': event,
            'parent_tool_use_id': null,
            'uuid': newUuid(),
          });
        }
        final finished = accumulator.add(event);
        if (finished != null) {
          blocks.add(finished.block);
          written.add(_keepBlock(accumulator, finished.block));
        }
      }
    } on Cancelled {
      _countUsage(accumulator, started);
      rethrow;
    }
    _countUsage(accumulator, started);
    // This run's context is what it says: the main agent's is the
    // session's (see AgentSession.lastUsage); a subagent's is its own.
    run.lastUsage = {...accumulator.usage};
    run.requested = true;
    for (final block in blocks) {
      if (block['type'] == 'text') {
        final text = '${block['text'] ?? ''}'.trim();
        if (text.isNotEmpty) _lastText = text;
      }
    }
    return _Answer(blocks, accumulator.stopReason, accumulator.usage);
  }

  void _countUsage(MessageAccumulator accumulator, DateTime started) {
    if (!accumulator.started) return;
    _requests++;
    _apiTime += DateTime.now().difference(started);
    final usage = accumulator.usage;
    for (final key in _usage.keys) {
      _usage[key] = (asInt(_usage[key]) ?? 0) + (asInt(usage[key]) ?? 0);
    }
    session.addUsage(accumulator.model ?? model, usage);
    run.tokens +=
        (asInt(usage['input_tokens']) ?? 0) +
        (asInt(usage['cache_read_input_tokens']) ?? 0) +
        (asInt(usage['cache_creation_input_tokens']) ?? 0) +
        (asInt(usage['output_tokens']) ?? 0);
  }

  /// Keeps [block] of the answer in the conversation and tells the host:
  /// one message a block, as Claude Code writes them. Returns its line's
  /// id.
  String _keepBlock(
    MessageAccumulator accumulator,
    Map<String, Object?> block,
  ) {
    Map<String, Object?> messageOf(Map<String, Object?> block) => {
      'id': accumulator.id,
      'type': 'message',
      'role': 'assistant',
      'model': accumulator.model ?? model,
      'content': [block],
      'stop_reason': null,
      'stop_sequence': null,
      'usage': {...accumulator.usage},
    };
    final entry = store.append({
      'type': 'assistant',
      'message': messageOf(block),
      'requestId': ?accumulator.requestId,
      if (!isMain) ...{'agentId': run.agentId, 'isSidechain': true},
    });
    var shown = block;
    if (block['type'] == 'tool_use') {
      if (tools.find('${block['name']}') case final tool?) {
        final input = _safelyMap(
          () => tool.observableInput(asMap(block['input']), session),
        );
        if (input != null) shown = {...block, 'input': input};
      }
    }
    session.emit({
      'type': 'assistant',
      'message': messageOf(shown),
      'parent_tool_use_id': _parent,
      'uuid': entry['uuid'],
    });
    if (block['type'] == 'tool_use') {
      run.toolUses++;
      run.lastTool = '${block['name']}';
      run.onToolUse?.call('${block['name']}');
    }
    return entry['uuid'] as String;
  }

  /// Ends the turn with what went wrong said, as the model would say it.
  LoopResult _failed(String error) {
    final message = {
      'id': 'msg_${randomId(20)}',
      'type': 'message',
      'role': 'assistant',
      'model': '<synthetic>',
      'content': [
        {'type': 'text', 'text': error},
      ],
      'stop_reason': 'stop_sequence',
      'stop_sequence': '',
      'usage': const {'input_tokens': 0, 'output_tokens': 0},
    };
    final entry = store.append({
      'type': 'assistant',
      'message': message,
      'isApiErrorMessage': true,
      if (!isMain) ...{'agentId': run.agentId, 'isSidechain': true},
    });
    // The main agent's error is the result's to tell.
    if (!isMain) {
      session.emit({
        'type': 'assistant',
        'message': message,
        'parent_tool_use_id': _parent,
        'uuid': entry['uuid'],
        'error': 'api_error',
      });
    }
    return _result('error', error: error);
  }

  static String _describe(ApiError error) {
    if (error.promptTooLong) return 'Prompt is too long';
    final action = error.action;
    return action.isEmpty ? error.toString() : '${error.toString()} · $action';
  }

  LoopResult _result(String reason, {String? error}) => LoopResult(
    reason: reason,
    lastText: _lastText,
    requests: _requests,
    usage: {..._usage},
    apiDuration: _apiTime,
    error: error,
  );

  /// The turn was stopped: the calls left unanswered are answered as
  /// stopped, and the model told.
  LoopResult _interrupted({
    required bool during,
    List<_Call> calls = const [],
  }) {
    for (final call in calls) {
      if (call.done) continue;
      call.done = true;
      _appendResult(
        call,
        const ToolOutput('The user interrupted this tool call.', isError: true),
        emitResult: false,
      );
    }
    _appendUser(
      during
          ? '[Request interrupted by user for tool use]'
          : '[Request interrupted by user]',
      emitIt: false,
    );
    return _result('interrupted');
  }

  // --- Messages kept --------------------------------------------------------------

  Map<String, Object?> _appendUser(
    String text, {
    bool meta = false,
    bool emitIt = true,
  }) {
    final entry = store.append({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
      if (meta) 'isMeta': true,
      if (!isMain) ...{'agentId': run.agentId, 'isSidechain': true},
    });
    if (emitIt) {
      session.emit({
        'type': 'user',
        'message': entry['message'],
        'parent_tool_use_id': _parent,
        'uuid': entry['uuid'],
        if (meta) 'isMeta': true,
      });
    }
    return entry;
  }

  /// A message sent while the turn ran, taken up now.
  void _appendQueued(Map<String, Object?> message) {
    // A new user message is a new attempt: the same call may be the right
    // one again.
    _repeats.reset();
    final uuid = asString(message['uuid']) ?? newUuid();
    session.emit({
      'type': 'command_lifecycle',
      'command_uuid': uuid,
      'state': 'started',
    });
    final entry = store.append({
      'type': 'user',
      'message': asMap(message['message']),
      'uuid': uuid,
    });
    session.checkpoints.begin(uuid);
    session.emit({
      'type': 'user',
      'message': entry['message'],
      'parent_tool_use_id': null,
      'uuid': uuid,
      'isReplay': true,
      'timestamp': entry['timestamp'],
    });
  }

  void _appendResult(_Call call, ToolOutput output, {bool emitResult = true}) {
    final content = output.content;
    final block = <String, Object?>{
      'type': 'tool_result',
      'tool_use_id': call.id,
      'content': content is String && content.isEmpty ? '(no output)' : content,
      if (output.isError) 'is_error': true,
    };
    final entry = store.append({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [block],
      },
      'toolUseResult': ?output.result,
      if (!isMain) ...{'agentId': run.agentId, 'isSidechain': true},
    });
    _offloadIfLarge(call, output);
    if (emitResult) {
      session.emit({
        'type': 'user',
        'message': entry['message'],
        'parent_tool_use_id': _parent,
        'uuid': entry['uuid'],
        'tool_use_result': ?output.result,
      });
    }
    for (final followUp in output.followUp) {
      final extra = store.append({
        'type': 'user',
        'message': {'role': 'user', 'content': followUp['content']},
        if (followUp['isMeta'] == true) 'isMeta': true,
        if (!isMain) ...{'agentId': run.agentId, 'isSidechain': true},
      });
      session.emit({
        'type': 'user',
        'message': extra['message'],
        'parent_tool_use_id': _parent,
        'uuid': extra['uuid'],
        if (followUp['isMeta'] == true) 'isMeta': true,
      });
    }
  }

  /// A result too large to keep in the context is sent as a placeholder
  /// from now on; the file keeps it, and retrieve_tool_result reads it.
  /// The event for this call has the whole of it: the user sees what the
  /// tool returned.
  void _offloadIfLarge(_Call call, ToolOutput output) {
    final settings = session.settings;
    if (!settings.contextManagementEnabled ||
        settings.contextCcrMinTokens <= 0) {
      return;
    }
    if (contextToolNames.contains(call.name)) return;
    if (!_textOnly(output.content)) return;
    final text = output.text;
    final tokens = estimateTokens(text);
    if (tokens < settings.contextCcrMinTokens) return;
    final previewChars = settings.contextCcrPreviewChars;
    final headChars = previewChars <= 1
        ? previewChars
        : (previewChars / 2).ceil();
    final tailChars = previewChars - headChars;
    final preview = headChars <= 0
        ? ''
        : text.substring(0, math.min(text.length, headChars));
    final tail = tailChars <= 0 || text.length <= headChars + tailChars
        ? ''
        : text.substring(text.length - tailChars);
    store.append(
      OffloadedResult(
        toolUseId: call.id,
        tokens: tokens,
        preview: preview,
        tail: tail,
      ).entry(logicalParentUuid: store.leaf),
    );
    // The last request's count included what is now a placeholder: the
    // next one is smaller, and measuring from the old count would compact
    // for room that was already made.
    run.lastUsage = null;
  }

  /// Whether a result is words: an image or a document is sent as it is.
  static bool _textOnly(Object? content) {
    if (content is String) return true;
    for (final raw in asList(content)) {
      if (asMap(raw)['type'] != 'text') return false;
    }
    return true;
  }

  // --- Tool calls -------------------------------------------------------------------

  /// Runs [calls]: those that may run together at once, the others in
  /// turn. Returns whether a hook stopped the turn.
  Future<bool> _runCalls(List<_Call> calls, CancelToken cancel) async {
    final groups = <List<_Call>>[];
    var groupSafe = false;
    for (final call in calls) {
      final tool = tools.find(call.name);
      final safe =
          tool != null && _safely(() => tool.isConcurrencySafe(call.input));
      if (safe && groupSafe && groups.isNotEmpty) {
        groups.last.add(call);
      } else {
        groups.add([call]);
      }
      groupSafe = safe;
    }
    var stopped = false;
    for (final group in groups) {
      if (cancel.isCancelled) break;
      if (group.length == 1) {
        if (await _runCall(group.single, cancel)) stopped = true;
      } else {
        final results = await Future.wait([
          for (final call in group) _runCall(call, cancel),
        ]);
        if (results.any((r) => r)) stopped = true;
      }
      if (stopped) break;
    }
    return stopped;
  }

  static Map<String, Object?>? _safelyMap(
    Map<String, Object?> Function() make,
  ) {
    try {
      return make();
    } on Object {
      return null;
    }
  }

  static bool _safely(bool Function() test) {
    try {
      return test();
    } on Object {
      return false;
    }
  }

  /// Runs one call, from its checks to its answer. Returns whether a hook
  /// stopped the turn.
  Future<bool> _runCall(_Call call, CancelToken cancel) async {
    final tool = tools.find(call.name);
    final context = ToolContext(
      session: session,
      run: run,
      toolUseId: call.id,
      cancel: CancelToken(cancel),
      model: model,
    );
    ToolOutput output;
    var stop = false;
    try {
      if (tool == null) {
        output = ToolOutput.error(
          '<tool_use_error>There is no tool named ${call.name}.</tool_use_error>',
        );
      } else if (call.input.containsKey('_unparsed')) {
        output = ToolOutput.error(
          '<tool_use_error>The input was not valid JSON.</tool_use_error>',
        );
      } else {
        var input = coerceInput(tool.inputSchema, call.input);
        input = _safelyMap(() => tool.observableInput(input, session)) ?? input;
        final invalid =
            validateSchema(tool.inputSchema, input) ??
            await tool.validate(input, context);
        if (invalid != null) {
          output = ToolOutput.error(
            '<tool_use_error>$invalid</tool_use_error>',
          );
        } else {
          final verdict = await _authorize(tool, input, context);
          switch (verdict) {
            case PermissionAllow(:final updatedInput):
              input = updatedInput ?? input;
              call.input = input;
              output = await _execute(tool, input, context);
            case PermissionDeny(:final message, :final interrupt):
              denials.add({
                'tool_name': tool.name,
                'tool_use_id': call.id,
                'tool_input': input,
              });
              session.emitSystem('permission_denied', {
                'tool_use_id': call.id,
                'tool_name': tool.name,
                'message': message,
              });
              output = ToolOutput(message, isError: true);
              if (interrupt) cancel.cancel('denied');
            default:
              output = ToolOutput.error('Permission was not granted.');
          }
          if (verdict is PermissionDeny && verdict.reasonType == 'hookStop') {
            stop = true;
          }
        }
      }
    } on Cancelled {
      return false;
    }
    if (cancel.isCancelled && !call.done) {
      // Answered as stopped by [_interrupted].
      return false;
    }
    call.done = true;
    _appendResult(call, output);
    // The same call, again, is worth saying once; it is advice, not a stop.
    final reminder = _repeats.record(call.name, call.input);
    if (reminder != null) _appendUser(reminder, meta: true, emitIt: false);
    return stop;
  }

  Future<ToolOutput> _execute(
    Tool tool,
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    ToolOutput output;
    try {
      output = await callWithTimeout(
        () => tool.call(input, context),
        timeout: tool.timeout,
        cancel: context.cancel,
      );
    } on ToolFailure catch (failure) {
      output = ToolOutput.error(failure.message, result: failure.result);
    } on Cancelled {
      rethrow;
    } on Object catch (error) {
      output = ToolOutput.error('Error: $error');
    }
    final event = output.isError
        ? HookEvent.postToolUseFailure
        : HookEvent.postToolUse;
    if (session.hooks.has(event)) {
      final post = await session.hooks.run(
        event,
        {
          'tool_name': tool.name,
          'tool_input': input,
          'tool_use_id': context.toolUseId,
          if (output.isError)
            'error': output.text
          else
            'tool_response': output.result ?? output.text,
          if (!isMain) 'agent_id': run.agentId,
        },
        query: tool.name,
        cancel: context.cancel,
      );
      _notifyHookMessages(post);
      final notes = [
        if (post.blocked) '$event hook feedback:\n${post.blockReason}',
        ...post.additionalContext,
      ];
      if (notes.isNotEmpty) {
        output = ToolOutput(
          [
            ..._contentBlocks(output.content),
            for (final note in notes)
              {
                'type': 'text',
                'text': '<system-reminder>\n$note\n</system-reminder>',
              },
          ],
          isError: output.isError,
          result: output.result,
          followUp: output.followUp,
        );
      }
    }
    return output;
  }

  static List<Map<String, Object?>> _contentBlocks(Object content) =>
      switch (content) {
        final String text => [
          if (text.isNotEmpty) {'type': 'text', 'text': text},
        ],
        final List<Object?> blocks => [for (final b in blocks) asMap(b)],
        _ => [
          {'type': 'text', 'text': '$content'},
        ],
      };

  void _notifyHookMessages(HookOutcome outcome) {
    for (final message in [...outcome.systemMessages, ...outcome.errors]) {
      session.emitSystem('informational', {
        'level': outcome.errors.contains(message) ? 'warning' : 'notice',
        'content': message,
      });
    }
  }

  /// Whether [tool] may run with [input]: hooks, rules, the mode, the
  /// classifier, the user.
  Future<PermissionDecision> _authorize(
    Tool tool,
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    var current = input;
    PermissionDecision? decided;
    if (session.hooks.has(HookEvent.preToolUse)) {
      final pre = await session.hooks.run(
        HookEvent.preToolUse,
        {
          'tool_name': tool.name,
          'tool_input': input,
          'tool_use_id': context.toolUseId,
          if (!isMain) 'agent_id': run.agentId,
        },
        query: tool.name,
        cancel: context.cancel,
      );
      _notifyHookMessages(pre);
      if (pre.stop) {
        return PermissionDeny(
          pre.stopReason ?? 'A hook stopped the turn.',
          reasonType: 'hookStop',
        );
      }
      current = pre.updatedInput ?? input;
      if (pre.blocked || pre.decision == 'deny') {
        return PermissionDeny(
          pre.decisionReason ??
              pre.blockReason.trim().nullIfEmpty ??
              'Blocked by a PreToolUse hook',
          reasonType: 'hook',
        );
      }
      if (pre.decision == 'allow') {
        return PermissionAllow(updatedInput: current, reason: 'hook');
      }
      if (pre.decision == 'ask') {
        decided = PermissionAsk(
          message: pre.decisionReason,
          reasonType: 'hook',
        );
      }
    }
    final decision =
        decided ?? await session.permissions.check(tool, current, context);
    switch (decision) {
      case PermissionAllow(:final updatedInput, :final reason):
        return PermissionAllow(
          updatedInput: updatedInput ?? current,
          reason: reason,
        );
      case PermissionDeny():
        return decision;
      case PermissionAsk():
        return _askUser(tool, current, context, decision);
      case PermissionPassthrough(:final suggestions):
        return _askUser(
          tool,
          current,
          context,
          PermissionAsk(suggestions: suggestions),
        );
    }
  }

  Future<PermissionDecision> _askUser(
    Tool tool,
    Map<String, Object?> input,
    ToolContext context,
    PermissionAsk ask,
  ) async {
    final mode = run.permissionMode;
    final userOnly =
        ask.requiresUserInteraction || tool.requiresUserInteraction;
    if (mode == 'dontAsk' && !userOnly) {
      return PermissionDeny(
        'Permission to use ${tool.name} has not been granted, and the session '
        'does not ask (don\'t-ask mode).',
        reasonType: 'mode',
      );
    }
    final classifies =
        mode == 'auto' ||
        (mode == 'plan' && session.settings.useAutoModeDuringPlan == true);
    if (classifies &&
        !userOnly &&
        ask.classifierApprovable &&
        ask.matchedAskRule == null) {
      final verdict = await _classify(
        tool,
        input,
        context,
        plan: mode == 'plan',
      );
      if (verdict != null) return verdict;
    }
    if (session.hooks.has(HookEvent.permissionRequest)) {
      final hook = await session.hooks.run(
        HookEvent.permissionRequest,
        {
          'tool_name': tool.name,
          'tool_input': input,
          'tool_use_id': context.toolUseId,
          'permission_suggestions': ask.suggestions,
        },
        query: tool.name,
        cancel: context.cancel,
      );
      if (hook.permissionRequest case final answer?) {
        if (answer['behavior'] == 'allow') {
          return PermissionAllow(
            updatedInput: switch (answer['updatedInput']) {
              final Map<Object?, Object?> updated =>
                updated.cast<String, Object?>(),
              _ => input,
            },
            reason: 'hook',
          );
        }
        if (answer['behavior'] == 'deny') {
          return PermissionDeny(
            asString(answer['message']) ?? 'Denied by a PermissionRequest hook',
            reasonType: 'hook',
            interrupt: answer['interrupt'] == true,
          );
        }
      }
    }
    final audit = ApprovalAudit(session);
    final started = DateTime.now();
    audit.asked(tool.name, input, reason: ask.message);
    final risk = approvalRiskFor(tool.name, input);
    Duration elapsed() => DateTime.now().difference(started);
    final Map<String, Object?> response;
    try {
      response = await context.cancel.guard(
        session.hostRequest(
          'can_use_tool',
          {
            'tool_name': tool.name,
            'display_name': tool.name,
            'input': input,
            'tool_use_id': context.toolUseId,
            'permission_suggestions': ask.suggestions,
            'description': ?tool.describe(input),
            'decision_reason': ?ask.message,
            'decision_reason_type': ?ask.reasonType,
            'matched_ask_rule': ?ask.matchedAskRule,
            'classifier_approvable': ask.classifierApprovable,
            'requires_user_interaction': userOnly,
            'blocked_path': ?ask.blockedPath,
            'risk': risk.risk.name,
            if (risk.reversible != null) 'reversible': risk.reversible,
            'source': risk.source,
            if (!isMain) 'agent_id': run.agentId,
          },
          // A question to the user is the turn's point: it waits as long
          // as they take. A permission for a call is not: a host that
          // never answers must not hold the turn forever.
          timeout: userOnly ? null : session.settings.approvalTimeout,
        ),
      );
    } on HostRequestTimeout catch (error) {
      audit.decided(tool.name, 'denied', reason: 'timeout', elapsed: elapsed());
      return PermissionDeny(
        '${error.toString()}, so this call was not made. The user can '
        'answer it by asking again.',
        reasonType: 'timeout',
      );
    } on Cancelled {
      audit.decided(tool.name, 'cancelled', elapsed: elapsed());
      rethrow;
    } on Object catch (error) {
      audit.decided(tool.name, 'denied', reason: 'error', elapsed: elapsed());
      return PermissionDeny(
        'Permission could not be asked for: $error',
        reasonType: 'other',
      );
    }
    if (response['behavior'] == 'allow') {
      audit.decided(tool.name, 'allowed', elapsed: elapsed());
      _applyUpdates(asList(response['updatedPermissions']));
      return PermissionAllow(
        updatedInput: switch (response['updatedInput']) {
          final Map<Object?, Object?> updated when updated.isNotEmpty =>
            updated.cast<String, Object?>(),
          _ => input,
        },
        reason: 'user',
      );
    }
    final message = asText(response['message']);
    audit.decided(tool.name, 'denied', reason: message, elapsed: elapsed());
    return PermissionDeny(
      message ??
          'The user said no to this call, so it was not made (an edit, say, '
              'was not written). Stop here, and wait for the user to say how '
              'to go on.',
      reasonType: 'user',
      interrupt: response['interrupt'] == true,
    );
  }

  /// Applies what the user allowed from now on.
  void _applyUpdates(List<Object?> updates) {
    for (final raw in updates) {
      final update = asMap(raw);
      final destination =
          SettingsSource.parse(update['destination']) ?? SettingsSource.session;
      switch (update['type']) {
        case 'addRules' || 'replaceRules':
          final rules = [
            for (final rule in asList(update['rules'])) ruleString(asMap(rule)),
          ];
          final behavior = asString(update['behavior']) ?? 'allow';
          session.settings.addRules(rules, behavior, destination);
          session.reloadSettings();
        case 'setMode':
          if (asString(update['mode']) case final mode?) {
            session.setPermissionMode(mode);
          }
        case 'addDirectories':
          final dirs = [...asList(update['directories']).whereType<String>()];
          session.sessionDirectories.addAll(dirs);
          if (destination != SettingsSource.session) {
            session.settings.addDirectories(dirs, destination);
            session.reloadSettings();
          }
      }
    }
  }

  /// Auto mode's classifier on a call: allowed, refused, or null to ask
  /// the user (it could not tell).
  Future<PermissionDecision?> _classify(
    Tool tool,
    Map<String, Object?> input,
    ToolContext context, {
    required bool plan,
  }) async {
    try {
      final transcript = transcriptText(store.apiMessages(), maxChars: 12000);
      final action =
          '${tool.name}: ${_actionText(input)}'
          '${plan ? '\n(The session is in plan mode: only actions that change nothing may be allowed.)' : ''}';
      final answer = await session.quickQuery(
        system: classifierSystem,
        prompt: classifierPrompt(transcript, action),
        model: session.resolvedModel,
        cancel: context.cancel,
        maxTokens: 400,
      );
      final json = extractJson(answer);
      switch (json['decision']) {
        case 'allow':
          return PermissionAllow(updatedInput: input, reason: 'classifier');
        case 'block':
          return PermissionDeny(
            'Blocked by auto mode: ${asText(json['reason']) ?? 'this action could be risky'}. '
            'Find a safer way, or ask the user to run it themselves.',
            reasonType: 'classifier',
          );
      }
    } on Cancelled {
      rethrow;
    } on Object {
      // Asked of the user instead.
    }
    return null;
  }

  static String _actionText(Map<String, Object?> input) {
    final text = input.entries
        .where((e) => e.key != 'content' || '${e.value}'.length < 2000)
        .map((e) => '${e.key}: ${e.value}')
        .join('\n');
    return text.length > 4000 ? '${text.substring(0, 4000)}…' : text;
  }

  // --- Stopping ---------------------------------------------------------------------

  /// The Stop (or SubagentStop) hooks' say on ending the turn; null when
  /// the turn was stopped meanwhile.
  Future<HookOutcome?> _stopHooks(bool active, CancelToken cancel) async {
    final event = isMain ? HookEvent.stop : HookEvent.subagentStop;
    if (!session.hooks.has(event)) return HookOutcome.empty;
    try {
      final outcome = await session.hooks.run(
        event,
        {
          'stop_hook_active': active,
          if (!isMain) ...{
            'agent_id': run.agentId,
            'agent_type': run.agentType,
          },
          'last_assistant_message': _lastText,
        },
        query: isMain ? null : run.agentType,
        cancel: cancel,
      );
      _notifyHookMessages(outcome);
      return outcome;
    } on Cancelled {
      return null;
    }
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
