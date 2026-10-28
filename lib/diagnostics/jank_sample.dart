import 'dart:io';

import 'package:path/path.dart' as p;

/// Starts [executable] with [arguments], on its own: nothing waits for it.
typedef StartDetached = Future<void> Function(
  String executable,
  List<String> arguments,
);

Future<void> _startDetached(String executable, List<String> arguments) =>
    Process.start(executable, arguments, mode: ProcessStartMode.detached);

/// On a Mac, what the app's threads were doing while its frames were slow
/// one after another (see JankWindow): macOS's `/usr/bin/sample` run on the
/// app itself for [seconds], into `hangs/jank-<YYYYMMDD-HHMMSS>-<pid>.txt`
/// of the logs [folder], which a diagnostics upload sends as it does a
/// hang report. Its main thread is the one Dart runs on, beside it
/// `io.flutter.raster`.
///
/// The Dart code's frames read `??? (in App) load address … + 0x…`:
/// `dart run tool/symbolize_mac_sample.dart` names them with the build's
/// symbols (CI's `symbols-macos` artifact, tool/build_macos.dart).
///
/// Not more than one each [gap] nor [most] in a run, and only the [kept]
/// newest stay: it slows the app a little more while it samples.
class JankSampler {
  JankSampler(
    this.folder, {
    this.seconds = 3,
    this.gap = const Duration(minutes: 10),
    this.most = 3,
    this.kept = 5,
    DateTime Function()? clock,
    StartDetached? start,
    int? pid,
    bool? mac,
  }) : _clock = clock ?? DateTime.now,
       _start = start ?? _startDetached,
       _pid = (mac ?? Platform.isMacOS) ? pid ?? _ownPid() : null;

  static int _ownPid() => pid;

  /// The logs folder (`DataDirectory.logsDir`).
  final String folder;
  final int seconds;
  final Duration gap;
  final int most;
  final int kept;

  final DateTime Function() _clock;
  final StartDetached _start;

  /// Its own process; null where there is no `sample` (not a Mac).
  final int? _pid;

  int _taken = 0;
  DateTime? _last;

  /// Samples the app, unless it was just done or no more is to be: the
  /// file's name under [folder] (`hangs/jank-….txt`), written once
  /// `sample` is done; else null.
  Future<String?> sample() async {
    final pid = _pid;
    if (pid == null || _taken >= most) return null;
    final now = _clock();
    if (_last case final last? when now.difference(last) < gap) return null;
    _taken++;
    _last = now;
    final hangs = Directory(p.join(folder, 'hangs'));
    try {
      hangs.createSync(recursive: true);
      _prune(hangs);
      String two(int n) => '$n'.padLeft(2, '0');
      final name =
          'jank-${now.year}${two(now.month)}${two(now.day)}-'
          '${two(now.hour)}${two(now.minute)}${two(now.second)}-$pid.txt';
      await _start('/usr/bin/sample', [
        '$pid',
        '$seconds',
        '-file',
        p.join(hangs.path, name),
      ]);
      return 'hangs/$name';
    } on Object {
      return null;
    }
  }

  /// Leaves room for one more: the oldest go past [kept].
  void _prune(Directory hangs) {
    final samples = [
      for (final entity in hangs.listSync(followLinks: false))
        if (entity is File &&
            p.basename(entity.path).startsWith('jank-') &&
            entity.path.endsWith('.txt'))
          entity,
    ]..sort((a, b) => b.path.compareTo(a.path));
    for (final old in samples.skip(kept - 1)) {
      try {
        old.deleteSync();
      } on FileSystemException {
        // Gone already.
      }
    }
  }
}
