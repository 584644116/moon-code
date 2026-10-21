import 'package:flutter/foundation.dart';

/// A session and what belongs to it, packed as a ZIP: its transcript, its
/// subagents' and, when asked, the files kept beside it.
@immutable
class SessionExport {
  const SessionExport(this.bytes, this.files, {this.omitted = 0});

  /// The ZIP, deflated.
  final Uint8List bytes;

  /// The names in it, `/`-separated, the session's transcript first.
  final List<String> files;

  /// Files left out: too large, or past what a bundle may hold.
  final int omitted;
}

/// The most one file of an export may be (32 MiB).
const sessionExportMaxFileBytes = 32 * 1024 * 1024;

/// The most an export may hold (256 MiB).
const sessionExportMaxBytes = 256 * 1024 * 1024;
