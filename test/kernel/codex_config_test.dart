@TestOn('vm')
library;

import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/models/model_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// What `codex app-server` is started with, as `-c` overrides. Codex reads
/// its own `config.toml` otherwise, whose upstream is not this app's.
void main() {
  test('its turns are on the app\'s proxy, with the token that proxy takes',
      () async {
    final config = await KernelRegistry.codexConfig();
    final pairs = <String, String>{};
    for (var i = 0; i + 1 < config.length; i += 2) {
      expect(config[i], '-c');
      final pair = config[i + 1];
      pairs[pair.substring(0, pair.indexOf('='))] =
          pair.substring(pair.indexOf('=') + 1);
    }
    expect(pairs['model_provider'], '"baocode"');
    expect(pairs['model_providers.baocode.wire_api'], '"responses"');
    expect(pairs['model_providers.baocode.requires_openai_auth'], 'false');
    final baseUrl = pairs['model_providers.baocode.base_url']!;
    expect(baseUrl, startsWith('"http://127.0.0.1:'));
    expect(baseUrl, endsWith('/v1"'));
    final endpoint = await codexResponsesEndpoint();
    expect(pairs['model_providers.baocode.base_url'], '"${endpoint.baseUrl}"');
    expect(
      pairs['model_providers.baocode.experimental_bearer_token'],
      '"${endpoint.token}"',
    );
    await stopModelProxy();
  });

  test('approvals are the app\'s to ask, not a model of Codex\'s own', () async {
    // Its automatic review asks for `codex-auto-review`, which no upstream of
    // Settings → Models has: the review fails, and with it the approval.
    final config = await KernelRegistry.codexConfig();
    expect(config, contains('approvals_reviewer="user"'));
    await stopModelProxy();
  });
}
