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
}
