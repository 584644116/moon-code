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
      '把本次对话中较早的、连续的一段折叠成摘要，释放上下文。'
      '各段由用户消息末尾的 <ctx id="m…"/> 标记命名：start_ref 是要折叠的第一条消息，'
      'end_ref 是该段之后那条消息（省略则折叠最近若干轮之前的全部内容）。'
      '原始消息仍留在会话中，用 decompress 可以把它们取回来。';

  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'start_ref': {
        'type': 'string',
        'description': '要折叠的第一条消息的 m… 引用。',
      },
      'end_ref': {
        'type': 'string',
        'description':
            '该部分之后那条消息的 m… 引用；省略则保留 '
            '最近的若干轮。',
      },
      'summary': {
        'type': 'string',
        'description':
            '已有的摘要，如果有就给出。省略则由系统生成'
            'written.',
      },
      'reason': {
        'type': 'string',
        'description': '摘要必须保留的内容。',
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
      '按块 id（来自 acp_status 或压缩提示）取回某个折叠范围的原始消息。'
      '上下文会重新变大；需要空间时之后再折叠别的范围。';

  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'block_id': {
        'type': 'string',
        'description': '折叠范围的 id，例如 c1a2b3。',
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
      '在本次对话中搜索词语，包括已折叠成摘要的部分。'
      '每条命中会指出它前面的提示（一个 ref）或它所在的折叠块；'
      '用 decompress 展开那个块可以读到更多。子智能体也能以只读方式搜索其父级上下文。';

  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description': '要查找的内容（至少两个字符）。',
      },
      'limit': {
        'type': 'integer',
        'minimum': 1,
        'maximum': 50,
        'description': '最多返回多少条（默认 20）。',
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
      '显示上下文管理已折叠或移出上下文的内容：'
      '当前生效的块及各自省下的量、已移出的工具结果、对话大小，以及何时会提示。';

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
      '读取被存到上下文之外的某个工具结果；'
      '占位符里写着它的 id。从 offset 开始读，最多 limit 个字符；'
      '返回结果会说明是否还有更多。';

  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'tool_use_id': {
        'type': 'string',
        'description': '占位符里的 id（toolu_…）。',
      },
      'offset': {
        'type': 'integer',
        'minimum': 0,
        'description': '从哪个位置开始读（默认 0）。',
      },
      'limit': {
        'type': 'integer',
        'minimum': 1,
        'maximum': 50000,
        'description': '最多多少字符。',
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
