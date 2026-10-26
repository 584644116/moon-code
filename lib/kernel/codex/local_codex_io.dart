import 'dart:io';

import 'package:bao_remote/local.dart'
    show AppPaths, ClaudeEnvironment;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../../platform/bundled_tools.dart';
import 'codex_transport.dart';

/// Where the `codex` CLI is, and the environment to run it in.
class CodexCli {
  const CodexCli(this.executable, this.environment);

  final String executable;
  final Map<String, String> environment;

  /// Whether starting it goes through the shell, which only `cmd.exe` runs
  /// an npm `.cmd` shim for. Nothing here minds: the one argument it takes
  /// is `app-server`, no quoting for a shell to take apart.
  bool get throughShell =>
      Platform.isWindows &&
      const {'.cmd', '.bat'}.contains(p.extension(executable).toLowerCase());
}

/// Finds the `codex` CLI as the user's terminal would: on the PATH, then
/// where npm and the package managers put it. Nothing is downloaded for
/// them (Codex is another agent they may as well not have).
abstract final class LocalCodex {
  static Future<CodexCli>? _located;

  /// Where to look instead of the usual places, under test: so that a test
  /// of Codex not installed never finds the machine's own.
  @visibleForTesting
  static List<String> Function(Map<String, String> environment)?
  candidatesOverride;

  static Future<CodexCli> locate() async {
    if (_located case final located?) {
      final cli = await located;
      if (File(cli.executable).existsSync()) return cli;
      // Gone since, removed or uninstalled: looked for again.
      if (identical(_located, located)) _located = null;
    }
    return _located ??= _locate().then(
      (cli) => cli,
      onError: (Object error) {
        _located = null; // Look again next time: it may be installed now.
        throw error;
      },
    );
  }

  /// Looks again next time, the one found having failed to run: what the
  /// user changed since to mend it is then seen on a retry.
  static void forget() => _located = null;

  static Future<CodexCli> _locate() async {
    // Claude's environment lookup, which is the user's shell's: an app
    // opened from the Finder or the Start menu gets a bare PATH, and the
    // codex the user runs is where their rc file put it.
    final environment = _withBundledTools(await ClaudeEnvironment.of());
    for (final candidate in (candidatesOverride ?? _candidates)(environment)) {
      if (File(candidate).existsSync()) return CodexCli(candidate, environment);
    }
    throw const CodexNotInstalled(
      'Codex is not installed',
      detail: 'Install it (`npm install -g @openai/codex`, or `brew install '
          'codex`), then try again.',
    );
  }

  /// [environment] with the tools this app keeps for itself on its `PATH`:
  /// ripgrep, so that a command Codex's model writes (`rg --files`) is found
  /// the way its own prompts expect. Only when there is one to add.
  static Map<String, String> _withBundledTools(Map<String, String> environment) {
    final directory = BundledTools.directory;
    if (!Directory(directory).existsSync()) return environment;
    final separator = Platform.isWindows ? ';' : ':';
    final path = environment['PATH'] ?? '';
    if (path.split(separator).contains(directory)) return environment;
    return {
      ...environment,
      'PATH': path.isEmpty ? directory : '$directory$separator$path',
    };
  }

  /// Where the CLI usually is: the PATH first, then npm's global bin — its
  /// native build beside the shim, so the server runs without node in the
  /// way, the shim standing in for layouts that is not — then the package
  /// managers' own places.
  static List<String> _candidates(Map<String, String> environment) {
    final home = AppPaths.home(environment);
    final path = environment['PATH'] ?? '';
    if (Platform.isWindows) {
      final npm = p.join(environment['APPDATA'] ?? home, 'npm');
      return [
        for (final dir in path.split(';'))
          if (dir.isNotEmpty) ...[
            p.join(dir, 'codex.exe'),
            ?_behindNpmShim(dir),
            p.join(dir, 'codex.cmd'),
          ],
        p.join(npm, 'codex.exe'),
        ?_behindNpmShim(npm),
        p.join(npm, 'codex.cmd'),
      ];
    }
    return [
      for (final dir in path.split(':'))
        if (dir.isNotEmpty) '$dir/codex',
      '$home/.local/bin/codex',
      '/opt/homebrew/bin/codex',
      '/usr/local/bin/codex',
    ];
  }

  /// The native build the npm shim in [dir] forwards to, when [dir] is
  /// npm's own global `bin` (the package beside it in `node_modules`); the
  /// shim stands for itself in any other layout. Null with no shim there.
  static String? _behindNpmShim(String dir) {
    const builds = {
      'codex-win32-x64': 'x86_64-pc-windows-msvc',
      'codex-win32-arm64': 'aarch64-pc-windows-msvc',
    };
    String? found;
    for (final MapEntry(:key, :value) in builds.entries) {
      final exe = p.join(
        dir,
        'node_modules',
        '@openai',
        key,
        'vendor',
        value,
        'bin',
        'codex.exe',
      );
      if (File(exe).existsSync()) found ??= exe;
    }
    return found;
  }
}
