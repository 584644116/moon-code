import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/src/engine/compression_blocks.dart';
import 'package:bao_agent/src/engine/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A range can be folded into a summary and brought back; the messages
/// are kept as they were, and what is sent is the summary in their place.
void main() {
  Map<String, Object?> user(String id, String text) => {
    'type': 'user',
    'uuid': id,
    'message': {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': text},
      ],
    },
  };

  Map<String, Object?> assistant(String id, String text) => {
    'type': 'assistant',
    'uuid': id,
    'message': {
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': text},
      ],
    },
  };

  Map<String, Object?> compression(
    String id, {
    required String start,
    required String end,
    String summary = 'the start of it',
    int before = 100,
    int after = 10,
  }) => {
    'type': 'system',
    'subtype': 'compression',
    'block_id': id,
    'start_uuid': start,
    'end_uuid': end,
    'summary': summary,
    'tokens_before': before,
    'tokens_after': after,
  };

  SessionStore storeOf(List<Map<String, Object?>> entries, {String? file}) {
    final store = SessionStore(sessionId: 's', cwd: '/p', file: file);
    for (final entry in entries) {
      store.append(entry);
    }
    return store;
  }

  test('a folded range is one summary; the messages are still there', () {
    final store = storeOf([
      user('u1', 'first'),
      assistant('a1', 'answer'),
      user('u2', 'second'),
      assistant('a2', 'second answer'),
      compression('c1', start: 'u1', end: 'a1'),
    ]);
    final messages = store.apiMessages();
    expect(messages, hasLength(2));
    expect(jsonEncode(messages.first), contains('the start of it'));
    expect(jsonEncode(messages.first), contains('second'));
    expect(jsonEncode(messages.last), contains('second answer'));
    expect(store.chain, hasLength(5));
  });

  test('restoring the range brings the messages back as they were', () {
    final store = storeOf([
      user('u1', 'first'),
      assistant('a1', 'answer'),
      user('u2', 'second'),
      compression('c1', start: 'u1', end: 'a1'),
    ]);
    expect(jsonEncode(store.apiMessages()), isNot(contains('first')));
    store.append({
      'type': 'system',
      'subtype': 'compression_restored',
      'block_id': 'c1',
    });
    final messages = store.apiMessages();
    expect(jsonEncode(messages), contains('first'));
    expect(jsonEncode(messages), contains('answer'));
    expect(store.compressionBlocks, isEmpty);
  });

  test('a later block covering an earlier one leaves only the later', () {
    final store = storeOf([
      user('u1', 'first'),
      assistant('a1', 'answer'),
      user('u2', 'second'),
      assistant('a2', 'second answer'),
      compression('c1', start: 'u1', end: 'a1', summary: 'old'),
      compression('c2', start: 'u1', end: 'u2', summary: 'new'),
    ]);
    expect(store.compressionBlocks.map((b) => b.id), ['c2']);
    expect(jsonEncode(store.apiMessages()), contains('new'));
    expect(jsonEncode(store.apiMessages()), isNot(contains('old')));
  });

  test('a block is rebuilt when the session is read again', () {
    final dir = Directory.systemTemp.createTempSync('bao_compression_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = p.join(dir.path, 's.jsonl');
    storeOf([
      user('u1', 'first'),
      assistant('a1', 'answer'),
      user('u2', 'second'),
      compression('c1', start: 'u1', end: 'a1'),
    ], file: file);

    final loaded = SessionStore.resume(sessionId: 's', cwd: '/p', file: file);
    expect(loaded.compressionBlocks.single.id, 'c1');
    expect(jsonEncode(loaded.apiMessages()), contains('the start of it'));
  });

  test('rewinding past a block takes the block with it', () {
    final store = storeOf([
      user('u1', 'first'),
      assistant('a1', 'answer'),
      compression('c1', start: 'u1', end: 'a1'),
      user('u2', 'second'),
    ]);
    expect(store.compressionBlocks, hasLength(1));
    expect(store.rewindTo('a1'), isTrue);
    expect(store.compressionBlocks, isEmpty);
    expect(jsonEncode(store.apiMessages()), contains('first'));
    expect(jsonEncode(store.apiMessages()), isNot(contains('the start of it')));
  });

  test('visible prompts keep a stable ref, folded ones lose theirs', () {
    final store = storeOf([
      user('u1', 'first'),
      assistant('a1', 'answer'),
      user('u2', 'second'),
      assistant('a2', 'second answer'),
      user('u3', 'third'),
      compression('c1', start: 'u1', end: 'a1'),
    ]);
    final plain = store.apiConversation();
    expect(plain.refs, isEmpty);
    expect(plain.messages, equals(store.apiMessages()));

    final withRefs = store.apiConversation(withRefs: true);
    expect(withRefs.refs, {'m2': 2, 'm4': 4});
    expect('${withRefs.messages}', contains('<ctx id="m2"/>'));
    expect('${withRefs.messages}', contains('<ctx id="m4"/>'));
    expect('${withRefs.messages}', isNot(contains('ctx id="m0"')));
  });

  test('the same request view is made every time', () {
    final store = storeOf([
      user('u1', 'first'),
      assistant('a1', 'answer'),
      user('u2', 'second'),
      assistant('a2', 'second answer'),
      user('u3', 'third'),
      compression('c1', start: 'u1', end: 'a1'),
    ]);
    final first = jsonEncode(store.apiConversation(withRefs: true).messages);
    final second = jsonEncode(store.apiConversation(withRefs: true).messages);
    expect(second, first);
  });

  test('a large result is sent as a placeholder, its content kept', () {
    final store = storeOf([
      user('u1', 'run it'),
      {
        'type': 'assistant',
        'uuid': 'a1',
        'message': {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 't1',
              'name': 'Bash',
              'input': {'command': 'ls'},
            },
          ],
        },
      },
      {
        'type': 'user',
        'uuid': 'r1',
        'message': {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 't1',
              'content': 'a very long answer',
            },
          ],
        },
      },
      {
        'type': 'system',
        'subtype': 'offload_boundary',
        'tool_use_id': 't1',
        'tokens': 9000,
        'preview': 'a very long',
      },
    ]);
    final text = jsonEncode(store.apiMessages());
    expect(text, contains('Large tool result stored out of context'));
    expect(text, contains('retrieve_tool_result'));
    expect(text, isNot(contains('a very long answer')));
    expect(jsonEncode(store.chain), contains('a very long answer'));
    expect(store.offloadedToolResults['t1']!.tokens, 9000);
  });

  test('a pruned result is cut again when the conversation is resumed', () {
    final store = storeOf([
      user('u1', 'read it'),
      {
        'type': 'assistant',
        'uuid': 'a1',
        'message': {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 't1',
              'name': 'Read',
              'input': {'file_path': 'a.txt'},
            },
          ],
        },
      },
      {
        'type': 'user',
        'uuid': 'r1',
        'message': {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 't1',
              'content': 'HEAD${'x' * 20000}TAIL',
            },
          ],
        },
      },
      {
        'type': 'system',
        'subtype': 'microcompact_boundary',
        'microcompactMetadata': {
          'prunedToolIds': ['t1'],
          'compactedToolIds': [],
        },
      },
    ]);
    final text = jsonEncode(store.apiMessages());
    expect(text, contains('characters omitted'));
    expect(text, contains('HEAD'));
    expect(text, contains('TAIL'));
    expect(text, isNot(contains('x' * 20000)));
  });

  test('a result both cleared and offloaded keeps the offload hint', () {
    final store = storeOf([
      user('u1', 'run it'),
      {
        'type': 'assistant',
        'uuid': 'a1',
        'message': {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 't1',
              'name': 'Bash',
              'input': {'command': 'ls'},
            },
          ],
        },
      },
      {
        'type': 'user',
        'uuid': 'r1',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'tool_use_id': 't1', 'content': 'long'},
          ],
        },
      },
      {
        'type': 'system',
        'subtype': 'microcompact_boundary',
        'microcompactMetadata': {
          'compactedToolIds': ['t1'],
        },
      },
      {
        'type': 'system',
        'subtype': 'offload_boundary',
        'tool_use_id': 't1',
        'tokens': 9000,
      },
    ]);
    final text = jsonEncode(store.apiMessages());
    expect(text, contains('retrieve_tool_result'));
    expect(text, isNot(contains('Old tool result content cleared')));
  });

  test('no blocks or offloads: the view is exactly as before', () {
    final store = storeOf([
      user('u1', 'first'),
      assistant('a1', 'answer'),
      user('u2', 'second'),
    ]);
    expect(store.apiMessages(), equals(toApiMessages(store.chain)));
    expect(
      store.apiConversation().messages,
      equals(toApiMessages(store.chain)),
    );
    final conversation = store.apiConversation(withRefs: true);
    expect(conversation.refs.keys, ['m0', 'm2']);
  });

  test('a block whose ends are gone is not folded', () {
    final chain = [
      {
        'type': 'user',
        'uuid': 'u1',
        'message': {'role': 'user', 'content': 'x'},
      },
    ];
    final block = CompressionBlock(
      id: 'c1',
      startUuid: 'missing',
      endUuid: 'gone',
      summary: 'none',
      createdAt: DateTime.utc(2026),
    );
    expect(foldCompressionBlocks(chain, [block]), chain);
  });
}
