import 'dart:convert';
import 'dart:math' as math;

import '../engine/context_compression.dart';
import '../engine/session.dart';
import '../permissions/decision.dart';
import '../util/json.dart';
import 'tool.dart';

/// The tools that fold, restore and search the agent's own context, and
/// read back what was offloaded. The model calls them; the chat does not
/// show them.
abstract class _ContextTool extends Tool {
  const _ContextTool();

  @override
  bool get hidden => true;

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAllow(reason: 'internal');

  @override
  bool isEnabled(AgentSession session) =>
      session.settings.contextManagementEnabled;

  ContextCompression _service(ToolContext context) =>
      ContextCompression(context.session, context.run, model: context.model);
}

/// Fold an older range into a summary.
class CompressTool extends _ContextTool {
  const CompressTool();

  @override
  String get name => 'compress';

  @override
  String get description =>
      'Fold an older, contiguous part of this conversation into a summary, '
      'freeing context. Parts are named by the <ctx id="m…"/> markers at '
      'the ends of user messages: start_ref is the first message to fold, '
      'end_ref the message just after the part (omit it to fold everything '
      'before the most recent turns). The original messages stay in the '
      'session and decompress brings them back.';

  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'start_ref': {
        'type': 'string',
        'description': 'The m… ref of the first message to fold.',
      },
      'end_ref': {
        'type': 'string',
        'description':
            'The m… ref of the message just after the part; omit to keep '
            'the most recent turns.',
      },
      'summary': {
        'type': 'string',
        'description':
            'The summary to keep, if you have it. Omit to have one '
            'written.',
      },
      'reason': {
        'type': 'string',
        'description': 'What the summary must be sure to keep.',
      },
    },
    'required': ['start_ref'],
  };

  @override
  bool isReadOnly(Map<String, Object?> input) => false;

  @override
  bool isConcurrencySafe(Map<String, Object?> input) => false;

  @override
  bool isEnabled(AgentSession session) =>
      super.isEnabled(session) && session.settings.contextCompressEnabled;

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final block = await _service(context).compress(
      startRef: asText(input['start_ref']) ?? '',
      endRef: asText(input['end_ref']),
      summary: asText(input['summary']),
      instructions: asText(input['reason']),
      cancel: context.cancel,
    );
    final result = <String, Object?>{
      'block_id': block.id,
      'messages': block.messages,
      'tokens_before': block.tokensBefore,
      'tokens_after': block.tokensAfter,
      'saved': block.savedTokens,
      'summary': block.summary,
    };
    return ToolOutput(
      'Folded ${block.messages} messages into ${block.id}: about '
      '${block.tokensBefore} tokens became ${block.tokensAfter} '
      '(${block.savedTokens} saved). The summary is in the context now.',
      result: result,
    );
  }
}

/// Bring a folded range back.
class DecompressTool extends _ContextTool {
  const DecompressTool();

  @override
  String get name => 'decompress';

  @override
  String get description =>
      'Bring back the original messages of a folded range, by its block '
      'id (from acp_status or a compression notice). The context grows '
      'again; fold another range afterwards if room is needed.';

  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'block_id': {
        'type': 'string',
        'description': 'The id of the folded range, such as c1a2b3.',
      },
    },
    'required': ['block_id'],
  };

  @override
  bool isConcurrencySafe(Map<String, Object?> input) => false;

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final block = _service(context).restore(asText(input['block_id']) ?? '');
    final result = <String, Object?>{
      'block_id': block.id,
      'messages': block.messages,
      'tokens': block.tokensBefore,
    };
    return ToolOutput(
      'Restored ${block.messages} messages (about ${block.tokensBefore} '
      'tokens) from ${block.id}.',
      result: result,
    );
  }
}

/// Search the context, folded parts included.
class SearchContextTool extends _ContextTool {
  const SearchContextTool();

  @override
  String get name => 'search_context';

  @override
  String get description =>
      'Search this conversation, including parts folded into summaries, '
      'for words. A hit names the prompt before it (a ref) or the folded '
      'block it is in; decompress that block to read more. A subagent also '
      'searches its parent\'s context, read-only.';

  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description': 'What to look for (at least two characters).',
      },
      'limit': {
        'type': 'integer',
        'minimum': 1,
        'maximum': 50,
        'description': 'How many hits at most (20 by default).',
      },
    },
    'required': ['query'],
  };

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final query = asText(input['query']) ?? '';
    final limit = math.min(math.max(1, asInt(input['limit']) ?? 20), 50);
    final hits = _service(context).search(query, limit: limit);
    final result = <String, Object?>{
      'matches': [for (final hit in hits) hit.toJson()],
      'total': hits.length,
    };
    return ToolOutput(
      hits.isEmpty
          ? 'No match for "$query" in the context.'
          : jsonEncode(result),
      result: result,
    );
  }
}

/// What is folded and offloaded now.
class AcpStatusTool extends _ContextTool {
  const AcpStatusTool();

  @override
  String get name => 'acp_status';

  @override
  String get description =>
      'Show what context management has folded or offloaded: the active '
      'blocks with what each saved, the offloaded results, the conversation '
      'size and when a nudge comes.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
  };

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final status = _service(context).status();
    return ToolOutput(jsonEncode(status), result: status);
  }
}

/// Read a tool result that was stored out of context.
class RetrieveToolResultTool extends _ContextTool {
  const RetrieveToolResultTool();

  @override
  String get name => 'retrieve_tool_result';

  @override
  String get description =>
      'Read a tool result that was stored out of the context; the '
      'placeholder names its id. Reads from offset, at most limit '
      'characters; the answer says whether there is more.';

  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'tool_use_id': {
        'type': 'string',
        'description': 'The id in the placeholder (toolu_…).',
      },
      'offset': {
        'type': 'integer',
        'minimum': 0,
        'description': 'Where to start reading (0 by default).',
      },
      'limit': {
        'type': 'integer',
        'minimum': 1,
        'maximum': 50000,
        'description': 'How many characters at most.',
      },
    },
    'required': ['tool_use_id'],
  };

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  @override
  bool isEnabled(AgentSession session) =>
      super.isEnabled(session) && session.settings.contextCcrMinTokens > 0;

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final id = asText(input['tool_use_id']) ?? '';
    final content = _service(context).toolResultContent(id);
    if (content == null) {
      return ToolOutput.error(
        'There is no tool result with id "$id" in this conversation.',
      );
    }
    final offset = math.min(
      math.max(0, asInt(input['offset']) ?? 0),
      content.length,
    );
    final asked =
        asInt(input['limit']) ??
        context.session.settings.contextRetrieveInlineChars;
    final limit = math.min(math.max(1, asked), 50000);
    final end = math.min(content.length, offset + limit);
    final result = <String, Object?>{
      'tool_use_id': id,
      'offset': offset,
      'content': content.substring(offset, end),
      'total_chars': content.length,
      'next_offset': end < content.length ? end : null,
    };
    return ToolOutput(jsonEncode(result), result: result);
  }
}
