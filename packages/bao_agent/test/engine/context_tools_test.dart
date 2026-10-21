import 'dart:io';

import 'package:bao_agent/bao_agent.dart';
import 'package:bao_agent/src/engine/agent_run.dart';
import 'package:bao_agent/src/engine/context_compression.dart';
import 'package:bao_agent/src/engine/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/harness.dart';

/// The model folds, searches, restores and reads back its context through
/// tools the chat does not show.
void main() {
  Future<Harness> withTurns(
    int count, {
    Map<String, Object?> context = const {},
  }) async {
    final h = await Harness.start(
      settings: {
        'contextManagement': {
          'minCompressTokens': 1,
          'keepRecentTurns': 1,
          ...context,
        },
      },
      errands: (_) => Reply.text('Generated range summary.'),
    );
    h.model.script.addAll([
      for (var i = 0; i < count; i++) Reply.text('answer $i'),
    ]);
    for (var i = 0; i < count; i++) {
      await h.turn('question $i');
    }
    return h;
  }

  Map<String, Object?>? toolResult(Harness h, String id) {
    for (final result in h.toolResults) {
      if (result['tool_use_id'] == id) {
        return (result['tool_use_result'] as Map?)?.cast<String, Object?>();
      }
    }
    return null;
  }

  test(
    'the context tools are offered only when context management is on',
    () async {
      List<String> names(Harness h) => [
        for (final tool in h.model.turns.first.body['tools'] as List)
          '${(tool as Map)['name']}',
      ];

      final off = await Harness.start(
        settings: {
          'contextManagement': {'enabled': false},
        },
      );
      addTearDown(off.dispose);
      off.model.script.add(Reply.text('ok'));
      await off.turn('hi');
      expect(names(off), isNot(contains('compress')));

      final on = await Harness.start();
      addTearDown(on.dispose);
      on.model.script.add(Reply.text('ok'));
      await on.turn('hi');
      expect(
        names(on),
        containsAll([
          'compress',
          'decompress',
          'search_context',
          'acp_status',
          'retrieve_tool_result',
        ]),
      );
    },
  );

  test('compress folds a range; decompress brings it back', () async {
    final h = await withTurns(3);
    addTearDown(h.dispose);
    h.model.script.addAll([
      Reply.tool('compress', {
        'start_ref': 'm0',
        'end_ref': 'm2',
        'summary': 'the first exchange',
      }, id: 'ct1'),
      Reply.text('done'),
    ]);
    await h.turn('question 3');
    final result = toolResult(h, 'ct1');
    expect(result!['block_id'], isNotNull);
    expect(result['messages'], 2);
    final sent = '${h.model.turns.last.body['messages']}';
    expect(sent, contains('Earlier conversation, compressed into'));
    expect(sent, contains('the first exchange'));
    expect(sent, isNot(contains('question 0')));

    h.model.script.addAll([
      Reply.tool('decompress', {'block_id': result['block_id']}, id: 'ct2'),
      Reply.text('back'),
    ]);
    await h.turn('question 4');
    final back = '${h.model.turns.last.body['messages']}';
    expect(back, contains('question 0'));
    expect(back, isNot(contains('Earlier conversation, compressed into')));
  });

  test(
    'search_context finds folded words, and acp_status says what is folded',
    () async {
      final h = await withTurns(3);
      addTearDown(h.dispose);
      h.model.script.addAll([
        Reply.tool('compress', {
          'start_ref': 'm0',
          'end_ref': 'm2',
          'summary': 'the first exchange',
        }, id: 'ct1'),
        Reply.tool('search_context', {'query': 'question 0'}, id: 'ct2'),
        Reply.tool('acp_status', const {}, id: 'ct3'),
        Reply.text('done'),
      ]);
      await h.turn('question 3');
      final search = toolResult(h, 'ct2');
      expect(search!['total'], 1);
      final match = (search['matches'] as List).single as Map;
      expect(match['block_id'], isNotNull);
      expect('${match['snippet']}', contains('question 0'));

      final status = toolResult(h, 'ct3');
      expect(status!['active_blocks'], hasLength(1));
      expect(status['saved_tokens'], greaterThan(0));
      expect(status['conversation_tokens'], greaterThan(0));
    },
  );

  test(
    'a large result is offloaded, and retrieve_tool_result reads it',
    () async {
      final h = await Harness.start(
        files: {'big.txt': 'x' * 400},
        settings: {
          'contextManagement': {
            'ccrMinTokens': 10,
            'minCompressTokens': 1,
            'keepRecentTurns': 1,
          },
        },
      );
      addTearDown(h.dispose);
      h.model.script.addAll([
        Reply.tool('Read', {'file_path': p.join(h.cwd, 'big.txt')}, id: 'tr1'),
        Reply.tool('retrieve_tool_result', {'tool_use_id': 'tr1'}, id: 'tr2'),
        Reply.text('done'),
      ]);
      await h.turn('read it');
      final afterRead = '${h.model.turns[1].body['messages']}';
      expect(afterRead, contains('Large tool result stored out of context'));
      expect(h.engine.session.store.offloadedToolResults['tr1'], isNotNull);
      // The user still saw what the tool returned.
      final shown = h.sent.where(
        (m) =>
            m['type'] == 'user' &&
            '${m['message']}'.contains('tool_result') &&
            '${m['message']}'.contains('tr1'),
      );
      expect(shown, isNotEmpty);
      expect('${shown.last['message']}', contains('x' * 400));

      final retrieved = toolResult(h, 'tr2');
      expect(retrieved!['content'], contains('x' * 400));
      expect(retrieved['total_chars'], greaterThan(400));
    },
  );

  test('a grown context is nudged once, and the nudge is not kept', () async {
    final h = await Harness.start(
      settings: {
        'contextManagement': {'nudgeGrowthTokens': 100},
      },
    );
    addTearDown(h.dispose);
    h.model.script.addAll([Reply.text('one'), Reply.text('two')]);
    await h.turn(
      'a first question long enough to be more than a hundred tokens, with '
      'several words in it so that the estimate is over the nudge line, and '
      'a little more text after that to be sure of it.',
    );
    await h.turn('a short second question');
    final first = '${h.model.turns.first.body['messages']}';
    final second = '${h.model.turns[1].body['messages']}';
    expect(first, contains('The conversation holds about'));
    expect(second, isNot(contains('The conversation holds about')));
    expect(
      File(h.sessionFile).readAsStringSync(),
      isNot(contains('The conversation holds about')),
    );
  });

  test('a subagent searches its caller\'s context, read-only', () async {
    final h = await withTurns(3);
    addTearDown(h.dispose);
    final parent = h.engine.session.mainRun;
    parent.store.append({
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': 'pt1',
            'name': 'Bash',
            'input': {'command': 'ls'},
          },
        ],
      },
    });
    parent.store.append({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'pt1',
            'content': 'parent tool output',
          },
        ],
      },
    });
    final child = AgentRun(
      session: h.engine.session,
      store: SessionStore(sessionId: 'child', cwd: h.cwd),
      agentId: 'a1',
      parentRun: parent,
    );
    final service = ContextCompression(
      h.engine.session,
      child,
      model: h.engine.session.resolvedModel,
    );
    final hits = service.search('question 0');
    expect(hits.any((hit) => hit.source == 'parent'), isTrue);
    expect(hits.first.ref, startsWith('p1:m'));
    expect(service.toolResultContent('pt1'), 'parent tool output');
    expect(
      parent.store.chain.any((e) => e['subtype'] == 'compression_restored'),
      isFalse,
    );
  });
}
