import 'dart:async';

import 'codex_transport.dart';

/// The web's stand-in: no processes to start, so every request is answered
/// with that said (the kernel says it in the conversation) rather than
/// left waiting.
class CodexProcessTransport implements CodexTransport {
  CodexProcessTransport({String? cwd, Future<List<String>> Function()? config});

  /// Nothing to wait for: every request is answered with the failure.
  final Future<void> ready = Future.value();

  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void write(Map<String, Object?> message) {
    if (message['id'] case final id? when message['method'] != null) {
      _messages.add({
        'id': id,
        'error': {
          'code': -32000,
          'message': 'Codex runs in the desktop app: the browser cannot '
              'start local processes.',
        },
      });
    }
  }

  @override
  void close() => _messages.close();

  /// No processes to stop on the web.
  static Future<void> stopAll() async {}

  static Future<void> reapLeftovers() async {}
}
