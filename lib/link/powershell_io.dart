import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Runs [script] in PowerShell and answers what it printed, or null when it
/// did not finish within [timeout].
///
/// `Process.run(…).timeout(…)` only stops *waiting*: the process keeps
/// running. A firewall check that walks every inbound rule takes minutes on
/// a machine with many of them, so each check that "timed out" left a
/// PowerShell behind; several of those together are what made the window
/// stutter. Here the one that ran out of time is ended.
Future<ProcessResult?> runPowerShell(
  String script, {
  required Duration timeout,
}) async {
  final Process process;
  try {
    process = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);
  } on Object {
    return null;
  }
  final output = utf8.decodeStream(process.stdout);
  final errors = utf8.decodeStream(process.stderr);
  var timedOut = false;
  final code = await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      timedOut = true;
      process.kill();
      return -1;
    },
  );
  if (timedOut) return null;
  return ProcessResult(
    process.pid,
    code,
    await _settled(output),
    await _settled(errors),
  );
}

/// [text], or what was read if it closes not at all: a process that started
/// another may leave the pipe open behind it, and nothing here waits for
/// that.
Future<String> _settled(Future<String> text) async {
  try {
    return await text.timeout(const Duration(seconds: 2));
  } on Object {
    return '';
  }
}
