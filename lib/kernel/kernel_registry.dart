import 'package:flutter/material.dart';

import '../models/launch_environment.dart';
import '../models/model_runtime.dart';

import 'agent_kernel.dart';
import 'claude_code/claude_code_kernel.dart';
import 'codex/codex_catalog.dart';
import 'codex/codex_kernel.dart';
import 'codex/codex_process_transport.dart';
import '../remote/remote_claude.dart';

/// The kernels the user can pick from. Another kernel is an adapter and a
/// line here.
abstract final class KernelRegistry {
  static final KernelDescriptor claudeCode = KernelDescriptor(
    id: 'claude-code',
    label: 'Claude Code',
    icon: Icons.auto_awesome_rounded,
    description: 'Anthropic’s coding agent',
    create: (context) => ClaudeCodeKernel(
      claudeCode,
      context,
      // On the project's host: this machine, or a remote one's.
      start: startClaude,
      readHistoryPage: readClaudeHistoryPage,
      readGoal: readClaudeGoal,
      forkSession: forkClaudeSession,
      usageOffBy: () => claudeUsageOffByAt(context.cwd),
      rejectTooOld: rejectTooOldClaude,
    ),
    catalog: const ClaudeCatalog(),
  );

  static final KernelDescriptor codex = KernelDescriptor(
    id: 'codex',
    label: 'Codex',
    icon: Icons.data_object_rounded,
    description: 'OpenAI’s coding agent',
    // The server runs in the project's folder: a thread is kept under the
    // directory its server runs in. Its turns go to this app's proxy, which
    // speaks the Responses API to whichever upstream Settings → Models has
    // the model on, so Codex runs on the same models Claude Code does.
    create: (context) => CodexKernel(
      codex,
      CodexProcessTransport(cwd: context.cwd, config: _codexConfig),
      settings: context.settings,
    ),
    catalog: CodexCatalog(),
  );

  /// The provider Codex is told about: this app's proxy, which every
  /// upstream of Settings → Models is behind.
  static const _proxyProvider = 'baocode';

  /// What `codex app-server` is started with (`-c`): its turns on this
  /// app's proxy, as the Responses API, with the token the proxy takes.
  /// None if the proxy cannot start, which leaves Codex on its own
  /// configuration (its own upstream, its own account).
  @visibleForTesting
  static Future<List<String>> codexConfig() => _codexConfig();

  static Future<List<String>> _codexConfig() async {
    final ProxyEndpoint endpoint;
    try {
      endpoint = await codexResponsesEndpoint();
    } on Object catch (error) {
      debugPrint('Codex: no proxy to run on: $error');
      return const [];
    }
    // A value of the config's own: quoted so TOML reads it as a string.
    String value(String text) =>
        '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
    return [
      '-c',
      'model_provider=${value(_proxyProvider)}',
      '-c',
      'model_providers.$_proxyProvider.name=${value('BaoCode')}',
      '-c',
      'model_providers.$_proxyProvider.base_url=${value(endpoint.baseUrl)}',
      '-c',
      'model_providers.$_proxyProvider.wire_api=${value('responses')}',
      '-c',
      'model_providers.$_proxyProvider.requires_openai_auth=false',
      '-c',
      'model_providers.$_proxyProvider.experimental_bearer_token='
          '${value(endpoint.token)}',
      // Approval requests are this app's to ask, as they are for Claude
      // Code's own tools. Codex's automatic review would otherwise ask for a
      // model of its own, `codex-auto-review`, which no upstream here has.
      '-c',
      'approvals_reviewer=${value('user')}',
    ];
  }

  static List<KernelDescriptor> _all = [claudeCode, codex];

  static List<KernelDescriptor> get all => _all;

  /// Replaces the kernels on offer, e.g. with mock ones under test.
  static void use(List<KernelDescriptor> kernels) => _all = kernels;
}
