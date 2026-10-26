import 'dart:async';

import '../../remote/remote_location.dart';
import '../agent_kernel.dart';
import 'codex_kernel.dart' show CodexRequestError;
import 'codex_process_transport.dart';
import 'codex_transport.dart';

/// The conversations codex kept on this machine, asked of `codex
/// app-server` (its `thread/list` and `thread/delete`). One server serves
/// every call, started for the first and shared after; one that went away
/// is started again by the next call. With no codex installed, nothing is
/// listed — not a failure, the machine just has none.
class CodexCatalog implements SessionCatalog {
  CodexCatalog([this._start]);

  final Future<CodexTransport> Function()? _start;

  CodexTransport? _server;
  int _requests = 0;
  final Map<Object, Completer<Map<String, Object?>>> _responses = {};

  static Future<CodexTransport> _startProcess() async {
    final transport = CodexProcessTransport();
    // Said here (e.g. nothing installed) rather than as the first
    // request's failure, so the caller can tell it from one that failed.
    await transport.ready;
    return transport;
  }

  Future<CodexTransport> _connect() async {
    final server = _server;
    if (server != null) return server;
    final transport = await (_start ?? _startProcess)();
    _server = transport;
    transport.messages.listen(
      _receive,
      onDone: () {
        // What it did not answer is not coming: a next call starts another.
        _server = null;
        final unanswered = [..._responses.values];
        _responses.clear();
        for (final response in unanswered) {
          response.completeError(
            const CodexRequestError('the app server went away'),
          );
        }
      },
    );
    // The server answers nothing until greeted, and a greeting once each
    // connection: this one's own, the kernel's transport sends its own.
    await _ask(
      transport,
      'initialize',
      const {
        'clientInfo': {'name': 'baocode', 'title': 'MoonCode', 'version': '1.0.0'},
        'capabilities': {'experimentalApi': false},
      },
    );
    return transport;
  }

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) async {
    return _ask(await _connect(), method, params);
  }

  Future<Map<String, Object?>> _ask(
    CodexTransport server,
    String method,
    Map<String, Object?> params,
  ) async {
    final id = ++_requests;
    final response = Completer<Map<String, Object?>>();
    _responses[id] = response;
    server.write({'id': id, 'method': method, 'params': params});
    return response.future;
  }

  void _receive(Map<String, Object?> message) {
    if (message['method'] != null) return; // Notifications: none ours.
    final response = _responses.remove(message['id']);
    if (response == null) return;
    // An error is an answer too: the caller waits for one either way.
    if (message['error'] case final Map<Object?, Object?> error) {
      response.completeError(
        CodexRequestError(
          '${error['message'] ?? 'the request failed'}',
          code: error['code'] as int?,
        ),
      );
      return;
    }
    response.complete((message['result'] as Map?)?.cast<String, Object?>());
  }

  /// Every kept thread, newest first, as `thread/list` pages them out.
  Future<List<Map<String, Object?>>> _threads(String? cwd) async {
    final threads = <Map<String, Object?>>[];
    String? cursor;
    do {
      final page = await _request('thread/list', {
        'cwd': ?cwd,
        // Every provider's threads, not the one this server runs on: Codex
        // filters by its own provider when the list is left out, so a
        // session begun on another upstream (the app names a provider per
        // thread) would vanish from the history the moment the app's
        // provider changed. Empty asks for all of them.
        'modelProviders': const <String>[],
        // The protocol's own names, not the responses': its enums are
        // snake_case, and a value it does not know is a rejected request.
        'sortKey': 'updated_at',
        'sortDirection': 'desc',
        'cursor': ?cursor,
      });
      threads.addAll([
        for (final raw in page['data'] as List? ?? const [])
          (raw as Map).cast<String, Object?>(),
      ]);
      cursor = page['nextCursor'] as String?;
    } while (cursor != null);
    return threads;
  }

  SessionRecord _record(Map<String, Object?> thread) {
    final name = (thread['name'] as String?)?.trim();
    return SessionRecord(
      id: thread['id'] as String,
      // Its title when the user gave it one; codex keeps the first user
      // message as the preview of an untitled thread.
      title: name == null || name.isEmpty
          ? '${thread['preview'] ?? ''}'
          : name,
      // The protocol's times are seconds.
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        ((thread['updatedAt'] as num?) ?? 0).toInt() * 1000,
      ),
      cwd: thread['cwd'] as String,
      path: thread['path'] as String?,
    );
  }

  @override
  Future<List<ProjectRecord>> projects() async {
    try {
      return _group(await _threads(null));
    } on CodexNotInstalled {
      return const [];
    }
  }

  List<ProjectRecord> _group(List<Map<String, Object?>> threads) {
    final byProject = <String, List<SessionRecord>>{};
    for (final thread in threads) {
      final record = _record(thread);
      byProject.putIfAbsent(record.cwd, () => []).add(record);
    }
    final projects = [
      for (final MapEntry(:key, :value) in byProject.entries)
        ProjectRecord(path: key, sessions: value),
    ];
    // The threads came newest first, so each project's first session is
    // its newest: the projects follow that order.
    projects.sort(
      (a, b) => (b.updatedAt ?? DateTime(0)).compareTo(
        a.updatedAt ?? DateTime(0),
      ),
    );
    return projects;
  }

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async {
    // A remote project's sessions are its host's: the local codex keeps
    // none of them, and none are asked of it.
    if (RemoteLocation.isRemote(cwd)) return const [];
    try {
      return [for (final thread in await _threads(cwd)) _record(thread)];
    } on CodexNotInstalled {
      return const [];
    }
  }

  @override
  Future<void> delete(String id) async {
    try {
      await _request('thread/delete', {'threadId': id});
    } on CodexNotInstalled {
      // Nothing to delete through: the machine has no codex.
    } on CodexRequestError {
      // Already gone, or the server would not say: either way it is not
      // there to delete, which is what was asked.
    }
  }
}
