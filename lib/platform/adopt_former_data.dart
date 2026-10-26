// What an older install left behind, brought into this one.
//
// The app was called MoonCode before it was renamed, and kept its files in a
// folder of that name. Its settings, keys, sessions and history are all
// there. On the first run under the new name nothing would be found — the
// app would start as a fresh install, with the user's own keys gone — so
// the former folder is copied in once, and a note kept that it was.

import 'dart:io';

import 'package:bao_remote/local.dart' show AppPaths;
import 'package:path/path.dart' as p;

import 'app_identity.dart';

/// Copies the former data folder into this build's, once.
abstract final class AdoptsFormerData {
  /// What is copied: the user's own files, and the app's state. Not the
  /// caches, the logs, or what the app can fetch again (a search's ripgrep,
  /// an update's download), which are this build's to make anew.
  static const carried = [
    'User',
    'secrets',
    'state',
    'claude',
    'checkpoints',
    'turn-stats',
  ];

  /// The note that says it was done, so that a run never does it twice.
  static String markerFile(String dataDirectory) =>
      p.join(dataDirectory, 'state', 'adopted-from.json');

  /// Copies the former folder into [dataDirectory] when it is there and
  /// this has not been done. Returns the folder it came from, or null when
  /// there was nothing to do.
  ///
  /// A copy that fails partway leaves the marker unwritten, so the next run
  /// tries again; what it did copy is left in place, as [copy] does not
  /// overwrite a file that is already there.
  static Future<String?> adopt(
    String dataDirectory, {
    required Map<String, String> environment,
  }) async {
    final former = AppIdentity.formerDataFolder;
    if (former == null) return null;
    if (File(markerFile(dataDirectory)).existsSync()) return null;
    final source = _formerPath(former, environment);
    // Nothing there to bring: a first install, not an older one.
    if (!Directory(source).existsSync()) return null;

    await Directory(dataDirectory).create(recursive: true);
    final copied = <String>[];
    for (final entry in carried) {
      final from = p.join(source, entry);
      if (!Directory(from).existsSync()) continue;
      await _copyTree(from, p.join(dataDirectory, entry));
      copied.add(entry);
    }
    await File(markerFile(dataDirectory)).create(recursive: true);
    await File(markerFile(dataDirectory)).writeAsString(
      '{"from": ${_json(source)}, "entries": ${_jsonList(copied)}}',
    );
    return source;
  }

  /// Where the former folder is, as the platform keeps it: beside this
  /// build's own, in the same place.
  static String _formerPath(
    String former,
    Map<String, String> environment,
  ) => AppPaths.dataDir(environment, folder: former);

  /// [from]'s files into [to], keeping what is already there.
  static Future<void> _copyTree(String from, String to) async {
    await for (final entity in Directory(from).list(followLinks: false)) {
      final name = p.basename(entity.path);
      final target = p.join(to, name);
      if (entity is Directory) {
        await Directory(target).create(recursive: true);
        await _copyTree(entity.path, target);
      } else if (entity is File) {
        if (File(target).existsSync()) continue;
        await Directory(to).create(recursive: true);
        try {
          await entity.copy(target);
        } on FileSystemException {
          // Locked or gone since it was listed: not this run's to insist
          // on, and the next one tries again.
        }
      }
    }
  }

  static String _json(String value) =>
      '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  static String _jsonList(List<String> values) =>
      '[${values.map(_json).join(', ')}]';
}
