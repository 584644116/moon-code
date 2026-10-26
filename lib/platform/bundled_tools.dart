// The tools this app keeps for itself, under its own data directory: so
// that a search is quick and regex-faithful for anyone who installs the
// app, without asking them to install anything else.
//
// ripgrep is the one that matters. It is not required — the agent searches
// in Dart without it, and `git ls-files` lists files — but with it a search
// runs several times faster and takes the Rust regex syntax the tools
// describe. So it is fetched once, on first use, and kept.

import 'dart:async';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart';
import 'package:path/path.dart' as p;

import 'data_dir.dart';

/// Where this app keeps the tools it fetched, and how to fetch them.
abstract final class BundledTools {
  /// `…/tools`, beside the app's own files.
  static String get directory => p.join(DataDirectory.current.path, 'tools');

  /// The fetched ripgrep, or null when it has not been fetched.
  static BundledRipgrep get ripgrep => BundledRipgrep(directory: directory);

  /// Fetches ripgrep, unless it is already there or the system has one.
  ///
  /// Returns its path when it is now usable, null when this machine needs
  /// nothing done (a `rg` is already on `PATH`), or throws
  /// [BundledRipgrepException] when the fetch failed: the app goes on
  /// either way, searching in Dart where it must.
  static Future<String?> ensureRipgrep({
    Map<String, String>? environment,
    bool force = false,
  }) async {
    final fetched = ripgrep;
    if (fetched.executable case final path?) return path;
    if (!force) {
      final onPath = FileIndex(
        environment ?? Platform.environment,
      ).ripgrep;
      if (onPath != null) return null;
    }
    return fetched.install();
  }

  /// Whether a search on this machine will use ripgrep: the fetched one, or
  /// the system's.
  static bool get hasRipgrep =>
      ripgrep.executable != null ||
      FileIndex(Platform.environment).ripgrep != null;

  /// The fetched binary's path, when there is one.
  static String? get ripgrepPath => ripgrep.executable;
}
