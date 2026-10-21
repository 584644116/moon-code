import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/platform/app_identity.dart';
import 'package:baocode/platform/app_paths.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:path/path.dart' as p;

/// BaoCode Lab (lib/platform/app_identity.dart): the build kept beside an
/// installed BaoCode — its own data folder, and the installed app's `User/`
/// files and keys read as its own.
void main() {
  late Directory home;
  late Map<String, String> environment;

  setUp(() {
    home = Directory.systemTemp.createTempSync('baocode-lab-home');
    environment = {
      'HOME': home.path,
      'USERPROFILE': home.path,
      'APPDATA': p.join(home.path, 'AppData', 'Roaming'),
    };
    AppIdentity.isLab = true;
  });
  tearDown(() {
    AppIdentity.isLab = false;
    home.deleteSync(recursive: true);
  });

  /// The installed app's folder, made, as an install would leave it.
  Directory installed({String folder = 'baocode'}) {
    final directory = Directory(AppPaths.dataDir(environment, folder: folder));
    directory.createSync(recursive: true);
    return directory;
  }

  test('the app\'s own build is BaoCode, in baocode, sharing nothing', () {
    AppIdentity.isLab = false;
    expect(AppIdentity.name, 'BaoCode');
    expect(AppIdentity.dataFolder, 'baocode');
    expect(AppIdentity.sharedFolder, isNull);
    expect(AppIdentity.pointerFolder, '.baocode');
  });

  test('the Lab build is BaoCode Lab, in baocodelab, beside baocode', () {
    expect(AppIdentity.name, 'BaoCode Lab');
    expect(AppIdentity.dataFolder, 'baocodelab');
    expect(AppIdentity.sharedFolder, 'baocode');
    expect(AppIdentity.pointerFolder, '.baocodelab');
    expect(
      DataDirectory.defaultPath(environment),
      AppPaths.dataDir(environment, folder: 'baocodelab'),
    );
  });

  test('the user\'s files are the installed app\'s, the state its own', () {
    const directory = DataDirectory(
      '/lab',
      shared: '/installed',
    );
    expect(directory.userDir, p.join('/installed', 'User'));
    expect(directory.settingsFile, p.join('/installed', 'User', 'settings.json'));
    expect(directory.keybindingsFile,
        p.join('/installed', 'User', 'keybindings.json'));
    expect(directory.lspSettingsFile, p.join('/installed', 'User', 'lsp.json'));
    expect(directory.argvFile, p.join('/installed', 'argv.json'));
    expect(directory.keymapsDir, p.join('/installed', 'keymaps'));
    expect(directory.secretsDir, p.join('/installed', 'secrets'));
    // What the app keeps for itself stays in its own folder.
    expect(directory.stateFile, p.join('/lab', 'state', 'state.json'));
    expect(directory.cacheDir, p.join('/lab', 'cache'));
    expect(directory.logsDir, p.join('/lab', 'logs'));
  });

  test('a build alone keeps its own User/ and keys', () {
    const directory = DataDirectory('/data');
    expect(directory.userDir, p.join('/data', 'User'));
    expect(directory.secretsDir, p.join('/data', 'secrets'));
  });

  test('the Lab build shares the installed app\'s folder when it is there',
      () {
    final resolution = DataDirectoryResolution(
      path: AppPaths.dataDir(environment, folder: 'baocodelab'),
      source: DataDirectorySource.defaultLocation,
      defaultPath: AppPaths.dataDir(environment, folder: 'baocodelab'),
      pointerFile: p.join(home.path, '.baocodelab', 'config-dir.json'),
      environment: environment,
      home: home.path,
    );
    // Not installed: nothing to share, and the Lab build keeps its own.
    expect(resolution.sharedPath, isNull);
    expect(resolution.directory.userDir,
        p.join(resolution.path, 'User'));

    final installedFolder = installed();
    expect(resolution.sharedPath, installedFolder.path);
    expect(resolution.directory.userDir, p.join(installedFolder.path, 'User'));
  });

  test('a folder the installed app was moved to is the one shared', () async {
    final moved = Directory(p.join(home.path, 'moved-baocode'))
      ..createSync(recursive: true);
    await DataDirectoryPointer(
      dataDir: moved.path,
    ).write(File(p.join(home.path, '.baocode', 'config-dir.json')));

    expect(
      sharedDataDirectory(environment: environment, home: home.path),
      moved.path,
    );
  });

  test('with no pointer, the platform\'s default of the installed app', () {
    expect(
      sharedDataDirectory(environment: environment, home: home.path),
      AppPaths.dataDir(environment, folder: 'baocode'),
    );
  });

  test('a build alone shares nothing', () {
    AppIdentity.isLab = false;
    expect(
      sharedDataDirectory(environment: environment, home: home.path),
      isNull,
    );
  });
}
