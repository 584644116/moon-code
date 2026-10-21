// Builds BaoCode Lab: the same app built under another name, installed
// beside a BaoCode already there, to be run at the same time. Run from
// anywhere in the repository:
//
//   dart run tool/build_windows_lab.dart               build, then package
//   dart run tool/build_windows_lab.dart --skip-build  package what is built
//   dart run tool/build_windows_lab.dart --patched-engine
//                                                      put tool/engine's
//                                                      engine in (it fits only
//                                                      the Flutter it was
//                                                      built for; see
//                                                      tool/engine/README.md)
//
// What it differs in (lib/platform/app_identity.dart, windows/runner/
// app_identity.cpp):
//
//   * its executable is baocodelab.exe, and what Windows shows for it
//     BaoCode Lab, so the installed app and this one are told apart in the
//     task manager, the tray and the uninstaller's list;
//   * its own data folder (%APPDATA%\baocodelab): sessions, caches,
//     checkpoints and logs, which the two must not share;
//   * the user's own files — User\settings.json, User\keybindings.json,
//     argv.json, keymaps\ and secrets\ — are the installed app's, read and
//     written where it keeps them (DataDirectory.shared): a setting or a
//     key set in one is there in the other;
//   * it never looks for updates (lib/update/installer_io.dart): the
//     releases are the installed app's installer, not this one's;
//   * no `code` command, Explorer menu, baocode: link or browser host: each
//     would be the installed app's, under the same keys.
//
// The bundle goes to build\windows\x64\lab\runner\Release (the flavor keeps
// it apart from the app's own build); the installer lands in
// build\installers\.
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Where the Lab bundle goes: `flutter build windows --flavor=lab` puts it
/// under build\windows\x64\lab, apart from the app's own Release build (a
/// folder of its own, so that nothing of that build — a baocode.exe from
/// before, say — is taken for this one's).
const _flavor = 'lab';
const _buildRelative = r'build\windows\x64\lab';
const _bundleRelative = r'build\windows\x64\lab\runner\Release';
const _installersRelative = r'build\installers';

/// What has to be in the bundle for the app to start.
const _required = [
  'baocodelab.exe',
  'flutter_windows.dll',
  r'data\app.so',
  r'data\icudtl.dat',
  r'data\flutter_assets',
];

/// SHA-256 of Flutter's own release flutter_windows.dll that
/// tool/engine/flutter_windows.dll was built to replace (3.47.5), and of
/// that one. The patched engine only fits the Dart snapshot of the same
/// Flutter; one built by another is not put in (see --patched-engine).
const _stockEngineSha256 =
    '8bd7b61eee31aa436edb182db41624d1cd3b2688a7e03622320dbeae067b5251';
const _patchedEngineSha256 =
    'd20feefdf335b0e3ae92f4e2f1b1892b5bd9d4c80b194b14b8bb87b34b9591d5';

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    _fail('This builds the Windows installer, and only runs on Windows.');
  }
  final skipBuild = arguments.contains('--skip-build');
  final patchedEngine = arguments.contains('--patched-engine');

  final root = File.fromUri(Platform.script).parent.parent.absolute;
  final bundle = Directory('${root.path}\\$_bundleRelative');
  final installers = Directory('${root.path}\\$_installersRelative');
  final version = _readVersion(File('${root.path}\\pubspec.yaml'));

  if (!skipBuild) {
    _step('Building the Release bundle of BaoCode Lab');
    // The flavor keeps this build's folder apart from the app's own
    // (build\windows\x64\lab); what is in it from a build before goes.
    final build = Directory('${root.path}\\$_buildRelative');
    if (build.existsSync()) build.deleteSync(recursive: true);
    // BAOCODE_LAB is what windows/CMakeLists.txt reads: it names the
    // executable baocodelab and Runner.rc the app BaoCode Lab. `flutter
    // build windows` hands CMake no definitions of ours, so it goes in the
    // environment.
    await _run('flutter', [
      'build',
      'windows',
      '--release',
      '--flavor=$_flavor',
      '--dart-define=BAOCODE_EDITION=lab',
    ], root.path, environment: {'BAOCODE_LAB': '1'});
  } else {
    _step('Using the bundle already built');
  }

  _step('Checking the bundle');
  _checkBundle(bundle, _required);

  if (patchedEngine) {
    _step('Putting in the patched engine');
    _swapEngine(root, bundle);
  } else {
    _step('Keeping Flutter\'s own engine');
  }

  // What the app needs beside it for remote projects, which this build does
  // not make: the installed app's, or the app's own build's.
  _step('Putting in the remote server\'s listing and OpenSSH');
  for (final item in ['remote', 'openssh']) {
    final target = Directory('${bundle.path}\\$item');
    if (target.existsSync()) continue;
    final source = _besideInstalledApp(root, item);
    if (source == null) {
      stdout.writeln(
        '  No $item\\ found (not in the installed app or in the app\'s own '
        'build): remote projects over SSH will ask for it and fail.',
      );
      continue;
    }
    target.createSync(recursive: true);
    await _copyTree(source, target);
    stdout.writeln('  $item\\ taken from ${source.path}');
  }

  _step('Compiling the installer');
  final iscc = _findIscc();
  installers.createSync(recursive: true);
  await _run(iscc, [
    '/DBundleDir=${bundle.path}',
    '/DAppVersion=${version.full}',
    '/DOutDir=${installers.path}',
    '${root.path}\\tool\\baocodelab.iss',
  ], root.path);

  _step('Done');
  final installer = File(
    '${installers.path}\\BaoCodeLab-${version.marketing}-setup.exe',
  );
  if (!installer.existsSync()) {
    _fail('ISCC wrote no installer at ${installer.path}.');
  }
  final mb = (installer.lengthSync() / (1024 * 1024)).toStringAsFixed(1);
  stdout.writeln('  ${installer.path}  ($mb MB)');
  stdout.writeln();
  stdout.writeln(
    'BaoCode Lab installs beside BaoCode and reads its User\\ settings and\n'
    'secrets; what it keeps for itself is in %APPDATA%\\baocodelab.',
  );
}

/// Where [item] is for the app built here: the installed app's, else the
/// app's own build's; null when neither has it.
Directory? _besideInstalledApp(Directory root, String item) {
  final local = Platform.environment['LOCALAPPDATA'];
  final programFiles = Platform.environment['ProgramFiles'];
  for (final folder in [
    if (programFiles != null) '$programFiles\\BaoCode',
    if (local != null) '$local\\Programs\\BaoCode',
    '${root.path}\\build\\windows\\x64\\runner\\Release',
  ]) {
    final directory = Directory('$folder\\$item');
    if (directory.existsSync()) return directory;
  }
  return null;
}

/// [from]'s files and folders into [to], as they are.
Future<void> _copyTree(Directory from, Directory to) async {
  await for (final entity in from.list(recursive: true, followLinks: false)) {
    final relative = entity.path.substring(from.path.length + 1);
    final target = '${to.path}\\$relative';
    if (entity is Directory) {
      await Directory(target).create(recursive: true);
    } else if (entity is File) {
      await Directory(File(target).parent.path).create(recursive: true);
      await entity.copy(target);
    }
  }
}

/// The version pubspec.yaml carries, as `1.0.0+1`.
({String full, String marketing}) _readVersion(File pubspec) {
  final text = pubspec.readAsStringSync();
  final match = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(text);
  if (match == null) _fail('No "version:" line in ${pubspec.path}');
  final full = match.group(1)!;
  final plus = full.indexOf('+');
  return (full: full, marketing: plus < 0 ? full : full.substring(0, plus));
}

/// Stops unless [directory] holds every one of [required].
void _checkBundle(Directory directory, List<String> required) {
  if (!directory.existsSync()) {
    _fail('No bundle at ${directory.path}. Build it first.');
  }
  final missing = [
    for (final item in required)
      if (FileSystemEntity.typeSync('${directory.path}\\$item') ==
          FileSystemEntityType.notFound)
        item,
  ];
  if (missing.isEmpty) {
    stdout.writeln('  ${directory.path} looks complete.');
    return;
  }
  _fail(
    'The bundle at ${directory.path} is incomplete; missing:\n'
    '${missing.map((item) => '  $item').join('\n')}',
  );
}

/// Replaces the bundle's flutter_windows.dll with tool/engine's, provided the
/// bundle's is the stock engine that one was built from (or it already is).
void _swapEngine(Directory root, Directory bundle) {
  final patched = File('${root.path}\\tool\\engine\\flutter_windows.dll');
  final target = File('${bundle.path}\\flutter_windows.dll');
  String sha256Of(File file) =>
      sha256.convert(file.readAsBytesSync()).toString();

  if (!patched.existsSync()) _fail('No patched engine at ${patched.path}.');
  if (sha256Of(patched) != _patchedEngineSha256) {
    _fail(
      '${patched.path} is not the engine this script expects.\n'
      'Update _patchedEngineSha256 in this script after rebuilding it.',
    );
  }
  final current = sha256Of(target);
  if (current == _patchedEngineSha256) {
    stdout.writeln('  The bundle already has it.');
    return;
  }
  if (current != _stockEngineSha256) {
    _fail(
      'The bundle\'s flutter_windows.dll is not the stock engine the patched\n'
      'one replaces: this Flutter is not the one the engine was built for.\n'
      'Build without --patched-engine (Flutter\'s own engine), or rebuild the\n'
      'engine with tool/engine/build_windows_engine.ps1 for this Flutter and\n'
      'update both hashes in this script.\n'
      '  bundle: $current',
    );
  }
  patched.copySync(target.path);
  stdout.writeln('  ${target.path} replaced.');
}

/// The Inno Setup compiler: where winget puts it, where a manual install
/// does, where the registry says it was installed (a folder of the user's
/// choosing), then wherever the PATH has it.
String _findIscc() {
  final local = Platform.environment['LOCALAPPDATA'];
  final candidates = [
    if (local != null) '$local\\Programs\\Inno Setup 6\\ISCC.exe',
    for (final variable in ['ProgramFiles(x86)', 'ProgramFiles'])
      if (Platform.environment[variable] case final root?)
        '$root\\Inno Setup 6\\ISCC.exe',
    ?_isccFromRegistry(),
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  _fail(
    'ISCC.exe (the Inno Setup compiler) was not found. Install it with:\n'
    '\n'
    '  winget install --id JRSoftware.InnoSetup\n'
    '\n'
    'or download it from https://jrsoftware.org/isdl.php',
  );
}

/// `InstallLocation` of an installed Inno Setup 6, from the uninstall key
/// Windows keeps (per machine, or per user).
String? _isccFromRegistry() {
  const keys = [
    r'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
    r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
  ];
  for (final key in keys) {
    final result = Process.runSync('reg', ['query', key, '/v', 'InstallLocation']);
    if (result.exitCode != 0) continue;
    final match = RegExp(
      r'InstallLocation\s+REG_SZ\s+(.+?)\s*$',
      multiLine: true,
    ).firstMatch('${result.stdout}');
    if (match != null) return '${match.group(1)!.trim()}\\ISCC.exe';
  }
  return null;
}

/// Runs [executable], printing the command; stops the script on a non-zero
/// exit. A .bat (flutter's own launcher, on Windows) needs a shell.
Future<void> _run(
  String executable,
  List<String> arguments,
  String workingDirectory, {
  Map<String, String>? environment,
}) async {
  stdout.writeln('  \$ $executable ${arguments.join(' ')}');
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    runInShell: executable == 'flutter',
    environment: environment,
  );
  final output = '${result.stdout}'.trim();
  if (output.isNotEmpty) stdout.writeln(output);
  final error = '${result.stderr}'.trim();
  if (error.isNotEmpty) stderr.writeln(error);
  if (result.exitCode != 0) {
    _fail('$executable exited with code ${result.exitCode}.');
  }
}

void _step(String message) => stdout.writeln('\n==> $message');

Never _fail(String message) {
  stderr.writeln('\n$message');
  exit(1);
}
