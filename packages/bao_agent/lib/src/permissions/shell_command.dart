import 'dart:convert';

import 'windows_dangerous.dart';

/// A shell command line, taken apart as far as permissions need: the
/// simple commands it is made of, and what in it could hide another
/// command or write a file.
class ShellCommand {
  ShellCommand._(
    this.source,
    this.commands,
    this.hasSubstitution,
    this.redirects,
    this.unbalanced,
  );

  /// Splits [source] at `&&`, `||`, `;`, `|`, `&` and new lines outside
  /// quotes. A heredoc's lines are its command's input, not commands.
  factory ShellCommand.parse(String source) {
    final commands = <String>[];
    final redirects = <String>[];
    var substitution = false;
    final current = StringBuffer();
    String? quote;
    var i = 0;
    // The heredocs begun on this line, their lines to come after it.
    final heredocs = <({String end, bool tabs, bool literal})>[];

    void cut() {
      final text = current.toString().trim();
      if (text.isNotEmpty) commands.add(text);
      current.clear();
    }

    while (i < source.length) {
      final c = source[i];
      final next = i + 1 < source.length ? source[i + 1] : '';
      if (quote == "'") {
        current.write(c);
        if (c == "'") quote = null;
        i++;
        continue;
      }
      if (c == r'\' && next.isNotEmpty) {
        // A line continued: no break.
        if (next != '\n') current.write('$c$next');
        i += 2;
        continue;
      }
      if (quote == '"') {
        current.write(c);
        if (c == '"') {
          quote = null;
        } else if (c == r'$' && next == '(' || c == '`') {
          substitution = true;
        }
        i++;
        continue;
      }
      switch (c) {
        case "'" || '"':
          quote = c;
          current.write(c);
          i++;
        case '`':
          substitution = true;
          current.write(c);
          i++;
        case r'$' when next == '(':
          substitution = true;
          current.write(c);
          i++;
        case '<' || '>' when next == '(':
          substitution = true;
          current.write(c);
          i++;
        case '#'
            when current.isEmpty || RegExp(r'\s$').hasMatch(current.toString()):
          // A comment, to the end of the line.
          while (i < source.length && source[i] != '\n') {
            i++;
          }
        case '<' when next == '<' && source.startsWith('<<<', i):
          // A here-string: a word, not lines.
          current.write('<<<');
          i += 3;
        case '<' when next == '<':
          final tabs = source.startsWith('<<-', i);
          var at = i + (tabs ? 3 : 2);
          while (at < source.length && ' \t'.contains(source[at])) {
            at++;
          }
          final (end, after) = _redirectTarget(source, at);
          final word = source.substring(at, after);
          heredocs.add((
            end: end,
            tabs: tabs,
            // A quoted delimiter: the lines as they are, nothing expanded.
            literal:
                word.contains("'") || word.contains('"') || word.contains(r'\'),
          ));
          current.write(source.substring(i, after));
          i = after;
        case ';':
          cut();
          i++;
        case '\n':
          cut();
          i++;
          for (final heredoc in heredocs) {
            while (i < source.length) {
              var lineEnd = source.indexOf('\n', i);
              if (lineEnd < 0) lineEnd = source.length;
              var line = source.substring(i, lineEnd);
              i = lineEnd + 1;
              if (heredoc.tabs) line = line.replaceFirst(RegExp('^\t+'), '');
              if (line == heredoc.end) break;
              if (!heredoc.literal &&
                  (line.contains(r'$(') || line.contains('`'))) {
                substitution = true;
              }
            }
          }
          heredocs.clear();
        case '&' when next == '&':
          cut();
          i += 2;
        case '|' when next == '|':
          cut();
          i += 2;
        case '|':
          cut();
          i += next == '&' ? 2 : 1;
        case '&' when next == '>':
          // `&>file`: both streams to a file.
          final (target, end) = _redirectTarget(source, i + 2);
          redirects.add(target);
          current.write(source.substring(i, end));
          i = end;
        case '&':
          final before = current.toString();
          // `2>&1` and `>&2` are not a command's end.
          if (before.endsWith('>') || before.endsWith('<')) {
            current.write(c);
            i++;
          } else {
            cut();
            i++;
          }
        case '>':
          var end = i + 1;
          if (end < source.length &&
              (source[end] == '>' || source[end] == '|')) {
            end++;
          }
          if (end < source.length && source[end] == '&') {
            // `>&2`: to another stream, not a file.
            current.write(source.substring(i, end + 1));
            i = end + 1;
            break;
          }
          final (target, after) = _redirectTarget(source, end);
          redirects.add(target);
          current.write(source.substring(i, after));
          i = after;
        default:
          current.write(c);
          i++;
      }
    }
    cut();
    return ShellCommand._(
      source,
      commands,
      substitution,
      redirects,
      quote != null,
    );
  }

  static (String, int) _redirectTarget(String source, int from) {
    var i = from;
    while (i < source.length && (source[i] == ' ' || source[i] == '\t')) {
      i++;
    }
    final start = i;
    String? quote;
    while (i < source.length) {
      final c = source[i];
      if (quote != null) {
        if (c == quote) quote = null;
      } else if (c == '"' || c == "'") {
        quote = c;
      } else if (' \t\n;&|<>()'.contains(c)) {
        break;
      }
      i++;
    }
    return (_unquote(source.substring(start, i)), i);
  }

  final String source;

  /// The simple commands, each as written.
  final List<String> commands;

  /// Whether it runs a command inside another: `$(…)`, backticks, `<(…)`.
  final bool hasSubstitution;

  /// The files output is sent to (`> file`, `>> file`).
  final List<String> redirects;

  /// Whether a quote is left open: what it means is not clear.
  final bool unbalanced;

  /// Whether it writes to no file but the null device.
  bool get redirectsOnlyToNull =>
      redirects.every((target) => target == '/dev/null' || target == 'NUL');

  /// Each simple command's words, quotes taken off, environment assignments
  /// before it left out.
  List<List<String>> get words => [
    for (final command in commands) withoutAssignments(tokenize(command)),
  ];

  static String _unquote(String word) {
    final out = StringBuffer();
    String? quote;
    for (var i = 0; i < word.length; i++) {
      final c = word[i];
      if (quote != null) {
        if (c == quote) {
          quote = null;
        } else if (c == r'\' && quote == '"' && i + 1 < word.length) {
          out.write(word[++i]);
        } else {
          out.write(c);
        }
      } else if (c == '"' || c == "'") {
        quote = c;
      } else if (c == r'\' && i + 1 < word.length) {
        out.write(word[++i]);
      } else {
        out.write(c);
      }
    }
    return out.toString();
  }

  /// [command]'s words, as the shell would split them (no expansion),
  /// redirections left out.
  static List<String> tokenize(String command) {
    final words = <String>[];
    final current = StringBuffer();
    String? quote;
    var started = false;
    var skipNext = false;
    void end() {
      if (started) {
        final word = current.toString();
        if (skipNext) {
          skipNext = false;
        } else if (RegExp(r'^\d*(>>?|<|&>)$').hasMatch(word)) {
          // A redirection; its target is the next word.
          skipNext = true;
        } else if (RegExp(r'^\d*(>>?|<|&>|>&)\S').hasMatch(word)) {
          // A redirection with its target: left out.
        } else {
          words.add(word);
        }
      }
      current.clear();
      started = false;
    }

    for (var i = 0; i < command.length; i++) {
      final c = command[i];
      if (quote != null) {
        if (c == quote) {
          quote = null;
        } else if (c == r'\' && quote == '"' && i + 1 < command.length) {
          current.write(command[++i]);
        } else {
          current.write(c);
        }
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
        started = true;
      } else if (c == r'\' && i + 1 < command.length) {
        current.write(command[++i]);
        started = true;
      } else if (c == ' ' || c == '\t' || c == '\n') {
        end();
      } else {
        current.write(c);
        started = true;
      }
    }
    end();
    return words;
  }

  /// [words] without the `NAME=value` assignments before the command.
  static List<String> withoutAssignments(List<String> words) {
    var i = 0;
    while (i < words.length &&
        RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(words[i])) {
      i++;
    }
    return words.sublist(i);
  }

  /// The words a rule for [command] (one simple command) is best made of:
  /// the program, and its subcommand where it has them (`git commit`,
  /// `npm run build`).
  ///
  /// Empty when no rule made of it could be offered: a shell or an
  /// interpreter run this way would allow any command at all (`bash:*`),
  /// and a shell told to run one plain command is taken as that command
  /// (`bash -c "npm test"` as `npm test`).
  static String prefix(String command) => _prefix(command.trim(), 0);

  static String _prefix(String command, int depth) {
    if (depth > 4) return '';
    final parsed = ShellCommand.parse(command);
    final one = parsed.commands.isEmpty
        ? command.trim()
        : parsed.commands.first;
    // A wrapper with nothing after it runs nothing at all.
    final words = _unwrap(withoutAssignments(tokenize(one)));
    if (words.isEmpty) return '';
    final first = words.first;
    final shell = _programName(first);
    if (_shellPrograms.contains(shell)) {
      final script = scriptOf(words);
      if (script == null) return '';
      final inner = ShellCommand.parse(script);
      if (inner.commands.length != 1) return '';
      // PowerShell's script is read as PowerShell: `& { rm -fo … }` is
      // `Remove-Item -Force`, and `rm` alone would name the POSIX program.
      final single = inner.commands.single;
      return _prefix(
        shell == 'powershell' || shell == 'pwsh'
            ? _asPowerShell(withoutAssignments(tokenize(single))).join(' ')
            : single,
        depth + 1,
      );
    }
    final program = _programName(first);
    // `python -m pytest` runs a named module, which is a thing to allow;
    // `python -c "…"` runs whatever it was handed, which is not.
    if (const {'python', 'python3', 'py', 'pypy', 'pypy3'}.contains(program)) {
      if (words.length > 2 && words[1] == '-m') {
        return '$first -m ${words[2]}';
      }
      return '';
    }
    if (_unprefixable.contains(program)) return '';
    if (_hasSubcommands.contains(first) && words.length > 1) {
      final second = words[1];
      if ((first == 'python' || first == 'python3') && second == '-m') {
        return words.length > 2 ? '$first -m ${words[2]}' : first;
      }
      if (second.startsWith('-')) return first;
      if ((first == 'npm' ||
              first == 'pnpm' ||
              first == 'yarn' ||
              first == 'bun') &&
          second == 'run' &&
          words.length > 2) {
        return '$first $second ${words[2]}';
      }
      return '$first $second';
    }
    return first;
  }

  /// The script [words] (one simple command) is a shell told to run:
  /// `bash -c "…"`, `sh -lc "…"`, `cmd /c …`, `powershell -Command …`, its
  /// `-EncodedCommand` decoded. Null when it is not one (a shell reading
  /// its input, a script file, an interactive session).
  static String? scriptOf(List<String> words) {
    if (words.isEmpty) return null;
    final program = _programName(words.first);
    final args = words.sublist(1);
    switch (program) {
      case 'sh' ||
          'bash' ||
          'zsh' ||
          'dash' ||
          'ksh' ||
          'fish' ||
          'csh' ||
          'tcsh':
        return _posixScript(args);
      case 'busybox':
        // `busybox sh -c …`
        if (args.isEmpty || args.first.startsWith('-')) return null;
        return scriptOf(args);
      case 'cmd':
        return _flaggedScript(args, const {'/c', '/k', '-c'});
      case 'powershell' || 'pwsh':
        return _powerShellScript(args);
    }
    return null;
  }

  /// The text after the first of [flags] (`cmd /c …`).
  static String? _flaggedScript(List<String> args, Set<String> flags) {
    for (var i = 0; i < args.length; i++) {
      if (flags.contains(args[i].toLowerCase())) {
        return i + 1 < args.length ? args.sublist(i + 1).join(' ') : null;
      }
    }
    return null;
  }

  /// The script after `-c` (`-c`, `-lc`, `-ic`…), its options' values
  /// stepped over.
  static String? _posixScript(List<String> args) {
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      // The options end here: what follows is a script file, not one.
      if (arg == '--') return null;
      // Short options whose value is the word after them.
      if (const {'-o', '+o', '-O', '+O'}.contains(arg)) {
        i++;
        continue;
      }
      if (arg.length > 1 && arg.startsWith('-') && !arg.startsWith('--')) {
        if (arg.substring(1).contains('c')) {
          return i + 1 < args.length ? args.sublist(i + 1).join(' ') : null;
        }
      }
    }
    return null;
  }

  /// The script after `-Command` / `-c`, or `-EncodedCommand` decoded.
  ///
  /// Both may be written as short as PowerShell resolves them (`-com`,
  /// `-c`, `-enc`): a parameter is any prefix of its name that no other
  /// parameter of the same program starts with.
  static String? _powerShellScript(List<String> args) {
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (isPowerShellFlag(arg, 'command')) {
        final colon = arg.indexOf(':');
        if (colon >= 0) return arg.substring(colon + 1);
        return i + 1 < args.length ? args.sublist(i + 1).join(' ') : null;
      }
      if (isPowerShellFlag(arg, 'encodedcommand')) {
        if (i + 1 >= args.length) return null;
        return _decodePowerShell(args[i + 1]);
      }
    }
    return null;
  }

  /// `-EncodedCommand`'s payload: base64 of UTF-16LE.
  static String? _decodePowerShell(String encoded) {
    try {
      final bytes = base64Decode(encoded);
      final units = <int>[
        for (var i = 0; i + 1 < bytes.length; i += 2)
          bytes[i] | (bytes[i + 1] << 8),
      ];
      return String.fromCharCodes(units);
    } on Object {
      return null;
    }
  }

  static const _hasSubcommands = {
    'git',
    'npm',
    'pnpm',
    'yarn',
    'bun',
    'cargo',
    'go',
    'docker',
    'kubectl',
    'flutter',
    'dart',
    'gh',
    'brew',
    'pip',
    'pip3',
    'uv',
    'poetry',
    'make',
    'mvn',
    'gradle',
    './gradlew',
    'dotnet',
    'swift',
    'xcodebuild',
    'pod',
    'terraform',
    'helm',
    'aws',
    'gcloud',
    'az',
    'deno',
    'npx',
    'bunx',
    'python',
    'python3',
    'rails',
    'bundle',
    'composer',
    'php',
    'mix',
    'stack',
    'cabal',
    'nx',
    'turbo',
    'wrangler',
    'firebase',
    'vercel',
  };
}

/// Whether [command] only reads: each of its simple commands is one known
/// not to change anything, it writes no file and runs nothing hidden.
bool isReadOnlyCommand(String command) {
  final parsed = ShellCommand.parse(command);
  if (parsed.unbalanced || parsed.hasSubstitution) return false;
  if (!parsed.redirectsOnlyToNull) return false;
  if (parsed.commands.isEmpty) return false;
  return parsed.words.every(isReadOnlyWords);
}

/// Whether the simple command [words] only reads.
bool isReadOnlyWords(List<String> words) {
  if (words.isEmpty) return true;
  final program = words.first.split('/').last;
  final args = words.sublist(1);
  bool has(Iterable<String> flags) => args.any(
    (arg) => flags.any((flag) => arg == flag || arg.startsWith('$flag=')),
  );
  switch (program) {
    case 'git':
      return _readOnlyGit(args);
    case 'find':
      return !has(const [
        '-exec',
        '-execdir',
        '-delete',
        '-ok',
        '-okdir',
        '-fprint',
        '-fprint0',
        '-fprintf',
        '-fls',
      ]);
    case 'sed':
      return !args.any(
        (arg) =>
            arg == '-i' ||
            arg.startsWith('-i') && !arg.startsWith('--') ||
            arg.startsWith('--in-place') ||
            RegExp(r'^-[a-zA-Z]*i').hasMatch(arg),
      );
    case 'sort':
      return !has(const ['-o', '--output']);
    case 'tree':
      return !has(const ['-o']);
    case 'env' || 'printenv':
      // `env cmd` runs cmd.
      return args.every((arg) => arg.startsWith('-') || arg.contains('='))
          ? program == 'printenv' || args.isEmpty
          : program == 'printenv';
    case 'xargs':
      return args.isNotEmpty &&
          isReadOnlyWords([
            for (final arg in args)
              if (!arg.startsWith('-')) arg,
          ]);
    case 'command':
      return args.isNotEmpty && (args.first == '-v' || args.first == '-V');
    case 'npm' || 'pnpm' || 'yarn':
      return args.isNotEmpty &&
          const {
            'ls',
            'list',
            'view',
            'info',
            'outdated',
            'why',
            'root',
            'prefix',
            'bin',
            'help',
            '--version',
            '-v',
          }.contains(args.first);
    case 'cargo':
      return args.isNotEmpty &&
          const {
            'tree',
            'metadata',
            '--version',
            'search',
          }.contains(args.first);
    case 'go':
      return args.isNotEmpty &&
          const {'version', 'env', 'list', 'doc'}.contains(args.first);
    case 'docker':
      return args.isNotEmpty &&
          const {
            'ps',
            'images',
            'logs',
            'inspect',
            'version',
            'info',
          }.contains(args.first);
    case 'gh':
      return args.length >= 2 &&
          const {'view', 'list', 'status', 'diff', 'checks'}.contains(args[1]);
  }
  return _readOnlyPrograms.contains(program);
}

const _readOnlyPrograms = {
  'ls',
  'cat',
  'head',
  'tail',
  'wc',
  'grep',
  'egrep',
  'fgrep',
  'rg',
  'ag',
  'ack',
  'pwd',
  'echo',
  'printf',
  'which',
  'whereis',
  'type',
  'file',
  'stat',
  'du',
  'df',
  'date',
  'uname',
  'whoami',
  'id',
  'hostname',
  'uniq',
  'cut',
  'tr',
  'jq',
  'yq',
  'diff',
  'cmp',
  'basename',
  'dirname',
  'realpath',
  'readlink',
  'true',
  'false',
  'test',
  '[',
  'nl',
  'od',
  'xxd',
  'hexdump',
  'strings',
  'md5',
  'md5sum',
  'shasum',
  'sha1sum',
  'sha256sum',
  'column',
  'comm',
  'fold',
  'expand',
  'unexpand',
  'seq',
  'sleep',
  'cd',
  'less',
  'more',
  'man',
  'help',
  'tac',
  'rev',
  'paste',
  'join',
  'fmt',
  'locale',
  'uptime',
  'arch',
  'nproc',
  'sw_vers',
  'lsof',
  'ps',
  'top',
  'pgrep',
  'groups',
  'tty',
  'cal',
  'look',
  'zcat',
  'bzcat',
  'xzcat',
  'fd',
  'fzf',
  'bat',
  'exa',
  'eza',
  'dust',
  'tokei',
  'cloc',
  'awk',
  'gawk',
  'mawk',
};

bool _readOnlyGit(List<String> args) {
  // Global options first (`git -C dir status`).
  var i = 0;
  while (i < args.length && args[i].startsWith('-')) {
    if (args[i] == '-C' || args[i] == '-c') i++;
    i++;
  }
  if (i >= args.length) return true;
  final sub = args[i];
  final rest = args.sublist(i + 1);
  bool none(Iterable<String> flags) => !rest.any(
    (arg) => flags.any((flag) => arg == flag || arg.startsWith('$flag=')),
  );
  switch (sub) {
    case 'status' ||
        'log' ||
        'diff' ||
        'show' ||
        'rev-parse' ||
        'ls-files' ||
        'ls-tree' ||
        'blame' ||
        'describe' ||
        'shortlog' ||
        'grep' ||
        'cat-file' ||
        'merge-base' ||
        'name-rev' ||
        'whatchanged' ||
        'rev-list' ||
        'show-ref' ||
        'for-each-ref' ||
        'count-objects' ||
        'check-ignore' ||
        'var' ||
        'version' ||
        'help' ||
        'ls-remote':
      return none(const ['--output', '-o']);
    case 'branch':
      return none(const [
            '-d',
            '-D',
            '-m',
            '-M',
            '-c',
            '-C',
            '--delete',
            '--move',
            '--copy',
            '--set-upstream-to',
            '-u',
            '--unset-upstream',
            '--edit-description',
            '-f',
            '--force',
          ]) &&
          // A name alone makes a branch; with a listing flag it filters.
          (rest.every((arg) => arg.startsWith('-')) ||
              rest.any(
                (arg) => const {
                  '--list',
                  '-l',
                  '--contains',
                  '--no-contains',
                  '--merged',
                  '--no-merged',
                  '--points-at',
                }.contains(arg),
              ));
    case 'tag':
      return rest.isEmpty || rest.contains('-l') || rest.contains('--list');
    case 'remote':
      return rest.isEmpty ||
          rest.every((arg) => arg == '-v' || arg == '--verbose') ||
          (rest.first == 'show' || rest.first == 'get-url');
    case 'config':
      return rest.any(
        (arg) =>
            arg == '--get' ||
            arg == '--get-all' ||
            arg == '--list' ||
            arg == '-l' ||
            arg == '--get-regexp',
      );
    case 'stash':
      return rest.isNotEmpty && (rest.first == 'list' || rest.first == 'show');
    case 'worktree':
      return rest.isNotEmpty && rest.first == 'list';
    case 'reflog':
      return rest.isEmpty || rest.first == 'show';
  }
  return false;
}

/// Whether [words] is a command that destroys what cannot be got back
/// wholesale (`rm -rf /`, `git reset --hard`, `find -delete`), or starts
/// something of Windows' own that does: asked about in every mode, and
/// never approved by the auto classifier.
///
/// A shell told to run a script is weighed by what the script runs, so
/// `bash -c "rm -rf /"` is what `rm -rf /` is: the script is parsed as
/// the command line it is, as far as `bash -c`, `cmd /c` and
/// `powershell -Command` are concerned.
bool isDangerousWords(List<String> words, {required String home}) =>
    _dangerKind(words, home, 0) != null;

/// What makes [words] dangerous, when something does: the reason an
/// approval gives for asking, rather than the label alone.
///
/// The innermost one wins — `bash -c "rm -rf /"` is dangerous because of
/// the `rm`, not because of the `bash` — so the sentence a person reads
/// names the command that does the harm.
DangerKind? dangerKindOf(List<String> words, {required String home}) =>
    _dangerKind(words, home, 0);

/// The kinds of harm a command can do that no later look can undo.
enum DangerKind {
  /// It removes what is there wholesale: a drive's root, a system folder,
  /// the home directory.
  wipesAll,

  /// It deletes without the recycle bin or a prompt: `rm -r`, `del /f`,
  /// `Remove-Item -Force`.
  forcedDelete,

  /// It hands a link to the system to open, which downloads and runs what
  /// is behind it.
  opensLink,

  /// It runs as another user, with what that user may do.
  elevated,

  /// It writes straight to a disk.
  disk,

  /// It discards work git has and cannot give back: a hard reset, a clean
  /// of untracked files, a force push.
  git,

  /// It runs code fetched from somewhere else (`iex (iwr https://…)`),
  /// which nothing here can read.
  runsCode,
}

DangerKind? _dangerKind(List<String> words, String home, int depth) {
  if (words.isEmpty || depth > 8) return null;
  words = _unwrap(words);
  if (words.isEmpty) return null;
  final outer = _programName(words.first);
  final script = ShellCommand.scriptOf(words);
  if (script != null) {
    final parsed = ShellCommand.parse(script);
    if (parsed.unbalanced) return null;
    // A PowerShell script is read with its own spelling: `& { … }` and
    // `$( … )` group commands, and `rm`, `del`, `rd` are aliases of
    // `Remove-Item` whose flags are PowerShell's, not a POSIX program's.
    final powerShell = outer == 'powershell' || outer == 'pwsh';
    for (final inner in parsed.words) {
      final kind = _dangerKind(
        powerShell ? _asPowerShell(inner) : inner,
        home,
        depth + 1,
      );
      if (kind != null) return kind;
    }
    return null;
  }
  if (launchesUrl(words)) return DangerKind.opensLink;
  if (forcedDeletes(words)) return DangerKind.forcedDelete;
  final program = _programName(words.first);
  final args = words.sublist(1);
  // `iex (iwr https://…)`: what it runs is whatever came back over the
  // network, and nothing here can read it.
  if (_runsRemoteCode.contains(program)) return DangerKind.runsCode;
  if (program == 'sudo' || program == 'doas' || program == 'pkexec') {
    return DangerKind.elevated;
  }
  if (program == 'mkfs' || program.startsWith('mkfs.') || program == 'dd') {
    return words.any((w) => w.startsWith('of=/dev/') || program != 'dd')
        ? DangerKind.disk
        : null;
  }
  if (program == 'rm') {
    return _removesEverything(args, home) ? DangerKind.wipesAll : null;
  }
  if (program == 'git') {
    return _gitDestroys(args) ? DangerKind.git : null;
  }
  if (program == 'find') {
    return args.contains('-delete') ? DangerKind.forcedDelete : null;
  }
  if (program == 'rsync') {
    return args.any((w) => w == '--delete' || w.startsWith('--delete-'))
        ? DangerKind.forcedDelete
        : null;
  }
  if (program == 'del' || program == 'erase') {
    return args.any((w) {
          final flag = w.toLowerCase();
          return flag == '/s' || flag == '/f';
        })
        ? DangerKind.forcedDelete
        : null;
  }
  if (program == 'rd' || program == 'rmdir') {
    return args.any((w) => w.toLowerCase() == '/s')
        ? DangerKind.forcedDelete
        : null;
  }
  if (program == 'robocopy') {
    return args.any((w) => w.toLowerCase() == '/mir')
        ? DangerKind.forcedDelete
        : null;
  }
  if (const {'remove-item', 'ri'}.contains(program)) {
    // A forced delete, or a recursive one: what cannot be got back. Either
    // may be written as short as PowerShell resolves it (`-fo`, `-r`).
    final forced = args.any((w) => isPowerShellFlag(w, 'force'));
    final recursive = args.any((w) => isPowerShellFlag(w, 'recurse'));
    return forced || recursive ? DangerKind.forcedDelete : null;
  }
  return null;
}

/// Whether [rule] (`Bash(bash:*)`) would allow any command at all: a shell
/// or interpreter told what to run, `Bash(*)`, `Bash(rm:*)`.
///
/// A rule like this reads as one narrow thing and is every command there
/// is, so it is not offered as "always allow" — the one command it was
/// asked for is.
bool isBlanketBashRule(String rule) {
  final open = rule.indexOf('(');
  if (open < 0 || !rule.endsWith(')')) {
    // The tool as a whole: every command.
    return rule.trim() == 'Bash';
  }
  if (rule.substring(0, open).trim() != 'Bash') return false;
  var content = rule.substring(open + 1, rule.length - 1).trim();
  if (content.isEmpty) return true;
  // `Bash(npm test:*)` means "npm test and what follows it": the `:*` is
  // the rule's own syntax, not a wildcard the command may use.
  if (content.endsWith(':*')) {
    content = content.substring(0, content.length - 2).trim();
  }
  if (content.isEmpty || content.contains('*')) return true;
  return ShellCommand.prefix(content).isEmpty;
}

/// Whether [words] removes more than one thing at once, so that what it
/// removes cannot be put back by hand: `rm -r`, `del /s`,
/// `Remove-Item -Recurse`, `robocopy /MIR`.
bool isRecursiveDelete(List<String> words) {
  if (words.isEmpty) return false;
  words = _unwrap(words);
  if (words.isEmpty) return false;
  final script = ShellCommand.scriptOf(words);
  if (script != null) {
    return ShellCommand.parse(script).words.any(isRecursiveDelete);
  }
  final program = _programName(words.first);
  final args = words.sublist(1);
  final lower = [for (final arg in args) arg.toLowerCase()];
  switch (program) {
    case 'rm':
      final flags = lower.where((w) => w.startsWith('-')).join();
      return flags.contains('r') || lower.contains('--recursive');
    case 'del' || 'erase' || 'rd' || 'rmdir':
      return lower.contains('/s');
    case 'robocopy':
      return lower.contains('/mir');
    case 'remove-item' || 'ri':
      return lower.contains('-recurse');
    case 'find':
      return args.contains('-delete');
  }
  return false;
}

/// [path] in words: the program's name, without its folder or `.exe`.
String _programName(String word) {
  var name = word.split(RegExp(r'[\\/]')).last.toLowerCase();
  // A Windows drive as it is written: `C:cmd.exe`.
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

/// Programs that run code they are handed from somewhere else, which
/// nothing here can read: PowerShell's `eval` and its download-and-run
/// pair.
const _runsRemoteCode = {
  'iex',
  'invoke-expression',
  'invoke-command',
  'icm',
  'iwr',
  'invoke-webrequest',
  'irm',
  'invoke-restmethod',
  'start-job',
  'start-threadjob',
  'add-type',
};

/// Programs that run what they are given, so that a rule for one prefix
/// (`Bash(bash:*)`, `Bash(sudo:*)`) would allow any command at all.
const _unprefixable = {
  // Shells.
  'sh',
  'bash',
  'zsh',
  'dash',
  'ksh',
  'fish',
  'csh',
  'tcsh',
  'cmd',
  'powershell',
  'pwsh',
  'busybox',
  // What runs its arguments as a command.
  'env',
  'xargs',
  'nice',
  'stdbuf',
  'nohup',
  'timeout',
  'time',
  'setsid',
  'ionice',
  'chrt',
  'watch',
  'parallel',
  'sudo',
  'doas',
  'pkexec',
  'su',
  // Interpreters given code to run.
  'python',
  'python3',
  'pythonw',
  'py',
  'pyw',
  'pypy',
  'pypy3',
  'node',
  'nodejs',
  'deno',
  'bun',
  'npx',
  'bunx',
  'perl',
  'ruby',
  'php',
  'lua',
  'julia',
  'rscript',
  'osascript',
  // PowerShell's own ways of running code it is handed: `iex` is `eval`,
  // and the rest fetch and run a script by name.
  'iex',
  'invoke-expression',
  'invoke-command',
  'icm',
  'invoke-webrequest',
  'iwr',
  'invoke-restmethod',
  'irm',
  'start-job',
  'start-threadjob',
  'add-type',
  'new-object',
  'set-item',
  'si',
  'copy-item',
  'cpi',
  'move-item',
  'mi',
  'new-item',
  'ni',
  'set-content',
  'sc',
  // What cannot be got back.
  'rm',
  'del',
  'erase',
  'rd',
  'rmdir',
  'remove-item',
  'ri',
  // Windows' own launchers, which run whatever they are pointed at.
  'start-process',
  'start',
  'saps',
  'invoke-item',
  'ii',
  'mshta',
  'rundll32',
  'explorer',
  'wscript',
  'cscript',
  'regsvr32',
  'shred',
  'dd',
  'mkfs',
  'wipefs',
  'diskpart',
  'format',
  'bcdedit',
  'vssadmin',
  'shutdown',
  'reboot',
  'halt',
  'poweroff',
};

/// The shells whose script `scriptOf` reads.
const _shellPrograms = {
  'sh',
  'bash',
  'zsh',
  'dash',
  'ksh',
  'fish',
  'csh',
  'tcsh',
  'busybox',
  'cmd',
  'powershell',
  'pwsh',
};

/// Whether `rm` [args] would remove a home, a root or everything.
/// [words], one command of a PowerShell script, as the cmdlet it is: `rm`
/// written out as `Remove-Item`, `& { … }` unwrapped to what it groups,
/// `$( … )` to what is inside it.
///
/// PowerShell reads `rm -r -fo` as `Remove-Item -Recurse -Force`, which no
/// POSIX reading of `rm` gives: `-fo` is not two flags, and `-r` is a
/// parameter of a different program.
List<String> _asPowerShell(List<String> words) {
  if (words.isEmpty) return words;
  var program = _programName(words.first);
  // `& { Remove-Item … }`: the call operator, then a block. What it runs is
  // the block's own first command.
  if (program == '&' || program == '.') {
    return _asPowerShell(words.sublist(1));
  }
  // A block's own braces: what is inside is the command.
  if (program == '{' || program == '}') {
    return _asPowerShell(words.sublist(1));
  }
  // `$(Remove-Item …)`: a subexpression, which runs as its own command.
  if (program.startsWith(r'$(')) {
    return _asPowerShell([program.substring(2), ...words.skip(1)]);
  }
  final alias = _powerShellAliases[program];
  if (alias != null) program = alias;
  final args = [
    for (final arg in words.skip(1))
      if (!arg.startsWith(r'$(') || arg.endsWith(')')) arg,
  ];
  return [program, ...args];
}

/// PowerShell's aliases of the cmdlets that delete, which it lets be
/// written as short as `rm -r -fo`.
const _powerShellAliases = {
  'rm': 'remove-item',
  'ri': 'remove-item',
  'del': 'remove-item',
  'erase': 'remove-item',
  'rd': 'remove-item',
  'rmdir': 'remove-item',
  'ni': 'new-item',
  'si': 'set-item',
  'sc': 'set-content',
  'cpi': 'copy-item',
  'mi': 'move-item',
  'iex': 'invoke-expression',
  'icm': 'invoke-command',
  'iwr': 'invoke-webrequest',
  'irm': 'invoke-restmethod',
};

bool _removesEverything(List<String> args, String home) {
  final flags = args.where((w) => w.startsWith('-')).join();
  final recursive =
      flags.contains('r') ||
      flags.contains('R') ||
      args.contains('--recursive');
  if (!recursive) return false;
  for (final target in args.where((w) => !w.startsWith('-'))) {
    final t = target.replaceAll(RegExp(r'[\\/]+$'), '');
    if (t.isEmpty ||
        t == '~' ||
        t == r'$HOME' ||
        t == r'${HOME}' ||
        t == '~/*' ||
        t == home ||
        t == '*' ||
        t == '.' ||
        t == '..') {
      return true;
    }
    // A root, or a system folder: `/`, `/*`, `C:`, `C:\*`, `/usr`, …
    final path = t.replaceAll(r'\', '/');
    if (RegExp(r'^/\*?$').hasMatch(path)) return true;
    if (RegExp(r'^[A-Za-z]:/?\*?$').hasMatch(path)) return true;
    if (_systemFolders.contains(path.toLowerCase())) return true;
  }
  return false;
}

/// Folders whose removal from the top takes the machine with it.
const _systemFolders = {
  '/usr',
  '/etc',
  '/var',
  '/bin',
  '/sbin',
  '/lib',
  '/lib64',
  '/boot',
  '/opt',
  '/home',
  '/system',
  '/library',
  '/applications',
  'c:/windows',
  'c:/users',
  'c:/program files',
  'c:/program files (x86)',
  'c:/programdata',
};

/// Whether a `git` call rewrites or throws away work that cannot be got
/// back: a hard reset, a clean, a forced push or checkout, a forced
/// branch delete. `--force-with-lease` is left alone: it refuses when the
/// remote moved.
bool _gitDestroys(List<String> args) {
  if (args.isEmpty) return false;
  final sub = args.first;
  final rest = args.sublist(1);
  final flags = rest.map((w) => w.toLowerCase()).toSet();
  switch (sub) {
    case 'reset':
      return rest.contains('--hard');
    case 'clean':
      return rest.any(
        (w) =>
            w == '--force' ||
            (w.startsWith('-') && !w.startsWith('--') && w.contains('f')),
      );
    case 'push':
      return rest.contains('--force') || rest.contains('-f');
    case 'checkout':
      return rest.contains('--force') || rest.contains('-f');
    case 'branch':
      return rest.contains('-D') ||
          (flags.contains('--delete') && flags.contains('--force'));
  }
  return false;
}

/// [words] with wrappers taken off (`env`, `nohup`, `time`, `nice`,
/// `timeout`, `xargs`, `command`, `builtin`, `exec`), so what they run is
/// weighed as if it were alone.
List<String> _unwrap(List<String> words) {
  var result = words;
  for (var guard = 0; guard < 8; guard++) {
    if (result.isEmpty) return result;
    final program = _programName(result.first);
    if (!const {
      'env',
      'nohup',
      'time',
      'nice',
      'stdbuf',
      'setsid',
      'ionice',
      'chrt',
      'timeout',
      'xargs',
      'command',
      'builtin',
      'exec',
    }.contains(program)) {
      return result;
    }
    var i = 1;
    while (i < result.length && result[i].startsWith('-')) {
      final option = result[i];
      i++;
      // Options whose value is the word after them.
      if (const {
            '-u',
            '--unset',
            '-C',
            '--chdir',
            '-S',
            '--split-string',
            '-n',
            '--adjustment',
            '-i',
            '--input',
            '-o',
            '--output',
            '-e',
            '--error',
            '-P',
            '--max-procs',
            '-I',
            '--replace',
            '-L',
            '--max-lines',
            '-s',
            '--max-chars',
            '-a',
            '--arg-file',
            '-k',
            '--kill-after',
            '-d',
            '--delimiter',
          }.contains(option) &&
          i < result.length) {
        i++;
      }
    }
    // `timeout DURATION command`: the duration is not the command.
    if (program == 'timeout' &&
        i < result.length &&
        !result[i].startsWith('-')) {
      final duration = RegExp(r'^\d+(?:\.\d+)?[smhd]?$');
      if (duration.hasMatch(result[i])) i++;
    }
    // `env NAME=value command`: assignments after the wrapper.
    while (i < result.length &&
        RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(result[i])) {
      i++;
    }
    if (i >= result.length) return const [];
    result = result.sublist(i);
  }
  return result;
}

/// Programs that only make, move or remove files: allowed in accept-edits
/// mode when what they touch is in the working folders.
const fileSystemPrograms = {
  'mkdir',
  'touch',
  'mv',
  'cp',
  'rm',
  'rmdir',
  'ln',
  'chmod',
};
