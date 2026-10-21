import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// A model that says nothing at all is asked again, but not forever.
void main() {
  test('an empty answer is asked for twice more', () async {
    final h = await Harness.start();
    addTearDown(h.dispose);
    h.model.script.addAll([
      Reply(const [], stopReason: 'end_turn'),
      Reply(const [], stopReason: 'end_turn'),
      Reply.text('found it'),
    ]);
    await h.turn('go');
    expect(h.model.turns, hasLength(3));
    expect(h.lastResult['result'], 'found it');
  });

  test('a refusal is not asked again', () async {
    final h = await Harness.start();
    addTearDown(h.dispose);
    h.model.script.add(Reply(const [], stopReason: 'refusal'));
    await h.turn('go');
    expect(h.model.turns, hasLength(1));
  });

  test('still empty after the retries: the turn ends with a warning', () async {
    final h = await Harness.start();
    addTearDown(h.dispose);
    h.model.script.addAll([
      for (var i = 0; i < 3; i++) Reply(const [], stopReason: 'end_turn'),
    ]);
    await h.turn('go');
    expect(h.model.turns, hasLength(3));
    expect(
      h.sent.where(
        (message) => '${message['content']}'.contains('returned no answer'),
      ),
      isNotEmpty,
    );
  });
}
