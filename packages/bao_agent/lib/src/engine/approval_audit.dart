import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../permissions/approval_risk.dart';
import 'session.dart';

/// A local record of what was asked and what was decided, beside the
/// session's own files. It is not part of the conversation and is never
/// sent to the model.
class ApprovalAudit {
  ApprovalAudit(this.session);

  final AgentSession session;

  void asked(String tool, Map<String, Object?> input, {String? reason}) {
    final risk = approvalRiskFor(tool, input);
    _write({
      'type': 'asked',
      'tool': tool,
      'risk': risk.risk.name,
      'source': risk.source,
      if (risk.why != null) 'why': risk.why,
      if (reason != null && reason.isNotEmpty) 'reason': reason,
      'input': _preview(tool, input),
    });
  }

  void decided(
    String tool,
    String decision, {
    String? reason,
    Duration? elapsed,
  }) {
    _write({
      'type': 'decided',
      'tool': tool,
      'decision': decision,
      if (reason != null && reason.isNotEmpty) 'reason': reason,
      if (elapsed != null) 'elapsed_ms': elapsed.inMilliseconds,
    });
  }

  void _write(Map<String, Object?> entry) {
    if (!session.settings.approvalAuditEnabled) return;
    try {
      final dir = Directory(p.join(session.paths.configDir, 'approvals'))
        ..createSync(recursive: true);
      final file = File(p.join(dir.path, '${session.sessionId}.jsonl'));
      file.writeAsStringSync(
        '${jsonEncode({'ts': DateTime.now().toUtc().toIso8601String(), ...entry})}\n',
        mode: FileMode.append,
      );
    } on Object {
      // A record that cannot be written must not hold the turn.
    }
  }

  /// The part of the input worth keeping: the command, the path, the URL.
  static String _preview(String tool, Map<String, Object?> input) {
    final value = switch (tool) {
      'Bash' => input['command'],
      'Edit' ||
      'MultiEdit' ||
      'Write' ||
      'NotebookEdit' => input['file_path'] ?? input['notebook_path'],
      'WebFetch' => input['url'],
      _ => input['path'] ?? input['url'] ?? input['query'],
    };
    final text = '${value ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= 200 ? text : '${text.substring(0, 200)}…';
  }
}
