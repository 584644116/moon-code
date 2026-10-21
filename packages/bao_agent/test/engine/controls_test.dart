import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/harness.dart';

/// An MCP server on stdio: a tool, a resource, a prompt.
const _stdioServer = r'''
import sys, json
def send(o):
    o['jsonrpc'] = '2.0'
    sys.stdout.write(json.dumps(o) + "\n")
    sys.stdout.flush()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    m = json.loads(line)
    if 'id' not in m:
        continue
    method, i, params = m.get('method'), m['id'], m.get('params') or {}
    if method == 'initialize':
        send({'id': i, 'result': {'protocolVersion': params.get('protocolVersion', '2025-06-18'),
              'capabilities': {'tools': {}, 'resources': {}, 'prompts': {}},
              'serverInfo': {'name': 'py', 'version': '1'},
              'instructions': 'Use add for sums.'}})
    elif method == 'tools/list':
        send({'id': i, 'result': {'tools': [{'name': 'add', 'description': 'Adds two numbers',
              'inputSchema': {'type': 'object', 'properties': {'a': {'type': 'number'}, 'b': {'type': 'number'}}}}]}})
    elif method == 'tools/call':
        a = params['arguments']
        send({'id': i, 'result': {'content': [{'type': 'text', 'text': str(a['a'] + a['b'])}]}})
    elif method == 'resources/list':
        send({'id': i, 'result': {'resources': [{'uri': 'mem://note', 'name': 'note', 'mimeType': 'text/plain'}]}})
    elif method == 'resources/read':
        send({'id': i, 'result': {'contents': [{'uri': params['uri'], 'mimeType': 'text/plain', 'text': 'remember milk'}]}})
    elif method == 'prompts/list':
        send({'id': i, 'result': {'prompts': [{'name': 'greet', 'description': 'Greets', 'arguments': [{'name': 'who'}]}]}})
    elif method == 'prompts/get':
        who = (params.get('arguments') or {}).get('who', '')
        send({'id': i, 'result': {'messages': [{'role': 'user', 'content': {'type': 'text', 'text': 'Say hi to ' + who}}]}})
    else:
        send({'id': i, 'error': {'code': -32601, 'message': 'no ' + str(method)}})
''';

void main() {
  late Harness h;

  tearDown(() => h.dispose());

  String sentIn(ModelRequest request) => jsonEncode(request.body['messages']);

  group('control requests', () {
    test('settings: the model and effort set, and said', () async {
      h = await Harness.start();
      await h.request('set_model', {'model': 'sonnet'});
      var applied = (await h.request('get_settings'))['applied'] as Map;
      expect(applied['model'], contains('sonnet'));
      await h.request('apply_flag_settings', {
        'settings': {'model': 'haiku', 'effortLevel': 'low'},
      });
      applied = (await h.request('get_settings'))['applied'] as Map;
      expect(applied['model'], contains('haiku'));
      expect(applied['effort'], 'low');
      h.model.script.add(Reply.text('ok'));
      await h.turn('hi');
      expect(h.model.turns.single.model, contains('haiku'));
      expect(h.of('system', 'init').single['model'], contains('haiku'));
    });

    test('get_context_usage, get_usage, file_suggestions', () async {
      h = await Harness.start(
        files: {
          'README.md': '# Hi',
          'lib/reader.dart': '',
          'CLAUDE.md': 'Be brief.',
        },
      );
      h.model.script.add(Reply.text('ok'));
      await h.turn('hi');
      final context = await h.request('get_context_usage');
      expect(context['maxTokens'], greaterThan(0));
      expect(context['totalTokens'], greaterThan(0));
      final names = [
        for (final c in context['categories'] as List) (c as Map)['name'],
      ];
      expect(names, containsAll(['System prompt', 'System tools', 'Messages']));
      expect(jsonEncode(context), contains('CLAUDE.md'));
      final usage = await h.request('get_usage');
      expect(usage['rate_limits_available'], isFalse);
      final files = await h.request('file_suggestions', {'query': 'rea'});
      final paths = [
        for (final s in files['suggestions'] as List) (s as Map)['path'],
      ];
      expect(paths, containsAll(['README.md', 'lib/reader.dart']));
    });

    test('rewind_conversation: the turns after it are gone', () async {
      h = await Harness.start();
      h.model.script.addAll([
        Reply.text('one'),
        Reply.text('two'),
        Reply.text('three'),
      ]);
      var idle = h.nextIdle();
      h.send('first', uuid: 'u-first');
      await idle;
      idle = h.nextIdle();
      h.send('second', uuid: 'u-second');
      await idle;
      final answer = await h.request('rewind_conversation', {
        'target_message_uuid': 'u-second',
      });
      expect(answer['rewound'], isTrue);
      expect(
        (await h.request('rewind_conversation', {
          'target_message_uuid': 'nope',
        }))['rewound'],
        isFalse,
      );
      await h.turn('again');
      final sent = sentIn(h.model.turns.last);
      expect(
        sent,
        allOf(contains('first'), contains('one'), contains('again')),
      );
      expect(sent, isNot(contains('second')));
    });

    test('rewind_files: the files as they were before a prompt', () async {
      h = await Harness.start(files: {'kept.txt': 'old\n'});
      h.model.script.addAll([
        Reply.tool('Read', {'file_path': p.join(h.cwd, 'kept.txt')}),
        Reply.tools([
          (
            'Edit',
            {
              'file_path': p.join(h.cwd, 'kept.txt'),
              'old_string': 'old',
              'new_string': 'new',
            },
          ),
          ('Write', {'file_path': p.join(h.cwd, 'made.txt'), 'content': 'x'}),
        ]),
        Reply.text('ok'),
      ]);
      final idle = h.nextIdle();
      h.send('change them', uuid: 'u-change');
      await idle;
      expect(h.file('kept.txt'), 'new\n');
      final dry = await h.request('rewind_files', {
        'user_message_id': 'u-change',
        'dry_run': true,
      });
      expect(dry['canRewind'], isTrue);
      expect(
        (dry['filesChanged'] as List).map((f) => p.basename('$f')),
        unorderedEquals(['kept.txt', 'made.txt']),
      );
      expect(h.file('kept.txt'), 'new\n');
      await h.request('rewind_files', {'user_message_id': 'u-change'});
      expect(h.file('kept.txt'), 'old\n');
      expect(File(p.join(h.cwd, 'made.txt')).existsSync(), isFalse);
      expect(
        (await h.request('rewind_files', {
          'user_message_id': 'nope',
        }))['canRewind'],
        isFalse,
      );
    });

    test(
      'an unknown request is an error; interrupt when idle is not',
      () async {
        h = await Harness.start();
        expect(() => h.request('no_such_thing'), throwsStateError);
        await h.request('interrupt');
      },
    );

    test('end_session ends it', () async {
      h = await Harness.start();
      await h.request('end_session');
      await h.engine.done.timeout(const Duration(seconds: 10));
      expect(h.engine.closed, isTrue);
    });
  });

  group('API errors', () {
    test('a refused key: the result says so', () async {
      h = await Harness.start();
      h.model.script.add(
        Reply.failing(
          const ApiError(
            'invalid x-api-key',
            status: 401,
            type: 'authentication_error',
          ),
        ),
      );
      await h.turn('hi');
      expect(h.lastResult['is_error'], isTrue);
      expect(
        h.lastResult['result'],
        allOf(contains('401'), contains('invalid x-api-key')),
      );
      // The host is not told twice.
      expect(h.of('assistant'), isEmpty);
    });

    test('thinking or effort refused: asked again without', () async {
      h = await Harness.start(
        effort: 'high',
        settings: {'alwaysThinkingEnabled': true},
      );
      h.model.script.addAll([
        Reply.failing(
          const ApiError('thinking: not supported by this model', status: 400),
        ),
        Reply.failing(
          const ApiError(
            'output_config.effort: Extra inputs are not permitted',
            status: 400,
          ),
        ),
        Reply.text('fine'),
      ]);
      await h.turn('hi');
      expect(h.lastResult['result'], 'fine');
      final [first, second, third] = h.model.turns;
      expect(first.body, contains('thinking'));
      expect(second.body, isNot(contains('thinking')));
      expect(jsonEncode(second.body), contains('effort'));
      expect(
        jsonEncode(third.body['output_config'] ?? {}),
        isNot(contains('effort')),
      );
    });

    test('a prompt too long: compacted, asked again', () async {
      h = await Harness.start();
      h.model.script.addAll([
        Reply.text('first'),
        Reply.failing(
          const ApiError(
            'prompt is too long: 210000 tokens > 200000 maximum',
            status: 400,
          ),
        ),
        Reply.text('<summary>Earlier talk.</summary>'),
        Reply.text('answered'),
      ]);
      await h.turn('one');
      await h.turn('two');
      expect(h.lastResult['result'], 'answered');
      expect(h.of('system', 'compact_boundary'), hasLength(1));
      expect(sentIn(h.model.turns.last), contains('Earlier talk.'));
    });

    test('a summary the model refuses: the newest messages kept', () async {
      h = await Harness.start();
      h.model.script.addAll([
        Reply.text('first answer'),
        Reply.failing(
          const ApiError(
            'prompt is too long: 210000 tokens > 200000 maximum',
            status: 400,
          ),
        ),
        // The summary, refused, however often it is asked for.
        Reply.failing(const ApiError('overloaded', status: 529)),
        Reply.text('answered'),
      ]);
      await h.turn('one');
      await h.turn('two');
      expect(h.lastResult['result'], 'answered');
      final boundary = h.of('system', 'compact_boundary').single;
      expect((boundary['compact_metadata'] as Map)['trigger'], 'auto');
      // What the conversation goes on from is what was said, not a summary.
      final sent = sentIn(h.model.turns.last);
      expect(sent, contains('first answer'));
      expect(sent, contains('What was said lately is kept below'));
      // Kept, and marked: it is a compaction, not a second telling.
      final lines = h
          .of('system', 'compact_boundary')
          .map((m) => m['uuid'])
          .toSet();
      expect(lines, isNotEmpty);
    });

    test("a subagent's context fills: compacted on its own model", () async {
      h = await Harness.start();
      final summaries = <String>[];
      var asked = 0;
      h.model.route = (request) {
        final body = jsonEncode(request.body);
        if (!body.contains('SUB')) return null;
        if (jsonEncode(request.body['system'])
            .contains('summary of a conversation')) {
          summaries.add(request.model);
          return Reply.text('<summary>SUB talk.</summary>');
        }
        asked++;
        return asked == 1
            ? Reply.failing(
                const ApiError(
                  'prompt is too long: 210000 tokens > 200000 maximum',
                  status: 400,
                ),
              )
            : Reply.text('sub done');
      };
      h.model.script.addAll([
        Reply.tool('Agent', {
          'description': 'Look',
          'prompt': 'SUB: look',
          'model': 'haiku',
        }),
        Reply.text('ok'),
      ]);
      await h.turn('go');
      // Its own conversation, summed up by its own model, and gone on
      // with: it used to end here, its context being its own to fill.
      expect(summaries, hasLength(1));
      expect(summaries.single, contains('haiku'));
      expect(
        (h.toolResults.single['tool_use_result'] as Map)['status'],
        'completed',
      );
      // Its compaction is the call's to show, not the conversation's.
      expect(h.of('system', 'compact_boundary'), isEmpty);
    });

    test(
      'two subagents compacting at once keep their contexts apart',
      () async {
        h = await Harness.start();
        bool isSummary(ModelRequest request) =>
            jsonEncode(request.body['system'])
                .contains('summary of a conversation');
        String? tagOf(ModelRequest request) {
          final first = jsonEncode((request.body['messages'] as List).first);
          if (first.contains('SUB1')) return 'SUB1';
          if (first.contains('SUB2')) return 'SUB2';
          return null;
        }

        final steps = <String, int>{'SUB1': 0, 'SUB2': 0};
        h.model.route = (request) {
          final tag = tagOf(request);
          if (tag == null) return null;
          if (isSummary(request)) {
            return Reply.text('<summary>$tag COMPACTED</summary>');
          }
          final step = steps[tag]!;
          steps[tag] = step + 1;
          return switch (step) {
            0 => Reply.tool('TodoWrite', {
              'todos': [
                {
                  'content': '$tag-TODO',
                  'status': 'pending',
                  'activeForm': tag,
                },
              ],
            }),
            1 => Reply.failing(
              const ApiError(
                'prompt is too long: 210000 tokens > 200000 maximum',
                status: 400,
              ),
            ),
            _ => Reply.text('$tag report'),
          };
        };
        h.model.script.addAll([
          Reply.tools([
            (
              'TodoWrite',
              {
                'todos': [
                  {
                    'content': 'MAIN-TODO',
                    'status': 'pending',
                    'activeForm': 'Main',
                  },
                ],
              },
            ),
            ('Agent', {'description': 'One', 'prompt': 'SUB1: look'}),
            ('Agent', {'description': 'Two', 'prompt': 'SUB2: look'}),
          ]),
          Reply.text('both done'),
        ]);
        await h.turn('go');

        List<ModelRequest> childRequests(String tag) => [
          for (final request in h.model.requests)
            if (request.body['tools'] != null &&
                jsonEncode(request.body['system']).contains('As an agent:') &&
                tagOf(request) == tag)
              request,
        ];
        // Both were at work at once: the second asked before the first
        // finished.
        int at(ModelRequest request) => h.model.requests.indexOf(request);
        expect(
          at(childRequests('SUB2').first),
          lessThan(at(childRequests('SUB1').last)),
        );
        // Each went on from its own summary, its own todos carried over,
        // and none of the other's.
        for (final tag in const ['SUB1', 'SUB2']) {
          final other = tag == 'SUB1' ? 'SUB2' : 'SUB1';
          final after = sentIn(childRequests(tag).last);
          expect(after, contains('$tag COMPACTED'));
          expect(after, contains('$tag-TODO'));
          expect(after, isNot(contains('$other COMPACTED')));
          expect(after, isNot(contains('$other-TODO')));
          expect(after, isNot(contains('MAIN-TODO')));
        }
        // The main agent's conversation has the reports, not the summaries.
        final main = h.model.requests.lastWhere(
          (request) =>
              request.body['tools'] != null &&
              !jsonEncode(request.body['system']).contains('As an agent:') &&
              !isSummary(request),
        );
        expect(sentIn(main), contains('SUB1 report'));
        expect(sentIn(main), contains('SUB2 report'));
        expect(sentIn(main), contains('MAIN-TODO'));
        expect(sentIn(main), isNot(contains('COMPACTED')));
        // Neither subagent's compaction is the conversation's to show.
        expect(h.of('system', 'compact_boundary'), isEmpty);

        final dir = p.join(p.withoutExtension(h.sessionFile), 'subagents');
        final files = Directory(dir)
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.jsonl'))
            .toList();
        expect(files, hasLength(2));
        for (final file in files) {
          final agentId = p
              .basenameWithoutExtension(file.path)
              .replaceFirst('agent-', '');
          final lines = [
            for (final line in file.readAsLinesSync())
              (jsonDecode(line) as Map).cast<String, Object?>(),
          ];
          // Every line is of the side chain, and names that agent: the
          // boundaries and summaries a compaction writes too.
          expect(
            lines.every((line) => line['isSidechain'] == true),
            isTrue,
            reason: '${file.path} has a line of the parent',
          );
          expect(
            lines.every((line) => line['agentId'] == agentId),
            isTrue,
            reason: '${file.path} names another agent',
          );
          expect(
            lines.where((line) => line['subtype'] == 'compact_boundary'),
            hasLength(1),
          );
          final summary = lines.firstWhere(
            (line) => line['isCompactSummary'] == true,
          );
          final tag = jsonEncode(summary['message']).contains('SUB1')
              ? 'SUB1'
              : 'SUB2';
          expect(jsonEncode(summary), contains('$tag COMPACTED'));
          expect(jsonEncode(summary), contains('$tag-TODO'));
          expect(jsonEncode(summary), isNot(contains('MAIN-TODO')));
        }
      },
    );

    test('the main agent and a subagent compact at once, apart', () async {
      h = await Harness.start();
      bool isSummary(ModelRequest request) =>
          jsonEncode(request.body['system'])
              .contains('summary of a conversation');
      bool childThread(ModelRequest request) =>
          jsonEncode((request.body['messages'] as List).first).contains('SUB');

      var subSteps = 0;
      h.model.route = (request) {
        if (isSummary(request)) {
          return Reply.text(
            childThread(request)
                ? '<summary>SUB COMPACTED</summary>'
                : '<summary>MAIN COMPACTED</summary>',
          );
        }
        if (childThread(request)) {
          subSteps++;
          return subSteps == 1
              ? Reply.failing(
                  const ApiError(
                    'prompt is too long: 210000 tokens > 200000 maximum',
                    status: 400,
                  ),
                )
              : Reply.text('sub report');
        }
        if (jsonEncode(request.body['messages'])
            .contains('<task-notification>')) {
          return Reply.text('noted');
        }
        return null;
      };
      h.model.script.addAll([
        Reply.tool('Agent', {
          'description': 'Background',
          'prompt': 'SUB: look',
          'run_in_background': true,
        }),
        Reply.failing(
          const ApiError(
            'prompt is too long: 210000 tokens > 200000 maximum',
            status: 400,
          ),
        ),
        Reply.text('main done'),
      ]);
      await h.turn('go');
      if (h.of('system', 'task_notification').isEmpty) {
        await h.nextIdle().timeout(const Duration(seconds: 10));
      }

      // The main agent went on from its own summary ...
      final mainAfter = sentIn(
        h.model.requests.lastWhere(
          (request) =>
              request.body['tools'] != null &&
              !childThread(request) &&
              !isSummary(request) &&
              sentIn(request).contains('MAIN COMPACTED'),
        ),
      );
      expect(mainAfter, contains('MAIN COMPACTED'));
      expect(mainAfter, isNot(contains('SUB COMPACTED')));
      // ... the subagent from its own.
      final childAfter = sentIn(
        h.model.requests.lastWhere(
          (request) =>
              childThread(request) && sentIn(request).contains('SUB COMPACTED'),
        ),
      );
      expect(childAfter, contains('SUB COMPACTED'));
      expect(childAfter, isNot(contains('MAIN COMPACTED')));
      // Each was compacting while the other was still at work: the child's
      // summary was asked before the main agent came back, and the main
      // agent's before the child answered.
      final parentSummary = h.model.requests.indexWhere(
        (request) => isSummary(request) && !childThread(request),
      );
      final childSummary = h.model.requests.indexWhere(
        (request) => isSummary(request) && childThread(request),
      );
      final parentLast = h.model.requests.lastIndexWhere(
        (request) =>
            request.body['tools'] != null &&
            !childThread(request) &&
            !isSummary(request),
      );
      final childLast = h.model.requests.lastIndexWhere(
        (request) => childThread(request) && !isSummary(request),
      );
      expect(childSummary, lessThan(parentLast));
      expect(parentSummary, lessThan(childLast));
      // Only the conversation's own compaction is the host's to show.
      expect(h.of('system', 'compact_boundary'), hasLength(1));

      final dir = p.join(p.withoutExtension(h.sessionFile), 'subagents');
      final file = Directory(dir)
          .listSync()
          .whereType<File>()
          .singleWhere((file) => file.path.endsWith('.jsonl'));
      final lines = [
        for (final line in file.readAsLinesSync())
          (jsonDecode(line) as Map).cast<String, Object?>(),
      ];
      expect(lines.every((line) => line['isSidechain'] == true), isTrue);
      expect(
        lines.where((line) => line['subtype'] == 'compact_boundary'),
        hasLength(1),
      );
      final summary = lines.firstWhere(
        (line) => line['isCompactSummary'] == true,
      );
      expect(jsonEncode(summary), contains('SUB COMPACTED'));
      expect(jsonEncode(summary), isNot(contains('MAIN COMPACTED')));
    });

    test('old tool results are cleared before a summary is asked', () async {
      final big1 = [for (var i = 0; i < 300; i++) 'BIG1-$i ${'x' * 90}']
          .join('\n');
      final big2 = [for (var i = 0; i < 300; i++) 'BIG2-$i ${'y' * 90}']
          .join('\n');
      // This is about microcompaction, not about offloading a large
      // result: keep the results in the context for it to clear.
      h = await Harness.start(
        files: {'big1.txt': big1, 'big2.txt': big2},
        settings: {
          'contextManagement': {'ccrMinTokens': 0},
        },
      );
      final cwd = h.cwd;
      var calls = 0;
      Map<String, Object?> usage(int input) => {
        'input_tokens': input,
        'cache_read_input_tokens': 0,
        'cache_creation_input_tokens': 0,
        'output_tokens': 10,
      };
      Reply call(String name, Map<String, Object?> input, int inputTokens) =>
          Reply(
            [
              {
                'type': 'tool_use',
                'id': 'toolu_${calls++}',
                'name': name,
                'input': input,
              },
            ],
            stopReason: 'tool_use',
            usage: usage(inputTokens),
          );
      h.model.script.addAll([
        call('Read', {'file_path': p.join(cwd, 'big1.txt')}, 100000),
        call('Read', {'file_path': p.join(cwd, 'big2.txt')}, 120000),
        call('Grep', {'pattern': 'needle', 'path': cwd}, 130000),
        call('Grep', {'pattern': 'needle', 'path': cwd}, 140000),
        call('Grep', {'pattern': 'needle', 'path': cwd}, 150000),
        call('Glob', {'pattern': '*.txt', 'path': cwd}, 175000),
        Reply.text('done'),
      ]);
      await h.turn('go');

      // The old output made room: no summary was asked for.
      expect(
        h.model.requests.where(
          (request) =>
              jsonEncode(request.body['system'])
                  .contains('summary of a conversation'),
        ),
        isEmpty,
      );
      // What is sent has the placeholder for the oldest group, and the
      // last five groups as they were.
      final sent = sentIn(h.model.turns.last);
      expect(sent, contains('Old tool result content cleared'));
      expect(sent, isNot(contains('BIG1-')));
      expect(sent, contains('BIG2-'));
      // The file keeps what was said; only the request left it out.
      final kept = File(h.sessionFile).readAsStringSync();
      expect(kept, contains('BIG1-'));
      expect(kept, contains('BIG2-'));
      expect(
        kept
            .split('\n')
            .where((line) => line.contains('"microcompact_boundary"')),
        hasLength(1),
      );
      expect(h.of('system', 'compact_boundary'), isEmpty);
    });

    test('a file read before the summary is given back after it', () async {
      final content = [for (var i = 0; i < 50; i++) 'RESTORE-$i ${'z' * 80}']
          .join('\n');
      h = await Harness.start(files: {'restore.txt': content});
      final cwd = h.cwd;
      h.model.route = (request) {
        if (jsonEncode(request.body['system'])
            .contains('summary of a conversation')) {
          return Reply.text('<summary>RESTORE talk.</summary>');
        }
        return null;
      };
      h.model.script.addAll([
        Reply(
          [
            {
              'type': 'tool_use',
              'id': 'toolu_restore',
              'name': 'Read',
              'input': {'file_path': p.join(cwd, 'restore.txt')},
            },
          ],
          stopReason: 'tool_use',
          usage: {
            'input_tokens': 100000,
            'cache_read_input_tokens': 0,
            'cache_creation_input_tokens': 0,
            'output_tokens': 10,
          },
        ),
        Reply.failing(
          const ApiError(
            'prompt is too long: 210000 tokens > 200000 maximum',
            status: 400,
          ),
        ),
        Reply.text('done'),
      ]);
      await h.turn('go');

      final sent = sentIn(h.model.turns.last);
      expect(
        sent,
        contains('The files read before the conversation was compacted'),
      );
      expect(sent, contains('RESTORE-'));
      expect(sent, contains('restore.txt'));
    });

    test('a summary is asked without the images in the conversation', () async {
      h = await Harness.start();
      final summaries = <ModelRequest>[];
      h.model.route = (request) {
        if (jsonEncode(request.body['system'])
            .contains('summary of a conversation')) {
          summaries.add(request);
          return Reply.text('<summary>seen.</summary>');
        }
        return null;
      };
      h.model.script.addAll([
        Reply.failing(
          const ApiError(
            'prompt is too long: 210000 tokens > 200000 maximum',
            status: 400,
          ),
        ),
        Reply.text('done'),
      ]);
      await h.turn(
        'look',
        blocks: [
          {
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': 'image/png',
              'data': 'aGVsbG8=',
            },
          },
        ],
      );

      expect(summaries, hasLength(1));
      final sent = jsonEncode(summaries.single.body['messages']);
      expect(sent, contains('[image]'));
      expect(sent, isNot(contains('"type":"image"')));
    });

    test("a subagent's model the provider lacks: the session's own", () async {
      h = await Harness.start();
      final models = <String>[];
      h.model.route = (request) {
        if (!jsonEncode((request.body['messages'] as List).first)
            .contains('SUB:')) {
          return null;
        }
        models.add(request.model);
        return models.length == 1
            ? Reply.failing(const ApiError('model: not found', status: 404))
            : Reply.text('sub done');
      };
      h.model.script.addAll([
        Reply.tool('Agent', {
          'description': 'Look',
          'prompt': 'SUB: look',
          'model': 'haiku',
        }),
        Reply.text('ok'),
      ]);
      await h.turn('go');
      expect(models.first, contains('haiku'));
      expect(models.last, h.model.turns.first.model);
      expect(
        (h.toolResults.single['tool_use_result'] as Map)['status'],
        'completed',
      );
    });
  });

  group('MCP', () {
    test("the host's own server, through the control channel", () async {
      final calls = <Map>[];
      h = await Harness.start(sdkServers: ['bao']);
      h.onRequest = (request) async {
        if (request['subtype'] != 'mcp_message') return const {};
        final message = request['message'] as Map;
        calls.add(message);
        final id = message['id'];
        Map<String, Object?> result(Map<String, Object?> r) => {
          'mcp_response': {'jsonrpc': '2.0', 'id': id, 'result': r},
        };
        return switch (message['method']) {
          'initialize' => result({
            'protocolVersion': '2025-06-18',
            'capabilities': {'tools': {}},
            'serverInfo': {'name': 'bao', 'version': '1'},
          }),
          'tools/list' => result({
            'tools': [
              {
                'name': 'open_page',
                'description': 'Opens a page',
                'inputSchema': {
                  'type': 'object',
                  'properties': {
                    'url': {'type': 'string'},
                  },
                },
              },
            ],
          }),
          'tools/call' => result({
            'content': [
              {
                'type': 'text',
                'text':
                    'opened ${(message['params'] as Map)['arguments']['url']}',
              },
            ],
          }),
          _ => {
            'mcp_response': {'jsonrpc': '2.0', 'id': id, 'result': {}},
          },
        };
      };
      h.model.script.addAll([
        Reply.tool('mcp__bao__open_page', {'url': 'https://example.com'}),
        Reply.text('ok'),
      ]);
      await h.turn('open it');
      final init = h.of('system', 'init').single;
      expect(init['tools'], contains('mcp__bao__open_page'));
      expect(
        init['mcp_servers'],
        contains(
          allOf(
            containsPair('name', 'bao'),
            containsPair('status', 'connected'),
          ),
        ),
      );
      expect(
        jsonEncode(h.toolResults.single['content']),
        contains('opened https://example.com'),
      );
      expect(
        calls.map((c) => c['method']),
        containsAll(['initialize', 'tools/list', 'tools/call']),
      );
    });

    test(
      "a server's errors, structured and large results, binary resources",
      () async {
        h = await Harness.start(
          sdkServers: ['kit'],
          environment: {'MAX_MCP_OUTPUT_TOKENS': '50'},
        );
        h.onRequest = (request) async {
          final message = request['message'] as Map;
          final id = message['id'];
          Map<String, Object?> answer(Object result) => {
            'mcp_response': {'jsonrpc': '2.0', 'id': id, 'result': result},
          };
          final params = (message['params'] as Map?) ?? {};
          return switch (message['method']) {
            'initialize' => answer({
              'protocolVersion': '2025-06-18',
              'capabilities': {'tools': {}, 'resources': {}},
              'serverInfo': {'name': 'kit', 'version': '1'},
            }),
            'tools/list' => answer({
              'tools': [
                for (final name in ['fails', 'structured', 'big', 'errs'])
                  {
                    'name': name,
                    'description': name,
                    'inputSchema': {'type': 'object'},
                  },
              ],
            }),
            'resources/list' => answer({
              'resources': [
                {'uri': 'mem://bin', 'name': 'bin'},
              ],
            }),
            'resources/read' => answer({
              'contents': [
                {
                  'uri': 'mem://bin',
                  'mimeType': 'application/octet-stream',
                  'blob': 'AAAAAAAA',
                },
              ],
            }),
            'tools/call' => switch (params['name']) {
              'fails' => {
                'mcp_response': {
                  'jsonrpc': '2.0',
                  'id': id,
                  'error': {'code': -32000, 'message': 'tool broke'},
                },
              },
              'structured' => answer({
                'content': [],
                'structuredContent': {'answer': 42},
              }),
              'big' => answer({
                'content': [
                  {'type': 'text', 'text': 'x' * 1000},
                  {'type': 'text', 'text': 'more'},
                ],
              }),
              _ => answer({
                'isError': true,
                'content': [
                  {'type': 'text', 'text': 'bad input'},
                ],
              }),
            },
            _ => answer({}),
          };
        };
        h.model.script.addAll([
          Reply.tools([
            ('mcp__kit__fails', {}),
            ('mcp__kit__structured', {}),
            ('mcp__kit__big', {}),
            ('mcp__kit__errs', {}),
            ('ReadMcpResourceTool', {'server': 'kit', 'uri': 'mem://bin'}),
            ('ReadMcpResourceTool', {'server': 'none', 'uri': 'x'}),
            ('ListMcpResourcesTool', {'server': 'none'}),
          ]),
          Reply.text('ok'),
        ]);
        await h.turn('go');
        final [fails, structured, big, errs, blob, noServer, noList] = [
          for (final r in h.toolResults) jsonEncode(r['content']),
        ];
        expect(fails, contains('MCP error: tool broke'));
        expect(structured, contains('{\\"answer\\":42}'));
        expect(big, contains('MAX_MCP_OUTPUT_TOKENS'));
        expect(big.length, lessThan(800));
        expect(errs, contains('bad input'));
        expect(h.toolResults[3]['is_error'], isTrue);
        expect(blob, contains('[binary content, 6 bytes]'));
        expect(noServer, contains('is connected'));
        expect(noList, contains('is connected'));
      },
    );

    test('a long answer is cut where it is least missed', () async {
      h = await Harness.start(
        sdkServers: ['kit'],
        environment: {'MAX_MCP_OUTPUT_TOKENS': '40'},
      );
      // A log says what happened in its last lines, a table in its first.
      final log = [
        for (var i = 0; i < 40; i++)
          '2026-10-21T09:00:${i.toString().padLeft(2, '0')} '
              'INFO step $i',
        '2026-10-21T09:01:00 ERROR the thing that matters',
      ].join('\n');
      final table = [for (var i = 0; i < 40; i++) 'row$i\tvalue$i\t${i * 2}']
          .join('\n');
      h.onRequest = (request) async {
        final message = request['message'] as Map;
        final id = message['id'];
        Map<String, Object?> answer(Object result) => {
          'mcp_response': {'jsonrpc': '2.0', 'id': id, 'result': result},
        };
        final params = (message['params'] as Map?) ?? {};
        return switch (message['method']) {
          'initialize' => answer({
            'protocolVersion': '2025-06-18',
            'capabilities': {'tools': {}},
            'serverInfo': {'name': 'kit', 'version': '1'},
          }),
          'tools/list' => answer({
            'tools': [
              for (final name in ['log', 'table'])
                {
                  'name': name,
                  'description': name,
                  'inputSchema': {'type': 'object'},
                },
            ],
          }),
          'tools/call' => answer({
            'content': [
              {'type': 'text', 'text': params['name'] == 'log' ? log : table},
            ],
          }),
          _ => answer({}),
        };
      };
      h.model.script.addAll([
        Reply.tools([('mcp__kit__log', {}), ('mcp__kit__table', {})]),
        Reply.text('ok'),
      ]);
      await h.turn('go');
      final [keptLog, keptTable] = [
        for (final r in h.toolResults) jsonEncode(r['content']),
      ];
      // The log's end, where the error is; the table's start, its rows.
      expect(keptLog, contains('the thing that matters'));
      expect(keptLog, contains('step 39'));
      expect(keptLog, isNot(contains('step 20')));
      expect(keptTable, contains('row0'));
      expect(keptTable, isNot(contains('row39')));
    });

    String? python() {
      try {
        final found = Process.runSync('python3', [
          '-c',
          'import sys; print(sys.executable)',
        ]);
        return found.exitCode == 0 ? '${found.stdout}'.trim() : null;
      } on ProcessException {
        return null;
      }
    }

    test(
      'a stdio server: tools, resources, prompts, status and toggling',
      () async {
        final interpreter = python()!;
        final dir = Directory.systemTemp
            .createTempSync('mcp_')
            .resolveSymbolicLinksSync();
        addTearDown(() => Directory(dir).deleteSync(recursive: true));
        final server = File(p.join(dir, 'server.py'))
          ..writeAsStringSync(_stdioServer);
        h = await Harness.start(
          files: {
            '.mcp.json': jsonEncode({
              'mcpServers': {
                'py': {
                  'command': interpreter,
                  'args': ['-I', server.path],
                },
              },
            }),
          },
        );
        h.model.script.addAll([
          Reply.tools([
            ('mcp__py__add', {'a': 2, 'b': 3}),
            ('ListMcpResourcesTool', {}),
            ('ReadMcpResourceTool', {'server': 'py', 'uri': 'mem://note'}),
          ]),
          Reply.text('5'),
        ]);
        await h.turn('add');
        final [sum, list, read] = h.toolResults;
        expect(jsonEncode(sum['content']), contains('5'));
        expect(jsonEncode(list['content']), contains('mem://note'));
        expect(jsonEncode(read['content']), contains('remember milk'));
        expect(
          jsonEncode(h.model.turns.first.body['system']),
          contains('Use add for sums.'),
        );
        // Its prompt, as a command.
        expect(
          h.of('system', 'init').last['slash_commands'],
          contains('mcp__py__greet'),
        );
        h.model.script.add(Reply.text('hi Ada'));
        await h.turn('/mcp__py__greet Ada');
        expect(sentIn(h.model.turns.last), contains('Say hi to Ada'));
        final status = await h.request('mcp_status');
        expect(
          status['mcpServers'],
          contains(
            allOf(
              containsPair('name', 'py'),
              containsPair('status', 'connected'),
            ),
          ),
        );
        await h.request('mcp_toggle', {'serverName': 'py', 'enabled': false});
        h.model.script.add(Reply.text('ok'));
        await h.turn('again');
        final names = [
          for (final t in h.model.turns.last.body['tools'] as List)
            (t as Map)['name'],
        ];
        expect(names, isNot(contains('mcp__py__add')));
        await h.request('mcp_toggle', {'serverName': 'py', 'enabled': true});
        await h.request('mcp_reconnect', {'serverName': 'py'});
        h.model.script.add(Reply.text('ok'));
        await h.turn('and again');
        final back = [
          for (final t in h.model.turns.last.body['tools'] as List)
            (t as Map)['name'],
        ];
        expect(back, contains('mcp__py__add'));
      },
      skip: python() == null ? 'no python3' : false,
    );

    test('an HTTP server', () async {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => http.close(force: true));
      http.listen((request) async {
        final body = jsonDecode(await utf8.decodeStream(request)) as Map;
        final id = body['id'];
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('mcp-session-id', 's1');
        if (id == null) {
          request.response.statusCode = 202;
        } else {
          request.response.write(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': switch (body['method']) {
                'initialize' => {
                  'protocolVersion': '2025-06-18',
                  'capabilities': {'tools': {}},
                  'serverInfo': {'name': 'web', 'version': '1'},
                },
                'tools/list' => {
                  'tools': [
                    {
                      'name': 'ping',
                      'description': 'Ping',
                      'inputSchema': {'type': 'object'},
                    },
                  ],
                },
                'tools/call' => {
                  'content': [
                    {'type': 'text', 'text': 'pong'},
                  ],
                },
                _ => {},
              },
            }),
          );
        }
        await request.response.close();
      });
      h = await Harness.start(
        flagSettings: {
          'mcpServers': {
            'web': {'type': 'http', 'url': 'http://127.0.0.1:${http.port}/mcp'},
          },
        },
      );
      h.model.script.addAll([
        Reply.tool('mcp__web__ping', {}),
        Reply.text('ok'),
      ]);
      await h.turn('ping');
      expect(jsonEncode(h.toolResults.single['content']), contains('pong'));
    });
  });
}
