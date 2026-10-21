import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A session file is read at its two ends when it is long: the place it ran
/// in and the first prompt are at its head, the title and the last message
/// at its tail. What the windows do not hold, the whole file is read for.
void main() {
  late Directory temp;
  late String cwd;
  late String config;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('bao_session_scan_');
    cwd = p.join(temp.path, 'project');
    Directory(cwd).createSync();
    config = p.join(temp.path, 'claude');
    Directory(p.join(config, 'projects', 'proj')).createSync(recursive: true);
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // Gone meanwhile.
    }
  });

  String writeSession(String id, Iterable<Map<String, Object?>> entries) {
    final path = p.join(config, 'projects', 'proj', '$id.jsonl');
    File(path).writeAsStringSync('${entries.map(jsonEncode).join('\n')}\n');
    return path;
  }

  Map<String, Object?> user(String uuid, String text, {String? at}) => {
    'type': 'user',
    'uuid': uuid,
    'cwd': cwd,
    'message': {'content': text},
    'timestamp': ?at,
  };

  Map<String, Object?> assistant(String uuid, {String? at}) => {
    'type': 'assistant',
    'uuid': uuid,
    'message': {'content': '长内容' * 200},
    'timestamp': ?at,
  };

  /// Enough lines to pass the windows on either side.
  List<Map<String, Object?>> filler(int count) => [
    for (var i = 0; i < count; i++) assistant('f$i'),
  ];

  Future<ClaudeSessionSummary> summaryOf(String id) async {
    final projects = await ClaudeSessions(
      configDir: config,
      cacheFile: p.join(temp.path, 'cache.json'),
    ).projects();
    return projects.expand((project) => project.sessions).single;
  }

  test('a long session is summarized from its head and its tail', () async {
    writeSession('s1', [
      user('u1', 'Fix the build', at: '2026-10-20T10:00:00Z'),
      ...filler(100),
      assistant('last', at: '2026-10-21T09:30:00Z'),
      {'type': 'custom-title', 'customTitle': '构建修复', 'sessionId': 's1'},
    ]);

    final summary = await summaryOf('s1');
    expect(summary.title, '构建修复');
    expect(summary.cwd, cwd);
    expect(summary.updatedAt.toUtc(), DateTime.utc(2026, 10, 21, 9, 30));
  });

  test('a title near the head is found when the tail has none', () async {
    writeSession('s2', [
      user('u1', 'Fix the build'),
      {'type': 'ai-title', 'aiTitle': 'Head title', 'sessionId': 's2'},
      ...filler(100),
      assistant('last', at: '2026-10-21T09:30:00Z'),
    ]);

    expect((await summaryOf('s2')).title, 'Head title');
  });

  test('a first prompt past the head window is still found', () async {
    writeSession('s3', [
      ...filler(200),
      user('u1', 'Late first prompt', at: '2026-10-20T10:00:00Z'),
      assistant('last', at: '2026-10-21T09:30:00Z'),
      {'type': 'custom-title', 'customTitle': 'Late title', 'sessionId': 's3'},
    ]);

    final summary = await summaryOf('s3');
    expect(summary.cwd, cwd);
    expect(summary.title, 'Late title');
  });

  test('a short session is read whole, as before', () async {
    writeSession('s4', [
      user('u1', 'Only one line', at: '2026-10-20T10:00:00Z'),
      assistant('a1', at: '2026-10-20T10:01:00Z'),
    ]);

    final summary = await summaryOf('s4');
    expect(summary.title, 'Only one line');
    expect(summary.updatedAt.toUtc(), DateTime.utc(2026, 10, 20, 10, 1));
  });
}
