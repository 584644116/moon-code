import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// A file that a diagnostics upload sends: its [name] in the bundle,
/// `/`-separated, and its size. One of the logs folder
/// (`DataDirectory.logsDir`), its name under it; or a crash report of the
/// system's, read from [source].
class DiagnosticsLog {
  const DiagnosticsLog(this.name, this.size, {this.source});

  /// `errors.log`, `hangs/hang-20261011-013600-1234.dmp`,
  /// `crashes/BaoCode-2026-10-28-120616.ips`.
  final String name;
  final int size;

  /// Where a file from outside the logs folder is read: a crash report.
  final String? source;

  /// A crash report of the system's ([listCrashReports]).
  bool get isCrash => source != null;

  /// A minidump of a hang (Windows: windows/runner/hang_watchdog.h): sent
  /// only when asked, as it may hold what the app had in memory.
  bool get isDump => name.endsWith('.dmp');

  Map<String, Object> toJson() => {'name': name, 'size': size};
}

/// What a diagnostics upload sends: [bytes], a `tar.gz` of [files]; the
/// minidumps left out as they would not fit, [omittedDumps].
class DiagnosticsBundle {
  const DiagnosticsBundle(this.bytes, this.files, {this.omittedDumps = 0});

  final Uint8List bytes;
  final List<DiagnosticsLog> files;
  final int omittedDumps;
}

/// The most the server takes of a bundle (stats.baocode.dev's
/// `/v1/diagnostics`).
const maxDiagnosticsBytes = 10 * 1024 * 1024;

/// The most crash reports a bundle takes: the newest.
const maxCrashReports = 5;

/// The logs of [folder]: its own `*.log` (errors.log and the run before's,
/// Windows' window.log), by name, then the system's crash reports of the
/// app in [crashFolders] ([listCrashReports]), then the hang reports of
/// `hangs/`, the newest first. None where there is no folder.
List<DiagnosticsLog> listDiagnosticsLogs(
  String folder, {
  List<String> crashFolders = const [],
}) {
  List<DiagnosticsLog> filesOf(String directory, bool Function(String) take) {
    final dir = Directory(directory);
    if (!dir.existsSync()) return [];
    return [
      for (final entity in dir.listSync(followLinks: false))
        if (entity is File && take(p.basename(entity.path)))
          DiagnosticsLog(
            p.relative(entity.path, from: folder).replaceAll(r'\', '/'),
            entity.lengthSync(),
          ),
    ];
  }

  final logs = filesOf(folder, (name) => name.endsWith('.log'))
    ..sort((a, b) => a.name.compareTo(b.name));
  // hang-YYYYMMDD-HHMMSS-pid: the names sort as the times.
  final hangs = filesOf(
    p.join(folder, 'hangs'),
    (name) => name.endsWith('.txt') || name.endsWith('.dmp'),
  )..sort((a, b) => b.name.compareTo(a.name));
  return [...logs, ...listCrashReports(crashFolders), ...hangs];
}

/// Where macOS keeps the app's crash reports (`BaoCode-<time>.ips`): the
/// user's DiagnosticReports, and its `Retired` the reports already sent to
/// Apple are moved to.
List<String> macCrashReportFolders(String home) {
  final reports = p.join(home, 'Library', 'Logs', 'DiagnosticReports');
  return [reports, p.join(reports, 'Retired')];
}

/// The app's crash reports in [folders] (`BaoCode-2026-10-28-120616.ips`;
/// a crash, a hang the system caught, a kill for memory), the [max]
/// newest, as `crashes/<name>`; a name in two folders once.
List<DiagnosticsLog> listCrashReports(
  List<String> folders, {
  int max = maxCrashReports,
}) {
  final found = <String, (File, DateTime)>{};
  for (final folder in folders) {
    final dir = Directory(folder);
    try {
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        if (entity is! File || !crashReportName.hasMatch(name)) continue;
        if (found.containsKey(name)) continue;
        found[name] = (entity, entity.lastModifiedSync());
      }
    } on FileSystemException {
      // Not to be read: none from there.
    }
  }
  final newest = found.entries.toList()
    ..sort((a, b) => b.value.$2.compareTo(a.value.$2));
  return [
    for (final MapEntry(key: name, value: (file, _)) in newest.take(max))
      if (_lengthOf(file) case final size?)
        DiagnosticsLog('crashes/$name', size, source: file.path),
  ];
}

/// The names the system gives the app's reports: its process's name
/// first. Not `BaoCodeHelper` and the like.
final crashReportName = RegExp(r'^BaoCode[-_.].*\.ips$');

int? _lengthOf(File file) {
  try {
    return file.lengthSync();
  } on FileSystemException {
    return null;
  }
}

/// [listDiagnosticsLogs]'s files of [folder] packed, in another isolate:
/// see [packDiagnosticsSync].
Future<DiagnosticsBundle> packDiagnostics(
  String folder, {
  required bool dumps,
  List<String> crashFolders = const [],
  String? home,
  bool windows = false,
  int maxBytes = maxDiagnosticsBytes,
}) => Isolate.run(
  () => packDiagnosticsSync(
    folder,
    dumps: dumps,
    crashFolders: crashFolders,
    home: home,
    windows: windows,
    maxBytes: maxBytes,
  ),
);

/// The logs of [folder] and the crash reports of [crashFolders] as a
/// `tar.gz` of at most [maxBytes]: the text ones with [home] written `~`
/// ([redactHome]), the crash reports without the machine's key
/// ([redactCrashReport]); then, with [dumps], the minidumps as they are,
/// the newest first. What would make it too large is left out, and a file
/// gone or unreadable since it was listed.
///
/// Each file is a gzip member of its own, so that what it adds is known
/// as it is added; gzip and tar read the members as one stream.
DiagnosticsBundle packDiagnosticsSync(
  String folder, {
  required bool dumps,
  List<String> crashFolders = const [],
  String? home,
  bool windows = false,
  int maxBytes = maxDiagnosticsBytes,
}) {
  final listed = listDiagnosticsLogs(folder, crashFolders: crashFolders);
  final ordered = [
    ...listed.where((log) => !log.isDump),
    if (dumps) ...listed.where((log) => log.isDump),
  ];
  final codec = GZipCodec();
  final end = codec.encode(Uint8List(1024));
  final out = BytesBuilder(copy: false);
  final files = <DiagnosticsLog>[];
  var omitted = 0;
  for (final log in ordered) {
    final file = File(log.source ?? p.join(folder, log.name));
    Uint8List bytes;
    DateTime modified;
    try {
      bytes = file.readAsBytesSync();
      modified = file.lastModifiedSync();
    } on FileSystemException {
      continue;
    }
    if (!log.isDump) {
      var text = utf8.decode(bytes, allowMalformed: true);
      if (home != null) {
        text = redactHome(text, home, windows: windows);
      }
      // A crash report keeps the machine's key, which says nothing of the
      // crash and would tell one user's reports from another's.
      if (log.isCrash) text = redactCrashReport(text);
      bytes = utf8.encode(scrubSecrets(text));
    }
    final member = codec.encode(tarEntry(log.name, bytes, modified));
    if (out.length + member.length + end.length > maxBytes) {
      if (log.isDump) omitted++;
      continue;
    }
    out.add(member);
    files.add(DiagnosticsLog(log.name, bytes.length));
  }
  out.add(end);
  return DiagnosticsBundle(out.takeBytes(), files, omittedDumps: omitted);
}

/// [text] with the user's [home] folder written `~`: in paths and in
/// JSON's escaped ones (`\/Users\/ann`, as macOS' crash reports have
/// them). On Windows, also with `/` between its parts, and in any case.
/// Not where it begins a longer name (`/Users/ann` in `/Users/anna`).
String redactHome(String text, String home, {bool windows = false}) {
  final trimmed = home.replaceFirst(RegExp(r'[\\/]+$'), '');
  // A root, or nothing: every path would go.
  if (trimmed.length < 2 || !trimmed.contains(RegExp(r'[\\/]'))) return text;
  final parts = trimmed.split(RegExp(r'[\\/]'));
  final variants = {
    trimmed,
    parts.join(r'\/'),
    if (windows) ...[parts.join('/'), parts.join(r'\'), parts.join(r'\\')],
  }.toList()..sort((a, b) => b.length.compareTo(a.length));
  final pattern = RegExp(
    '(?:${variants.map(RegExp.escape).join('|')})(?![A-Za-z0-9._-])',
    caseSensitive: !windows,
  );
  return text.replaceAll(pattern, '~');
}

/// [text] with credentials written over: keys, bearer tokens, cookies and
/// refresh tokens a log may have kept. Their shape says what they are, so
/// a diagnostics upload does not carry a working secret.
String scrubSecrets(String text) {
  var out = text;
  out = out.replaceAll(
    RegExp(
      r'\b(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|'
      r'github_pat_[A-Za-z0-9_]{8,}|AKIA[0-9A-Z]{16})\b',
    ),
    '***',
  );
  out = out.replaceAllMapped(
    RegExp(
      r'''(authorization["']?\s*[:=]\s*)(bearer\s+)?[^\s,;"']+''',
      caseSensitive: false,
    ),
    (match) => '${match[1]}${match[2] ?? ''}***',
  );
  out = out.replaceAllMapped(
    RegExp(
      r'''((?:x-api-key|api[-_]?key|apikey)["']?\s*[:=]\s*["']?)[^"'\s,;}]+''',
      caseSensitive: false,
    ),
    (match) => '${match[1]}***',
  );
  out = out.replaceAllMapped(
    RegExp(
      r'''((?:cookie|set-cookie)["']?\s*:\s*)[^\r\n]+''',
      caseSensitive: false,
    ),
    (match) => '${match[1]}***',
  );
  out = out.replaceAllMapped(
    RegExp(
      r'''((?:refresh_token|new_api_refresh|access_token|id_token)'''
      r'''["']?\s*[:=]\s*["']?)[^"'\s,;}]+''',
      caseSensitive: false,
    ),
    (match) => '${match[1]}***',
  );
  out = out.replaceAll(
    RegExp(
      r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?'
      r'-----END [A-Z ]*PRIVATE KEY-----',
    ),
    '-----BEGIN PRIVATE KEY-----***-----END PRIVATE KEY-----',
  );
  return out;
}

/// A crash report of macOS' without its `crashReporterKey`, the same for
/// every report of the machine: what would tell the reports of one user.
String redactCrashReport(String text) => text.replaceAllMapped(
  RegExp(r'("crashReporterKey"\s*:\s*")[^"]*"'),
  (match) => '${match[1]}"',
);

/// [bytes] as a file of a tar (`ustar`): its header, then its content to
/// a whole number of blocks.
Uint8List tarEntry(String name, List<int> bytes, DateTime modified) {
  final header = Uint8List(512);
  void put(int offset, int length, String value) {
    final encoded = utf8.encode(value);
    header.setRange(
      offset,
      offset + (encoded.length < length ? encoded.length : length),
      encoded,
    );
  }

  String octal(int value, int digits) =>
      '${value.toRadixString(8).padLeft(digits, '0')}\u0000';

  var path = name;
  // The name field holds 100 bytes; the logs' names are far shorter.
  while (utf8.encode(path).length > 100) {
    path = path.substring(1);
  }
  put(0, 100, path);
  put(100, 8, octal(420, 7)); // 0644
  put(108, 8, octal(0, 7));
  put(116, 8, octal(0, 7));
  put(124, 12, octal(bytes.length, 11));
  put(136, 12, octal(modified.millisecondsSinceEpoch ~/ 1000, 11));
  put(148, 8, '        ');
  put(156, 1, '0');
  put(257, 6, 'ustar\u0000');
  put(263, 2, '00');
  var sum = 0;
  for (final byte in header) {
    sum += byte;
  }
  put(148, 8, '${sum.toRadixString(8).padLeft(6, '0')}\u0000 ');
  final padded = (bytes.length + 511) ~/ 512 * 512;
  return (BytesBuilder(copy: false)
        ..add(header)
        ..add(bytes)
        ..add(Uint8List(padded - bytes.length)))
      .takeBytes();
}
