import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../util/cancel.dart';

/// The files under a folder, as a search goes through them: those git (or
/// ripgrep) would not ignore, hidden ones too, `.git` itself left out.
class FileIndex {
  FileIndex(this.environment, {this.bundledDirectory});

  /// The environment programs are looked up in (`PATH`).
  final Map<String, String> environment;

  /// Where this app keeps the ripgrep it fetched for itself, when it did
  /// ([BundledRipgrep]): looked in before `PATH`, so that an install of
  /// this app's own is what a session uses even where the system has none.
  final String? bundledDirectory;

  /// The most a folder that is no repository is walked for.
  static const maxWalked = 100000;

  /// ripgrep, where installed: null when not.
  late final String? ripgrep = _findRipgrep();

  String? _findRipgrep() {
    if (bundledDirectory case final directory?) {
      if (_executableAt(p.join(directory, _ripgrepName)) case final found?) {
        return found;
      }
    }
    return which('rg');
  }

  static String get _ripgrepName =>
      Platform.isWindows ? 'rg.exe' : 'rg';

  /// [candidate] when it is there and may be run; null otherwise.
  static String? _executableAt(String candidate) {
    final file = File(candidate);
    if (!file.existsSync()) return null;
    if (Platform.isWindows) return candidate;
    // Executable by someone: the mode's x bits.
    return file.statSync().mode & 0x49 != 0 ? candidate : null;
  }

  /// [program]'s path on `PATH`; null when it is not there.
  String? which(String program) {
    final path = environment['PATH'] ?? Platform.environment['PATH'] ?? '';
    final separator = Platform.isWindows ? ';' : ':';
    final names = Platform.isWindows
        ? ['$program.exe', '$program.cmd', program]
        : [program];
    for (final dir in path.split(separator)) {
      if (dir.isEmpty) continue;
      for (final name in names) {
        final candidate = p.join(dir, name);
        final file = File(candidate);
        if (!file.existsSync()) continue;
        if (Platform.isWindows) return candidate;
        // Executable by someone: the mode's x bits.
        if (file.statSync().mode & 0x49 != 0) return candidate;
      }
    }
    return null;
  }

  /// The files under [root] (absolute paths). Ignored files are left out
  /// unless [ignored].
  Future<List<String>> list(
    String root, {
    bool ignored = false,
    CancelToken? cancel,
  }) async {
    if (!ignored) {
      if (ripgrep case final rg?) {
        final files = await _run(
          rg,
          ['--files', '--hidden', '--glob', '!.git', '--null', '.'],
          root,
          cancel,
        );
        if (files != null) return files;
      }
      final git = await _run(
        'git',
        ['ls-files', '-z', '--cached', '--others', '--exclude-standard'],
        root,
        cancel,
      );
      if (git != null) {
        // Deleted but still in the index: not there to search.
        return [
          for (final file in git)
            if (File(file).existsSync()) file,
        ];
      }
    }
    return _walk(root, cancel);
  }

  Future<List<String>?> _run(
    String executable,
    List<String> arguments,
    String root,
    CancelToken? cancel,
  ) async {
    try {
      final process = await Process.start(
        executable,
        arguments,
        workingDirectory: root,
        environment: environment,
      );
      unawaited(cancel?.whenCancelled.then((_) => process.kill()));
      final stdout = process.stdout.transform(utf8.decoder).join();
      unawaited(process.stderr.drain<void>());
      final code = await process.exitCode;
      final out = await stdout;
      // ripgrep says 1 when it found nothing.
      if (code != 0 && !(code == 1 && executable == ripgrep)) return null;
      return [
        for (final name in out.split('\x00'))
          if (name.trim().isNotEmpty)
            p.normalize(
              p.join(root, name.startsWith('./') ? name.substring(2) : name),
            ),
      ];
    } on ProcessException {
      return null;
    }
  }

  List<String> _walk(String root, CancelToken? cancel) {
    final out = <String>[];
    final pending = [Directory(root)];
    while (pending.isNotEmpty && out.length < maxWalked) {
      cancel?.check();
      final dir = pending.removeLast();
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final entry in entries) {
        final name = p.basename(entry.path);
        if (entry is Directory) {
          if (name == '.git' || name == '.hg' || name == '.svn') continue;
          pending.add(entry);
        } else if (entry is File) {
          out.add(entry.path);
        } else if (entry is Link) {
          if (FileSystemEntity.isFileSync(entry.path)) out.add(entry.path);
        }
      }
    }
    return out;
  }
}

/// Sorts [paths] newest first; those that cannot be read last.
List<String> byModified(List<String> paths) {
  final times = <String, int>{
    for (final path in paths)
      path: () {
        try {
          return File(path).lastModifiedSync().millisecondsSinceEpoch;
        } on FileSystemException {
          return 0;
        }
      }(),
  };
  return [...paths]..sort((a, b) {
    final byTime = times[b]!.compareTo(times[a]!);
    return byTime != 0 ? byTime : a.compareTo(b);
  });
}

/// [path] as the model is shown it: from [cwd] when inside it.
///
/// Always with `/`, whatever the platform's separator: a path is quoted in
/// the tools' own examples that way (`lib/**/test_*.py`), and a model that
/// sees both `lib\b.dart` and `lib/b.dart` for one file can take them for
/// two. Windows takes either when it reads them back.
String shownPath(String path, String cwd) {
  final shown = p.isWithin(cwd, path) ? p.relative(path, from: cwd) : path;
  return Platform.isWindows ? shown.replaceAll(r'\', '/') : shown;
}
