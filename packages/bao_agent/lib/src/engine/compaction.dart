import 'dart:math' as math;

import '../api/message_accumulator.dart';
import '../api/model_client.dart';
import '../hooks/hooks.dart';
import '../prompts/task_prompts.dart';
import '../util/cancel.dart';
import '../util/json.dart';
import 'agent_run.dart';
import 'compression_blocks.dart';
import 'session.dart';
import 'session_store.dart';
import 'transcript.dart';

/// Sums the conversation up when it fills the model's context, and goes on
/// from the summary: a boundary in the session's file, then the summary as
/// the conversation's first message.
///
/// A summary that cannot be made does not end the turn: the conversation is
/// cut back to the messages that last passed and goes on from them, with
/// the boundary saying so. The whole of it stays in the file either way.
class Compaction {
  Compaction(this.session, this.run, {String? model})
    : model = model ?? session.resolvedModel;

  final AgentSession session;

  /// The agent whose conversation this is: its own, for a subagent. What
  /// is counted, cut and carried over is this run's, none other's.
  final AgentRun run;

  /// The model the conversation is with: a subagent's own, else the
  /// session's. Its window is the one the conversation is sized by.
  final String model;

  /// Whether this is the main agent's conversation: a subagent's is kept
  /// apart, sized by its own model, and says nothing to the host.
  bool get isMain => run.isMain;

  /// The subagent whose conversation this is, if one.
  String? get agentId => run.agentId;

  static const _system =
      'You write the summary of a conversation between a user and a coding '
      'agent, for the work to go on from.';

  /// Whether the conversation is compacted when full.
  bool get autoEnabled {
    bool on(String key) {
      final value = session.environment[key];
      return value != null &&
          value.isNotEmpty &&
          value != '0' &&
          value != 'false';
    }

    return session.settings['autoCompactEnabled'] != false &&
        !on('DISABLE_AUTO_COMPACT') &&
        !on('DISABLE_COMPACT');
  }

  /// How full this run's context is: the last request's, and what was
  /// added since. None but this run's own: a subagent's is not the main
  /// agent's, nor another subagent's.
  int usedTokens() {
    final messages = run.store.apiMessages();
    final usage = run.lastUsage;
    if (usage == null) return estimateTokens(messages);
    int count(String key) => asInt(usage[key]) ?? 0;
    final sent =
        count('input_tokens') +
        count('cache_read_input_tokens') +
        count('cache_creation_input_tokens');
    // A provider that reported no input at all says nothing about what the
    // conversation holds; the estimate is the only baseline there is.
    if (sent <= 0) return estimateTokens(messages);
    final lastAnswer = messages.lastIndexWhere((m) => m['role'] == 'assistant');
    final since = lastAnswer < 0 ? messages : messages.sublist(lastAnswer + 1);
    return sent + count('output_tokens') + estimateTokens(since);
  }

  /// The window this conversation is sized by.
  int get contextWindow => session.compactWindowOf(model);

  /// The tokens the context holds before it is compacted: the window less
  /// room for the model's answer (at most 21K) and 13K more for what a
  /// request adds, and never less than half the window.
  int get threshold => thresholdOf(
    contextWindow,
    maxOutput: session.catalog.info(model).maxOutput,
  );

  /// The compaction threshold of a [window], keeping room for an answer of
  /// [maxOutput] tokens. With no answer size known, the session's buffer
  /// is kept instead.
  static int thresholdOf(int window, {int maxOutput = 0}) {
    final reserve = maxOutput > 0
        ? math.min(maxOutput, _answerReserve) + _requestReserve
        : AgentSession.compactBufferOf(window);
    return math.max((window * 0.5).round(), window - reserve);
  }

  /// The room this conversation keeps free before it is compacted: what the
  /// threshold leaves of the window.
  int get reserve => (contextWindow - threshold).clamp(0, contextWindow);

  /// The reserve of a [window], for a caller that has only the window.
  static int reserveOf(int window, {int maxOutput = 0}) =>
      (window - thresholdOf(window, maxOutput: maxOutput)).clamp(0, window);

  /// The most of a window a model's answer is given.
  static const _answerReserve = 21000;

  /// What a request adds besides the answer itself.
  static const _requestReserve = 13000;

  /// How many auto compactions in a row may make no summary before the
  /// conversation is no longer put to the model for one: a provider that
  /// cannot answer would otherwise be asked again every turn.
  static const maxConsecutiveFailures = 3;

  /// The newest tool-result groups whose results are never cleared: what
  /// is being worked on now.
  static const _microKeepGroups = 5;

  /// What a microcompaction must save to be worth a boundary in the file.
  int get _microMinSaved => math.max(2000, contextWindow ~/ 50);

  /// The tools whose old output is cleared: what is read or run, not the
  /// agent's own reports (a subagent's, a task's).
  static const _clearableTools = {
    'Read',
    'Bash',
    'Grep',
    'Glob',
    'WebSearch',
    'WebFetch',
    'Edit',
    'Write',
  };

  /// The results a call returned, grouped by the call: an assistant message
  /// that called tools starts a group, and the user messages after it hold
  /// what those calls returned. Oldest first; a call and its results are
  /// never separated.
  static List<List<Map<String, Object?>>> _toolResultGroups(
    List<Map<String, Object?>> messages,
  ) {
    final groups = <List<Map<String, Object?>>>[];
    var current = <Map<String, Object?>>[];
    for (final message in messages) {
      if (message['role'] == 'assistant' &&
          asList(message['content'])
              .any((block) => asMap(block)['type'] == 'tool_use')) {
        if (current.isNotEmpty) groups.add(current);
        current = [];
        continue;
      }
      if (message['role'] != 'user') continue;
      if (asList(message['content'])
          .any((block) => asMap(block)['type'] == 'tool_result')) {
        current.add(message);
      }
    }
    if (current.isNotEmpty) groups.add(current);
    return groups;
  }

  /// Whether a result holds an image or a document: what a later look most
  /// needs, and what clearing would lose.
  static bool _hasMedia(Object? content) {
    for (final raw in asList(content)) {
      final type = asMap(raw)['type'];
      if (type == 'image' || type == 'document') return true;
    }
    return false;
  }

  /// Cuts the middle out of old, long tool results, then clears what old
  /// calls returned, as the CLI's microcompaction does: the calls, their
  /// results and the file stay as they were, and the model can read a file
  /// again for what it needs. Returns whether anything was changed.
  ///
  /// A boundary is written so that a resumed conversation applies the same
  /// cuts and clears again, and the usage is taken by estimate from here on:
  /// the last request's count included what is no longer sent.
  bool microcompact() {
    final store = run.store;
    final messages = store.apiMessages();
    final groups = _toolResultGroups(messages);
    if (groups.length <= _microKeepGroups) return false;
    final names = <String, String>{};
    for (final message in messages) {
      if (message['role'] != 'assistant') continue;
      for (final block in asList(message['content'])) {
        final call = asMap(block);
        if (call['type'] == 'tool_use' && call['id'] is String) {
          names[call['id'] as String] = '${call['name']}';
        }
      }
    }
    final clearGroups = groups.length - _microKeepGroups;
    final pruned = <String>[];
    var saved = 0;
    // First, cut the middle out of what is too long to send whole. It
    // keeps the start and the end, where a failure is usually read.
    for (var group = 0; group < clearGroups; group++) {
      for (final message in groups[group]) {
        for (final block in asList(message['content'])) {
          final result = asMap(block);
          if (result['type'] != 'tool_result') continue;
          final id = result['tool_use_id'];
          if (id is! String) continue;
          if (store.prunedToolResults.contains(id) ||
              store.clearedToolResults.contains(id) ||
              store.offloadedToolResults.containsKey(id)) {
            continue;
          }
          if (result['is_error'] == true) continue;
          if (_hasMedia(result['content'])) continue;
          if (!_clearableTools.contains(names[id])) continue;
          final content = result['content'];
          if (content is! String) continue;
          final short = pruneToolResult(content);
          if (identical(short, content)) continue;
          final save = estimateTokens(content) - estimateTokens(short);
          if (save <= 0) continue;
          pruned.add(id);
          saved += save;
        }
      }
    }
    // Enough room made without losing a whole result: stop here.
    if (pruned.isNotEmpty && saved >= _microMinSaved) {
      _commitMicrocompaction(store, pruned, const [], saved);
      return true;
    }
    final ids = <String>[];
    for (var group = 0; group < clearGroups; group++) {
      for (final message in groups[group]) {
        for (final block in asList(message['content'])) {
          final result = asMap(block);
          if (result['type'] != 'tool_result') continue;
          final id = result['tool_use_id'];
          if (id is! String) continue;
          if (store.clearedToolResults.contains(id)) continue;
          // A result kept out of the context already is not cleared again:
          // its whole content is still there to retrieve.
          if (store.offloadedToolResults.containsKey(id)) continue;
          // Failures and media are what a later look most needs.
          if (result['is_error'] == true) continue;
          if (_hasMedia(result['content'])) continue;
          if (!_clearableTools.contains(names[id])) continue;
          final tokens = estimateTokens(result['content']);
          if (tokens < 50) continue;
          saved += tokens - 16;
          ids.add(id);
        }
      }
    }
    if (ids.isEmpty || saved < _microMinSaved) return false;
    // Cutting was not enough on its own: clear the old results as before.
    _commitMicrocompaction(store, const [], ids, saved);
    return true;
  }

  void _commitMicrocompaction(
    SessionStore store,
    List<String> pruned,
    List<String> cleared,
    int saved,
  ) {
    final before = usedTokens();
    store.prunedToolResults.addAll(pruned);
    store.clearedToolResults.addAll(cleared);
    run.lastUsage = null;
    store.append({
      'type': 'system',
      'subtype': 'microcompact_boundary',
      'content': 'Context microcompacted',
      'isMeta': false,
      'level': 'info',
      'parentUuid': null,
      'logicalParentUuid': store.leaf,
      'microcompactMetadata': {
        'trigger': 'auto',
        'preTokens': before,
        'tokensSaved': saved,
        if (pruned.isNotEmpty) 'prunedToolIds': pruned,
        'compactedToolIds': cleared,
      },
    });
  }

  /// Compacts if the conversation has filled the context.
  ///
  /// A summary that cannot be made is tried again next turn, unless a few
  /// in a row made none; each such turn goes on from its recent messages
  /// instead ([fallBack]).
  Future<void> autoCompactIfNeeded(CancelToken cancel) async {
    if (!autoEnabled) return;
    if (usedTokens() < threshold) return;
    // Before a summary, what old calls returned is cleared: most of what
    // fills a context is their output, and the conversation itself can go
    // on.
    if (microcompact() && usedTokens() < threshold) return;
    if (run.compactFailures >= maxConsecutiveFailures) return;
    try {
      final done = await compact(trigger: 'auto', cancel: cancel);
      if (!done) run.compactFailures++;
    } on Cancelled {
      rethrow;
    } on Object catch (error) {
      run.compactFailures++;
      // No summary: what was said lately is kept and the rest goes. A turn
      // that ends here is worse than one that goes on without the older
      // part of a conversation too long to send as it is.
      await fallBack(
        trigger: 'auto',
        reason: error is ApiError && !error.promptTooLong
            ? 'summary_provider'
            : 'summary_budget',
        cancel: cancel,
      );
    }
  }

  /// Goes on without a summary: the conversation is cut back to the
  /// messages that last passed, the rest left in the file.
  ///
  /// A boundary is written as a compaction's is, so what the model is sent
  /// starts there, and the message it goes on from says what happened. The
  /// window kept is the newest messages that fit a third of the context,
  /// cut at a user message so that it starts as the API needs it to, and
  /// cleared of what the API would refuse (see [toApiMessages]).
  Future<bool> fallBack({
    required String trigger,
    required String reason,
    required CancelToken cancel,
  }) async {
    if (cancel.isCancelled) throw const Cancelled('interrupted');
    final store = run.store;
    final messages = store.apiMessages();
    if (messages.isEmpty) return false;
    final before = usedTokens();
    final budget = math.max(2000, (contextWindow * 0.3).round());
    final kept = _recentWindow(messages, budget);
    final text = _retainedTail(kept, reason: reason, file: store.file);
    final boundary = store.append({
      'type': 'system',
      'subtype': 'compact_boundary',
      'content': 'Conversation compacted',
      'isMeta': false,
      'level': 'info',
      'parentUuid': null,
      'logicalParentUuid': store.leaf,
      'compactMetadata': {
        'trigger': trigger,
        'preTokens': before,
        'fallback': 'retained_tail',
        'failureReason': reason,
        'keptMessages': kept.length,
      },
    });
    final after = estimateTokens(text) + estimateTokens(kept);
    _emitBoundary(boundary, trigger: trigger, before: before, after: after);
    final entry = store.append({
      'type': 'user',
      'message': {'role': 'user', 'content': text},
      'isCompactSummary': true,
      'isVisibleInTranscriptOnly': true,
      'isRetainedTail': true,
    });
    _emitSummary(entry);
    // The messages kept after the boundary, as they were: what the model
    // goes on from, under the note that says why.
    for (final message in kept) {
      store.append({
        'type': '${message['role']}',
        'message': message,
        // Not the user's: shown once already, above the boundary.
        'isMeta': true,
        'isRetainedTail': true,
        if (!isMain) ...{'agentId': ?agentId, 'isSidechain': true},
      });
    }
    // What the next request reports is this run's context now: its own
    // last usage no longer says how full it is.
    run.lastUsage = null;
    return true;
  }

  /// The newest of [messages] that fit [budget], from a user message on:
  /// what the conversation goes on from where no summary could be made.
  ///
  /// The last thing said is kept whatever it costs, and whole exchanges
  /// before it for as long as they fit; a call is kept with its results,
  /// and what is kept is what the API takes ([toApiMessages]).
  List<Map<String, Object?>> _recentWindow(
    List<Map<String, Object?>> messages,
    int budget,
  ) {
    // Where the user last spoke, not where a call's results were handed
    // back: a window cut at those would start with what the API refuses.
    var from = messages.length - 1;
    while (from >= 0 && !_begins(messages[from])) {
      from--;
    }
    if (from < 0) return const [];
    var used = estimateTokens(messages.sublist(from));
    while (from > 0) {
      var earlier = from - 1;
      while (earlier >= 0 && !_begins(messages[earlier])) {
        earlier--;
      }
      if (earlier < 0) break;
      final size = estimateTokens(messages.sublist(earlier, from));
      if (used + size > budget) break;
      used += size;
      from = earlier;
    }
    return toApiMessages([
      for (final message in messages.sublist(from))
        {'type': message['role'], 'message': message},
    ]);
  }

  /// Where the user spoke, not where a call's results were handed back: a
  /// message a window or a kept round may begin with.
  static bool _begins(Map<String, Object?> message) {
    if (message['role'] != 'user') return false;
    final content = message['content'];
    if (content is String) {
      final text = content.trimLeft();
      return text.isNotEmpty && !text.startsWith('<command-message>');
    }
    final blocks = asList(content);
    for (final block in blocks) {
      final text = asMap(block);
      if (text['type'] != 'text') continue;
      if ('${text['text'] ?? ''}'.trimLeft().startsWith('<command-message>')) {
        return false;
      }
      break;
    }
    return blocks.any((block) => asMap(block)['type'] != 'tool_result');
  }

  /// The newest exchange, from the last prompt to the end, within [budget]:
  /// what is kept verbatim after a summary.
  ///
  /// A call stays with its results. When the exchange is too long its
  /// oldest messages go, one whole call with its results at a time; what
  /// was said last is kept whatever it costs.
  List<Map<String, Object?>> _recentRound(
    List<Map<String, Object?>> messages,
    int budget,
  ) {
    var from = messages.length - 1;
    while (from >= 0 && !_begins(messages[from])) {
      from--;
    }
    if (from < 0) return const [];
    while (estimateTokens(messages.sublist(from)) > budget) {
      final next = _afterUnit(messages, from);
      if (next >= messages.length) break;
      from = next;
    }
    return messages.sublist(from);
  }

  /// Where the message at [from] ends: a prompt is its own unit; a call
  /// carries the results that came back after it.
  static int _afterUnit(List<Map<String, Object?>> messages, int from) {
    var next = from + 1;
    while (next < messages.length &&
        messages[next]['role'] != 'assistant' &&
        !_begins(messages[next])) {
      next++;
    }
    return next;
  }

  /// What the conversation goes on from where it could not be summed up.
  String _retainedTail(
    List<Map<String, Object?>> kept, {
    required String reason,
    required String? file,
  }) {
    final why = switch (reason) {
      'summary_budget' => 'it was too long to be summed up',
      'summary_provider' => 'the model could not be asked for a summary',
      _ => 'no summary could be made',
    };
    return [
      'The conversation before this point grew too long, and $why. What '
          'was said lately is kept below as it was; the earlier part is '
          'left out of this context.',
      if (file != null)
        'The whole of it is kept at $file: read it there for anything left '
            'out (exact code, error output, what you wrote).',
      if (kept.isEmpty)
        'Nothing of it fitted here: ask the user what to go on with.'
      else
        'Go on with the work where it stopped, without asking the user '
            'anything first. Do not mention this note or retell it, and do '
            'not announce that you are going on: just take the next step, '
            'as though nothing had come between.',
      ..._carriedOver(),
    ].join('\n');
  }

  /// Tells the host a conversation was compacted (its own only: a
  /// subagent's is the call's to show).
  void _emitBoundary(
    Map<String, Object?> boundary, {
    required String trigger,
    required int before,
    required int after,
  }) {
    if (!isMain) return;
    session.emit({
      'type': 'system',
      'subtype': 'compact_boundary',
      'compact_metadata': {
        'trigger': trigger,
        'pre_tokens': before,
        'post_tokens': after,
      },
      'uuid': boundary['uuid'],
    });
  }

  void _emitSummary(Map<String, Object?> entry) {
    if (!isMain) return;
    session.emit({
      'type': 'user',
      'message': entry['message'],
      'parent_tool_use_id': null,
      'uuid': entry['uuid'],
      'isSynthetic': true,
      'isCompactSummary': true,
    });
  }

  /// Sums up the conversation and goes on from the summary. Returns
  /// whether it did ([instructions] say what to keep).
  Future<bool> compact({
    required String trigger,
    String? instructions,
    required CancelToken cancel,
  }) async {
    final store = run.store;
    final messages = store.apiMessages();
    if (messages.isEmpty) return false;
    final before = usedTokens();
    var custom = instructions;
    if (session.hooks.has(HookEvent.preCompact)) {
      final hook = await session.hooks.run(
        HookEvent.preCompact,
        {
          'trigger': trigger,
          'custom_instructions': instructions ?? '',
          if (!isMain) 'agent_id': agentId,
        },
        query: trigger,
        cancel: cancel,
      );
      final added = [...hook.additionalContext, ...hook.outputs];
      if (added.isNotEmpty) {
        custom = [?instructions, ...added].join('\n\n');
      }
    }
    _status('compacting');
    final String summary;
    try {
      summary = await _summarize(messages, custom, cancel);
    } on Object {
      _status(null);
      rethrow;
    }
    if (summary.trim().isEmpty) {
      _status(null);
      return false;
    }
    // What was said last stays as it was said: a summary loses the words
    // the work is going on from.
    final retained = _recentRound(
      messages,
      math.min(20000, contextWindow ~/ 10),
    );
    final boundary = store.append({
      'type': 'system',
      'subtype': 'compact_boundary',
      'content': 'Conversation compacted',
      'isMeta': false,
      'level': 'info',
      'parentUuid': null,
      'logicalParentUuid': store.leaf,
      'compactMetadata': {
        'trigger': trigger,
        'preTokens': before,
        'retainedMessages': retained.length,
      },
    });
    final started = await _sessionStartAfterCompact(cancel);
    final text = [
      compactedSummary(summary, transcriptPath: store.file),
      if (retained.isNotEmpty)
        'The most recent exchange is kept below, as it was said.',
      ..._carriedOver(),
      ..._restoredFiles(),
      if (started.isNotEmpty)
        '<system-reminder>\nA SessionStart hook adds: '
            '${started.join('\n\n')}\n</system-reminder>',
    ].join('\n\n');
    final after = estimateTokens(text) + estimateTokens(retained);
    _emitBoundary(boundary, trigger: trigger, before: before, after: after);
    final entry = store.append({
      'type': 'user',
      'message': {'role': 'user', 'content': text},
      'isCompactSummary': true,
      'isVisibleInTranscriptOnly': true,
    });
    _emitSummary(entry);
    // The exchange kept verbatim goes after the summary, marked as not the
    // user's own words twice over.
    for (final message in retained) {
      store.append({
        'type': '${message['role']}',
        'message': message,
        'isMeta': true,
        'isRetainedTurn': true,
        if (!isMain) ...{'agentId': ?agentId, 'isSidechain': true},
      });
    }
    // What the next request reports is this run's context now.
    run.lastUsage = null;
    run.compactFailures = 0;
    _status(null);
    return true;
  }

  /// The host is told the conversation is being compacted (its own only).
  void _status(String? status) {
    if (!isMain) return;
    session.emitSystem('status', {'status': status});
  }

  /// What the model is to keep in view after the summary: this run's
  /// todos, and the plan the main agent was writing. A subagent carries
  /// its own list only: the main agent's plan and todos are not its task.
  List<String> _carriedOver() {
    final out = <String>[];
    final todos = run.todos;
    if (todos.isNotEmpty) {
      out.add(
        '<system-reminder>\nYour todo list before the conversation was '
        'compacted:\n${[for (final t in todos) '- [${t['status']}] ${t['content']}'].join('\n')}\n'
        '</system-reminder>',
      );
    }
    if (run.isMain && session.planSlug != null && session.planExists) {
      out.add(
        '<system-reminder>\nThe plan of this session is in '
        '${session.planFilePath}.\n</system-reminder>',
      );
    }
    return out;
  }

  /// The most recently read files, given back after the summary: the
  /// summary keeps what was said of them, not what they held, and a file
  /// read again costs a call. The newest are kept, five at most, each cut
  /// to a few thousand tokens, and all within a share of the window.
  static const _maxRestoredFiles = 5;
  static const _maxTokensPerFile = 5000;
  static const _maxRestoreTokens = 50000;

  int get _restoreBudget =>
      math.min(_maxRestoreTokens, math.max(1000, contextWindow ~/ 4));

  List<String> _restoredFiles() {
    final paths = run.readFiles.recentPaths;
    if (paths.isEmpty) return const [];
    var budget = _restoreBudget;
    final restored = <String>[];
    for (final path in paths.reversed) {
      if (restored.length >= _maxRestoredFiles || budget <= 0) break;
      final record = run.readFiles[path];
      if (record == null || record.content.trim().isEmpty) continue;
      final text = _cutToTokens(
        record.content,
        math.min(_maxTokensPerFile, budget),
      );
      final tokens = estimateTokens(text);
      if (tokens > budget) continue;
      budget -= tokens;
      restored.add(
        '## $path${record.partial ? ' (the part read)' : ''}\n\n$text',
      );
    }
    if (restored.isEmpty) return const [];
    return [
      '<system-reminder>\n'
          'The files read before the conversation was compacted, as they '
          'were (newest first). The summary does not hold their contents: '
          'read one again for more than is here.\n\n'
          '${restored.join('\n\n')}\n'
          '</system-reminder>',
    ];
  }

  /// [content], cut to about [tokens], saying so where it is cut.
  static String _cutToTokens(String content, int tokens) {
    if (estimateTokens(content) <= tokens) return content;
    var end = content.length;
    while (end > 0) {
      final text = content.substring(0, end);
      if (estimateTokens(text) <= tokens) {
        return '$text\n… (cut here: read the file for the rest)';
      }
      end = (end * 4) ~/ 5;
    }
    return '';
  }

  /// What a SessionStart hook adds once the conversation is compacted, as
  /// the CLI runs it with the source `compact`. The main agent's own
  /// session: a subagent's summary is its own.
  Future<List<String>> _sessionStartAfterCompact(CancelToken cancel) async {
    if (!isMain || !session.hooks.has(HookEvent.sessionStart)) {
      return const [];
    }
    try {
      final hook = await session.hooks.run(
        HookEvent.sessionStart,
        {'source': 'compact'},
        query: 'compact',
        cancel: cancel,
      );
      return [...hook.additionalContext, ...hook.outputs];
    } on Cancelled {
      rethrow;
    } on Object {
      // The summary stands without it.
      return const [];
    }
  }

  /// What the summary must hold, whatever else it leaves out: what the
  /// user asked for in their own words, and the files the work is in.
  ///
  /// A summary is the model's judgement of what mattered, and it is made
  /// from a conversation whose beginning may already be gone; asked for
  /// "all that matters", it drops a constraint the user set four turns
  /// back as readily as it drops a tool's output. These are the parts
  /// that cost the user most to have to say again, so they are given to
  /// it as what the summary has to hold rather than left to be weighed.
  ///
  /// Of [messages], not of the session: what was left out to fit is not
  /// to be asked for.
  static List<String> _mustKeep(List<Map<String, Object?>> messages) {
    final out = <String>[];
    final said = [
      for (final message in messages)
        if (message['role'] == 'user') ?_promptText(message),
    ];
    // The last few, in their own words: a task said once at the start is
    // as binding as one said now, but the newest are the ones in play.
    for (final text in said.reversed.take(6).toList().reversed) {
      out.add('The user said: ${_shorten(text, 600)}');
    }
    final files = <String>{};
    for (final message in messages.reversed) {
      if (message['role'] != 'assistant') continue;
      for (final block in asList(message['content'])) {
        if (asMap(block)['type'] != 'tool_use') continue;
        final input = asMap(asMap(block)['input']);
        for (final key in const ['file_path', 'path', 'notebook_path']) {
          if (input[key] case final String path when path.isNotEmpty) {
            files.add(path);
          }
        }
        if (files.length >= 12) break;
      }
      if (files.length >= 12) break;
    }
    if (files.isNotEmpty) {
      out.add('The work is in these files:\n${files.join('\n')}');
    }
    return out;
  }

  /// What [message] (a user message of the API's) says the user typed, or
  /// null where it says nothing.
  static String? _promptText(Map<String, Object?> message) {
    final content = message['content'];
    final text = switch (content) {
      final String text => text,
      final List<Object?> blocks => [
        for (final block in blocks)
          if (asMap(block)['type'] == 'text') '${asMap(block)['text']}',
      ].join('\n'),
      _ => '',
    }.trim();
    // A result is the tool's, not the user's.
    if (text.isEmpty || text.startsWith('<')) return null;
    return text;
  }

  static String _shorten(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  /// The model's summary of [messages]: the oldest left out for as long
  /// as they do not fit.
  Future<String> _summarize(
    List<Map<String, Object?>> messages,
    String? instructions,
    CancelToken cancel,
  ) async {
    var kept = messages;
    for (var attempt = 0; ; attempt++) {
      try {
        // What must be kept is read off what is being summed up now: a
        // message left out to fit is not one to ask the summary for.
        return await _ask(kept, instructions, cancel, keep: _mustKeep(kept));
      } on ApiError catch (error) {
        if (!error.promptTooLong || attempt >= 4 || kept.length < 4) rethrow;
        // A fifth of it left out, from the start: still from the user.
        var from = math.max(1, kept.length ~/ 5);
        while (from < kept.length && kept[from]['role'] != 'user') {
          from++;
        }
        if (from >= kept.length - 1) rethrow;
        kept = kept.sublist(from);
        // Results whose calls were left out are refused.
        kept = toApiMessages([
          for (final m in kept) {'type': m['role'], 'message': m},
        ]);
      }
    }
  }

  /// [messages] with images and documents replaced by a short marker: the
  /// summary needs what was said, not what was shown.
  static List<Map<String, Object?>> _withoutImages(
    List<Map<String, Object?>> messages,
  ) => [
    for (final message in messages)
      if (message['content'] case final List<Object?> blocks)
        {
          ...message,
          'content': [
            for (final block in blocks)
              if (block is Map &&
                  (block['type'] == 'image' || block['type'] == 'document'))
                {'type': 'text', 'text': '[${block['type']}]'}
              else
                block,
          ],
        }
      else
        message,
  ];

  Future<String> _ask(
    List<Map<String, Object?>> messages,
    String? instructions,
    CancelToken cancel, {
    List<String> keep = const [],
  }) async {
    final info = session.catalog.info(model);
    // Images and documents are not summed up: they are replaced by a
    // marker, so the summary request itself does not grow too long to send.
    final conversation = _withoutImages(messages);
    final ask = {'type': 'text', 'text': compactPrompt(instructions, keep)};
    if (conversation.isNotEmpty && conversation.last['role'] == 'user') {
      final last = conversation.removeLast();
      conversation.add({
        'role': 'user',
        'content': [...asList(last['content']), ask],
      });
    } else {
      conversation.add({
        'role': 'user',
        'content': [ask],
      });
    }
    final maxTokens = info.errandMaxTokens;
    var accumulator = MessageAccumulator();
    await for (final event in session.client.stream(
      ModelRequest({
        'model': model,
        'max_tokens': maxTokens,
        'system': [
          {'type': 'text', 'text': _system},
        ],
        'messages': conversation,
        if (info.canTurnThinkingOff) 'thinking': {'type': 'disabled'},
      }, errand: true),
      cancel: cancel,
    )) {
      if (event['type'] == 'stream_restart') {
        accumulator = MessageAccumulator();
        continue;
      }
      accumulator.add(event);
    }
    session.addUsage(accumulator.model ?? model, accumulator.usage);
    return [
      for (final block in accumulator.content)
        if (block['type'] == 'text') '${block['text']}',
    ].join().trim();
  }
}
