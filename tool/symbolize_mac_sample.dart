// Names the frames of a macOS `sample` (a jank sample from a diagnostics
// upload, logs/hangs/jank-*.txt; lib/diagnostics/jank_sample.dart) that it
// could not: the Dart code's, `??? (in App) load address … + 0x…`, with the
// build's symbols (CI's `symbols-macos` artifact of the run that built that
// version: App.macos.symbols; tool/build_macos.dart); and, given its
// symbols too, the engine's, `??? (in FlutterMacOS)`. Run on a Mac:
//
//   dart run tool/symbolize_mac_sample.dart <sample.txt> --app <App.macos.symbols>
//       [--engine <FlutterMacOS.framework.dSYM/Contents/Resources/DWARF/FlutterMacOS>]
//       [--out <file>]
//
// The engine's symbols are in its framework.zip, for the Flutter that built
// that version (FLUTTER_VERSION in .github/workflows/release.yml; its engine
// hash is bin/internal/engine.version there): storage.googleapis.com/
// flutter_infra_release/flutter/<engine hash>/darwin-x64-release/
// framework.zip, FlutterMacOS.xcframework/macos-arm64_x86_64/dSYMs/
// FlutterMacOS.framework.dSYM/Contents/Resources/DWARF/FlutterMacOS.
//
// Writes <sample>.symbolized.txt (or --out): the sample as it was, each such
// frame named, e.g. `FrameWatch._ended  (in App) + 4  [0x10a2b65f0]`. The
// architecture is the sample's (`Code Type`); `atos` reads the symbols.
import 'dart:io';

final _frame = RegExp(
  r'\?\?\?  \(in (App|FlutterMacOS)\)  load address (0x[0-9a-f]+) \+ '
  r'0x[0-9a-f]+  \[(0x[0-9a-f]+)\]',
);

Future<void> main(List<String> arguments) async {
  String? option(String name) {
    final at = arguments.indexOf(name);
    return at < 0 || at + 1 >= arguments.length ? null : arguments[at + 1];
  }

  final options = {'--app', '--engine', '--out'};
  final inputs = [
    for (var i = 0; i < arguments.length; i++)
      if (options.contains(arguments[i]))
        null
      else if (i > 0 && options.contains(arguments[i - 1]))
        null
      else
        arguments[i],
  ].nonNulls.toList();
  final app = option('--app');
  if (inputs.length != 1 || app == null) {
    stderr.writeln(
      'Usage: dart run tool/symbolize_mac_sample.dart <sample.txt> '
      '--app <App.macos.symbols> [--engine <FlutterMacOS symbols>] '
      '[--out <file>]',
    );
    exit(64);
  }
  final symbols = {'App': app, 'FlutterMacOS': ?option('--engine')};
  final input = File(inputs.single);
  final text = input.readAsStringSync();
  final arch = switch (RegExp(
    r'^Code Type:\s+(\S+)',
    multiLine: true,
  ).firstMatch(text)?[1]) {
    'ARM64' => 'arm64',
    'X86-64' || 'X86_64' => 'x86_64',
    final other => _fail('The sample is for $other: not arm64 nor x86_64.'),
  };

  // Each module's addresses, by its load address: atos names them at once.
  final wanted = <(String, String), Set<String>>{};
  for (final match in _frame.allMatches(text)) {
    if (!symbols.containsKey(match[1])) continue;
    (wanted[(match[1]!, match[2]!)] ??= {}).add(match[3]!);
  }
  final names = <(String, String), String>{};
  for (final MapEntry(key: (module, load), value: addresses)
      in wanted.entries) {
    final list = addresses.toList();
    for (var from = 0; from < list.length; from += 500) {
      final chunk = list.sublist(from, (from + 500).clamp(0, list.length));
      final result = await Process.run('atos', [
        '-o',
        symbols[module]!,
        '-arch',
        arch,
        '-l',
        load,
        ...chunk,
      ]);
      if (result.exitCode != 0) {
        _fail('atos failed for $module: ${result.stderr}');
      }
      final lines = '${result.stdout}'.trimRight().split('\n');
      for (var i = 0; i < chunk.length && i < lines.length; i++) {
        // An address atos cannot name comes back as it went.
        if (lines[i].startsWith('0x')) continue;
        // "FrameWatch._ended (in App.macos.symbols) + 4": the module as
        // the sample names it.
        names[(module, chunk[i])] = lines[i].replaceFirst(
          RegExp(r' \(in [^)]*\)'),
          '  (in $module)',
        );
      }
    }
  }

  var named = 0;
  final out = text.replaceAllMapped(_frame, (match) {
    final name = names[(match[1]!, match[3]!)];
    if (name == null) return match[0]!;
    named++;
    return '$name  [${match[3]}]';
  });
  final path = option('--out') ?? '${input.path}.symbolized.txt';
  File(path).writeAsStringSync(out);
  final total = _frame.allMatches(text).length;
  stdout.writeln('Named $named of $total unnamed frames ($arch): $path');
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
