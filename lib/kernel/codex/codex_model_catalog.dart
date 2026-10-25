import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../models/model_providers.dart';

/// The model catalog Codex is started with (`-c model_catalog_json`): one
/// entry per model of Settings → Models, so Codex knows each model's window,
/// its thinking levels, and whether it can run fast.
///
/// Codex has metadata for OpenAI's own models alone. A model without it
/// gets a fallback window of 272K that nothing raises — the model's own
/// `max_context_window` is the ceiling, and it is metadata's to say. And
/// what a model offers for effort is metadata's too: without it, every
/// level would look the same, and Fast would be filtered out as unsupported.
///
/// The instructions come from Codex's own catalog, which it prints
/// (`codex debug models`): its prompt is not this app's to write.
abstract final class CodexModelCatalog {
  /// The catalog's JSON for the models of Settings → Models, from the
  /// catalog Codex prints ([dump]). Null when it prints none, or there is
  /// no model to list, which leaves Codex on its own metadata.
  static Future<String?> build({
    required Future<String> Function() dump,
  }) async {
    final Object? parsed;
    try {
      parsed = jsonDecode(await dump());
    } on Object catch (error) {
      debugPrint('Codex: no catalog to start it with: $error');
      return null;
    }
    final templates = switch (parsed) {
      {'models': final List list} => [
        for (final model in list)
          if (model is Map<String, Object?>) model,
      ],
      _ => const <Map<String, Object?>>[],
    };
    if (templates.isEmpty) return null;
    // Its instructions and everything else it says of a model's tools: one
    // of its own, and what every entry here starts from.
    final template = templates.first;

    final entries = <Map<String, Object?>>[];
    for (final provider in ModelProviders.current.enabled) {
      for (final model in provider.enabledModels) {
        final windows = model.contextOptions;
        entries.add({
          ...template,
          // Codex's name for it: this is what its turns ask the proxy for.
          'slug': '${provider.id}/${model.id}',
          'display_name': model.displayName,
          'description': '${provider.name} · ${model.id}',
          // What the picker offers is what the model takes: Codex reads
          // these as its levels, and the proxy reads one back as Claude's
          // thinking budget.
          'default_reasoning_level': model.initialEffort,
          'supported_reasoning_levels': [
            for (final level in model.effortLevels)
              {'effort': level, 'description': _effortDescription(level)},
          ],
          // Fast is a tier the proxy passes on: an upstream that takes
          // `service_tier` answers it directly.
          'service_tiers': const [
            {'id': 'priority', 'name': 'Fast', 'description': '2x speed'},
          ],
          // The window, and the ceiling Codex will not raise it past: what
          // Settings → Models says the model holds.
          'context_window': windows.lastOrNull,
          'max_context_window': windows.lastOrNull,
        });
      }
    }
    if (entries.isEmpty) return null;
    return jsonEncode({'models': entries});
  }

  /// The levels as the picker says them, for Codex's own descriptions.
  static String _effortDescription(String level) => switch (level) {
    'none' => 'No thinking',
    'minimal' => 'Least thinking',
    'low' => 'Fastest, least thinking',
    'medium' => 'Balanced',
    'high' => 'Thinks more',
    'xhigh' => 'Thinks a lot more',
    'max' => 'Most thinking',
    _ => level,
  };
}
