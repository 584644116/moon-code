import '../util/json.dart';

/// A range of the conversation folded into one summary: the messages
/// between [startUuid] and [endUuid] (both in the session's chain) are
/// sent to the model as [summary] instead, and are still in the file.
///
/// A block that a later block covers is no longer active: the later
/// summary says what the earlier one said, in its own words.
class CompressionBlock {
  const CompressionBlock({
    required this.id,
    required this.startUuid,
    required this.endUuid,
    required this.summary,
    required this.createdAt,
    this.messages = 0,
    this.tokensBefore = 0,
    this.tokensAfter = 0,
  });

  final String id;
  final String startUuid;
  final String endUuid;
  final String summary;
  final DateTime createdAt;

  /// How many chain entries the range held.
  final int messages;

  /// What the range held, and what the summary holds, in estimated tokens.
  final int tokensBefore;
  final int tokensAfter;

  int get savedTokens =>
      tokensBefore > tokensAfter ? tokensBefore - tokensAfter : 0;

  /// The line this block is kept as, in the session file.
  Map<String, Object?> entry({required String? logicalParentUuid}) => {
    'type': 'system',
    'subtype': 'compression',
    'content': 'Conversation compressed',
    'isMeta': false,
    'level': 'info',
    'parentUuid': null,
    'logicalParentUuid': logicalParentUuid,
    'block_id': id,
    'start_uuid': startUuid,
    'end_uuid': endUuid,
    'summary': summary,
    'messages': messages,
    'tokens_before': tokensBefore,
    'tokens_after': tokensAfter,
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  /// The block [entry] records; null when it is not one this version reads.
  static CompressionBlock? fromEntry(Map<String, Object?> entry) {
    final id = asText(entry['block_id']);
    final start = asText(entry['start_uuid']);
    final end = asText(entry['end_uuid']);
    final summary = asText(entry['summary']);
    if (id == null ||
        id.isEmpty ||
        start == null ||
        end == null ||
        summary == null ||
        summary.isEmpty) {
      return null;
    }
    return CompressionBlock(
      id: id,
      startUuid: start,
      endUuid: end,
      summary: summary,
      createdAt:
          DateTime.tryParse(
            asText(entry['created_at']) ?? asText(entry['timestamp']) ?? '',
          ) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      messages: asInt(entry['messages']) ?? 0,
      tokensBefore: asInt(entry['tokens_before']) ?? 0,
      tokensAfter: asInt(entry['tokens_after']) ?? 0,
    );
  }
}

/// A large tool result kept out of the model's context, its content still
/// in the session's file: the model sees a placeholder and can ask for the
/// whole of it or a part.
class OffloadedResult {
  const OffloadedResult({
    required this.toolUseId,
    required this.tokens,
    this.preview = '',
    this.tail = '',
  });

  final String toolUseId;
  final int tokens;

  /// The start of what it held, enough to tell whether it is the one.
  final String preview;

  /// The end of it: the line a build failed on often comes last.
  final String tail;

  /// What the model is sent in its place.
  String get placeholder => [
    '[Large tool result stored out of context: id=$toolUseId, '
        '~$tokens tokens.',
    if (preview.isNotEmpty)
      'Preview: ${preview.replaceAll(RegExp(r'\s+'), ' ').trim()}',
    if (tail.isNotEmpty) 'End: ${tail.replaceAll(RegExp(r'\s+'), ' ').trim()}',
    'Use retrieve_tool_result with this id, or search_context to find part '
        'of it.]',
  ].join('\n');

  Map<String, Object?> entry({required String? logicalParentUuid}) => {
    'type': 'system',
    'subtype': 'offload_boundary',
    'content': 'Large tool result offloaded',
    'isMeta': false,
    'level': 'info',
    'parentUuid': null,
    'logicalParentUuid': logicalParentUuid,
    'tool_use_id': toolUseId,
    'tokens': tokens,
    'preview': preview,
    if (tail.isNotEmpty) 'tail': tail,
  };

  static OffloadedResult? fromEntry(Map<String, Object?> entry) {
    final id = asText(entry['tool_use_id']);
    if (id == null || id.isEmpty) return null;
    return OffloadedResult(
      toolUseId: id,
      tokens: asInt(entry['tokens']) ?? 0,
      preview: asText(entry['preview']) ?? '',
      tail: asText(entry['tail']) ?? '',
    );
  }
}
