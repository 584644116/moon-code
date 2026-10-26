// The ripgrep this app fetches for itself: found before the system's, and
// a failed fetch no more than the search going on in Dart.

import 'dart:io';

import 'package:bao_agent/bao_agent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('bundled_rg_'));
  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold it.
    }
  });

  /// A file standing in for the binary, executable where that matters.
  String fakeBinary(String directory) {
    final path = p.join(directory, BundledRipgrep.executableName);
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['+x', path]);
    }
    return path;
  }

  test('nothing is fetched until it is', () {
    final ripgrep = BundledRipgrep(directory: temp.path);
    expect(ripgrep.executable, isNull);
  });

  test('a fetched binary is the one found', () {
    final path = fakeBinary(temp.path);
    final ripgrep = BundledRipgrep(directory: temp.path);
    expect(ripgrep.executable, path);
  });

  test('it is looked in before PATH', () {
    // The system has one, and so does the app: the app's is used.
    final system = Directory(p.join(temp.path, 'system'))..createSync();
    final bundled = Directory(p.join(temp.path, 'bundled'))..createSync();
    fakeBinary(system.path);
    final wanted = fakeBinary(bundled.path);

    final index = FileIndex(
      {'PATH': system.path},
      bundledDirectory: bundled.path,
    );
    expect(index.ripgrep, wanted);
  });

  test('without one of its own it takes the system\'s', () {
    final system = Directory(p.join(temp.path, 'system'))..createSync();
    final onPath = fakeBinary(system.path);

    final index = FileIndex({'PATH': system.path});
    expect(index.ripgrep, onPath);
  });

  test('with neither, a search still works: ripgrep is null, not fatal', () {
    final index = FileIndex({'PATH': p.join(temp.path, 'nowhere')});
    expect(index.ripgrep, isNull);
  });

  test('a fetch that fails says so, and leaves nothing behind', () async {
    final ripgrep = BundledRipgrep(
      directory: temp.path,
      download: (url, destination) async {
        throw const HttpException('no network');
      },
    );
    await expectLater(
      ripgrep.install(),
      throwsA(isA<BundledRipgrepException>()),
    );
    expect(ripgrep.executable, isNull);
  });

  test('a fetch writes the binary where it is looked for', () async {
    // A release archive is a zip of a folder holding the binary; what the
    // downloader is given here is that zip, written by the platform's own
    // archiver, so that unpacking is exercised as it is in use.
    final staging = Directory(p.join(temp.path, 'staging'))
      ..createSync(recursive: true);
    final inner = Directory(
      p.join(staging.path, 'ripgrep-15.2.0-x86_64-pc-windows-msvc'),
    )..createSync();
    fakeBinary(inner.path);

    final ripgrep = BundledRipgrep(
      directory: p.join(temp.path, 'tools'),
      download: (url, destination) async {
        await _zip(staging.path, destination);
      },
    );
    final installed = await ripgrep.install();
    expect(installed, p.join(temp.path, 'tools', BundledRipgrep.executableName));
    expect(File(installed).existsSync(), isTrue);
    // The release's own folder is not kept.
    expect(
      Directory(p.join(temp.path, 'tools', 'ripgrep-15.2.0-x86_64-pc-windows-msvc'))
          .existsSync(),
      isFalse,
    );
  });
}

/// [directory]'s contents as a zip at [destination], by the platform's
/// archiver: the test writes no zip by hand.
Future<void> _zip(String directory, String destination) async {
  final name = p.basename(destination);
  final parent = p.dirname(destination);
  final ProcessResult result;
  if (Platform.isWindows) {
    result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Compress-Archive -Path ${_q(p.join(directory, '*'))} '
          '-DestinationPath ${_q(destination)} -Force',
    ]);
  } else {
    result = await Process.run('zip', [
      '-r',
      '-q',
      p.join(parent, name),
      '.',
    ], workingDirectory: directory);
  }
  if (result.exitCode != 0) {
    fail('could not build the archive: ${result.stderr}');
  }
}

String _q(String value) => "'${value.replaceAll("'", "''")}'";
