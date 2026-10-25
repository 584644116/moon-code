import 'dart:convert';

import 'package:baocode/kernel/codex/codex_model_catalog.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:flutter_test/flutter_test.dart';

/// What `codex debug models` prints, trimmed to what a catalog is built from:
/// one model with Codex's own prompt, and the metadata this app rewrites.
const _template = {
  'models': [
    {
      'slug': 'gpt-6-astra',
      'display_name': 'GPT-6-Astra',
      'base_instructions': 'You are Codex.',
      'model_messages': {'instructions_template': 'You are Codex.'},
      'supported_reasoning_levels': [
        {'effort': 'low', 'description': "OpenAI's own"},
      ],
      'context_window': 272000,
      'max_context_window': 872000,
      'service_tiers': [
        {'id': 'priority', 'name': 'Fast', 'description': '2x speed'},
      ],
      'shell_type': 'unified_exec',
    },
  ],
};

void main() {
  late ModelProviders previous;

  setUp(() {
    previous = ModelProviders.current;
    ModelProviders.current = ModelProviders.memory(
      providers: [
        ModelProvider(
          id: 'up',
          name: 'Up',
          models: const [
            ProviderModel(
              id: 'big',
              label: 'Big',
              efforts: ['low', 'high'],
              contexts: [200000, 1000000],
            ),
            ProviderModel(id: 'small'),
          ],
        ),
        ModelProvider(
          id: 'off',
          name: 'Off',
          enabled: false,
          models: const [ProviderModel(id: 'hidden')],
        ),
      ],
    );
  });

  tearDown(() => ModelProviders.current = previous);

  Future<String?> build({String? printed}) => CodexModelCatalog.build(
    dump: () async => printed ?? jsonEncode(_template),
  );

  test('every model of Settings → Models gets an entry, under Codex\'s '
      'name for it', () async {
    final catalog = jsonDecode((await build())!) as Map<String, Object?>;
    final models = (catalog['models']! as List).cast<Map<String, Object?>>();
    // The disabled upstream's models are not offered, so not listed.
    expect(models.map((m) => m['slug']), ['up/big', 'up/small']);
    expect(models.first['display_name'], 'Big');
    expect(models.first['description'], 'Up · big');
  });

  test('its window is the model\'s, not the fallback\'s', () async {
    final models =
        ((jsonDecode((await build())!) as Map)['models'] as List)
            .cast<Map<String, Object?>>();
    // The one it would not raise a picked window past.
    expect(models.first['context_window'], 1000000);
    expect(models.first['max_context_window'], 1000000);
    // What the model offers, in the picker's order.
    expect(models.first['supported_reasoning_levels'], [
      {'effort': 'low', 'description': 'Fastest, least thinking'},
      {'effort': 'high', 'description': 'Thinks more'},
    ]);
  });

  test('the instructions are Codex\'s own, not this app\'s', () async {
    final models =
        ((jsonDecode((await build())!) as Map)['models'] as List)
            .cast<Map<String, Object?>>();
    expect(models.first['base_instructions'], 'You are Codex.');
  });

  test('a catalog that is not one leaves Codex on its own', () async {
    expect(await build(printed: 'not json'), isNull);
    expect(await build(printed: '{"models":[]}'), isNull);
    expect(await build(printed: '{}'), isNull);
  });
}
