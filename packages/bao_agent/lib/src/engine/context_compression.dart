import 'dart:math' as math;

import '../api/message_accumulator.dart';
import '../api/model_client.dart';
import '../tools/tool.dart';
import '../util/cancel.dart';
import '../util/ids.dart';
import '../util/json.dart';
import 'agent_run.dart';
import 'compression_blocks.dart';
import 'session.dart';
import 'session_store.dart';
import 'transcript.dart';

/// A place a search found the words, and how to read more of it: the ref
/// of the visible prompt before it, or the compressed block it is inside.
class ContextHit {
  const ContextHit({
    required this.snippet,
    this.ref,
    this.block,
    this.source = 'self',
  });

  final String snippet;
  final String? ref;
  final String? block;

  /// `self`, or `parent` for a subagent reading its caller's context.
  final String source;

  Map<String, Object?> toJson() => {
    'source': source,
    if (ref != null) 'ref': ref,
    if (block != null) 'block_id': block,
    'snippet': snippet,
  };
}

/// One run's context, managed: ranges folded into summaries and brought
/// back, large results offloaded, and a search over what is still there.
///
/// The session file keeps every message; only what the model is sent
/// changes. A range starts at a user prompt and ends before another, so a
/// call and its results are never split.
class ContextCompression {
  ContextCompression(this.session, this.run, {required this.model});

  final AgentSession session;
  final AgentRun run;
  final String model;

  SessionStore get store => run.store;

  static const _system =
      'You fold part of a coding conversation into a compact summary for '
      'the agent that goes on from it. Keep what the user asked for in '
      'their own words, decisions and their reasons, file paths and what '
      'changed in them, commands run and what they returned, errors and '
      'how they were fixed, and what is unfinished. Do not call tools. '
      'Do not address the user. Output only the summary.';

  int get nudgeThreshold => session.settings.contextNudgeTokens;
  int get minCompressTokens => session.settings.contextMinCompressTokens;
  int get maxCompressTokens => session.settings.contextMaxCompressTokens;
  int get keepRecentTurns => session.settings.contextKeepRecentTurns;
  int get ccrMinTokens => session.settings.contextCcrMinTokens;
  int get ccrPreviewChars => session.settings.contextCcrPreviewChars;
  int get retrieveInlineChars => session.settings.contextRetrieveInlineChars;

  /// The last compaction's place: what came before it is not in the
  /// model's context, so a range or a search starts after it.
  int get _contextStart {
    for (var i = store.chain.length - 1; i >= 0; i--) {
      final entry = store.chain[i];
      if (entry['type'] == 'system' && entry['subtype'] == 'compact_boundary') {
        return i + 1;
      }
    }
    return 0;
  }

  Map<String, int> _chainIndex() {
    final at = <String, int>{};
    for (var i = 0; i < store.chain.length; i++) {
      if (store.chain[i]['uuid'] case final String uuid) at[uuid] = i;
    }
    return at;
  }

  ({int start, int end})? _rangeOf(
    CompressionBlock block,
    Map<String, int> at,
  ) {
    final start = at[block.startUuid];
    final end = at[block.endUuid];
    if (start == null || end == null || end < start) return null;
    return (start: start, end: end);
  }

  /// The entries the active blocks hide, by chain index.
  Set<int> _covered() {
    final at = _chainIndex();
    final covered = <int>{};
    for (final block in store.compressionBlocks) {
      final range = _rangeOf(block, at);
      if (range == null) continue;
      for (var i = range.start; i <= range.end; i++) {
        covered.add(i);
      }
    }
    return covered;
  }

  /// An active block by chain index.
  Map<int, CompressionBlock> _blocksByIndex() {
    final at = _chainIndex();
    final blocks = <int, CompressionBlock>{};
    for (final block in store.compressionBlocks) {
      final range = _rangeOf(block, at);
      if (range == null) continue;
      for (var i = range.start; i <= range.end; i++) {
        blocks[i] = block;
      }
    }
    return blocks;
  }

  /// The visible user prompts, oldest first: the coordinates a range is
  /// named by.
  List<int> visiblePrompts() {
    final covered = _covered();
    final from = _contextStart;
    return [
      for (var i = from; i < store.chain.length; i++)
        if (!covered.contains(i) && SessionStore.isPrompt(store.chain[i])) i,
    ];
  }

  /// The range the model named: from [startRef] (a visible prompt) to
  /// just before [endRef], or before the most recent turns that are kept.
  /// Both are chain indexes.
  ({int start, int end}) resolveRange(String startRef, String? endRef) {
    final refs = run.apiRefs;
    if (refs.isEmpty) {
      throw const ToolFailure(
        'No message references are available: ask again in a new turn.',
      );
    }
    final start = refs[startRef];
    if (start == null) {
      throw ToolFailure(
        'Unknown start_ref "$startRef". Use one of the refs in the '
        'conversation (m…) from this turn.',
      );
    }
    final prompts = visiblePrompts();
    final keep = keepRecentTurns;
    if (prompts.length <= keep) {
      throw ToolFailure(
        'There are not enough turns to compress while keeping the last '
        '$keep: ${prompts.length} are visible.',
      );
    }
    final allowedEnd = keep <= 0
        ? prompts.last
        : prompts[prompts.length - keep];
    if (!prompts.contains(start) || start >= allowedEnd) {
      throw ToolFailure(
        'The range must start at a visible prompt before '
        '${_refOf(allowedEnd)}.',
      );
    }
    final int end;
    if (endRef != null) {
      final asked = refs[endRef];
      if (asked == null || !prompts.contains(asked)) {
        throw ToolFailure('Unknown end_ref "$endRef".');
      }
      if (asked > allowedEnd) {
        throw ToolFailure(
          'Keep the last $keep turns: end_ref must be at or before '
          '${_refOf(allowedEnd)}.',
        );
      }
      end = asked;
    } else {
      end = allowedEnd;
    }
    if (end <= start) {
      throw const ToolFailure(
        'The range is empty: start_ref is not before end_ref.',
      );
    }
    return (start: start, end: end);
  }

  String _refOf(int index) => 'm$index';

  /// The messages in [start, end), with any blocks inside folded and any
  /// large results offloaded: what a summary of the range is made from.
  List<Map<String, Object?>> rangeMessages(int start, int end) {
    final slice = store.chain.sublist(start, end);
    final at = <String, int>{};
    for (var i = 0; i < slice.length; i++) {
      if (slice[i]['uuid'] case final String uuid) at[uuid] = i;
    }
    final inside = <CompressionBlock>[
      for (final block in store.compressionBlocks)
        if (_rangeOf(block, at) != null) block,
    ];
    return toApiMessages(
      slice,
      cleared: store.clearedToolResults,
      blocks: inside,
      offloaded: store.offloadedToolResults,
    );
  }

  /// Folds the range into one summary. A summary given by the model is
  /// used as it is; otherwise a request is made for one.
  Future<CompressionBlock> compress({
    required String startRef,
    String? endRef,
    String? summary,
    String? instructions,
    required CancelToken cancel,
  }) async {
    final range = resolveRange(startRef, endRef);
    final messages = rangeMessages(range.start, range.end);
    final before = estimateTokens(messages);
    if (before < minCompressTokens) {
      throw ToolFailure(
        'The range holds only about $before tokens; compress a larger span '
        '(at least $minCompressTokens).',
      );
    }
    if (before > maxCompressTokens) {
      throw ToolFailure(
        'The range holds about $before tokens, too much to summarize in one '
        'call (at most $maxCompressTokens): compress it in smaller ranges.',
      );
    }
    final given = summary?.trim();
    final text = given != null && given.isNotEmpty
        ? given
        : await _summarize(messages, cancel, instructions: instructions);
    final after = estimateTokens(text);
    if (after >= before) {
      throw const ToolFailure(
        'The summary is not smaller than the range; write a shorter one.',
      );
    }
    final block = CompressionBlock(
      id: 'c${randomId(6)}',
      startUuid: '${store.chain[range.start]['uuid']}',
      endUuid: '${store.chain[range.end - 1]['uuid']}',
      summary: text,
      createdAt: DateTime.now().toUtc(),
      tokensBefore: before,
      tokensAfter: after,
    );
    store.append(block.entry(logicalParentUuid: store.leaf));
    return block;
  }

  /// Brings a folded block's messages back. A block a later one covered
  /// cannot come back on its own.
  CompressionBlock restore(String blockId) {
    final active = _active(blockId);
    if (active == null) {
      final known = _known(blockId);
      if (known == null) {
        throw ToolFailure('There is no compressed block "$blockId".');
      }
      final cover = _coverOf(known);
      if (cover != null) {
        throw ToolFailure(
          'Block "$blockId" is covered by "${cover.id}": decompress '
          '"${cover.id}" to bring back that whole range.',
        );
      }
      throw ToolFailure('Block "$blockId" is no longer active.');
    }
    store.append({
      'type': 'system',
      'subtype': 'compression_restored',
      'content': 'Conversation restored',
      'isMeta': false,
      'level': 'info',
      'parentUuid': null,
      'logicalParentUuid': store.leaf,
      'block_id': active.id,
    });
    return active;
  }

  CompressionBlock? _active(String id) {
    for (final block in store.compressionBlocks) {
      if (block.id == id) return block;
    }
    return null;
  }

  /// A block that was made at some point, active or covered.
  CompressionBlock? _known(String id) {
    for (final entry in store.chain) {
      if (entry['type'] != 'system' || entry['subtype'] != 'compression') {
        continue;
      }
      final block = CompressionBlock.fromEntry(entry);
      if (block?.id == id) return block;
    }
    return null;
  }

  CompressionBlock? _coverOf(CompressionBlock known) {
    final at = _chainIndex();
    final range = _rangeOf(known, at);
    if (range == null) return null;
    for (final block in store.compressionBlocks) {
      final other = _rangeOf(block, at);
      if (other == null) continue;
      if (other.start <= range.start && other.end >= range.end) return block;
    }
    return null;
  }

  /// The whole text of the result of [toolUseId], as the file keeps it.
  String? toolResultContent(String toolUseId) {
    for (final entry in store.chain) {
      if (entry['type'] != 'user') continue;
      for (final raw in asList(asMap(entry['message'])['content'])) {
        final block = asMap(raw);
        if (block['type'] != 'tool_result' ||
            block['tool_use_id'] != toolUseId) {
          continue;
        }
        return _contentText(block['content']);
      }
    }
    return null;
  }

  static String _contentText(Object? content) {
    if (content is String) return content;
    final text = <String>[];
    for (final raw in asList(content)) {
      final block = asMap(raw);
      if (block['type'] == 'text') {
        text.add('${block['text'] ?? ''}');
      } else if (block['type'] != null) {
        text.add('[${block['type']}]');
      }
    }
    return text.join('\n');
  }

  /// Finds [query] in what the model's context still holds. A hit in a
  /// folded range names the block; one in the open names the prompt
  /// before it.
  List<ContextHit> search(
    String query, {
    int limit = 20,
    String source = 'self',
  }) {
    final needle = query.trim().toLowerCase();
    if (needle.length < 2) {
      throw const ToolFailure('Search for at least two characters.');
    }
    if (needle.length > 200) {
      throw const ToolFailure('Search for at most 200 characters.');
    }
    final blocks = _blocksByIndex();
    final hits = <ContextHit>[];
    String? ref;
    final from = _contextStart;
    for (var i = from; i < store.chain.length && hits.length < limit; i++) {
      final entry = store.chain[i];
      if (SessionStore.isPrompt(entry) && !blocks.containsKey(i)) {
        ref = _refOf(i);
      }
      final type = entry['type'];
      if (type != 'user' && type != 'assistant') continue;
      final text = _entryText(entry);
      final at = text.toLowerCase().indexOf(needle);
      if (at < 0) continue;
      final left = math.max(0, at - 80);
      final right = math.min(text.length, at + needle.length + 80);
      final snippet = text
          .substring(left, right)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final block = blocks[i];
      hits.add(
        ContextHit(
          snippet: snippet,
          ref: block == null ? ref : null,
          block: block?.id,
          source: source,
        ),
      );
    }
    return hits;
  }

  static String _entryText(Map<String, Object?> entry) {
    final content = asMap(entry['message'])['content'];
    if (content is String) return content;
    final text = <String>[];
    for (final raw in asList(content)) {
      final block = asMap(raw);
      switch (block['type']) {
        case 'text':
          if (asText(block['text']) case final said?) text.add(said);
        case 'tool_result':
          text.add(_contentText(block['content']));
      }
    }
    return text.join('\n');
  }

  /// What is folded and offloaded now, and how much room it saved.
  Map<String, Object?> status() {
    var saved = 0;
    final blocks = <Map<String, Object?>>[];
    for (final block in store.compressionBlocks) {
      saved += block.savedTokens;
      blocks.add({
        'id': block.id,
        'tokens_before': block.tokensBefore,
        'tokens_after': block.tokensAfter,
        'saved': block.savedTokens,
        'summary_chars': block.summary.length,
      });
    }
    var offloadedTokens = 0;
    for (final offloaded in store.offloadedToolResults.values) {
      offloadedTokens += offloaded.tokens;
    }
    return {
      'enabled': session.settings.contextManagementEnabled,
      'active_blocks': blocks,
      'saved_tokens': saved,
      'offloaded_results': store.offloadedToolResults.length,
      'offloaded_tokens': offloadedTokens,
      'conversation_tokens': estimateTokens(store.apiMessages()),
      'nudge_threshold': nudgeThreshold,
    };
  }

  Future<String> _summarize(
    List<Map<String, Object?>> messages,
    CancelToken cancel, {
    String? instructions,
  }) async {
    final info = session.catalog.info(model);
    final maxTokens = math.max(512, math.min(4000, info.maxOutput));
    final conversation = _withoutMedia(messages);
    final ask = <String, Object?>{
      'type': 'text',
      'text': [
        'Summarize the conversation above for the agent that goes on from '
            'it.',
        if (instructions != null && instructions.trim().isNotEmpty)
          'Additional instructions: ${instructions.trim()}',
      ].join('\n\n'),
    };
    if (conversation.isNotEmpty && conversation.last['role'] == 'user') {
      final last = conversation.removeLast();
      final content = last['content'];
      conversation.add({
        'role': 'user',
        'content': [
          if (content is String) {'type': 'text', 'text': content},
          if (content is! String) ...asList(content),
          ask,
        ],
      });
    } else {
      conversation.add({
        'role': 'user',
        'content': [ask],
      });
    }
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
    final text = [
      for (final block in accumulator.content)
        if (block['type'] == 'text') '${block['text']}',
    ].join().trim();
    if (text.isEmpty) {
      throw const ToolFailure('The model returned no summary.');
    }
    return text;
  }

  /// Images and documents are not read by a summary: they take its room.
  static List<Map<String, Object?>> _withoutMedia(
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
}
