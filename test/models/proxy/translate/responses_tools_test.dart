// What Codex declares as tools, and what comes back for them: the shapes
// its own app-server sends (a `namespace` of members, a freeform `custom`
// tool, and — in Responses Lite — the same as an `additional_tools` item).

import 'dart:convert';

import 'package:baocode/models/proxy/translate/claude_to_responses_response.dart';
import 'package:baocode/models/proxy/translate/json_value.dart';
import 'package:baocode/models/proxy/translate/responses_to_claude_request.dart';
import 'package:baocode/models/proxy/translate/responses_tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tool call of Claude's, as the upstream streams it.
List<String> callOf(String name, Map<String, Object?> arguments) => [
  'data: ${jsonEncode({
    'type': 'message_start',
    'message': {'usage': {'input_tokens': 1}},
  })}',
  'data: ${jsonEncode({
    'type': 'content_block_start',
    'index': 0,
    'content_block': {'type': 'tool_use', 'id': 'toolu_1', 'name': name},
  })}',
  'data: ${jsonEncode({
    'type': 'content_block_delta',
    'index': 0,
    'delta': {
      'type': 'input_json_delta',
      'partial_json': jsonEncode(arguments),
    },
  })}',
  'data: ${jsonEncode({'type': 'content_block_stop', 'index': 0})}',
  'data: ${jsonEncode({
    'type': 'message_delta',
    'delta': {'stop_reason': 'tool_use'},
    'usage': {'output_tokens': 1},
  })}',
  'data: ${jsonEncode({'type': 'message_stop'})}',
];

/// The items a call produced, as the Responses stream said them.
List<Map<String, Object?>> itemsOf(List<String> frames) => [
  for (final frame in frames)
    if (frame.startsWith('event: response.output_item.done'))
      (jsonDecode(frame.split('\n')[1].substring(6)) as Map)['item']
          as Map<String, Object?>,
];

/// A request as the [JsonValue] the converters take.
JsonValue _request(Map<String, Object?> request) =>
    JsonValue.parse(jsonEncode(request));

void main() {
  group('what Codex declares', () {
    test('a namespace is its members, flattened under its name', () {
      final tools = declaredToolsOf(
        _request({
          'tools': [
            {'type': 'function', 'name': 'exec_command'},
            {
              'type': 'namespace',
              'name': 'multi_agent_v1',
              'tools': [
                {'type': 'function', 'name': 'spawn_agent'},
                {'type': 'custom', 'name': 'exec'},
              ],
            },
            // A hosted tool is the upstream's to provide.
            {'type': 'web_search'},
          ],
        }),
      );
      expect(tools.map((tool) => tool.name), [
        'exec_command',
        'multi_agent_v1spawn_agent',
        'multi_agent_v1exec',
      ]);
      expect(tools[1].namespace, 'multi_agent_v1');
      expect(tools[1].freeform, isFalse);
      expect(tools[2].freeform, isTrue);
      expect(tools[0].namespace, isNull);
    });

    test('an additional_tools item declares them too', () {
      // Responses Lite: Codex puts the declarations in the conversation.
      final tools = declaredToolsOf(
        _request({
          'input': [
            {
              'type': 'message',
              'role': 'user',
              'content': [
                {'type': 'input_text', 'text': 'hi'},
              ],
            },
            {
              'type': 'additional_tools',
              'role': 'developer',
              'tools': [
                {
                  'type': 'namespace',
                  'name': 'functions',
                  'tools': [
                    {'type': 'function', 'name': 'exec_command'},
                    {'type': 'custom', 'name': 'exec'},
                  ],
                },
              ],
            },
          ],
        }),
      );
      expect(tools.map((tool) => tool.name), [
        'functionsexec_command',
        'functionsexec',
      ]);
    });
  });

  group('what is sent upstream', () {
    test('a namespace member keeps its flattened name', () {
      final out = convertResponsesRequestToClaude('m', {
        'input': [
          {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': 'hi'},
            ],
          },
        ],
        'tools': [
          {
            'type': 'namespace',
            'name': 'multi_agent_v1',
            'tools': [
              {
                'type': 'function',
                'name': 'spawn_agent',
                'parameters': {
                  'type': 'object',
                  'properties': {
                    'prompt': {'type': 'string'},
                  },
                },
              },
            ],
          },
        ],
      });
      final tools = out['tools']! as List;
      expect(tools, hasLength(1));
      expect((tools.single as Map)['name'], 'multi_agent_v1spawn_agent');
      expect(
        (tools.single as Map)['input_schema'],
        containsPair('properties', contains('prompt')),
      );
    });

    test('a freeform tool takes one string argument', () {
      final out = convertResponsesRequestToClaude('m', {
        'input': [
          {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': 'hi'},
            ],
          },
        ],
        'tools': [
          {'type': 'custom', 'name': 'exec', 'description': 'Run JavaScript'},
        ],
      });
      final tool = (out['tools']! as List).single as Map;
      expect(tool['name'], 'exec');
      final schema = tool['input_schema'] as Map;
      expect(schema['required'], [freeformInputKey]);
      expect(
        (schema['properties'] as Map)[freeformInputKey],
        containsPair('type', 'string'),
      );
    });

    test('an additional_tools item is sent as tools', () {
      final out = convertResponsesRequestToClaude('m', {
        'input': [
          {
            'type': 'additional_tools',
            'role': 'developer',
            'tools': [
              {'type': 'function', 'name': 'exec_command'},
            ],
          },
          {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': 'hi'},
            ],
          },
        ],
      });
      expect((out['tools']! as List).single, containsPair('name', 'exec_command'));
    });
  });

  group('what comes back', () {
    Map<String, DeclaredTool> toolsOf(Map<String, Object?> request) =>
        toolsByName(declaredToolsOf(_request(request)));

    test('a namespace member is called with its namespace', () {
      final request = {
        'tools': [
          {
            'type': 'namespace',
            'name': 'multi_agent_v1',
            'tools': [
              {'type': 'function', 'name': 'spawn_agent'},
            ],
          },
        ],
      };
      final translator = ClaudeToResponsesTranslator(
        'm',
        tools: toolsOf(request),
      );
      final frames = [
        for (final line in callOf('multi_agent_v1spawn_agent', {
          'prompt': 'hi',
        }))
          ...translator.convert(line),
      ];
      final item = itemsOf(frames).single;
      expect(item['type'], 'function_call');
      expect(item['name'], 'multi_agent_v1spawn_agent');
      expect(item['namespace'], 'multi_agent_v1');
      expect(item['arguments'], jsonEncode({'prompt': 'hi'}));
    });

    test('a freeform tool is answered as a custom call, its input unpacked',
        () {
      final request = {
        'tools': [
          {'type': 'custom', 'name': 'exec'},
        ],
      };
      final translator = ClaudeToResponsesTranslator(
        'm',
        tools: toolsOf(request),
      );
      final frames = [
        for (final line in callOf('exec', {freeformInputKey: '1+1'}))
          ...translator.convert(line),
      ];
      final item = itemsOf(frames).single;
      expect(item['type'], 'custom_tool_call');
      expect(item['name'], 'exec');
      // Source text, not the arguments it was wrapped in.
      expect(item['input'], '1+1');
      expect(item.containsKey('arguments'), isFalse);
    });

    test('a plain function tool is a function call, with no namespace', () {
      final translator = ClaudeToResponsesTranslator(
        'm',
        tools: toolsOf({
          'tools': [
            {'type': 'function', 'name': 'exec_command'},
          ],
        }),
      );
      final frames = [
        for (final line in callOf('exec_command', {'cmd': 'echo hi'}))
          ...translator.convert(line),
      ];
      final item = itemsOf(frames).single;
      expect(item['type'], 'function_call');
      expect(item['name'], 'exec_command');
      expect(item.containsKey('namespace'), isFalse);
      expect(item['arguments'], jsonEncode({'cmd': 'echo hi'}));
    });

    test('a freeform call streams as custom input deltas', () {
      final translator = ClaudeToResponsesTranslator(
        'm',
        tools: toolsOf({
          'tools': [
            {'type': 'custom', 'name': 'exec'},
          ],
        }),
      );
      final frames = [
        for (final line in callOf('exec', {freeformInputKey: '1+1'}))
          ...translator.convert(line),
      ];
      expect(
        frames.where((frame) => frame.contains('custom_tool_call_input.delta')),
        isNotEmpty,
      );
      expect(
        frames.where((frame) => frame.contains('function_call_arguments.delta')),
        isEmpty,
      );
    });

    test('a tool the request did not declare is a plain function call', () {
      final translator = ClaudeToResponsesTranslator('m');
      final frames = [
        for (final line in callOf('unknown_tool', {'a': 1}))
          ...translator.convert(line),
      ];
      final item = itemsOf(frames).single;
      expect(item['type'], 'function_call');
      expect(item['name'], 'unknown_tool');
    });
  });
}
