import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../platform/child_process_registry.dart';
import '../../platform/data_dir.dart';
import 'codex_transport.dart';
import 'local_codex_io.dart';

/// `codex app-server` as a child process, over its stdin and stdout. The
/// server is started in the constructor, ahead of the first request: what
/// is written before it is up waits for it, and a start that fails answers
/// those requests with the failure (the kernel says it in the
/// conversation) rather than leaving them waiting forever.
class CodexProcessTransport implements CodexTransport {
  CodexProcessTransport({this.cwd, this.config}) {
    _live.add(this);
    _starting = _start();
  }

  /// The project directory the server works in; codex keeps each thread
  /// under the directory its server runs in. Null for none in particular.
  final String? cwd;

  /// `-c` overrides the server is started with, worked out just before it
  /// starts: the upstream its turns go to (this app's proxy, which speaks
  /// the Responses API to every upstream of Settings → Models), and the
  /// token that proxy takes.
  final Future<List<String>> Function()? config;

  /// A transport over [process], e.g. a stand-in process under test.
  @visibleForTesting
  CodexProcessTransport.forProcess(Process process, {this.cwd})
    : config = null,
      _process = process {
    _live.add(this);
    unawaited(registry.add(process.pid));
    _wire();
  }

  Process? _process;
  Future<void>? _starting;
  bool _closing = false;

  /// What the server is started with: its subcommand, or a stand-in
  /// program under test.
  @visibleForTesting
  static List<String> serverArguments = const ['app-server'];

  /// What a start that failed failed with, told to whoever asks [ready].
  Object? _startError;

  /// Completes once the server is up; or with what failed to start it,
  /// before any request is left waiting on one.
  late final Future<void> ready = (_starting ?? Future.value()).then(
    (_) => switch (_startError) {
      final error? => throw error,
      null => null,
    },
  );

  /// Where the running processes are kept track of across runs.
  @visibleForTesting
  static CodexProcessRegistry registry = CodexProcessRegistry(
    file: File(DataDirectory.current.processRegistryFile('codex')),
  );

  /// The processes this run of the app started and that still run.
  static final Set<CodexProcessTransport> _live = {};

  /// Ends every codex process this run started, and waits (up to
  /// [timeout] each) for them to go: done as the app quits, so a turn
  /// under way does not go on unseen, spending tokens, after the app is
  /// gone.
  static Future<void> stopAll({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    await Future.wait([
      for (final transport in [..._live]) transport._stop(timeout),
    ]);
    // Their entries gone from the list before the app is.
    await registry.flush();
  }

  /// Ends the processes an earlier run left behind; see
  /// [ChildProcessRegistry].
  static Future<void> reapLeftovers() => registry.reaped;

  Future<void> _stop(Duration timeout) async {
    close();
    final process = _process;
    if (process == null) {
      _live.remove(this);
      return;
    }
    try {
      await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
  }

  Future<void> _start() async {
    try {
      // Left over from a run that ended without stopping them: gone first,
      // so two servers never go on with one thread.
      await registry.reaped;
      final cli = await LocalCodex.locate();
      if (cwd case final dir? when !Directory(dir).existsSync()) {
        throw const CodexNotInstalled(
          'Codex cannot work there',
          detail: 'The project folder is not on this machine: Codex runs '
              'locally, and a project over SSH is not its to work in.',
        );
      }
      final overrides = await config?.call() ?? const <String>[];
      final process = await Process.start(
        cli.executable,
        [...overrides, ...serverArguments],
        workingDirectory: cwd,
        environment: cli.environment,
        // On Windows the app's environment stands (Claude's locator has it
        // no other), and the child needs the parent's beside it for what
        // `cmd.exe` itself runs on (COMSPEC, PATHEXT, …) when the CLI came
        // as an npm shim.
        includeParentEnvironment: Platform.isWindows,
        runInShell: cli.throughShell,
      );
      if (_closing) {
        // Stopped before it was even up: not started after all.
        process.kill();
        _failed('codex app-server was stopped before it started.');
        return;
      }
      _process = process;
      unawaited(registry.add(process.pid));
      _wire();
    } on Object catch (error) {
      _startError = error;
      _failed('$error');
    }
  }

  /// What both streams are read with, and not strict about it: a line that
  /// is not UTF-8 takes the replacement character and goes on to [_line],
  /// which drops it as it would any other line that is not protocol.
  static const _decoder = Utf8Decoder(allowMalformed: true);

  void _wire() {
    final process = _process!;
    _starting = null;
    process.stdout
        .transform(_decoder)
        .transform(const LineSplitter())
        .listen(_line, onError: _undecodable, onDone: _stdoutDone);
    process.stderr
        .transform(_decoder)
        .transform(const LineSplitter())
        .listen(_stderrLine, onError: _undecodable);
    unawaited(process.exitCode.then(_exited));
    // Held writes go in now that the server's input is there.
    final waiting = _waiting ?? const <Map<String, Object?>>[];
    _waiting = null;
    for (final message in waiting) {
      _writeNow(message);
    }
  }

  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();

  /// The last lines it printed on stderr, to say why it failed.
  final List<String> _stderr = [];
  static const _stderrLines = 30;

  int? _exitCode;
  bool _stdoutClosed = false;

  /// Requests written and not answered: what a server that goes away is
  /// owing, and answered for it here.
  final Set<Object?> _pending = {};

  /// Writes held while the server starts; null once they go straight out.
  List<Map<String, Object?>>? _waiting = [];

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void write(Map<String, Object?> message) {
    if (message['id'] case final id? when message['method'] != null) {
      _pending.add(id);
    }
    final waiting = _waiting;
    if (waiting != null) {
      waiting.add(message);
      return;
    }
    if (_exitCode == null && _startError == null && _process != null) {
      _writeNow(message);
    }
  }

  void _writeNow(Map<String, Object?> message) {
    try {
      _process!.stdin.writeln(jsonEncode(message));
    } on StateError {
      // Closed under us: the exit message follows.
    }
  }

  void _line(String line) {
    if (line.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, Object?>) {
        // An answer, be it to a request of ours (its id leaves the owed)
        // or one of the server's own requests answered.
        if (decoded['method'] == null) _pending.remove(decoded['id']);
        _messages.add(decoded);
      }
    } on FormatException {
      // Not protocol (e.g. a warning printed to stdout): kept for the
      // failure report.
      _stderrLine(line);
    }
  }

  /// A read error on either stream: kept as a stderr line, so that it is
  /// in the report when the process ends.
  void _undecodable(Object error) => _stderrLine('$error');

  void _stderrLine(String line) {
    _stderr.add(line);
    if (_stderr.length > _stderrLines) _stderr.removeAt(0);
  }

  void _stdoutDone() {
    _stdoutClosed = true;
    _finish();
  }

  void _exited(int code) {
    _exitCode = code;
    _live.remove(this);
    final process = _process;
    if (process != null) unawaited(registry.remove(process.pid));
    _finish();
  }

  /// Ends the stream once both the output is read and the process gone,
  /// so its last messages come before the exit; what it owed is answered
  /// for it, and a turn in flight is told the server is gone.
  void _finish() {
    final code = _exitCode;
    if (code == null || !_stdoutClosed || _messages.isClosed) return;
    final said = [
      'codex app-server exited (code $code)',
      if (_stderr.isNotEmpty) _stderr.join('\n'),
    ].join('\n');
    if (code != 0) {
      // What a mid-turn exit would otherwise leave unsaid: the turn
      // itself ends only when the user stops it, this says why they
      // would.
      _messages.add({'method': 'warning', 'params': {'message': said}});
    }
    for (final id in [..._pending]) {
      _messages.add({
        'id': id,
        'error': {'code': -32000, 'message': said},
      });
    }
    _pending.clear();
    _messages.close();
  }

  /// A start that failed: the requests it holds are answered with the
  /// failure, and the stream ends (nothing else is coming).
  void _failed(String said) {
    _live.remove(this);
    _waiting = null;
    for (final id in [..._pending]) {
      _messages.add({
        'id': id,
        'error': {'code': -32000, 'message': said},
      });
    }
    _pending.clear();
    _messages.close();
  }

  @override
  void close() {
    if (_closing) return;
    _closing = true;
    final process = _process;
    if (process == null) return; // Still starting: _start ends it.
    unawaited(process.stdin.close().catchError((_) {}));
    if (Platform.isWindows) {
      unawaited(_endTree());
    } else {
      process.kill();
    }
  }

  /// Windows ends a killed process alone, and the server it started goes
  /// on without it: given a moment to end itself, its input closed, then
  /// ended with all it started.
  Future<void> _endTree() async {
    final process = _process!;
    final ended = await process.exitCode
        .timeout(const Duration(seconds: 1))
        .then((_) => true, onError: (Object _) => false);
    if (ended) return;
    try {
      await Process.run('taskkill', ['/pid', '${process.pid}', '/T', '/F']);
    } on ProcessException {
      process.kill();
    }
  }
}

/// The codex processes the app has running (`codex-processes.json`); see
/// [ChildProcessRegistry]. Entries a run recorded without a command line
/// are ended only when they run codex's app server.
class CodexProcessRegistry extends ChildProcessRegistry {
  CodexProcessRegistry({
    required super.file,
    super.ownPid,
    super.lookup,
    super.signal,
  }) : super(recognizes: _isCodex);

  static bool _isCodex(String command) =>
      command.contains('codex') && command.contains('app-server');
}
