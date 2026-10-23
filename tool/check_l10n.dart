// Checks the translations (lib/l10n): each ARB is JSON, English and Chinese
// name the same messages, every one has text, and the classes gen-l10n
// writes are what the ARBs make. Run before committing a change to them,
// and by .github/workflows/l10n.yml on one:
//
//   dart run tool/check_l10n.dart
//
// A merge is what breaks an ARB — an entry left open, or two sides' entries
// run into each other — and what it then gives reads as a broken build
// rather than a broken file: `flutter pub get` stops on a FormatException,
// and every test in test/l10n_test.dart fails on the same parse error. This
// names the file, and the line. test/l10n_test.dart says the same of the
// ARBs from inside a test run; this also says that the classes gen-l10n
// writes are what the ARBs make.
import 'dart:convert';
import 'dart:io';

/// The template, and the translations beside it (l10n.yaml).
const _arbs = ['lib/l10n/app_en.arb', 'lib/l10n/app_zh.arb'];

/// What gen-l10n writes, in the order it writes them.
const _generated = [
  'lib/l10n/app_localizations.dart',
  'lib/l10n/app_localizations_en.dart',
  'lib/l10n/app_localizations_zh.dart',
];

void main(List<String> arguments) {
  if (arguments.isNotEmpty) {
    stderr.writeln('Usage: dart run tool/check_l10n.dart');
    exit(2);
  }
  final problems = <String>[];

  // Each file on its own: one that does not parse is said so, and the rest
  // are still checked.
  final messages = <String, Set<String>>{};
  final values = <String, Map<String, String>>{};
  for (final path in _arbs) {
    final file = File(path);
    if (!file.existsSync()) {
      problems.add('$path is not there');
      continue;
    }
    final text = file.readAsStringSync();
    final Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException catch (error) {
      problems.add('$path is not JSON: ${error.message} at ${_where(text, error.offset)}');
      continue;
    }
    if (parsed is! Map<String, Object?>) {
      problems.add('$path is not a JSON object');
      continue;
    }
    messages[path] = {
      for (final key in parsed.keys)
        if (!key.startsWith('@')) key,
    };
    values[path] = {
      for (final MapEntry(:key, :value) in parsed.entries)
        if (!key.startsWith('@') && value is String) key: value,
    };
  }

  if (messages.length == _arbs.length) {
    final [en, zh] = [for (final path in _arbs) messages[path]!];
    for (final (only, side) in [(en.difference(zh), 'English'), (zh.difference(en), 'Chinese')]) {
      if (only.isEmpty) continue;
      problems.add('$side alone names ${_listed(only)}');
    }
    for (final path in _arbs) {
      for (final MapEntry(key: key, value: value) in values[path]!.entries) {
        if (value.trim().isEmpty) problems.add('$path: $key is empty');
      }
    }
  }

  // What gen-l10n writes is committed, so a message added without running
  // it is caught here rather than as a missing getter somewhere else. Only
  // said where Flutter is: the classes are made by it.
  final flutter = _flutter();
  if (flutter != null) {
    final before = {for (final path in _generated) path: _read(path)};
    final run = Process.runSync(flutter, ['pub', 'get'], runInShell: false);
    if (run.exitCode != 0) {
      problems.add(
        'flutter pub get failed (gen-l10n runs in it):\n'
        '${run.stdout}${run.stderr}'.trim(),
      );
    } else {
      for (final path in _generated) {
        if (_read(path) == before[path]) continue;
        problems.add('$path is not what the ARBs make: commit it');
      }
    }
  }

  if (problems.isEmpty) {
    stdout.writeln(
      'the translations are in order: ${messages[_arbs.first]?.length} messages',
    );
    return;
  }
  for (final problem in problems) {
    stderr.writeln(problem);
  }
  exit(1);
}

String? _read(String path) {
  final file = File(path);
  return file.existsSync() ? file.readAsStringSync() : null;
}

/// [offset] into [text], as a line and the start of it: the offset alone
/// says nothing a person can find in a file of thousands of lines.
String _where(String text, int? offset) {
  if (offset == null) return 'somewhere';
  final before = text.substring(0, offset.clamp(0, text.length));
  final line = '\n'.allMatches(before).length + 1;
  final start = before.lastIndexOf('\n') + 1;
  final rest = text.substring(start).split('\n').first.trim();
  return rest.isEmpty
      ? 'line $line'
      : 'line $line: ${rest.length <= 60 ? rest : '${rest.substring(0, 60)}…'}';
}

/// Sorted, and no more than a handful named: a merge that dropped a side's
/// entries leaves hundreds.
String _listed(Set<String> keys) {
  final sorted = keys.toList()..sort();
  return sorted.length <= 8
      ? sorted.join(', ')
      : '${sorted.take(8).join(', ')}, and ${sorted.length - 8} more';
}

/// Flutter's, when it is on PATH (CI puts it there; a machine may not).
String? _flutter() {
  final name = Platform.isWindows ? 'flutter.bat' : 'flutter';
  final run = Process.runSync(
    Platform.isWindows ? 'where' : 'which',
    [name],
    runInShell: true,
  );
  if (run.exitCode != 0) return null;
  final first = '${run.stdout}'.split(RegExp(r'\r?\n')).first.trim();
  return first.isEmpty ? null : first;
}
