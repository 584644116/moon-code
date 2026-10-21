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

/// The risk of [tool] with [input], whether the change can be undone, and
/// where the tool comes from (`kernel`, `mcp` or `sdk`).
({ApprovalRisk risk, bool? reversible, String source}) approvalRiskFor(
  String tool,
  Map<String, Object?> input,
) {
  final mcp = tool.startsWith('mcp__');
  final source = tool.startsWith('mcp__baocode__')
      ? 'sdk'
      : mcp
      ? 'mcp'
      : 'kernel';
  if (tool == 'mcp__baocode__browser_evaluate') {
    final expression = '${input['expression'] ?? ''}';
    if (_sensitiveScript.hasMatch(expression)) {
      return (risk: ApprovalRisk.credential, reversible: false, source: 'sdk');
    }
  }
  if (mcp) {
    final name = tool.split('__').last;
    return (
      risk: _networkName.hasMatch(name)
          ? ApprovalRisk.network
          : ApprovalRisk.write,
      reversible: null,
      source: source,
    );
  }
  return switch (tool) {
    'Read' || 'Glob' || 'Grep' || 'LS' || 'NotebookRead' => (
      risk: ApprovalRisk.read,
      reversible: true,
      source: source,
    ),
    'Edit' || 'MultiEdit' || 'Write' || 'NotebookEdit' => (
      risk: ApprovalRisk.write,
      reversible: true,
      source: source,
    ),
    'WebFetch' || 'WebSearch' => (
      risk: ApprovalRisk.network,
      reversible: true,
      source: source,
    ),
    'Bash' => _bash('${input['command'] ?? ''}'),
    'Agent' ||
    'Task' => (risk: ApprovalRisk.write, reversible: null, source: source),
    _ => (risk: ApprovalRisk.write, reversible: null, source: source),
  };
}

({ApprovalRisk risk, bool? reversible, String source}) _bash(String raw) {
  final command = raw.toLowerCase();
  if (_credential.hasMatch(command)) {
    return (risk: ApprovalRisk.credential, reversible: false, source: 'kernel');
  }
  if (_destructive.hasMatch(command) ||
      command.contains('> /dev/sd') ||
      command.contains('dd if=')) {
    return (
      risk: ApprovalRisk.destructive,
      reversible: false,
      source: 'kernel',
    );
  }
  if (_network.hasMatch(command)) {
    return (risk: ApprovalRisk.network, reversible: true, source: 'kernel');
  }
  if (_readOnly.hasMatch(command)) {
    return (risk: ApprovalRisk.read, reversible: true, source: 'kernel');
  }
  return (risk: ApprovalRisk.write, reversible: true, source: 'kernel');
}

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

final _destructive = RegExp(
  r'\b(rm|rmdir|del|erase|format|mkfs|shutdown|reboot|taskkill|killall)\b'
  r'|git\s+(reset\s+--hard|clean\s+-[a-z]*f|push\s+.*(--force|-f)\b)',
  caseSensitive: false,
);

final _network = RegExp(
  r'\b(curl|wget|ssh|scp|sftp|nc|netcat|telnet)\b'
  r'|\bgit\s+(push|fetch|pull|clone)\b',
  caseSensitive: false,
);

final _readOnly = RegExp(
  r'^\s*(ls|cat|head|tail|grep|rg|find|pwd|whoami|which|'
  r'git\s+(status|log|diff|show|branch))\b',
  caseSensitive: false,
);
