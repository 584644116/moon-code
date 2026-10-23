import 'shell_command.dart';

/// What an approval is about, in terms a person can weigh before saying yes.
enum ApprovalRisk {
  /// It only looks.
  read,

  /// It changes files, and the change can be undone.
  write,

  /// It cannot be undone.
  destructive,

  /// It reaches the network.
  network,

  /// It reads or changes a credential.
  credential,
}

/// What the call is about, in a word: its [risk], whether the change can be
/// undone, where the tool comes from (`kernel`, `mcp` or `sdk`), and
/// [why] — what in the call made it that, in words, when something did
/// (`"Removes files without the recycle bin"`, `"Reads a private key"`).
///
/// The risk is the label; the why is the evidence. An approval that says
/// only "Destructive" leaves the reader to work out from the command what
/// was seen in it.
typedef ApprovalAssessment = ({
  ApprovalRisk risk,
  bool? reversible,
  String source,
  String? why,
});

/// The risk of [tool] with [input], whether the change can be undone, and
/// where the tool comes from (`kernel`, `mcp` or `sdk`).
ApprovalAssessment approvalRiskFor(String tool, Map<String, Object?> input) {
  final mcp = tool.startsWith('mcp__');
  final source = tool.startsWith('mcp__baocode__')
      ? 'sdk'
      : mcp
      ? 'mcp'
      : 'kernel';
  if (tool == 'mcp__baocode__browser_evaluate') {
    final expression = '${input['expression'] ?? ''}';
    if (_sensitiveScript.hasMatch(expression)) {
      return (
        risk: ApprovalRisk.credential,
        reversible: false,
        source: 'sdk',
        why:
            'Reaches the signed-in page\'s own state: cookies, storage or '
            'credentials.',
      );
    }
  }
  if (mcp) {
    final name = tool.split('__').last;
    final network = _networkName.hasMatch(name);
    return (
      risk: network ? ApprovalRisk.network : ApprovalRisk.write,
      reversible: null,
      source: source,
      why: null,
    );
  }
  return switch (tool) {
    'Read' || 'Glob' || 'Grep' || 'LS' || 'NotebookRead' => (
      risk: ApprovalRisk.read,
      reversible: true,
      source: source,
      why: null,
    ),
    'Edit' || 'MultiEdit' || 'Write' || 'NotebookEdit' => (
      risk: ApprovalRisk.write,
      reversible: true,
      source: source,
      why: null,
    ),
    'WebFetch' || 'WebSearch' => (
      risk: ApprovalRisk.network,
      reversible: true,
      source: source,
      why: null,
    ),
    'Bash' => _bash('${input['command'] ?? ''}'),
    'Agent' || 'Task' => (
      risk: ApprovalRisk.write,
      reversible: null,
      source: source,
      why: null,
    ),
    _ => (
      risk: ApprovalRisk.write,
      reversible: null,
      source: source,
      why: null,
    ),
  };
}

/// A command's risk, read from what it is made of rather than from how it
/// is written: `bash -c "rm -rf /"` is what `rm -rf /` is, and
/// `echo "rm -rf /"` is an echo.
ApprovalAssessment _bash(String raw) {
  final command = raw.toLowerCase();
  if (_credential.hasMatch(command)) {
    return (
      risk: ApprovalRisk.credential,
      reversible: false,
      source: 'kernel',
      why: 'Touches a key, a password file or another secret.',
    );
  }
  final parsed = ShellCommand.parse(raw);
  final words = parsed.words;
  // A home written out in full is the session's to know; `~` and `$HOME`
  // are told apart by their own text.
  DangerKind? kind;
  for (final w in words) {
    kind = dangerKindOf(w, home: '');
    if (kind != null) break;
  }
  if (kind == null && words.any(isRecursiveDelete)) {
    kind = DangerKind.forcedDelete;
  }
  if (parsed.redirects.any((target) => target.startsWith('/dev/sd'))) {
    kind = DangerKind.disk;
  }
  if (kind != null) {
    return (
      risk: ApprovalRisk.destructive,
      reversible: false,
      source: 'kernel',
      why: _whyDangerous(kind),
    );
  }
  if (!parsed.unbalanced && isReadOnlyCommand(raw)) {
    return (
      risk: ApprovalRisk.read,
      reversible: true,
      source: 'kernel',
      why: null,
    );
  }
  if (_network.hasMatch(command)) {
    return (
      risk: ApprovalRisk.network,
      reversible: true,
      source: 'kernel',
      why: null,
    );
  }
  return (
    risk: ApprovalRisk.write,
    reversible: true,
    source: 'kernel',
    why: null,
  );
}

/// What [kind] does, in the words an approval reads.
String _whyDangerous(DangerKind kind) => switch (kind) {
  DangerKind.wipesAll =>
    'Removes a drive\'s root, a system folder or the home directory.',
  DangerKind.forcedDelete =>
    'Removes files or folders in a way that skips the recycle bin.',
  DangerKind.opensLink =>
    'Hands a link to the system to open, which runs what is behind it.',
  DangerKind.elevated =>
    'Runs with another user\'s rights, which is every file that user may '
        'change.',
  DangerKind.disk => 'Writes straight to a disk.',
  DangerKind.git => 'Discards work git has that cannot be given back.',
  DangerKind.runsCode =>
    'Runs code fetched from somewhere else, which nothing here can read.',
};

final _networkName = RegExp(
  r'browser|fetch|http|web|search|url|navigate',
  caseSensitive: false,
);

/// A script that reaches a signed-in page's state, rather than just the
/// document in front of it.
final _sensitiveScript = RegExp(
  r'document\.cookie|localStorage|sessionStorage|indexedDB|'
  r'navigator\.credentials|fetch\s*\(|XMLHttpRequest',
  caseSensitive: false,
);

final _credential = RegExp(
  r'\.ssh|\.aws|\.gnupg|id_rsa|id_ed25519|credentials|\.env\b|keychain|secret',
  caseSensitive: false,
);

final _network = RegExp(
  r'\b(curl|wget|ssh|scp|sftp|nc|netcat|telnet)\b'
  r'|\bgit\s+(push|fetch|pull|clone)\b',
  caseSensitive: false,
);
