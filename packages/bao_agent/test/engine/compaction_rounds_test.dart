import 'dart:convert';

import 'package:bao_agent/bao_agent.dart';
import 'package:bao_agent/src/engine/compaction.dart';
import 'package:bao_agent/src/engine/compression_blocks.dart';
import 'package:bao_agent/src/engine/session_store.dart';
import 'package:bao_agent/src/util/cancel.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// When a conversation is compacted, and what is kept as it was said.
void main() {
  test('a window keeps room for the answer and the request', () {
    // 128K and 200K: 21K of answer room, 13K of request room.
    expect(Compaction.thresholdOf(128000, maxOutput: 32000), 94000);
    expect(Compaction.thresholdOf(200000, maxOutput: 64000), 166000);
    // A million-token window reserves the same, not a share of it.
    expect(Compaction.thresholdOf(1000000, maxOutput: 128000), 966000);
    // No answer size known: the session's own buffer is the reserve.
    expect(Compaction.thresholdOf(128000), 95000);
    expect(Compaction.thresholdOf(200000), 167000);
    // A small window does not compact below half of it.
    expect(Compaction.thresholdOf(32000, maxOutput: 8000), 16000);
  });

  test(
    'a summary keeps the exchange it goes on from, as it was said',
    () async {
      final h = await Harness.start(settings: {'autoCompactWindow': 20000});
      addTearDown(h.dispose);
      h.model.route = (request) {
        if (jsonEncode(request.body['system'])
            .contains('summary of a conversation')) {
          return Reply.text('<summary>SUMMARY</summary>');
        }
        return null;
      };
      h.engine.session.store = SessionStore(sessionId: 's1', cwd: h.cwd);
      final run = h.engine.session.mainRun;
      final store = run.store;
      _user(store, 'first question');
      _assistant(store, {'type': 'text', 'text': 'first answer'});
      _user(store, 'latest question');
      _assistant(store, {
        'type': 'tool_use',
        'id': 't1',
        'name': 'Bash',
        'input': {'command': 'ls'},
      });
      _result(store, 't1', 'file list');

      final done = await Compaction(
        h.engine.session,
        run,
      ).compact(trigger: 'manual', cancel: CancelToken());
      expect(done, isTrue);

      final retained = store.chain
          .where((entry) => entry['isRetainedTurn'] == true)
          .toList();
      expect(retained.map((entry) => entry['type']), [
        'user',
        'assistant',
        'user',
      ]);
      expect('${retained.first['message']}', contains('latest question'));

      final messages = store.apiMessages();
      final flat = jsonEncode(messages);
      // The summary comes first, then what was said last, in order.
      expect(flat, contains('SUMMARY'));
      expect(flat, contains('most recent exchange is kept below'));
      expect(
        flat.indexOf('latest question'),
        greaterThan(flat.indexOf('SUMMARY')),
      );
      expect(flat, contains('t1'));
      expect(flat, contains('file list'));
      expect(flat, isNot(contains('first question')));
    },
  );

  test(
    'a kept exchange over its budget drops whole calls, never a pairing',
    () async {
      final h = await Harness.start(settings: {'autoCompactWindow': 20000});
      addTearDown(h.dispose);
      h.model.route = (request) {
        if (jsonEncode(request.body['system'])
            .contains('summary of a conversation')) {
          return Reply.text('<summary>SUMMARY</summary>');
        }
        return null;
      };
      h.engine.session.store = SessionStore(sessionId: 's1', cwd: h.cwd);
      final run = h.engine.session.mainRun;
      final store = run.store;
      _user(store, 'first question');
      _assistant(store, {
        'type': 'tool_use',
        'id': 'old',
        'name': 'Read',
        'input': {'file_path': 'big.txt'},
      });
      _result(store, 'old', 'x' * 30000);
      _assistant(store, {
        'type': 'tool_use',
        'id': 'new',
        'name': 'Bash',
        'input': {'command': 'pwd'},
      });
      _result(store, 'new', 'small result');

      await Compaction(
        h.engine.session,
        run,
      ).compact(trigger: 'manual', cancel: CancelToken());

      final retained = store.chain
          .where((entry) => entry['isRetainedTurn'] == true)
          .toList();
      // The 2K budget cannot hold the large call: it and the prompt go, and
      // the last call stays with its result.
      expect(retained.map((entry) => entry['type']), ['assistant', 'user']);
      expect('${retained.first['message']}', contains('new'));
      expect('${retained.first['message']}', isNot(contains('old')));
      expect('${retained.last['message']}', contains('small result'));
      expect(
        jsonEncode(store.apiMessages()),
        isNot(contains('first question')),
      );
    },
  );

  test(
    'microcompaction clears old groups only, and protects what matters',
    () async {
      final h = await Harness.start(settings: {'autoCompactWindow': 20000});
      addTearDown(h.dispose);
      h.engine.session.store = SessionStore(sessionId: 's1', cwd: h.cwd);
      final run = h.engine.session.mainRun;
      final store = run.store;
      _user(store, 'go');
      for (var i = 0; i < 9; i++) {
        _assistant(store, {
          'type': 'tool_use',
          'id': 't$i',
          'name': 'Grep',
          'input': {'pattern': 'needle'},
        });
        final Object content = switch (i) {
          0 => 'x' * 60000,
          1 => [
            {'type': 'text', 'text': 'the command failed'},
          ],
          2 => [
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': 'image/png',
                'data': 'aGVsbG8=',
              },
            },
          ],
          _ => 'result $i',
        };
        _result(store, 't$i', content, isError: i == 1);
      }
      // The fourth group's result is already kept out of the context.
      store.offloadedToolResults['t3'] = const OffloadedResult(
        toolUseId: 't3',
        tokens: 5000,
      );

      final done = Compaction(h.engine.session, run).microcompact();
      expect(done, isTrue);
      // Only the first group went: the failure, the image and the offloaded
      // result stay, and the last five groups were never candidates.
      expect(store.clearedToolResults, {'t0'});
      final boundary = store.chain.lastWhere(
        (entry) => entry['subtype'] == 'microcompact_boundary',
      );
      final metadata = (boundary['microcompactMetadata'] as Map)
          .cast<String, Object?>();
      expect(metadata['compactedToolIds'], ['t0']);
    },
  );
}

void _user(SessionStore store, String text) => store.append({
  'type': 'user',
  'message': {'role': 'user', 'content': text},
});

void _assistant(SessionStore store, Map<String, Object?> block) =>
    store.append({
      'type': 'assistant',
      'message': {
        'role': 'assistant',
        'content': [block],
      },
    });

void _result(
  SessionStore store,
  String id,
  Object content, {
  bool isError = false,
}) => store.append({
  'type': 'user',
  'message': {
    'role': 'user',
    'content': [
      {
        'type': 'tool_result',
        'tool_use_id': id,
        'content': content,
        if (isError) 'is_error': true,
      },
    ],
  },
});
