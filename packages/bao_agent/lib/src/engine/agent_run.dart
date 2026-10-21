import '../tools/file_state.dart';
import 'session.dart';
import 'session_store.dart';

/// One agent at work in a session: the main one, or a subagent a call of
/// the Agent tool started. What it read, where its shell is, the mode it
/// works in, and the conversation and context it keeps: its own, apart
/// from the main agent's and from the other subagents' running beside it.
///
/// What a run shares is [session] and its services: the settings, the
/// tools, the hooks, the permission rules, the task list and how the host
/// is told. The context that fills and is compacted is this run's.
class AgentRun {
  AgentRun({
    required this.session,
    this.agentId,
    this.parentToolUseId,
    this.agentType,
    String? cwd,
    this.modeOverride,
    ReadFileState? readFiles,
    SessionStore? store,
    this.parentRun,
  }) : cwd = cwd ?? session.cwd,
       readFiles = readFiles ?? ReadFileState() {
    if (store != null) this.store = store;
  }

  final AgentSession session;

  /// Null for the main agent.
  final String? agentId;

  /// The call of the Agent tool that started it.
  final String? parentToolUseId;

  /// The run that started it: a subagent may search its caller's context,
  /// read-only, when what it needs was folded there.
  final AgentRun? parentRun;

  /// The kind of subagent (`Explore`, `general-purpose`…).
  final String? agentType;

  /// Where its shell is: a `cd` in one command holds for the next.
  String cwd;

  /// Its own permission mode, if its definition sets one.
  String? modeOverride;

  final ReadFileState readFiles;

  /// The instruction files it has been given (a nested `CLAUDE.md`, a
  /// rule), so each is given once.
  final Set<String> givenMemory = {};

  /// The conversation this run is on: the session's for the main agent,
  /// a file of its own for a subagent (see [sidechainFile]). Set when the
  /// session's is (the main) or as it starts (a subagent).
  late SessionStore store;

  /// The last request's usage of this run's conversation: what its context
  /// held, as the API counted it. Its own, for a subagent; the session's
  /// report reads the main run's (see [AgentSession.lastUsage]).
  Map<String, Object?>? lastUsage;

  /// The coordinate each visible user prompt had in the last request
  /// (`m12`), by which the model names a range to compress.
  Map<String, int> apiRefs = {};

  /// The conversation's size when the model was last told it had grown.
  int lastNudgeTokens = 0;

  /// Whether this run's model ever answered a request.
  bool requested = false;

  /// Auto compactions in a row that made no summary: after a few, the
  /// conversation is not to be put to the model for one again (see
  /// compaction.dart). This run's own count.
  int compactFailures = 0;

  bool get isMain => agentId == null;

  /// What this run's context is kept under: its own, apart from the other
  /// agents' (see [AgentSession.todos]).
  String get contextKey => agentId ?? session.sessionId;

  /// The todos of this run: its own list, not the main agent's or another
  /// subagent's.
  List<Map<String, Object?>> get todos => session.todos[contextKey] ?? const [];

  /// The mode its calls are weighed in.
  String get permissionMode {
    final own = modeOverride;
    final session = this.session.permissionMode;
    // A subagent's own mode gives way to one that asks less, and to plan.
    if (own == null || session == 'bypassPermissions' || session == 'plan') {
      return session;
    }
    return own;
  }

  /// Told of each tool call it makes (by name), for a subagent's progress.
  void Function(String toolName)? onToolUse;

  /// Tool calls made, tokens used: a subagent's report.
  int toolUses = 0;
  int tokens = 0;
  String? lastTool;
}
