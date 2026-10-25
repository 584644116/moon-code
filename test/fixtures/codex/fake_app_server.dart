import 'dart:convert';
import 'dart:io';

/// A stand-in for `codex app-server`, run by codex_process_test.dart as a
/// real child process: JSON-RPC, one message per line, as the server
/// speaks on stdio. Not a test of its own; not run by `flutter test`.
///
/// What it answers, by request method:
/// - `echo`   — its params, back as the result.
/// - `config` — the arguments it was started with, before `app-server`.
/// - `rubbish`— a line that is not JSON first (what a warning printed to
///             stdout looks like), then `{}`.
/// - `hang`   — nothing, ever: for what a transport does when the process
///             goes with a request owed.
/// - `exit`   — ends the process, with the code its `code` param gives.
///
/// Its stdin ending ends it, code 0.
void main(List<String> arguments) {
  // Started as `dart fake_app_server.dart [-c key=value...] app-server`:
  // the overrides before the subcommand. The test names this file there in
  // place of `app-server`, so a last argument that is a script is it too.
  final last = arguments.isEmpty ? '' : arguments.last;
  final subcommand = last == 'app-server' || last.endsWith('.dart');
  final overrides = subcommand
      ? arguments.sublist(0, arguments.length - 1)
      : arguments;
  stdout.writeln('{"method":"started"}');
  var owed = 0;
  stdin
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .listen((line) {
        if (line.trim().isEmpty) return;
        final Map<String, Object?> message;
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map<String, Object?>) return;
          message = decoded;
        } on FormatException {
          return;
        }
        final id = message['id'];
        switch (message['method']) {
          case 'echo':
            _answer(id, Map<String, Object?>.from(message['params'] as Map));
          case 'config':
            _answer(id, {'arguments': overrides});
          case 'rubbish':
            stdout.writeln('this line is not protocol');
            _answer(id, const {});
          case 'hang':
            owed++;
          case 'exit':
            exit(((message['params'] as Map)['code'] as num?)?.toInt() ?? 0);
        }
      },
      onDone: () {
        // stdin closed with a request owed: the server takes its time
        // going, as one busy ending a turn would.
        if (owed > 0) {
          sleep(const Duration(milliseconds: 300));
        }
        exit(0);
      });
}

void _answer(Object? id, Map<String, Object?> result) =>
    stdout.writeln(jsonEncode({'id': id, 'result': result}));
