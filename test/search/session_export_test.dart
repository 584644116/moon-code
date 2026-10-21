import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/search/session_export_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A session packs into a ZIP that opens: transcript, subagents, files.
void main() {
  late Directory config;
  late Directory project;
  late Directory session;

  setUp(() {
    config = Directory.systemTemp.createTempSync('bao_export_');
    project = Directory(p.join(config.path, 'projects', 'p'))
      ..createSync(recursive: true);
    session = Directory(p.join(project.path, 's1'))
      ..createSync(recursive: true);
    File(p.join(project.path, 's1.jsonl')).writeAsStringSync(
      '{"type":"user","message":{"content":"hi"}}\n{"bad":\n',
    );
    Directory(p.join(session.path, 'subagents')).createSync();
    File(
      p.join(session.path, 'subagents', 'agent-1.jsonl'),
    ).writeAsStringSync('{"type":"assistant"}\n');
    Directory(p.join(session.path, 'tool-results')).createSync();
    File(
      p.join(session.path, 'tool-results', 'out.txt'),
    ).writeAsStringSync('full output');
  });

  tearDown(() => config.deleteSync(recursive: true));

  test('the transcript, subagents and files are in the ZIP', () {
    final export = exportSessionSync(
      sessionId: 's1',
      configDir: config.path,
      environment: const {},
    );
    expect(export, isNotNull);
    expect(export!.files, [
      's1.jsonl',
      's1/subagents/agent-1.jsonl',
      's1/tool-results/out.txt',
    ]);
    expect(export.omitted, 0);

    final entries = _unzip(export.bytes);
    expect(entries.keys, export.files);
    expect(utf8.decode(entries['s1.jsonl']!), contains('"content":"hi"'));
    expect(utf8.decode(entries['s1/tool-results/out.txt']!), 'full output');
  });

  test('without attachments only the transcript and subagents go', () {
    final export = exportSessionSync(
      sessionId: 's1',
      configDir: config.path,
      environment: const {},
      attachments: false,
    );
    expect(export!.files, ['s1.jsonl', 's1/subagents/agent-1.jsonl']);
  });

  test('a file past the limit is left out, and counted', () {
    File(p.join(session.path, 'tool-results', 'out.txt'))
        .writeAsStringSync('x' * 40);
    final export = exportSessionSync(
      sessionId: 's1',
      configDir: config.path,
      environment: const {},
      maxFileBytes: 30,
    );
    expect(export!.files, isNot(contains('s1/tool-results/out.txt')));
    expect(export.omitted, 1);
  });

  test('a session that is not there is null', () {
    expect(
      exportSessionSync(
        sessionId: 'none',
        configDir: config.path,
        environment: const {},
      ),
      isNull,
    );
  });

  test('the CRC-32 is the one a ZIP reader checks', () {
    expect(crc32(utf8.encode('123456789')), 0xCBF43926);
  });
}

/// The entries of the ZIP [bytes], by name, inflated.
Map<String, Uint8List> _unzip(Uint8List bytes) {
  int u16(int at) => bytes[at] | (bytes[at + 1] << 8);
  int u32(int at) =>
      bytes[at] |
      (bytes[at + 1] << 8) |
      (bytes[at + 2] << 16) |
      (bytes[at + 3] << 24);
  final entries = <String, Uint8List>{};
  var at = 0;
  while (at + 4 <= bytes.length && u32(at) == 0x04034b50) {
    final method = u16(at + 8);
    final size = u32(at + 18);
    final nameLength = u16(at + 26);
    final extraLength = u16(at + 28);
    final name = utf8.decode(bytes.sublist(at + 30, at + 30 + nameLength));
    final data = at + 30 + nameLength + extraLength;
    final body = bytes.sublist(data, data + size);
    entries[name] = method == 8
        ? Uint8List.fromList(ZLibDecoder(raw: true).convert(body))
        : body;
    at = data + size;
  }
  return entries;
}
