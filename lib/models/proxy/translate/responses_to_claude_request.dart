// A Responses API request as an Anthropic Messages one: what Codex sends,
// turned round. The forward direction is responses_request.dart; this is
// its mirror, so that a Codex session can run on the upstreams of
// Settings → Models, whatever protocol they speak.

import 'json_value.dart';
import 'responses_tools.dart';
import 'thinking.dart';

/// The `instructions` and developer messages of a Responses request, as
/// Claude's `system`: what the model is told before the conversation.
const _systemRoles = {'developer', 'system'};

/// What a turn is given when nothing says how long it may be: room for a
/// long answer, since Codex leaves the ceiling to the API.
const _defaultMaxTokens = 32000;

/// [request] (decoded or as JSON text), a Responses API request, as an
/// Anthropic Messages request for [model].
///
/// Its `input` becomes the messages: a message item a turn of the
/// conversation, a `function_call` the `tool_use` it was, and a
/// `function_call_output` the `tool_result` answering it. `instructions`
/// and developer messages become `system`, and `tools` come back as
/// Claude's own. What has no Claude counterpart — a stored response, an
/// item of a kind Claude does not have — is left out rather than guessed
/// at.
Map<String, Object?> convertResponsesRequestToClaude(
  String model,
  Object? request,
) {
  final root = JsonValue.of(request);
  final system = <Map<String, Object?>>[];
  final messages = <Map<String, Object?>>[];

  void addSystem(String text) {
    if (text.trim().isEmpty) return;
    system.add({'type': 'text', 'text': text});
  }

  final instructions = root.get('instructions');
  if (instructions.isString) addSystem(instructions.string);

  /// Appends [blocks] to the last message when it is [role]'s, so that a
  /// tool result and the text after it are one turn, as Claude has them.
  void add(String role, List<Map<String, Object?>> blocks) {
    if (blocks.isEmpty) return;
    if (messages.lastOrNull case {'role': final last} when last == role) {
      (messages.last['content']! as List).addAll(blocks);
      return;
    }
    messages.add({'role': role, 'content': blocks});
  }

  final input = root.get('input');
  if (input.isString) {
    add('user', [
      {'type': 'text', 'text': input.string},
    ]);
  } else if (input.isArray) {
    for (final item in input.array) {
      switch (item.get('type').string) {
        case 'additional_tools':
          // A declaration, not a turn: read as tools (declaredToolsOf).
          break;
        case 'message':
          final role = item.get('role').string;
          final texts = _messageText(item.get('content'));
          if (_systemRoles.contains(role)) {
            texts.forEach(addSystem);
          } else if (role == 'assistant') {
            add('assistant', [
              for (final text in texts) {'type': 'text', 'text': text},
            ]);
          } else {
            add('user', [
              for (final text in texts) {'type': 'text', 'text': text},
            ]);
          }
        case 'function_call':
          // A call the model made, as the tool_use it was.
          final id = item.get('call_id').string;
          if (id.isEmpty) continue;
          add('assistant', [
            {
              'type': 'tool_use',
              'id': id,
              'name': item.get('name').string,
              'input': _arguments(item.get('arguments')),
            },
          ]);
        case 'function_call_output':
          final id = item.get('call_id').string;
          if (id.isEmpty) continue;
          add('user', [
            {
              'type': 'tool_result',
              'tool_use_id': id,
              'content': _toolOutput(item.get('output')),
            },
          ]);
        case 'reasoning':
          // Its thinking comes back as Claude's, unsigned: an upstream
          // that signs its own does not take another's signature, and one
          // that does not think has no use for it.
          final summary = item.get('summary');
          if (!summary.isArray) continue;
          final texts = [
            for (final part in summary.array)
              if (part.get('type').string == 'summary_text')
                if (part.get('text').string case final text
                    when text.trim().isNotEmpty)
                  text,
          ];
          if (texts.isEmpty) continue;
          add('assistant', [
            {'type': 'thinking', 'thinking': texts.join('\n\n'), 'signature': ''},
          ]);
      }
    }
  }

  final out = <String, Object?>{'model': model, 'messages': messages};
  if (system.isNotEmpty) out['system'] = system;

  final declared = declaredToolsOf(root);
  if (declared.isNotEmpty) {
    final converted = [
      for (final tool in declared) _claudeTool(tool),
    ];
    out['tools'] = converted;
    if (_toolChoice(root.get('tool_choice')) case final choice?) {
      out['tool_choice'] = choice;
    }
  }

  // Reasoning: the effort picked as Claude's thinking budget, as the
  // forward direction reads a budget back as an effort.
  final effort = root.get('reasoning.effort').string.trim().toLowerCase();
  final thinking = _thinkingFor(effort);
  if (thinking != null) out['thinking'] = thinking;

  // Claude asks for a ceiling where the Responses API has none: Codex
  // sends no `max_output_tokens`, and the turn needs one all the same. It
  // is the thinking's budget and room for the answer beside it.
  final ceiling = root.get('max_output_tokens').integer;
  final budget = thinking?['budget_tokens'] as int? ?? 0;
  out['max_tokens'] = ceiling > 0
      ? ceiling
      : _defaultMaxTokens + budget;

  // The Responses API streams; Claude's does when asked.
  out['stream'] = root.get('stream').value == true;
  return out;
}

/// [tool] as Claude's: its own name, and its input schema.
///
/// A freeform tool — Codex's `exec`, which takes raw source rather than a
/// JSON object — is sent as a tool of one string argument, so an upstream
/// that speaks only JSON schemas can still call it; the response side reads
/// that argument back as the call's `input`.
Map<String, Object?> _claudeTool(DeclaredTool tool) => {
  'name': tool.name,
  if (tool.description.isNotEmpty) 'description': tool.description,
  'input_schema': tool.freeform
      ? {
          'type': 'object',
          'properties': {
            freeformInputKey: {
              'type': 'string',
              'description': 'The tool input, as its own source text.',
            },
          },
          'required': [freeformInputKey],
        }
      : _schema(tool.parameters),
};

/// A message item's content as its texts: a plain string, or the parts of
/// an array that carry text. An image or a file is left out, as Claude
/// takes those in the messages and the upstream may not.
List<String> _messageText(JsonValue content) {
  if (content.isString) return [content.string];
  if (!content.isArray) return const [];
  return [
    for (final part in content.array)
      if (part.get('type').string case 'input_text' || 'output_text' || 'text')
        if (part.get('text').string case final text when text.isNotEmpty) text,
  ];
}

/// A function call's `arguments` as Claude's `input`: the JSON object it
/// is, or an empty one when it is not JSON at all.
Map<String, Object?> _arguments(JsonValue arguments) {
  if (arguments.isObject) {
    return (arguments.value! as Map).cast<String, Object?>();
  }
  final parsed = JsonValue.parse(arguments.string);
  if (parsed.isObject) {
    return (parsed.value! as Map).cast<String, Object?>();
  }
  return <String, Object?>{};
}

/// A `function_call_output`'s output as Claude's `tool_result` content.
Object? _toolOutput(JsonValue output) {
  if (output.isString) return output.string;
  if (output.isArray) {
    final texts = [
      for (final part in output.array)
        if (part.get('type').string == 'input_text')
          if (part.get('text').string case final text when text.isNotEmpty)
            {'type': 'text', 'text': text},
    ];
    if (texts.isNotEmpty) return texts;
  }
  return output.raw;
}

/// A function tool's `parameters` as Claude's `input_schema`: an object
/// with a type, as Claude needs, whatever it was given.
Map<String, Object?> _schema(JsonValue? parameters) {
  if (parameters == null || !parameters.isObject) {
    return {'type': 'object', 'properties': <String, Object?>{}};
  }
  final schema = (parameters.value! as Map).cast<String, Object?>();
  if (schema['type'] == null) {
    return {'type': 'object', ...schema};
  }
  return schema;
}

/// The Responses API's `tool_choice` as Claude's.
Map<String, Object?>? _toolChoice(JsonValue choice) {
  final kind = choice.get('type').string;
  return switch (kind) {
    'auto' => {'type': 'auto'},
    'none' => {'type': 'none'},
    'required' => {'type': 'any'},
    'function' => switch (choice.get('name').string) {
      '' => null,
      final name => {'type': 'tool', 'name': name},
    },
    _ => null,
  };
}

/// Claude's `thinking` for a Responses `reasoning.effort`: its budget, as
/// the forward direction reads one back. Null for an effort that asks for
/// no thinking, which Claude takes as not asked at all.
Map<String, Object?>? _thinkingFor(String effort) {
  final budget = switch (effort) {
    ThinkingLevel.minimal => 512,
    ThinkingLevel.low => 1024,
    ThinkingLevel.medium => 8192,
    ThinkingLevel.high => 24576,
    ThinkingLevel.xhigh => 32768,
    _ => 0,
  };
  if (budget == 0) return null;
  return {'type': 'enabled', 'budget_tokens': budget};
}
