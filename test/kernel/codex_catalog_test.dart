import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/codex/codex_catalog.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart'
    show CodexRequestError;
import 'package:baocode/kernel/codex/codex_transport.dart';

/// The catalog over the app-server protocol: what it asks, how it pages,
/// and what it makes of the answers. A fake server answers; the real one
/// is exercised only by the process transport's own tests.
void main() {
  test('projects groups the threads by folder, newest folder first', () async {
    final server = _FakeServer()
      ..pages.addAll([
        [
          _thread('a', cwd: '/work/one', updatedAt: 100, preview: 'Fix it'),
          _thread('b', cwd: '/work/two', updatedAt: 300, name: 'Refactor'),
        ],
        [_thread('c', cwd: '/work/one', updatedAt: 200)],
      ]);
    final projects = await _catalog(server).projects();
    expect(projects.map((p) => p.path), ['/work/two', '/work/one']);
    expect(projects.last.name, 'one');
    expect(projects.last.sessions.map((s) => s.id), ['a', 'c']);
    // The threads came newest first; each folder keeps that order, and the
    // folders follow their newest thread.
    expect(projects.first.updatedAt, _at(300));
  });

  test('a thread is titled as named, else by its first message', () async {
    final server = _FakeServer()
      ..pages.add([
        _thread('c', cwd: '/w', updatedAt: 3, preview: 'first ask'),
        _thread('b', cwd: '/w', updatedAt: 2, name: 'Named'),
        _thread('a', cwd: '/w', updatedAt: 1, name: '  ', preview: 'hello'),
      ]);
    final sessions = await _catalog(server).sessionsIn('/w');
    expect(sessions.map((s) => s.title), [
      'first ask',
      'Named',
      'hello', // A blank name is no name.
    ]);
    expect(sessions.first.path, isNotNull);
    expect(sessions.first.updatedAt, _at(3));
  });

  test('sessionsIn asks for the folder alone, over the pages', () async {
    final server = _FakeServer()
      ..pages.addAll([
        [_thread('a', cwd: '/w', updatedAt: 2)],
        [_thread('b', cwd: '/w', updatedAt: 1)],
      ]);
    final sessions = await _catalog(server).sessionsIn('/w');
    expect(sessions.map((s) => s.id), ['a', 'b']);
    // The greeting comes first, then the listing, page by page.
    expect(server.written[0]['method'], 'initialize');
    expect(server.written[1]['method'], 'thread/list');
    expect(server.written[1]['params'], {
      'cwd': '/w',
      'sortKey': 'updated_at',
      'sortDirection': 'desc',
    });
    // The next page follows the cursor the last one gave.
    expect(server.written[2]['params'], {
      'cwd': '/w',
      'sortKey': 'updated_at',
      'sortDirection': 'desc',
      'cursor': 'page-2',
    });
  });

  test('a remote folder has no sessions of the local codex', () async {
    final server = _FakeServer();
    expect(await _catalog(server).sessionsIn('ssh://host/work'), isEmpty);
    expect(server.written, isEmpty);
  });

  test('delete asks for the thread, and a missing one is no error', () async {
    final server = _FakeServer();
    final catalog = _catalog(server);
    await catalog.delete('a');
    expect(server.written.last['method'], 'thread/delete');
    expect(server.written.last['params'], {'threadId': 'a'});

    server.failDelete = true;
    await catalog.delete('gone');
  });

  test('a server that went away answers what it owed, and is started again',
      () async {
    final first = _FakeServer()
      ..pages.add([_thread('a', cwd: '/w', updatedAt: 1)]);
    final next = _FakeServer()
      ..pages.add([_thread('b', cwd: '/w', updatedAt: 2)]);
    final servers = [first, next];
    final catalog = CodexCatalog(() async => servers.removeAt(0));
    expect((await catalog.projects()).single.sessions.single.id, 'a');

    // The next call hangs on a listing, and the server goes with it open.
    first.hangListings = true;
    final listing = catalog.projects();
    await pumpEventQueue();
    first.die();
    await expectLater(listing, throwsA(isA<CodexRequestError>()));

    // The one after starts another server.
    final projects = await catalog.projects();
    expect(projects.single.sessions.single.id, 'b');
  });

  test('nothing installed lists nothing, without starting anything', () async {
    final catalog = CodexCatalog(
      () async => throw const CodexNotInstalled('Codex is not here'),
    );
    expect(await catalog.projects(), isEmpty);
    expect(await catalog.sessionsIn('/w'), isEmpty);
    await catalog.delete('a');
  });
}

CodexCatalog _catalog(_FakeServer server) =>
    CodexCatalog(() async => server);

DateTime _at(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

Map<String, Object?> _thread(
  String id, {
  required String cwd,
  required int updatedAt,
  String? name,
  String? preview,
}) => {
  'id': id,
  'cwd': cwd,
  'updatedAt': updatedAt,
  'name': name,
  'preview': preview ?? '',
  'path': '/root/.codex/sessions/$id.jsonl',
};

/// Answers catalog requests as the app server does, over pages it is given
/// ahead of time.
class _FakeServer implements CodexTransport {
  final StreamController<Map<String, Object?>> _out =
      StreamController.broadcast(sync: true);
  final List<Map<String, Object?>> written = [];

  /// The pages `thread/list` hands out, in order.
  final List<List<Map<String, Object?>>> pages = [];

  /// Answer `thread/delete` with an error, as one of a thread not there.
  bool failDelete = false;

  /// Leave `thread/list` unanswered, as a listing still working when the
  /// process goes.
  bool hangListings = false;

  int _served = 0;

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    final method = message['method'] as String?;
    if (method == null) return; // Our own request, answered.
    switch (method) {
      case 'thread/list':
        if (hangListings) return;
        final page = pages.isEmpty ? const <Map<String, Object?>>[] : pages.removeAt(0);
        _served++;
        _respond(message['id'], {
          'data': page,
          'nextCursor': pages.isEmpty ? null : 'page-${_served + 1}',
        });
      case 'thread/delete':
        if (failDelete) {
          _emit({
            'id': message['id'],
            'error': {'code': -32602, 'message': 'no such thread'},
          });
        } else {
          _respond(message['id'], const {});
        }
      default:
        _respond(message['id'], const {});
    }
  }

  void _respond(Object? id, Map<String, Object?> result) =>
      _emit({'id': id, 'result': result});

  void _emit(Map<String, Object?> message) {
    if (!_out.isClosed) _out.add(message);
  }

  /// Ends the stream with a request unanswered, as a process gone.
  void die() => _out.close();

  @override
  void close() => _out.close();
}
