import 'package:flutter/foundation.dart';

import 'claude_code/claude_core_setting.dart';

/// Settings → General → Core: what runs an agent (`agent.engine` in
/// settings.json), the kernels a new agent may run on, by the engine each
/// is made of.
///
/// Claude Code has two: MoonCode's own core, written in Dart, and the CLI.
/// A new agent starts on the kernel of the engine picked; the ones already
/// running keep theirs, as a conversation cannot change kernel once it has
/// started.
enum AgentEngine {
  /// The Claude Code CLI, as a process: downloaded the first time where
  /// the machine has none (see LocalClaude).
  claudeCli('claude-code', ClaudeCore.cli),

  /// MoonCode's own core, written in Dart (package:bao_agent): the same
  /// protocol, files and settings as the CLI, in the app itself. It runs
  /// on the upstreams of Settings → Models alone, never on a model the
  /// machine's Claude Code setup names.
  claudeBuiltin('claude-code', ClaudeCore.builtin);

  const AgentEngine(this.kernelId, this.core);

  /// The id of the kernel it makes ([KernelRegistry]'s).
  final String kernelId;

  /// The Claude Code core it picks: the CLI's, or the app's own.
  final ClaudeCore core;

  static const settingKey = 'agent.engine';

  /// When the setting is unset, or not one of these: the CLI where Claude
  /// Code is on this machine, else the built-in core (which suggests the
  /// CLI): nothing is downloaded unasked.
  static AgentEngine get fallback =>
      ClaudeCore.fallback == ClaudeCore.cli ? claudeCli : claudeBuiltin;

  static AgentEngine parse(Object? setting) =>
      values.where((value) => value.name == setting).firstOrNull ?? fallback;

  /// The setting as it is now, read as each agent starts; main() points
  /// it at settings.json.
  static AgentEngine Function() current = () => fallback;

  /// Told as the setting may have changed; main() points it at
  /// settings.json.
  static Listenable changes = const _Never();

  /// Keeps [engine] as the setting, for the agents to come; main() points
  /// it at settings.json.
  static Future<void> Function(AgentEngine engine) pick = (_) async {};
}

/// Tells nothing: no settings file to follow.
class _Never implements Listenable {
  const _Never();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
