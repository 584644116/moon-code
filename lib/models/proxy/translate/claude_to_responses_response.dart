// Anthropic Messages' stream as the Responses API's: the mirror of
// responses_response.dart, for a Codex session running on an upstream that
// speaks Claude's protocol.

import 'dart:convert';

import 'json_value.dart';
import 'responses_tools.dart';

/// One event of the Responses API's stream, as its line of SSE.
String responsesEvent(Map<String, Object?> data) =>
    'event: ${data['type']}\ndata: ${jsonEncode(data)}\n\n';

/// Anthropic's stream, event by event, as the Responses API's: the same
/// turn said in the other protocol.
///
/// The output items it makes carry indexes of their own, in the order they
/// begin: a text block, a thinking block and each tool call. A turn that
/// ends with a tool call ends with `response.completed` and
/// `status: incomplete` — the Responses API has no `tool_use` stop reason,
/// and Codex goes on from the calls it was given either way.
class ClaudeToResponsesTranslator {
  ClaudeToResponsesTranslator(this.model, {Map<String, DeclaredTool>? tools})
    : _tools = tools ?? const {};

  final String model;

  /// The tools the request declared, by the name a call comes back under:
  /// a freeform one is answered as `custom_tool_call`, a namespace's
  /// member carries its namespace, and the rest as `function_call`.
  final Map<String, DeclaredTool> _tools;

  /// The response id, made here: the upstream's is Claude's own, and the
  /// Responses API's is this proxy's to name.
  final String _id = 'resp_${DateTime.now().microsecondsSinceEpoch}';

  bool _created = false;
  int _nextIndex = 0;
  bool _closed = false;

  /// The blocks being written, by Claude's content block index.
  final Map<int, _OpenItem> _open = {};

  /// What the turn is made of so far, as `response.output` will list it.
  final List<Map<String, Object?>> _output = [];

  int _inputTokens = 0;
  int _outputTokens = 0;
  String? _stopReason;

  /// Whether the turn has ended: nothing more is expected of it.
  bool get isDone => _closed;

  /// The events for one line of Claude's stream: none for a line that is
  /// not `data:`, or an event of a kind this does not know.
  List<String> convert(String line) {
    if (!line.startsWith('data:')) return const [];
    final raw = line.substring(5).trim();
    if (raw.isEmpty || raw == '[DONE]') return const [];
    final root = JsonValue.parse(raw);
    final type = root.get('type').string;
    final out = <String>[];
    if (!_created) out.add(_createdEvent());
    switch (type) {
      case 'message_start':
        _inputTokens = root.get('message.usage.input_tokens').integer;
      case 'content_block_start':
        out.addAll(_startBlock(root));
      case 'content_block_delta':
        out.addAll(_blockDelta(root));
      case 'content_block_stop':
        out.addAll(_stopBlock(root.get('index').integer));
      case 'message_delta':
        _outputTokens = root.get('usage.output_tokens').integer;
        if (root.get('delta.stop_reason').string case final reason
            when reason.isNotEmpty) {
          _stopReason = reason;
        }
      case 'message_stop':
        out.addAll(_complete());
      case 'error':
        out.add(_errorEvent(root));
    }
    return out;
  }

  /// Ends the turn where the stream did not: the last of it.
  List<String> finish() => _closed ? const [] : _complete();

  String _createdEvent() {
    _created = true;
    return responsesEvent({
      'type': 'response.created',
      'response': _response(status: 'in_progress'),
    });
  }

  Map<String, Object?> _response({required String status}) => {
    'id': _id,
    'object': 'response',
    'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    'model': model,
    'status': status,
    'output': _output,
    'usage': {
      'input_tokens': _inputTokens,
      'output_tokens': _outputTokens,
      'total_tokens': _inputTokens + _outputTokens,
    },
  };

  List<String> _startBlock(JsonValue root) {
    final index = root.get('index').integer;
    final block = root.get('content_block');
    final kind = block.get('type').string;
    final out = <String>[];
    final item = switch (kind) {
      'text' => _OpenItem.text(_nextIndex++),
      'thinking' => _OpenItem.reasoning(_nextIndex++),
      'tool_use' => _OpenItem.call(
        _nextIndex++,
        block.get('id').string,
        block.get('name').string,
        _tools[block.get('name').string],
      ),
      _ => null,
    };
    if (item == null) return out;
    _open[index] = item;
    out.add(
      responsesEvent({
        'type': 'response.output_item.added',
        'output_index': item.index,
        'item': item.added,
      }),
    );
    return out;
  }

  List<String> _blockDelta(JsonValue root) {
    final item = _open[root.get('index').integer];
    if (item == null) return const [];
    final delta = root.get('delta');
    switch (delta.get('type').string) {
      case 'text_delta':
        final text = delta.get('text').string;
        if (text.isEmpty) return const [];
        item.text.write(text);
        return [
          responsesEvent({
            'type': 'response.output_text.delta',
            'item_id': item.id,
            'output_index': item.index,
            'content_index': 0,
            'delta': text,
          }),
        ];
      case 'thinking_delta':
        final text = delta.get('thinking').string;
        if (text.isEmpty) return const [];
        item.text.write(text);
        return [
          responsesEvent({
            'type': 'response.reasoning_summary_text.delta',
            'item_id': item.id,
            'output_index': item.index,
            'summary_index': 0,
            'delta': text,
          }),
        ];
      case 'input_json_delta':
        final text = delta.get('partial_json').string;
        if (text.isEmpty) return const [];
        item.text.write(text);
        // A freeform call's input is source text, which Claude sends as the
        // one string argument: unwrapped once the arguments are whole (in
        // [done]), and streamed here as they come.
        return [
          responsesEvent({
            'type': item.freeform
                ? 'response.custom_tool_call_input.delta'
                : 'response.function_call_arguments.delta',
            'item_id': item.id,
            'output_index': item.index,
            'delta': text,
          }),
        ];
      case 'signature_delta':
        item.signature = delta.get('signature').string;
    }
    return const [];
  }

  List<String> _stopBlock(int index) {
    final item = _open.remove(index);
    if (item == null) return const [];
    final done = item.done;
    _output.add(done);
    return [
      responsesEvent({
        'type': 'response.output_item.done',
        'output_index': item.index,
        'item': done,
      }),
    ];
  }

  List<String> _complete() {
    _closed = true;
    final out = <String>[];
    // Blocks the upstream left open, as ended.
    for (final index in [..._open.keys]) {
      out.addAll(_stopBlock(index));
    }
    out.add(
      responsesEvent({
        'type': 'response.completed',
        'response': _response(
          status: _stopReason == 'max_tokens' ? 'incomplete' : 'completed',
        ),
      }),
    );
    return out;
  }

  String _errorEvent(JsonValue root) => responsesEvent({
    'type': 'error',
    'code': root.get('error.type').string,
    'message': root.get('error.message').string,
  });
}

/// A block being written, as the item the Responses API reports.
class _OpenItem {
  _OpenItem.text(this.index)
    : kind = 'message',
      callId = '',
      name = '',
      namespace = null,
      freeform = false;

  _OpenItem.reasoning(this.index)
    : kind = 'reasoning',
      callId = '',
      name = '',
      namespace = null,
      freeform = false;

  /// A call the model made. [declared] says how it comes back: a freeform
  /// tool as `custom_tool_call`, whose input is source text rather than
  /// arguments; a namespace's member with the namespace beside its name,
  /// which Codex needs to find the tool; the rest as `function_call`.
  _OpenItem.call(this.index, this.callId, this.name, DeclaredTool? declared)
    : kind = declared?.freeform == true ? 'custom_tool_call' : 'function_call',
      namespace = declared?.namespace,
      freeform = declared?.freeform == true;

  final int index;
  final String kind;
  final String callId;
  final String name;

  /// The namespace the called tool belongs to, when it is a member of one.
  final String? namespace;

  /// Whether it takes its input as source text (Codex's `exec`).
  final bool freeform;

  /// What it has said so far: the text, the thinking, or the arguments.
  final StringBuffer text = StringBuffer();

  /// A thinking block's signature, which the Responses API has no place
  /// for: the reasoning comes back as its summary alone.
  String signature = '';

  String get id => '${kind}_$index';

  /// The item as it begins: empty, its kind said.
  Map<String, Object?> get added => switch (kind) {
    'message' => {
      'type': 'message',
      'id': id,
      'status': 'in_progress',
      'role': 'assistant',
      'content': <Object?>[],
    },
    'reasoning' => {
      'type': 'reasoning',
      'id': id,
      'summary': <Object?>[],
    },
    _ => {
      'type': kind,
      'id': id,
      'status': 'in_progress',
      'call_id': callId,
      'name': name,
      'namespace': ?namespace,
      if (freeform) 'input': '' else 'arguments': '',
    },
  };

  /// The item as it ends, with what it said.
  Map<String, Object?> get done => switch (kind) {
    'message' => {
      'type': 'message',
      'id': id,
      'status': 'completed',
      'role': 'assistant',
      'content': [
        {'type': 'output_text', 'text': text.toString(), 'annotations': []},
      ],
    },
    'reasoning' => {
      'type': 'reasoning',
      'id': id,
      'summary': [
        {'type': 'summary_text', 'text': text.toString()},
      ],
    },
    _ => {
      'type': kind,
      'id': id,
      'status': 'completed',
      'call_id': callId,
      'name': name,
      'namespace': ?namespace,
      if (freeform)
        'input': _freeformInput(text.toString())
      else
        'arguments': text.toString(),
    },
  };

  /// A freeform call's input out of the arguments it came in: the one
  /// string argument's text, or the arguments as they are when they are not
  /// that (an upstream that answered in its own shape).
  static String _freeformInput(String arguments) {
    final parsed = JsonValue.parse(arguments);
    if (parsed.get(freeformInputKey) case final input when input.isString) {
      return input.string;
    }
    return arguments;
  }
}
