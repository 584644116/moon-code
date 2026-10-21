import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:bao_agent/bao_agent.dart' show AgentPaths;
import 'package:path/path.dart' as p;

import '../kernel/claude_code/claude_environment.dart';
import 'session_export_model.dart';

/// Packs the session [sessionId] from the agent's state folder: see
/// [exportSessionSync].
Future<SessionExport?> exportSession({
  required String sessionId,
  String? configDir,
  bool attachments = true,
  int maxFileBytes = sessionExportMaxFileBytes,
  int maxBytes = sessionExportMaxBytes,
}) async {
  final environment = await ClaudeEnvironment.of();
  final config =
      configDir ??
      switch (environment) {
        {ClaudeEnvironment.dataPathVariable: final dir} when dir.isNotEmpty =>
          dir,
        {'CLAUDE_CONFIG_DIR': final dir} when dir.isNotEmpty => dir,
        _ => p.join(AgentPaths.homeOf(environment), '.claude'),
      };
  return Isolate.run(
    () => exportSessionSync(
      sessionId: sessionId,
      configDir: config,
      environment: environment,
      attachments: attachments,
      maxFileBytes: maxFileBytes,
      maxBytes: maxBytes,
    ),
  );
}

/// Packs the session [sessionId] of [configDir] as a ZIP: its transcript
/// (`<sessionId>.jsonl`), the files under `<project>/<sessionId>/` — its
/// subagents' transcripts, and [attachments]' files — and the project's
/// name as the folder in it. Null where there is no such session.
///
/// A file larger than [maxFileBytes], or one that would take the archive
/// past [maxBytes], is left out ([SessionExport.omitted]); so is a
/// minidump, which may hold what the app had in memory.
SessionExport? exportSessionSync({
  required String sessionId,
  required String configDir,
  Map<String, String>? environment,
  bool attachments = true,
  int maxFileBytes = sessionExportMaxFileBytes,
  int maxBytes = sessionExportMaxBytes,
}) {
  final paths = AgentPaths.from(
    environment ?? Platform.environment,
    configDir: configDir,
  );
  final session = paths.findSession(sessionId);
  if (session == null) return null;
  final project = p.dirname(session);
  final kept = <({String name, List<int> bytes, DateTime modified})>[];
  var total = 0;
  var omitted = 0;
  void add(File file, String name, {bool transcript = false}) {
    final stat = file.statSync();
    if (stat.type != FileSystemEntityType.file ||
        !transcript && stat.size > maxFileBytes ||
        total + stat.size > maxBytes) {
      omitted++;
      return;
    }
    try {
      final bytes = file.readAsBytesSync();
      total += bytes.length;
      kept.add((name: name, bytes: bytes, modified: stat.modified));
    } on FileSystemException {
      omitted++;
    }
  }

  String relative(String path) =>
      p.relative(path, from: project).replaceAll(r'\', '/');
  add(File(session), '$sessionId.jsonl', transcript: true);
  final folder = Directory(p.join(project, sessionId));
  if (folder.existsSync()) {
    final subagents = Directory(p.join(folder.path, 'subagents'));
    if (subagents.existsSync()) {
      for (final file in subagents.listSync().whereType<File>()) {
        if (file.path.endsWith('.jsonl')) add(file, relative(file.path));
      }
    }
    if (attachments) {
      for (final entity in folder.listSync(recursive: true)) {
        if (entity is! File ||
            entity.path.endsWith('.dmp') ||
            p.isWithin(subagents.path, entity.path)) {
          continue;
        }
        add(entity, relative(entity.path));
      }
    }
  }
  if (kept.isEmpty) return null;
  final rest = kept.skip(1).toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  final ordered = [kept.first, ...rest];
  final names = [for (final file in ordered) file.name];
  return SessionExport(
    zipEntries(ordered),
    names,
    omitted: omitted,
  );
}

/// Writes [export] at [path].
Future<void> writeSessionExport(SessionExport export, String path) async {
  await File(path).writeAsBytes(export.bytes, flush: true);
}

/// [files] as a ZIP: deflated where that makes them smaller, UTF-8 names,
/// no comment. [files]' names are `/`-separated.
Uint8List zipEntries(
  Iterable<({String name, List<int> bytes, DateTime modified})> files,
) {
  final out = BytesBuilder(copy: false);
  final directory = BytesBuilder(copy: false);
  var count = 0;
  void u16(BytesBuilder to, int value) =>
      to.add([value & 0xFF, (value >> 8) & 0xFF]);
  void u32(BytesBuilder to, int value) => to.add([
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ]);
  for (final file in files) {
    final name = utf8.encode(file.name.replaceAll(r'\', '/'));
    final raw = Uint8List.fromList(file.bytes);
    final deflated = ZLibCodec(raw: true, level: 6).encode(raw);
    final stored = deflated.length >= raw.length;
    final body = stored ? raw : Uint8List.fromList(deflated);
    final crc = crc32(raw);
    final (time, date) = dosTime(file.modified);
    final offset = out.length;
    u32(out, 0x04034b50);
    u16(out, 20);
    u16(out, 0x0800);
    u16(out, stored ? 0 : 8);
    u16(out, time);
    u16(out, date);
    u32(out, crc);
    u32(out, body.length);
    u32(out, raw.length);
    u16(out, name.length);
    u16(out, 0);
    out.add(name);
    out.add(body);
    u32(directory, 0x02014b50);
    u16(directory, 20);
    u16(directory, 20);
    u16(directory, 0x0800);
    u16(directory, stored ? 0 : 8);
    u16(directory, time);
    u16(directory, date);
    u32(directory, crc);
    u32(directory, body.length);
    u32(directory, raw.length);
    u16(directory, name.length);
    u16(directory, 0);
    u16(directory, 0);
    u16(directory, 0);
    u16(directory, 0);
    u32(directory, 0);
    u32(directory, offset);
    directory.add(name);
    count++;
  }
  final directoryAt = out.length;
  out.add(directory.takeBytes());
  final directorySize = out.length - directoryAt;
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, count);
  u16(out, count);
  u32(out, directorySize);
  u32(out, directoryAt);
  u16(out, 0);
  return out.takeBytes();
}

/// [time] as ZIP's date and time, seconds to a whole two, no earlier than
/// 1980 (what the format holds).
(int, int) dosTime(DateTime time) {
  final at = time.isBefore(DateTime(1980)) ? DateTime(1980) : time;
  return (
    (at.hour << 11) | (at.minute << 5) | (at.second ~/ 2),
    ((at.year - 1980) << 9) | (at.month << 5) | at.day,
  );
}

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

/// [bytes]' CRC-32, as ZIP's entries carry it.
int crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
