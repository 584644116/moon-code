import 'package:bao_agent/bao_agent.dart';
import 'package:bao_agent/src/engine/compaction.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// What the context panel shows and what the compactor does are one sum.
void main() {
  test('the context panel and the compactor reserve the same room', () async {
    final h = await Harness.start();
    addTearDown(h.dispose);
    h.model.script.add(Reply.text('ok'));
    await h.turn('hi');
    final context = await h.request('get_context_usage');
    final window = context['maxTokens'] as int;
    final buffer =
        (context['categories'] as List).cast<Map>().firstWhere(
              (category) => category['kind'] == 'buffer',
            )['tokens']
            as int;
    expect(
      buffer,
      Compaction.reserveOf(
        window,
        maxOutput: h.engine.session.modelInfo.maxOutput,
      ),
    );
  });

  test('a compaction ratio from settings reaches the panel', () async {
    final h = await Harness.start(
      settings: {
        'autoCompactWindow': 32000,
        'contextManagement': {'compactRatio': 0.8},
      },
    );
    addTearDown(h.dispose);
    h.model.script.add(Reply.text('ok'));
    await h.turn('hi');
    final context = await h.request('get_context_usage');
    final buffer =
        (context['categories'] as List).cast<Map>().firstWhere(
              (category) => category['kind'] == 'buffer',
            )['tokens']
            as int;
    // 32K, 80%: compaction starts at 25.6K, leaving 6.4K.
    expect(buffer, 6400);
  });
}
