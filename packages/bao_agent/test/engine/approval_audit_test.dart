import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/harness.dart';

/// What was asked and decided is kept beside the session, not in it.
void main() {
  test('an approval is written down, with its risk', () async {
    final h = await Harness.start();
    addTearDown(h.dispose);
    h.model.script.addAll([
      Reply.tool('Bash', {'command': 'touch a', 'description': 'Touch'}),
      Reply.text('done'),
    ]);
    await h.turn('go');
    final file = File(
      p.join(h.config, 'approvals', '${h.engine.session.sessionId}.jsonl'),
    );
    expect(file.existsSync(), isTrue);
    final lines = [
      for (final line in file.readAsLinesSync()) jsonDecode(line) as Map,
    ];
    expect(lines, hasLength(2));
    expect(lines.first['type'], 'asked');
    expect(lines.first['tool'], 'Bash');
    expect(lines.first['risk'], 'write');
    expect(lines.first['input'], 'touch a');
    expect(lines.last['type'], 'decided');
    expect(lines.last['decision'], 'allowed');
  });
}
