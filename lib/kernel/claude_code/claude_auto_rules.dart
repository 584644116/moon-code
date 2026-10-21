// Allow rules that would let auto mode be bypassed.
//
// In auto mode BaoCode judges the actions the CLI asks about. A rule like
// `Bash(python:*)` lets an action through before the CLI asks, so the
// classifier never sees it; so does any allow rule for the Agent tool,
// whose subagents are then started without being weighed. The CLI strips
// such rules when its own auto mode is entered, but with another provider's
// model it runs in `default` and BaoCode classifies, so the rules stay in
// effect. This finds them, to tell the user.
//
// The shapes are the CLI's (see its dangerousPatterns and
// permissionSetup): a rule is `Tool` or `Tool(content)`, and content is
// matched exactly, as a prefix (`python:*`), as a trailing wildcard
// (`python*`, `python *`), or as `python -…*`.

/// Entry points that run arbitrary code, on Unix and Windows alike.
const _crossPlatform = [
  'python',
  'python3',
  'python2',
  'node',
  'deno',
  'tsx',
  'ruby',
  'perl',
  'php',
  'lua',
  'npx',
  'bunx',
  'npm run',
  'yarn run',
  'pnpm run',
  'bun run',
  'bash',
  'sh',
  'ssh',
];

/// Shell interpreters and wrappers that a Bash allow rule may name.
const _bashPatterns = [
  ..._crossPlatform,
  'zsh',
  'fish',
  'eval',
  'exec',
  'env',
  'xargs',
  'sudo',
];

/// PowerShell's own ways to run code: nested shells, evaluators, process
/// spawners, event/session code, and .NET escape hatches.
const _powershellPatterns = [
  ..._crossPlatform,
  'pwsh',
  'powershell',
  'cmd',
  'wsl',
  'iex',
  'invoke-expression',
  'icm',
  'invoke-command',
  'start-process',
  'saps',
  'start',
  'start-job',
  'sajb',
  'start-threadjob',
  'register-objectevent',
  'register-engineevent',
  'register-wmievent',
  'register-scheduledjob',
  'new-pssession',
  'nsn',
  'enter-pssession',
  'etsn',
  'add-type',
  'new-object',
];

/// `Tool` or `Tool(content)`, as a permission rule is written; null where
/// it is neither.
({String tool, String? content})? parsePermissionRule(String rule) {
  final text = rule.trim();
  if (text.isEmpty) return null;
  final open = text.indexOf('(');
  if (open < 0) return (tool: text, content: null);
  if (!text.endsWith(')')) return null;
  final tool = text.substring(0, open).trim();
  if (tool.isEmpty) return null;
  return (tool: tool, content: text.substring(open + 1, text.length - 1));
}

/// Whether [content] names [pattern] in a shape that allows more than it
/// says. [exe] also accepts the `.exe` spelling Windows uses.
bool _matchesPattern(String content, String pattern, {bool exe = false}) {
  final p = pattern.toLowerCase();
  final names = [p, if (exe) _withExe(p)];
  for (final name in names) {
    if (content == name) return true;
    if (content == '$name:*') return true;
    if (content == '$name*') return true;
    if (content == '$name *') return true;
    if (content.startsWith('$name -') && content.endsWith('*')) return true;
  }
  return false;
}

String _withExe(String pattern) {
  final space = pattern.indexOf(' ');
  return space < 0
      ? '$pattern.exe'
      : '${pattern.substring(0, space)}.exe${pattern.substring(space)}';
}

/// Whether [rule] would let arbitrary code run (Bash/PowerShell) or start
/// subagents unweighed (Agent/Task) without the classifier seeing it.
bool isDangerousAutoAllowRule(String rule) {
  final parsed = parsePermissionRule(rule);
  if (parsed == null) return false;
  final tool = parsed.tool.toLowerCase();
  final content = parsed.content?.trim().toLowerCase();
  switch (tool) {
    case 'agent' || 'task':
      return true;
    case 'bash':
      if (content == null || content.isEmpty || content == '*') return true;
      return _bashPatterns.any((pattern) => _matchesPattern(content, pattern));
    case 'powershell':
      if (content == null || content.isEmpty || content == '*') return true;
      return _powershellPatterns.any(
        (pattern) => _matchesPattern(content, pattern, exe: true),
      );
  }
  return false;
}

/// The allow rules in [effective] (the merged settings a `get_settings`
/// answer holds) that would bypass auto mode's classifier.
List<String> dangerousAutoAllowRules(Object? effective) {
  if (effective is! Map) return const [];
  final permissions = effective['permissions'];
  if (permissions is! Map) return const [];
  final allow = permissions['allow'];
  if (allow is! List) return const [];
  return [
    for (final rule in allow)
      if (rule is String && isDangerousAutoAllowRule(rule)) rule,
  ];
}
