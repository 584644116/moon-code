import 'dart:math' as math;

import '../api/message_accumulator.dart';
import '../api/model_client.dart';
import '../hooks/hooks.dart';
import '../prompts/task_prompts.dart';
import '../util/cancel.dart';
import '../util/json.dart';
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
  Compaction(
    this.session, {
    String? model,
    this.isMain = true,
    this.agentId,
    this.usage,
  }) : model = model ?? session.resolvedModel;

  final AgentSession session;

  /// The model the conversation is with: a subagent's own, else the
  /// session's. Its window is the one the conversation is sized by.
  final String model;

  /// Whether this is the main agent's conversation: a subagent's is kept
  /// apart, sized by its own model, and says nothing to the host.
  final bool isMain;

  /// The subagent whose conversation this is, if one.
  final String? agentId;

  /// The last request's usage, where the caller keeps it (a subagent's is
  /// its own, the session keeping the main agent's).
  final Map<String, Object?>? usage;

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

  /// How full the context is: the last request's, and what was added since.
  int usedTokens(SessionStore store) {
    final messages = store.apiMessages();
    // The main agent's is the session's (cleared by a compaction, so that
    // what the next request reports is the context then); a subagent's is
    // its own, kept by its loop.
    final usage = isMain ? session.lastUsage : this.usage;
    if (usage == null) return estimateTokens(messages);
    int count(String key) => asInt(usage[key]) ?? 0;
    final reported =
        count('input_tokens') +
        count('cache_read_input_tokens') +
        count('cache_creation_input_tokens') +
        count('output_tokens');
    final lastAnswer = messages.lastIndexWhere((m) => m['role'] == 'assistant');
    final since = lastAnswer < 0 ? messages : messages.sublist(lastAnswer + 1);
    return reported + estimateTokens(since);
  }

  /// The window this conversation is sized by.
  int get contextWindow => session.compactWindowOf(model);

  /// The tokens the context holds before it is compacted.
  int get threshold =>
      contextWindow - AgentSession.compactBufferOf(contextWindow);

  /// Compacts if the conversation has filled the context.
  ///
  /// A summary that cannot be made leaves the turn to go on: the
  /// conversation is cut back to its recent messages instead ([fallBack]).
  Future<void> autoCompactIfNeeded(
    SessionStore store,
    CancelToken cancel,
  ) async {
    if (!autoEnabled) return;
    if (usedTokens(store) < threshold) return;
    try {
      await compact(store, trigger: 'auto', cancel: cancel);
    } on Cancelled {
      rethrow;
    } on Object catch (error) {
      // No summary: what was said lately is kept and the rest goes. A turn
      // that ends here is worse than one that goes on without the older
      // part of a conversation too long to send as it is.
      await fallBack(
        store,
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
  Future<bool> fallBack(
    SessionStore store, {
    required String trigger,
    required String reason,
    required CancelToken cancel,
  }) async {
    if (cancel.isCancelled) throw const Cancelled('interrupted');
    final messages = store.apiMessages();
    if (messages.isEmpty) return false;
    final before = usedTokens(store);
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
    if (isMain) session.lastUsage = null;
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
    bool begins(int at) {
      if (messages[at]['role'] != 'user') return false;
      final content = messages[at]['content'];
      if (content is String) return content.trim().isNotEmpty;
      return asList(content).any(
        (block) => asMap(block)['type'] != 'tool_result',
      );
    }

    var from = messages.length - 1;
    while (from >= 0 && !begins(from)) {
      from--;
    }
    if (from < 0) return const [];
    var used = estimateTokens(messages.sublist(from));
    while (from > 0) {
      var earlier = from - 1;
      while (earlier >= 0 && !begins(earlier)) {
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
  Future<bool> compact(
    SessionStore store, {
    required String trigger,
    String? instructions,
    required CancelToken cancel,
  }) async {
    final messages = store.apiMessages();
    if (messages.isEmpty) return false;
    final before = usedTokens(store);
    var custom = instructions;
    if (session.hooks.has(HookEvent.preCompact)) {
      final hook = await session.hooks.run(
        HookEvent.preCompact,
        {'trigger': trigger, 'custom_instructions': instructions ?? ''},
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
      summary = await _summarize(
        messages,
        custom,
        cancel,
      );
    } on Object {
      _status(null);
      rethrow;
    }
    if (summary.trim().isEmpty) {
      _status(null);
      return false;
    }
    final boundary = store.append({
      'type': 'system',
      'subtype': 'compact_boundary',
      'content': 'Conversation compacted',
      'isMeta': false,
      'level': 'info',
      'parentUuid': null,
      'logicalParentUuid': store.leaf,
      'compactMetadata': {'trigger': trigger, 'preTokens': before},
    });
    final text = [
      compactedSummary(summary, transcriptPath: store.file),
      ..._carriedOver(),
    ].join('\n\n');
    final after = estimateTokens(text);
    _emitBoundary(boundary, trigger: trigger, before: before, after: after);
    final entry = store.append({
      'type': 'user',
      'message': {'role': 'user', 'content': text},
      'isCompactSummary': true,
      'isVisibleInTranscriptOnly': true,
    });
    _emitSummary(entry);
    // What the next request reports is the context now.
    if (isMain) session.lastUsage = null;
    _status(null);
    return true;
  }

  /// The host is told the conversation is being compacted (its own only).
  void _status(String? status) {
    if (!isMain) return;
    session.emitSystem('status', {'status': status});
  }

  /// What the model is to keep in view after the summary: its todos, the
  /// plan it was writing.
  List<String> _carriedOver() {
    final out = <String>[];
    final todos = session.mainTodos;
    if (todos.isNotEmpty) {
      out.add(
        '<system-reminder>\nYour todo list before the conversation was '
        'compacted:\n${[for (final t in todos) '- [${t['status']}] ${t['content']}'].join('\n')}\n'
        '</system-reminder>',
      );
    }
    if (session.planSlug != null && session.planExists) {
      out.add(
        '<system-reminder>\nThe plan of this session is in '
        '${session.planFilePath}.\n</system-reminder>',
      );
    }
    return out;
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

  Future<String> _ask(
    List<Map<String, Object?>> messages,
    String? instructions,
    CancelToken cancel, {
    List<String> keep = const [],
  }) async {
    final info = session.catalog.info(model);
    final conversation = [...messages];
    final ask = {
      'type': 'text',
      'text': compactPrompt(instructions, keep),
    };
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
      }),
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
