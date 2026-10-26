/// Which build of the app this is: MoonCode's own, or one built beside it
/// (`--dart-define=BAOCODE_EDITION=lab`, tool/build_windows_lab.dart),
/// under another name, in a data folder of its own, and sharing the first
/// one's settings and keys.
///
/// The edition is a build-time constant; [isLab] may be set under test.
///
/// The folder names are MoonCode's; [formerDataFolder] is what the app was
/// called before, kept so that a run finds the files an older install left
/// and carries them over ([AdoptsFormerData]).
abstract final class AppIdentity {
  static const String _edition = String.fromEnvironment('BAOCODE_EDITION');

  /// Whether this is the build made to run beside an installed MoonCode.
  /// A test sets it to read that build's paths.
  static bool isLab = _edition == 'lab';

  /// What the app calls itself: the window's title, the tray's tooltip,
  /// Settings → About.
  static String get name => isLab ? 'MoonCode Lab' : 'MoonCode';

  /// Its folder in the platform's place for app data (`%APPDATA%` on
  /// Windows): its own, so that what it keeps for itself is not the
  /// installed app's.
  static String get dataFolder => isLab ? 'mooncodelab' : 'mooncode';

  /// The folder this app kept its data in before it was renamed: read once
  /// at startup, to copy what is there into [dataFolder]. Null for the Lab
  /// build, which has no such past.
  static String? get formerDataFolder => isLab ? null : 'baocode';

  /// The folder of the app it runs beside, whose `User/` files and keys it
  /// reads and writes as its own; null for the app's own build.
  static String? get sharedFolder => isLab ? 'mooncode' : null;

  /// The folder under the user's home the data pointer is kept in
  /// (`~/.mooncode/config-dir.json`): its own, so that moving this build's
  /// data leaves the installed app's where it is.
  static String get pointerFolder => isLab ? '.mooncodelab' : '.mooncode';
}
