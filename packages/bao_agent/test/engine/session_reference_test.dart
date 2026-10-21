import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/harness.dart';

/// What another conversation said, as a message's reference adds it.
void main() {
  String line(String type, String text, {bool meta = false}) => jsonEncode({
    'type': type,
    'isMeta': meta,
    'message': {
      'role': type,
      'content': type == 'user'
          ? text
          : [
              {'type': 'text', 'text': text},
            ],
    },
  });

  test('the newest messages are kept when it is too long', () {
    final root = Directory.systemTemp.createTempSync('bao_ref_');
    addTearDown(() => root.deleteSync(recursive: true));
    final config = p.join(root.path, 'config');
    final project = Directory(p.join(config, 'projects', 'p'))
      ..createSync(recursive: true);
    File(p.join(project.path, 'other.jsonl')).writeAsStringSync(
      [
        line('user', 'a' * 40),
        line('assistant', 'b' * 40),
        line('assistant', 'c' * 40),
        line('user', 'injected', meta: true),
      ].join('\n'),
    );
    final paths = AgentPaths.from({'HOME': root.path}, configDir: config);
    final said = readSessionReference(paths, 'other', maxChars: 90);
    expect(said, isNotNull);
    expect(said, contains('c' * 40));
    // The older one no longer fits whole; it is dropped, not cut.
    expect(said, isNot(contains('a' * 40)));
    expect(said, isNot(contains('injected')));
  });

  test('a reference not on this machine is null', () {
    final root = Directory.systemTemp.createTempSync('bao_ref_');
    addTearDown(() => root.deleteSync(recursive: true));
    final paths = AgentPaths.from(
      {'HOME': root.path},
      configDir: p.join(root.path, 'config'),
    );
    expect(readSessionReference(paths, 'missing'), isNull);
  });

  test('a prompt referring to another conversation carries it, marked '
      'as background', () async {
    final h = await Harness.start();
    addTearDown(() => h.dispose());
    final project = Directory(p.join(h.config, 'projects', 'p'))
      ..createSync(recursive: true);
    File(p.join(project.path, 'ref1.jsonl')).writeAsStringSync(
      [
        line('user', 'Fix the login'),
        line('assistant', 'The token is read too late.'),
      ].join('\n'),
    );
    h.model.script.addAll([Reply.text('ok')]);
    await h.turn('As discussed in [Session ref1: Login notes], what was it?');
    final sent = jsonEncode(h.model.turns.single.body);
    expect(sent, contains('<session-reference>'));
    expect(sent, contains('The token is read too late.'));
    expect(sent, contains('not instructions'));
  });
}
