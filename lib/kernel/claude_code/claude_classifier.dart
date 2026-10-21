// Auto mode's classifier where Claude Code's own does not run on the
// model (another provider's, or one without auto): the action is judged
// here, by the provider's small model, as the CLI's would.

import 'package:bao_agent/bao_agent.dart';

import 'claude_haiku.dart';

/// What auto mode's classifier made of an action: allowed, or blocked for
/// [reason]. Null from a [ClaudeClassifier] means it could not tell, and
/// the user is asked.
class ClaudeVerdict {
  const ClaudeVerdict.allow() : allowed = true, reason = null;
  const ClaudeVerdict.block(String this.reason) : allowed = false;

  final bool allowed;
  final String? reason;
}

/// Judges [action] (what the agent is about to do) against [transcript]
/// (what was asked and done so far): null when it could not tell.
typedef ClaudeClassifier = Future<ClaudeVerdict?> Function(
  String transcript,
  String action,
);

/// [classifierSystem]'s verdict on [action], asked of [model] (a
/// provider's: its Haiku model, or itself when it sets none), where
/// [location] is.
Future<ClaudeVerdict?> classifyClaudeAction(
  String transcript,
  String action, {
  String? model,
  String? location,
}) async {
  try {
    final answer = await askClaudeHaiku(
      classifierSystem,
      classifierPrompt(transcript, action),
      model: model,
      location: location,
    );
    final json = extractJson(answer);
    return switch (json['decision']) {
      'allow' => const ClaudeVerdict.allow(),
      'block' => ClaudeVerdict.block(switch (json['reason']) {
        final String reason when reason.trim().isNotEmpty => reason.trim(),
        _ => 'this action could be risky',
      }),
      _ => null,
    };
  } on Object {
    // Asked of the user instead.
    return null;
  }
}
