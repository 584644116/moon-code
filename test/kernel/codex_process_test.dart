@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/codex/codex_process_transport_io.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/codex/local_codex_io.dart';
import 'package:path/path.dart' as p;

/// One message of the protocol, as the transport hands it over.
typedef Message = Map<String, Object?>;

/// The transport over a real `codex app-server` child process. No codex
/// runs: the Dart of the test itself stands in for it
/// (test/fixtures/codex/fake_app_server.dart), found as the locator would
/// find codex, started as it would start it.
void main() {
  // The stand-in is run with Dart; `flutter test` names the tester binary
  // (flutter_tester), not the VM, so the SDK's own beside it in the cache
  // is tried, then PATH's.
  final dart = _dartToRun();
  const withoutDart = 'dart is not runnable here; these tests need it';

  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('baocode-codex');
    // Never the user's own list, nor their codex.
    CodexProcessTransport.registry = CodexProcessRegistry(
      file: File(p.join(dir.path, 'codex-processes.json')),
      lookup: (_) async => null,
      signal: (_) => false,
    );
    LocalCodex.forget();
    LocalCodex.candidatesOverride = (_) => [dart ?? 'dart'];
    CodexProcessTransport.serverArguments = [
      'test/fixtures/codex/fake_app_server.dart',
    ];
  });

  tearDown(() async {
    LocalCodex.candidatesOverride = null;
    CodexProcessTransport.serverArguments = const ['app-server'];
    LocalCodex.forget();
    await CodexProcessTransport.stopAll(
      timeout: const Duration(milliseconds: 300),
    );
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Still held by a process ending.
    }
  });

  /// The first [count] messages of the transport's, past [skip].
  Future<List<Message>> heard(
    CodexProcessTransport transport,
    int count, {
    int skip = 0,
  }) async {
    final messages = <Message>[];
    await for (final message in transport.messages.skip(skip)) {
      messages.add(message);
      if (messages.length == count) break;
    }
    return messages;
  }

  test('a request written before the server is up waits and is answered',
      skip: dart == null ? withoutDart : null, () async {
    final transport = CodexProcessTransport();
    final answers = heard(transport, 2);
    // Written while the process is still starting: held for its stdin.
    transport.write({
      'id': 1,
      'method': 'echo',
      'params': {'value': 'hello'},
    });
    final messages = await answers.timeout(const Duration(seconds: 30));
    expect(messages.last, {
      'id': 1,
      'result': {'value': 'hello'},
    });
    await transport.ready;
  });

  test('the config it is given is on the command line, before the server',
      skip: dart == null ? withoutDart : null, () async {
    // Started through a shell, as codex's npm shim is: the arguments reach
    // the stand-in as codex's own would, and the shell does not take the
    // `-c` for one of its own.
    final shim = File(p.join(dir.path, 'codex.bat'))
      ..writeAsStringSync(
        '@echo off\r\n"$dart" "'
        '${p.absolute('test/fixtures/codex/fake_app_server.dart')}" %*\r\n',
      );
    LocalCodex.forget();
    LocalCodex.candidatesOverride = (_) => [shim.path];
    final transport = CodexProcessTransport(
      config: () async => [
        '-c',
        'model_provider="baocode"',
        '-c',
        'model_providers.baocode.base_url="http://127.0.0.1:1/v1"',
      ],
    );
    await transport.ready;
    final answers = heard(transport, 1, skip: 1);
    transport.write({'id': 3, 'method': 'config'});
    final messages = await answers.timeout(const Duration(seconds: 30));
    expect(messages.single, {
      'id': 3,
      'result': {
        'arguments': [
          '-c',
          'model_provider="baocode"',
          '-c',
          'model_providers.baocode.base_url="http://127.0.0.1:1/v1"',
        ],
      },
    });
  });

  test('a line that is not protocol is passed over',
      skip: dart == null ? withoutDart : null, () async {
    final transport = CodexProcessTransport();
    await transport.ready;
    // Past the server's opening notice: what comes is the one answer, the
    // line that is not JSON having gone by unsaid.
    final answers = heard(transport, 1, skip: 1);
    transport.write({'id': 2, 'method': 'rubbish'});
    final messages = await answers.timeout(const Duration(seconds: 30));
    expect(messages.single, {'id': 2, 'result': {}});
  });

  test('a process that goes with requests owed answers for them, and says so',
      skip: dart == null ? withoutDart : null, () async {
    final transport = CodexProcessTransport();
    await transport.ready;
    final done = transport.messages.toList();
    transport.write({'id': 3, 'method': 'hang'});
    transport.write({
      'id': 4,
      'method': 'exit',
      'params': {'code': 3},
    });
    final messages = await done.timeout(const Duration(seconds: 30));
    // What it owed is answered, each with the exit said.
    expect(
      _errorOf(messages.where((m) => m['id'] == 3).single),
      contains('code 3'),
    );
    expect(messages.where((m) => m['id'] == 4).single, isNotNull);
    // And the going itself is said, as the warning the kernel shows.
    expect(
      (messages.where((m) => m['method'] == 'warning').single['params']
          as Map)['message'],
      contains('code 3'),
    );
  });

  test('close ends the process, and with it its registry entry',
      skip: dart == null ? withoutDart : null, () async {
    final transport = CodexProcessTransport();
    await transport.ready;
    transport.close();
    await CodexProcessTransport.stopAll(timeout: const Duration(seconds: 5));
    // The entry went with the process, before the app would; written
    // aside in the background, so given a moment to land.
    final listed = File(p.join(dir.path, 'codex-processes.json'));
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    Object? entries;
    while (true) {
      entries = listed.existsSync() ? jsonDecode(listed.readAsStringSync()) : null;
      if (identical(entries, const []) ||
          (entries is List && entries.isEmpty) ||
          DateTime.now().isAfter(deadline)) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(entries, isEmpty);
  });

  test('nothing installed answers every request with that said',
      skip: dart == null ? withoutDart : null, () async {
    LocalCodex.forget();
    LocalCodex.candidatesOverride = (_) => const [];
    final transport = CodexProcessTransport();
    final done = transport.messages.toList();
    transport.write({'id': 5, 'method': 'echo'});
    final messages = await done.timeout(const Duration(seconds: 30));
    expect(messages.single['id'], 5);
    expect(_errorOf(messages.single), contains('not installed'));
    await expectLater(transport.ready, throwsA(isA<CodexNotInstalled>()));
  });

  test('a folder not on this machine is refused, saying why',
      skip: dart == null ? withoutDart : null, () async {
    final transport = CodexProcessTransport(cwd: p.join(dir.path, 'gone'));
    final done = transport.messages.toList();
    transport.write({'id': 6, 'method': 'echo'});
    final messages = await done.timeout(const Duration(seconds: 30));
    expect(_errorOf(messages.single), contains('not on this machine'));
  });
}

/// What [message]'s error says, as the answers of the gone are read.
String _errorOf(Message message) =>
    (message['error'] as Map)['message'] as String;

/// The Dart to run the stand-in server with: the SDK's own, up from the
/// tester binary in the Flutter cache (the tester is at
/// `…/bin/cache/artifacts/engine/<platform>/flutter_tester`, its Dart at
/// `…/bin/cache/dart-sdk/bin/dart`); else `dart` of the PATH (an `.exe`
/// there, which Flutter's own `bin` has not: its is a `.bat`). Null with
/// none runnable.
String? _dartToRun() {
  var dir = p.dirname(Platform.resolvedExecutable);
  for (var up = 0; up < 3; up++) {
    dir = p.dirname(dir); // …/artifacts/engine/<platform> → …/bin/cache
  }
  final beside = p.join(
    dir,
    'dart-sdk',
    'bin',
    Platform.isWindows ? 'dart.exe' : 'dart',
  );
  for (final candidate in [beside, 'dart']) {
    try {
      if (Process.runSync(candidate, ['--version']).exitCode == 0) {
        return candidate;
      }
    } on ProcessException {
      // Not there: the next, then none.
    }
  }
  return null;
}
