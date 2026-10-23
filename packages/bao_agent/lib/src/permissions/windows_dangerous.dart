/// The things a Windows command can do that no later look can undo, or that
/// hand the machine's own shell out to whatever is on the other end of a
/// link.
///
/// Windows has two paths a command line reaches that POSIX doesn't, and both
/// are one word wide:
///
/// * **ShellExecute.** `Start-Process`, `Invoke-Item`, `start`, `mshta`,
///   `rundll32 url.dll,FileProtocolHandler` and a browser given a URL do not
///   run a program the way `exec` does: they hand a scheme to the shell,
///   which downloads and runs what is behind it. A model asked to open a
///   link can therefore run code by writing `Start-Process https://…`.
/// * **Forced delete.** `del /f`, `rd /s /q`, and `Remove-Item -Force`
///   (and its aliases `ri`, `rm`, `del`, `erase`, `rd`, `rmdir`) remove
///   without the prompt or the recycle bin.
///
/// The rules are deliberately narrow: only what is being asked, in the
/// segment it is asked in. A delete cmdlet with `-Force` anywhere in the
/// same command counts even without `-Recurse` — `-Force` is what turns a
/// quiet failure into a removal that happened.
library;

/// Whether [words] (one simple command) is one of Windows' own ways of
/// running what it is given, unasked.
bool isDangerousWindowsWords(List<String> words) =>
    launchesUrl(words) || forcedDeletes(words);

/// Whether [words] hands a link to the system to open, which downloads and
/// runs what is behind it: `Start-Process https://…`, `mshta`, a browser
/// given an address.
bool launchesUrl(List<String> words) {
  if (words.isEmpty) return false;
  final program = _programName(words.first);
  final args = words.sublist(1);
  final lower = [for (final arg in args) arg.toLowerCase()];
  if (!args.any(_looksLikeUrl)) return false;

  if (_shellExecutePrograms.contains(program)) return true;
  if (_browsers.contains(program)) return true;
  if (program == 'rundll32' &&
      lower.any((arg) => arg.contains('url.dll,fileprotocolhandler'))) {
    return true;
  }
  // `powershell -Command "… Start-Process 'https://…'"` arrives as its own
  // command, but a line that names one of these beside a URL is the same
  // act however it was wrapped.
  return words.any(
    (word) => _shellExecuteMarkers.any(
      (marker) => word.toLowerCase().contains(marker),
    ),
  );
}

/// Whether [words] removes files or folders in a way that skips the
/// recycle bin and asks nothing: `del /f`, `rd /s /q`,
/// `Remove-Item -Force`.
bool forcedDeletes(List<String> words) {
  if (words.isEmpty) return false;
  final program = _programName(words.first);
  final args = words.sublist(1);
  final lower = [for (final arg in args) arg.toLowerCase()];
  // `-Force` on any of the delete cmdlets, spelled as short as PowerShell
  // allows: `-fo`, `-f`.
  if (_deletePrograms.contains(program) && _hasForce(args)) return true;
  if ((program == 'del' || program == 'erase') && lower.contains('/f')) {
    return true;
  }
  return (program == 'rd' || program == 'rmdir') &&
      lower.contains('/s') &&
      lower.contains('/q');
}

/// What the program of [words] is called, without its folder or `.exe`.
String _programName(String word) {
  var name = word.split(RegExp(r'[\\/]')).last.toLowerCase();
  if (name.length > 2 && name[1] == ':' && RegExp('[a-z]').hasMatch(name[0])) {
    name = name.substring(2);
  }
  for (final suffix in const ['.exe', '.cmd', '.bat', '.com']) {
    if (name.endsWith(suffix)) {
      return name.substring(0, name.length - suffix.length);
    }
  }
  return name;
}

/// Whether [arg] is [name] as PowerShell lets it be written: any prefix of
/// it from one letter on (`-f`, `-fo`, `-for`, `-force`), and either slash.
///
/// PowerShell resolves a parameter by the shortest prefix no other
/// parameter of the same cmdlet starts with, so `Remove-Item -fo` is
/// `-Force`, and `-r` is `-Recurse`. Matching only the full name misses
/// every abbreviated one, which is how `rm -r -fo C:\` went unseen.
bool isPowerShellFlag(String arg, String name) {
  final lower = arg.toLowerCase().replaceAll('/', '-');
  if (!lower.startsWith('-')) return false;
  var given = lower.substring(1);
  // `-Force:$true`, `-Recurse:$false`: the value is not part of the name.
  final colon = given.indexOf(':');
  if (colon >= 0) given = given.substring(0, colon);
  if (given.isEmpty) return false;
  if (name.startsWith(given)) return true;
  // A few parameters have an alias that is not a prefix of the name:
  // `-ec` for `-EncodedCommand`, `-e` for it too, `-nop`, `-noni`.
  return _powerShellAliasesOf[name]?.contains(given) ?? false;
}

/// The documented aliases of PowerShell's own parameters, the ones that
/// are not a prefix of the name they stand for.
const _powerShellAliasesOf = {
  'encodedcommand': {'ec', 'e'},
};

bool _hasForce(List<String> args) =>
    args.any((arg) => isPowerShellFlag(arg, 'force'));

/// Whether [token] has an `http` or `https` address in it, quoted,
/// parenthesised or bare (`Start-Process('https://…')`).
bool _looksLikeUrl(String token) {
  final lower = token.toLowerCase();
  return lower.contains('http://') || lower.contains('https://');
}

const _shellExecutePrograms = {
  'start-process',
  'start',
  'saps',
  'invoke-item',
  'ii',
  'explorer',
  'mshta',
  'shellexecute',
};

/// Names that mean "run this through the shell" wherever they are in a
/// PowerShell line.
const _shellExecuteMarkers = {
  'start-process',
  'invoke-item',
  'shellexecute',
  'shell.application',
};

const _browsers = {
  'chrome',
  'msedge',
  'firefox',
  'iexplore',
  'brave',
  'opera',
  'vivaldi',
};

const _deletePrograms = {
  'remove-item',
  'ri',
  'rm',
  'del',
  'erase',
  'rd',
  'rmdir',
};
