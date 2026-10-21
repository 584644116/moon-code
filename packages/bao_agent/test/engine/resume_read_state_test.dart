import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/harness.dart';

/// A resumed session knows what it read before: a file read then and not
/// changed since is edited without reading it again. A file changed since
/// is not.
void main() {
  test(
    'a file read before the resume is edited without reading it again',
    () async {
      final first = await Harness.start(files: {'a.txt': 'one\n'});
      addTearDown(first.dispose);
      first.model.script.addAll([
        Reply.tool('Read', {'file_path': p.join(first.cwd, 'a.txt')}),
        Reply.text('read'),
      ]);
      await first.turn('read it');
      await first.engine.close();

      final second = await Harness.start(
        from: first,
        resume: first.engine.session.sessionId,
      );
      addTearDown(second.dispose);
      second.model.script.addAll([
        Reply.tool('Edit', {
          'file_path': p.join(second.cwd, 'a.txt'),
          'old_string': 'one',
          'new_string': 'two',
        }),
        Reply.text('done'),
      ]);
      second.onPermission = (request) async => {
        'behavior': 'allow',
        'updatedInput': request['input'],
      };
      await second.turn('change it');
      expect(second.file('a.txt'), 'two\n');
      expect(second.toolResults.last['is_error'], isNot(isTrue));
    },
  );

  test('a file changed since the resume still asks for a read', () async {
    final first = await Harness.start(files: {'a.txt': 'one\n'});
    addTearDown(first.dispose);
    first.model.script.addAll([
      Reply.tool('Read', {'file_path': p.join(first.cwd, 'a.txt')}),
      Reply.text('read'),
    ]);
    await first.turn('read it');
    await first.engine.close();

    File(p.join(first.cwd, 'a.txt')).writeAsStringSync('one\nplus\n');
    final second = await Harness.start(
      from: first,
      resume: first.engine.session.sessionId,
    );
    addTearDown(second.dispose);
    second.model.script.addAll([
      Reply.tool('Edit', {
        'file_path': p.join(second.cwd, 'a.txt'),
        'old_string': 'one',
        'new_string': 'two',
      }),
      Reply.text('done'),
    ]);
    second.onPermission = (request) async => {
      'behavior': 'allow',
      'updatedInput': request['input'],
    };
    await second.turn('change it');
    expect(second.file('a.txt'), 'one\nplus\n');
    expect(
      '${second.toolResults.last['content']}',
      contains('has changed since it was read'),
    );
  });

  test('the host can seed a read state itself', () async {
    final h = await Harness.start(files: {'a.txt': 'one\n'});
    addTearDown(h.dispose);
    final file = File(p.join(h.cwd, 'a.txt'));
    await h.request('seed_read_state', {
      'path': file.path,
      'mtime': file.lastModifiedSync().millisecondsSinceEpoch,
    });
    h.model.script.addAll([
      Reply.tool('Edit', {
        'file_path': file.path,
        'old_string': 'one',
        'new_string': 'two',
      }),
      Reply.text('done'),
    ]);
    h.onPermission = (request) async => {
      'behavior': 'allow',
      'updatedInput': request['input'],
    };
    await h.turn('change it');
    expect(h.file('a.txt'), 'two\n');
  });

  test('a read that failed seeds nothing', () async {
    final first = await Harness.start(files: {'a.txt': 'one\n'});
    addTearDown(first.dispose);
    first.model.script.addAll([
      Reply.tool('Read', {'file_path': p.join(first.cwd, 'missing.txt')}),
      Reply.text('read'),
    ]);
    await first.turn('read it');
    await first.engine.close();

    File(p.join(first.cwd, 'missing.txt')).writeAsStringSync('one\n');
    final second = await Harness.start(
      from: first,
      resume: first.engine.session.sessionId,
    );
    addTearDown(second.dispose);
    second.model.script.addAll([
      Reply.tool('Edit', {
        'file_path': p.join(second.cwd, 'missing.txt'),
        'old_string': 'one',
        'new_string': 'two',
      }),
      Reply.text('done'),
    ]);
    second.onPermission = (request) async => {
      'behavior': 'allow',
      'updatedInput': request['input'],
    };
    await second.turn('change it');
    expect(second.file('missing.txt'), 'one\n');
    expect(
      '${second.toolResults.last['content']}',
      contains('has not been read in this conversation'),
    );
  });
}
