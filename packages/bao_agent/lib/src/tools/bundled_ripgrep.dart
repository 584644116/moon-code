// ripgrep, fetched by this app for itself: a search that is quick and
// regex-faithful without asking anyone to install anything.
//
// It is not required — [FileIndex] searches in Dart when it is absent — but
// an upstream that speaks Rust regex runs several times faster and takes
// syntax Dart's own RegExp refuses. So the app fetches it once, where it
// keeps its own files, and every session after that uses it.

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Where a fetched ripgrep lives, and how to get it.
class BundledRipgrep {
  BundledRipgrep({
    required this.directory,
    Future<void> Function(Uri url, String destination)? download,
  }) : _download = download ?? _httpDownload;

  /// Where [executable] is kept, when it has been fetched.
  final String directory;

  final Future<void> Function(Uri url, String destination) _download;

  static String get executableName => Platform.isWindows ? 'rg.exe' : 'rg';

  /// The fetched binary's path; null when it has not been fetched.
  String? get executable {
    final path = p.join(directory, executableName);
    final file = File(path);
    if (!file.existsSync()) return null;
    if (Platform.isWindows) return path;
    return file.statSync().mode & 0x49 != 0 ? path : null;
  }

  /// The release to fetch: ripgrep's own builds, one per platform.
  static ({Uri url, String archive})? get _release {
    const version = '15.2.0';
    const base = 'https://github.com/BurntSushi/ripgrep/releases/download';
    if (Platform.isWindows) {
      return (
        url: Uri.parse(
          '$base/$version/ripgrep-$version-x86_64-pc-windows-msvc.zip',
        ),
        archive: 'zip',
      );
    }
    if (Platform.isMacOS) {
      // One build for both, as ripgrep ships it.
      return (
        url: Uri.parse(
          '$base/$version/ripgrep-$version-aarch64-apple-darwin.tar.gz',
        ),
        archive: 'tar.gz',
      );
    }
    if (Platform.isLinux) {
      final arch = _machineHardware();
      final target = arch == 'aarch64'
          ? 'aarch64-unknown-linux-gnu'
          : 'x86_64-unknown-linux-musl';
      return (
        url: Uri.parse('$base/$version/ripgrep-$version-$target.tar.gz'),
        archive: 'tar.gz',
      );
    }
    return null;
  }

  static String _machineHardware() {
    try {
      final result = Process.runSync('uname', ['-m']);
      return '${result.stdout}'.trim();
    } on Object {
      return '';
    }
  }

  /// Fetches ripgrep into [directory] and returns its path.
  ///
  /// Throws [BundledRipgrepException] when this platform has no build to
  /// fetch, the download fails, or the archive holds no binary: the caller
  /// goes on without it, as it does when it was never fetched.
  Future<String> install({void Function(int received, int? total)? onProgress}) async {
    final release = _release;
    if (release == null) {
      throw BundledRipgrepException(
        'No ripgrep build is published for this platform.',
      );
    }
    final target = Directory(directory);
    await target.create(recursive: true);
    final archive = p.join(
      target.path,
      'ripgrep-download.${release.archive}',
    );
    try {
      await _download(release.url, archive);
      await _unpack(archive, target.path);
    } on BundledRipgrepException {
      rethrow;
    } on Object catch (error) {
      throw BundledRipgrepException(
        'Could not fetch ripgrep',
        detail: '$error',
      );
    } finally {
      final file = File(archive);
      if (file.existsSync()) {
        try {
          await file.delete();
        } on FileSystemException {
          // Left for the next attempt to overwrite.
        }
      }
    }
    final found = executable;
    if (found == null) {
      throw BundledRipgrepException(
        'The ripgrep archive held no $executableName.',
      );
    }
    return found;
  }

  /// Unpacks [archive] into [directory], keeping only the binary: the
  /// release's documentation is not this app's to keep.
  Future<void> _unpack(String archive, String directory) async {
    if (archive.endsWith('.zip')) {
      await _unzip(archive, directory);
    } else {
      final result = await Process.run('tar', [
        '-xzf',
        archive,
        '-C',
        directory,
      ]);
      if (result.exitCode != 0) {
        throw BundledRipgrepException(
          'Could not unpack the ripgrep archive',
          detail: '${result.stderr}',
        );
      }
    }
    await _collectBinary(directory);
  }

  /// Moves the binary out of the archive's own folder to [directory], and
  /// takes that folder, and the release's other files, away.
  Future<void> _collectBinary(String directory) async {
    final wanted = p.join(directory, executableName);
    if (File(wanted).existsSync()) return;
    await for (final entity in Directory(directory).list()) {
      if (entity is! Directory) continue;
      final nested = p.join(entity.path, executableName);
      if (File(nested).existsSync()) {
        await File(nested).rename(wanted);
      }
      try {
        await entity.delete(recursive: true);
      } on FileSystemException {
        // Not this app's to insist on.
      }
    }
  }

  /// `unzip` where the system has it; PowerShell on Windows, which does.
  Future<void> _unzip(String archive, String directory) async {
    if (Platform.isWindows) {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Expand-Archive -LiteralPath ${_quote(archive)} '
            '-DestinationPath ${_quote(directory)} -Force',
      ]);
      if (result.exitCode == 0) return;
      throw BundledRipgrepException(
        'Could not unpack the ripgrep archive',
        detail: '${result.stderr}',
      );
    }
    final result = await Process.run('unzip', [
      '-o',
      archive,
      '-d',
      directory,
    ]);
    if (result.exitCode != 0) {
      throw BundledRipgrepException(
        'Could not unpack the ripgrep archive',
        detail: '${result.stderr}',
      );
    }
  }

  static String _quote(String value) =>
      "'${value.replaceAll("'", "''")}'";

  /// Over HTTPS with `dart:io`, following redirects (GitHub's release
  /// assets redirect to their storage), into a temporary file renamed once
  /// complete.
  static Future<void> _httpDownload(Uri url, String destination) async {
    final client = HttpClient()..userAgent = 'baocode';
    final partial = File('$destination.part');
    try {
      final request = await client.getUrl(url);
      request.followRedirects = true;
      request.maxRedirects = 10;
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('HTTP ${response.statusCode}', uri: url);
      }
      final sink = partial.openWrite();
      await response.pipe(sink);
      await partial.rename(destination);
    } finally {
      client.close();
    }
  }
}

/// A fetched ripgrep that could not be fetched: the search goes on without
/// it, in Dart.
class BundledRipgrepException implements Exception {
  const BundledRipgrepException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message: $detail';
}
