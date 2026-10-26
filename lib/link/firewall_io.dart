import 'dart:convert';
import 'dart:io';

import 'firewall.dart';
import 'powershell_io.dart';

/// Windows' firewall, through PowerShell: `Get-NetFirewallRule` to see
/// whether this app is let in, `New-NetFirewallRule` to let it in.
///
/// The check asks the same question the system asks of a connection: an
/// inbound rule that allows this executable, on the profile the machine is
/// on now. A rule written for Public while the machine is on a Private
/// network does not count, which is the whole point of asking.
///
/// Asking rule by rule (`$r | Get-NetFirewallApplicationFilter`) costs a
/// query per rule; with a few hundred of them that is minutes, not seconds.
/// The filters are asked for once and the rules they name looked up
/// together, which is the same answer for a fraction of the work.
Future<FirewallState> checkFirewall(int port) async {
  if (!Platform.isWindows) return FirewallState.unknown;
  final script =
      '''
\$exe = '${_quoted(Platform.resolvedExecutable)}'
\$port = $port
# The profiles the machine is on now: Domain 1, Private 2, Public 4. Asked
# of the firewall itself; `Get-NetConnectionProfile` is a query of its own.
\$bits = 0
try { \$bits = (New-Object -ComObject HNetCfg.FwPolicy2).CurrentProfileTypes } catch { }
if (-not \$bits) { 'unknown'; exit }
\$covers = @()
if (\$bits -band 1) { \$covers += 'Domain' }
if (\$bits -band 2) { \$covers += 'Private' }
if (\$bits -band 4) { \$covers += 'Public' }
\$names = New-Object 'System.Collections.Generic.HashSet[string]'
foreach (\$f in @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue)) {
  if (\$f.Name -and \$f.Program -eq \$exe) { [void]\$names.Add(\$f.Name) }
}
foreach (\$f in @(Get-NetFirewallPortFilter -ErrorAction SilentlyContinue)) {
  if (-not \$f.Name) { continue }
  if (("\$(\$f.LocalPorts)" -split ',' | ForEach-Object { \$_.Trim() }) -contains "\$port") {
    [void]\$names.Add(\$f.Name)
  }
}
\$open = \$false
if (\$names.Count -gt 0) {
  foreach (\$r in @(Get-NetFirewallRule -Name @(\$names) -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue)) {
    \$profile = "\$(\$r.Profile)"
    if (\$profile -eq 'Any') { \$open = \$true; break }
    foreach (\$one in (\$profile -split ',')) {
      if (\$covers -contains \$one.Trim()) { \$open = \$true; break }
    }
    if (\$open) { break }
  }
}
"open=\$open"
''';
  // Long enough for the bulk queries above, short enough to be someone's
  // background work and not the machine's.
  final result = await runPowerShell(
    script,
    timeout: const Duration(seconds: 20),
  );
  if (result == null || result.exitCode != 0) return FirewallState.unknown;
  final said = '${result.stdout}'.trim();
  if (!said.startsWith('open=')) return FirewallState.unknown;
  return said.endsWith('True') ? FirewallState.open : FirewallState.blocked;
}

/// Adds the two inbound rules — TCP and UDP — for this executable on every
/// profile, in one administrator's prompt. False when the user dismissed
/// it, or the system refused.
///
/// The rules are made in an elevated PowerShell that is told what to do
/// through `-EncodedCommand`: a started process is not reliably given the
/// environment it was started from, and quoting through two shells is a
/// place to lose a path with spaces in it (this one has them).
Future<bool> allowThroughFirewall(int port) async {
  if (!Platform.isWindows) return false;
  final exe = _quoted(Platform.resolvedExecutable);
  final inner =
      '''
Remove-NetFirewallRule -DisplayName 'MoonCode Lab' -ErrorAction SilentlyContinue
foreach (\$protocol in 'TCP', 'UDP') {
  New-NetFirewallRule -DisplayName 'MoonCode Lab' -Direction Inbound -Action Allow `
    -Program '$exe' -Enabled True -Profile Domain,Private,Public `
    -Protocol \$protocol | Out-Null
}
''';
  // `Start-Process -Verb RunAs` is the prompt; `-Wait` and `-PassThru` are
  // how its answer comes back at all. One line: a continuation is a
  // backtick, and a backtick is a thing to lose in a string.
  final outer =
      "\$p = Start-Process -Verb RunAs -Wait -PassThru "
      "-FilePath 'powershell.exe' "
      "-ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy',"
      "'Bypass','-EncodedCommand','${_encode(inner)}'; "
      "if (\$p) { \$p.ExitCode } else { 1 }";
  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      outer,
    ]).timeout(const Duration(minutes: 2));
    if (result.exitCode != 0) return false;
    return '${result.stdout}'.trim() == '0';
  } on Object {
    // Dismissed, or no administrator to give: the caller offers the
    // commands instead.
    return false;
  }
}

String ownExecutable() => Platform.resolvedExecutable;

/// [script] as PowerShell's UTF-16LE base64, as `-EncodedCommand` takes it.
String _encode(String script) {
  final units = script.codeUnits;
  final bytes = List<int>.filled(units.length * 2, 0);
  for (var i = 0; i < units.length; i++) {
    bytes[2 * i] = units[i] & 0xff;
    bytes[2 * i + 1] = units[i] >> 8;
  }
  return base64Encode(bytes);
}

/// [text] for a PowerShell single-quoted string: its own quotes doubled.
String _quoted(String text) => text.replaceAll("'", "''");
