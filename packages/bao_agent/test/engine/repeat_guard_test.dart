import 'dart:convert';

import 'package:bao_agent/src/engine/repeat_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/harness.dart';

/// The same tool call, over and over, gets a word from the agent.
void main() {
  test('the same call is called out at 3, 5 and 8, and not elsewhere', () {
    final guard = RepeatGuard();
    for (var i = 0; i < 2; i++) {
      expect(guard.record('Read', {'file_path': 'a.txt'}), isNull);
    }
    expect(guard.record('Read', {'file_path': 'a.txt'}), contains('3 times'));
    expect(guard.record('Read', {'file_path': 'a.txt'}), isNull);
    expect(guard.record('Read', {'file_path': 'a.txt'}), contains('5 times'));
    expect(guard.record('Read', {'file_path': 'a.txt'}), isNull);
    expect(guard.record('Read', {'file_path': 'a.txt'}), isNull);
    expect(guard.record('Read', {'file_path': 'a.txt'}), contains('8 times'));
  });

  test('key order does not make a different call', () {
    final guard = RepeatGuard();
    guard.record('Read', {'a': 1, 'b': 2});
    guard.record('Read', {'b': 2, 'a': 1});
    expect(guard.record('Read', {'a': 1, 'b': 2}), contains('3 times'));
  });

  test('a different tool or input starts the count again', () {
    final guard = RepeatGuard();
    guard.record('Read', {'file_path': 'a.txt'});
    guard.record('Read', {'file_path': 'a.txt'});
    expect(guard.record('Grep', {'pattern': 'a'}), isNull);
    expect(guard.record('Read', {'file_path': 'b.txt'}), isNull);
    expect(guard.record('Read', {'file_path': 'b.txt'}), isNull);
  });

  test('reset starts the count again', () {
    final guard = RepeatGuard();
    guard.record('Read', {'file_path': 'a.txt'});
    guard.record('Read', {'file_path': 'a.txt'});
    guard.reset();
    expect(guard.record('Read', {'file_path': 'a.txt'}), isNull);
    expect(guard.record('Read', {'file_path': 'a.txt'}), isNull);
  });

  test('the model is told once, before its next request', () async {
    final h = await Harness.start(files: {'a.txt': 'one\n'});
    addTearDown(h.dispose);
    final path = p.join(h.cwd, 'a.txt');
    h.model.script.addAll([
      for (var i = 0; i < 3; i++) Reply.tool('Read', {'file_path': path}),
      Reply.text('done'),
    ]);
    await h.turn('read it');
    final last = jsonEncode(h.model.turns.last.body['messages']);
    expect(
      RegExp(r'called Read with the same input 3 times').allMatches(last),
      hasLength(1),
    );
  });

  test('a new user message starts the count again', () async {
    final h = await Harness.start(files: {'a.txt': 'one\n'});
    addTearDown(h.dispose);
    final path = p.join(h.cwd, 'a.txt');
    h.model.script.addAll([
      for (var i = 0; i < 2; i++) Reply.tool('Read', {'file_path': path}),
      Reply.text('one'),
      for (var i = 0; i < 2; i++) Reply.tool('Read', {'file_path': path}),
      Reply.text('two'),
    ]);
    await h.turn('first');
    await h.turn('second');
    expect(
      jsonEncode(h.model.turns[2].body['messages']),
      isNot(contains('same input')),
    );
    expect(
      jsonEncode(h.model.turns.last.body['messages']),
      isNot(contains('same input')),
    );
  });
}
