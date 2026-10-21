import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_identity.dart';
import 'app_paths.dart';

/// Where [DataDirectory.current] was found.
enum DataDirectorySource {
  /// The `BAOCODE_DATA_DIR` environment variable.
  environment,

  /// `~/.baocode/config-dir.json` ([DataDirectoryPointer]).
  pointer,

  /// The platform's place for app data ([DataDirectory.defaultPath]).
  defaultLocation,

  /// The platform's place for this run only: the one configured could not
  /// be used, and the user chose to go on without it.
  temporaryDefault,
}

/// The folder the app keeps the user's settings and its own state in, laid
/// out as VS Code's user data folder is:
///
/// ```text
/// <path>/User/{settings.json,keybindings.json,lsp.json}
/// <path>/argv.json                  the display language
/// <path>/keymaps/
/// <path>/state/{state.json,storage.json,*-processes.json}
/// <path>/servers/  <path>/language-packs/
/// <path>/checkpoints/             snapshots of the projects agents change
/// <path>/workspaces/              the folders of multi-folder workspaces
/// <path>/cache/                   what can be made again, to start faster
/// <path>/pastes/                  pastes too long to send, which agents read
/// <path>/logs/errors.log          the errors the app did not handle
/// <path>/extensions/              theme extensions, as VS Code lays them out
/// <path>/browser/                 the browser's bridge: whether one connected
/// <path>/images/                  the pictures agents made (generate_image)
/// <path>/secrets/                 providers' keys, where the system has no
///                                 keychain of its own (Windows, Linux)
/// ```
///
/// Other programs keep files there too (the web views' `Cookies`,
/// `GPUCache`, `Local Storage`…): only [items] are the app's.
class DataDirectory {
  const DataDirectory(
    this.path, {
    this.source = DataDirectorySource.defaultLocation,
    this.shared,
  });

  /// The one this run uses, resolved once as the app starts (main.dart,
  /// [resolveDataDirectory]). Until then the platform's default; under
  /// `flutter test` a temporary folder instead, so no test touches the
  /// user's data.
  static DataDirectory get current => _current ??= DataDirectory(
    Platform.environment.containsKey('FLUTTER_TEST')
        ? p.join(Directory.systemTemp.path, 'baocode-test-data-$pid')
        : defaultPath(Platform.environment),
    // Before main.dart has resolved the folder: a build kept beside another
    // already reads the other's files, not none at all.
    shared: Platform.environment.containsKey('FLUTTER_TEST')
        ? null
        : sharedDataDirectory(),
  );
  static set current(DataDirectory value) => _current = value;
  static DataDirectory? _current;

  final String path;
  final DataDirectorySource source;

  /// Where the user's own files are, when this build keeps them beside
  /// another's rather than its own: BaoCode Lab reads and writes the
  /// installed BaoCode's `User/`, `argv.json`, `keymaps/` and `secrets/`
  /// (see [AppIdentity]). Null for a build that keeps its own.
  final String? shared;

  /// The folder the user's files are in: [shared], else [path].
  String get userRoot => shared ?? path;

  /// What the user edits: settings, keybindings, language servers.
  String get userDir => p.join(userRoot, 'User');
  String get settingsFile => p.join(userDir, 'settings.json');
  String get keybindingsFile => p.join(userDir, 'keybindings.json');
  String get lspSettingsFile => p.join(userDir, 'lsp.json');

  /// The display language (`locale`), as VS Code's `argv.json`.
  String get argvFile => p.join(userRoot, 'argv.json');
  String get keymapsDir => p.join(userRoot, 'keymaps');

  /// The providers' keys, where the system has no keychain of its own:
  /// read as an installed BaoCode's are, so that a key added in one is
  /// there in the other.
  String get secretsDir => p.join(userRoot, 'secrets');

  /// What the app keeps for itself.
  String get stateDir => p.join(path, 'state');

  /// The Workspace's preferences ([PreferenceStore]).
  String get stateFile => p.join(stateDir, 'state.json');

  /// Small app-wide values (`GlobalStorage`).
  String get storageFile => p.join(stateDir, 'storage.json');

  /// Where the child processes of one kind are listed
  /// (`ChildProcessRegistry`): `claude`, `lsp`, `pty`.
  String processRegistryFile(String name) =>
      p.join(stateDir, '$name-processes.json');
  String get serversDir => p.join(path, 'servers');
  String get languagePacksDir => p.join(path, 'language-packs');

  /// A Git repository per project, of snapshots of its files, which the
  /// agents' changes are kept or undone against (see change_review.dart).
  String get checkpointsDir => p.join(path, 'checkpoints');

  /// What is kept only to be quicker, made again if lost (e.g. the
  /// summaries of Claude Code's sessions).
  String get cacheDir => p.join(path, 'cache');

  /// The pastes too long to go in a message, which it names for the agent
  /// to read instead (see paste_store.dart): kept, as the conversations
  /// that name them are.
  String get pastesDir => p.join(path, 'pastes');

  /// A folder per multi-folder workspace, where its agents start (see
  /// project_workspace.dart).
  String get workspacesDir => p.join(path, 'workspaces');

  /// The pictures uploaded as project icons, and `index.json` listing them
  /// (see icon_library.dart).
  String get iconsDir => p.join(path, 'icons');

  /// The app's updates, downloaded and checked, waiting to be installed
  /// (see lib/update/update_io.dart).
  String get updatesDir => p.join(path, 'updates');

  /// The errors the app did not handle, for a user to send (see
  /// error_log.dart).
  String get logsDir => p.join(path, 'logs');

  /// Installed theme extensions, as VS Code lays them out
  /// (`publisher.name-version/`, `extensions.json`).
  String get extensionsDir => p.join(path, 'extensions');

  /// What the browser's bridge keeps (see lib/browser/): `connected`, the
  /// mark that a browser has connected once.
  String get browserDir => p.join(path, 'browser');

  /// The pictures agents made where they did not say where (see
  /// lib/images/image_tools.dart): kept, as the conversations that show
  /// them are.
  String get imagesDir => p.join(path, 'images');

  /// The app's own entries, all others' left alone: what moving the folder
  /// copies and removing old data deletes.
  static const items = [
    'User',
    'argv.json',
    'keymaps',
    'state',
    'servers',
    'language-packs',
    'checkpoints',
    'cache',
    'pastes',
    'icons',
    'workspaces',
    'logs',
    'extensions',
    'browser',
    'images',
    // Where the providers' keys are kept where the system has no keychain
    // of its own (Windows' DPAPI files, Linux's fallback; see
    // secret_store_io.dart). Moving the folder without it left the
    // providers in place and their keys behind, and every task failed with
    // "Invalid API key".
    'secrets',
  ];

  /// Entries that show a folder holds the app's data.
  static const markers = ['User', 'state', 'argv.json'];

  /// The platform's place for it: `%APPDATA%\baocode` on Windows,
  /// `~/Library/Application Support/baocode` on macOS, `~/.config/baocode`
  /// elsewhere; BaoCode Lab's own folder beside it (`baocodelab`).
  static String defaultPath(Map<String, String> environment) =>
      AppPaths.dataDir(environment, folder: AppIdentity.dataFolder);

  /// The environment variable that overrides everything else.
  static const environmentVariable = 'BAOCODE_DATA_DIR';

  @override
  bool operator ==(Object other) =>
      other is DataDirectory && other.path == path && other.source == source;

  @override
  int get hashCode => Object.hash(path, source);

  @override
  String toString() => 'DataDirectory($path, ${source.name})';
}

/// `~/.baocode/config-dir.json`: the folder the user moved the data to
/// (`dataDir`; the default when absent), and the one it was moved from
/// (`previousDataDir`) until the app has asked what to do with what is
/// left there.
class DataDirectoryPointer {
  const DataDirectoryPointer({this.dataDir, this.previousDataDir});

  /// As written: absolute, or starting with `~`.
  final String? dataDir;
  final String? previousDataDir;

  /// Where it is, under [home]: `~/.baocode/config-dir.json`, or this
  /// build's own folder beside it (`~/.baocodelab`, see [AppIdentity]).
  static String fileIn(String home) =>
      p.join(home, AppIdentity.pointerFolder, 'config-dir.json');

  /// What [file] says; null when there is no such file. Throws a
  /// [FormatException] when it is not a pointer (or cannot be read).
  static DataDirectoryPointer? read(File file) {
    final String text;
    try {
      if (!file.existsSync()) return null;
      text = file.readAsStringSync();
    } on FileSystemException catch (error) {
      throw FormatException('Cannot read ${file.path}: ${error.message}');
    }
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (error) {
      throw FormatException('${file.path} is not JSON: ${error.message}');
    }
    if (json is! Map) {
      throw FormatException('${file.path} does not hold an object');
    }
    final entries = json;
    String? path(String key) => switch (entries[key]) {
      null => null,
      final String value when value.trim().isNotEmpty => value.trim(),
      _ => throw FormatException('${file.path}: "$key" is not a path'),
    };
    return DataDirectoryPointer(
      dataDir: path('dataDir'),
      previousDataDir: path('previousDataDir'),
    );
  }

  /// Writes it to [file] whole or not at all (aside, then renamed over);
  /// with neither entry, [file] goes.
  Future<void> write(File file) async {
    if (dataDir == null && previousDataDir == null) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await writeFileAtomically(
      file,
      '${const JsonEncoder.withIndent('  ').convert({'dataDir': ?dataDir, 'previousDataDir': ?previousDataDir})}\n',
    );
  }
}

/// Writes [text] to [file] aside, then renames it over: a reader never
/// sees half a file, and nothing is left aside when that fails. Where the
/// rename cannot replace the file (Windows, while another program has it
/// open) it is written in place.
Future<void> writeFileAtomically(File file, String text) async {
  final aside = File('${file.path}.$pid.${_asides++}.tmp');
  try {
    await aside.writeAsString(text, flush: true);
    try {
      await aside.rename(file.path);
    } on FileSystemException {
      await file.writeAsString(text, flush: true);
    }
  } finally {
    try {
      if (await aside.exists()) await aside.delete();
    } on FileSystemException {
      // Gone already, or a later sweep finds it.
    }
  }
}

int _asides = 0;

/// Why the data directory configured cannot be used.
enum DataDirectoryProblem {
  /// `~/.baocode/config-dir.json` cannot be read, or is not a pointer.
  invalidPointer,

  /// The folder is not there (e.g. on a drive that is gone).
  missing,

  /// The folder is there, but files cannot be made in it.
  notWritable,
}

/// Where the data directory is, and whether it can be used.
class DataDirectoryResolution {
  const DataDirectoryResolution({
    required this.path,
    required this.source,
    required this.defaultPath,
    required this.pointerFile,
    this.problem,
    this.error,
    this.environment,
    this.home,
  });

  /// The folder found; with an invalid pointer, [defaultPath].
  final String path;
  final DataDirectorySource source;

  /// The platform's place for it.
  final String defaultPath;

  /// `~/.baocode/config-dir.json`.
  final String pointerFile;

  /// Why [path] cannot be used; null when it can.
  final DataDirectoryProblem? problem;

  /// [problem] for the user.
  final String? error;

  /// The environment and home [path] was found by, when they were given
  /// (the process's and the user's otherwise): where the folder of the app
  /// this one is kept beside is looked for.
  final Map<String, String>? environment;
  final String? home;

  bool get ok => problem == null;

  /// Where the user's own files are, for a build that keeps them beside
  /// the installed app's: the folder that app uses — the one its pointer
  /// names when the user moved it, else the platform's default — when it
  /// is there (a build that runs alone keeps its own, and finds none).
  String? get sharedPath =>
      sharedBeside(path, environment: environment, home: home);

  DataDirectory get directory => DataDirectory(
    path,
    source: source,
    shared: sharedPath,
  );
}

/// Where the data directory is: `BAOCODE_DATA_DIR`, else the folder
/// `~/.baocode/config-dir.json` names (`{"dataDir": "..."}`), else the
/// platform's default. One set by either must exist and take files; one
/// that does not is reported, never replaced by the default unasked (a
/// drive may just be gone for now). [environment] is the process's and
/// [home] the user's home folder by default.
DataDirectoryResolution resolveDataDirectory({
  Map<String, String>? environment,
  String? home,
}) {
  environment ??= Platform.environment;
  home ??= AppPaths.home(environment);
  final defaultPath = DataDirectory.defaultPath(environment);
  final pointerFile = DataDirectoryPointer.fileIn(home);

  DataDirectoryResolution resolved(
    String path,
    DataDirectorySource source, {
    DataDirectoryProblem? problem,
    String? error,
  }) => DataDirectoryResolution(
    path: path,
    source: source,
    defaultPath: defaultPath,
    pointerFile: pointerFile,
    problem: problem,
    error: error,
    environment: environment,
    home: home,
  );

  DataDirectoryResolution checked(String path, DataDirectorySource source) {
    final (problem, error) = checkDataDirectory(path);
    return resolved(path, source, problem: problem, error: error);
  }

  final variable = environment[DataDirectory.environmentVariable]?.trim();
  if (variable != null && variable.isNotEmpty) {
    final path = expandDataDirectory(variable, home);
    return checked(
      p.isAbsolute(path) ? p.normalize(path) : p.absolute(path),
      DataDirectorySource.environment,
    );
  }
  final DataDirectoryPointer? pointer;
  try {
    pointer = DataDirectoryPointer.read(File(pointerFile));
  } on FormatException catch (error) {
    return resolved(
      defaultPath,
      DataDirectorySource.pointer,
      problem: DataDirectoryProblem.invalidPointer,
      error: error.message,
    );
  }
  if (pointer?.dataDir case final dataDir?) {
    final path = expandDataDirectory(dataDir, home);
    if (!p.isAbsolute(path)) {
      return resolved(
        defaultPath,
        DataDirectorySource.pointer,
        problem: DataDirectoryProblem.invalidPointer,
        error:
            '$pointerFile: "dataDir" must be an absolute path or start '
            'with ~ ($dataDir)',
      );
    }
    return checked(p.normalize(path), DataDirectorySource.pointer);
  }
  return resolved(defaultPath, DataDirectorySource.defaultLocation);
}

/// The folder the app kept beside this one ([AppIdentity.sharedFolder])
/// keeps its data in: the one `~/.baocode/config-dir.json` names, when the
/// user moved it, else the platform's default. Null for a build that runs
/// alone.
String? sharedDataDirectory({Map<String, String>? environment, String? home}) {
  final folder = AppIdentity.sharedFolder;
  if (folder == null) return null;
  environment ??= Platform.environment;
  home ??= AppPaths.home(environment);
  final pointer = File(
    p.join(home, '.${AppIdentity.sharedFolder}', 'config-dir.json'),
  );
  try {
    if (DataDirectoryPointer.read(pointer)?.dataDir case final dataDir?) {
      final path = expandDataDirectory(dataDir, home);
      if (p.isAbsolute(path)) return p.normalize(path);
    }
  } on FormatException {
    // Not a pointer: the default, as the app itself would take it.
  }
  return AppPaths.dataDir(environment, folder: folder);
}

/// [sharedDataDirectory], when it is there and is not [path] itself: what a
/// [DataDirectory] whose files are in it has for [DataDirectory.shared].
String? sharedBeside(
  String path, {
  Map<String, String>? environment,
  String? home,
}) {
  final shared = sharedDataDirectory(environment: environment, home: home);
  if (shared == null || p.equals(shared, path)) return null;
  return Directory(shared).existsSync() ? shared : null;
}

/// [path] with a leading `~` spelled out as [home].
String expandDataDirectory(String path, String home) {
  if (path == '~') return home;
  if (path.startsWith('~/') || path.startsWith(r'~\')) {
    return p.join(home, path.substring(2));
  }
  return path;
}

/// Why the folder at [path] cannot hold the data: missing (or not a
/// folder), or no file can be made in it; `(null, null)` when it can.
(DataDirectoryProblem?, String?) checkDataDirectory(String path) {
  final type = FileSystemEntity.typeSync(path);
  if (type == FileSystemEntityType.notFound) {
    return (DataDirectoryProblem.missing, 'The folder $path is not there.');
  }
  if (type != FileSystemEntityType.directory) {
    return (DataDirectoryProblem.missing, '$path is not a folder.');
  }
  if (!canWriteIn(path)) {
    return (
      DataDirectoryProblem.notWritable,
      'Files cannot be written in $path.',
    );
  }
  return (null, null);
}

/// Whether a file can be made (and removed) in the folder at [path].
bool canWriteIn(String path) {
  final probe = File(p.join(path, '.baocode-write-probe-$pid'));
  try {
    probe.writeAsStringSync('');
    probe.deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}
