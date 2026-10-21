import 'package:bao_agent/bao_agent.dart';
import 'package:bao_agent/src/engine/context_compression.dart';
import 'package:bao_agent/src/tools/tool.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// The context manager folds a range the model named, finds what it hid,
/// and brings it back; it refuses ranges it cannot make smaller, or that
/// would take the recent turns away.
void main() {
  Future<Harness> withTurns(
    int count, {
    Map<String, Object?> context = const {},
  }) async {
    final h = await Harness.start(
      settings: {
        'contextManagement': {
          'minCompressTokens': 1,
          'keepRecentTurns': 1,
          ...context,
        },
      },
      errands: (_) => Reply.text('Generated range summary.'),
    );
    h.model.script.addAll([
      for (var i = 0; i < count; i++) Reply.text('answer $i'),
    ]);
    for (var i = 0; i < count; i++) {
      await h.turn('question $i');
    }
    return h;
  }

  ContextCompression serviceOf(Harness h) => ContextCompression(
    h.engine.session,
    h.engine.session.mainRun,
    model: h.engine.session.resolvedModel,
  );

  test('a named range is folded, found, and brought back', () async {
    final h = await withTurns(3);
    addTearDown(h.dispose);
    final service = serviceOf(h);
    expect(h.engine.session.mainRun.apiRefs.keys, ['m0', 'm2', 'm4']);

    final block = await service.compress(
      startRef: 'm0',
      endRef: 'm2',
      summary: 'The first exchange answered the first question.',
      cancel: CancelToken(),
    );
    expect(block.savedTokens, greaterThan(0));
    expect(service.status()['active_blocks'], hasLength(1));
    final sent = '${h.engine.session.store.apiMessages()}';
    expect(sent, contains('The first exchange'));
    expect(sent, isNot(contains('question 0')));

    final hits = service.search('question 0');
    expect(hits.single.block, block.id);
    expect(hits.single.snippet, contains('question 0'));

    service.restore(block.id);
    expect(h.engine.session.store.compressionBlocks, isEmpty);
    final back = '${h.engine.session.store.apiMessages()}';
    expect(back, contains('question 0'));
    expect(back, isNot(contains('The first exchange')));
  });

  test('the model is asked for a summary when none is given', () async {
    final h = await withTurns(3);
    addTearDown(h.dispose);
    final block = await serviceOf(h)
        .compress(startRef: 'm0', endRef: 'm2', cancel: CancelToken());
    expect(block.summary, 'Generated range summary.');
    expect(h.model.requests.any((r) => r.body['tools'] == null), isTrue);
  });

  test(
    'a range it cannot name, or that takes the recent turns, is refused',
    () async {
      final h = await withTurns(3);
      addTearDown(h.dispose);
      final service = serviceOf(h);
      await expectLater(
        service.compress(startRef: 'm99', cancel: CancelToken()),
        throwsA(
          isA<ToolFailure>().having(
            (e) => e.message,
            'message',
            contains('Unknown start_ref'),
          ),
        ),
      );
      await expectLater(
        service.compress(startRef: 'm4', cancel: CancelToken()),
        throwsA(
          isA<ToolFailure>().having(
            (e) => e.message,
            'message',
            contains('must start at a visible prompt'),
          ),
        ),
      );
    },
  );

  test('not enough turns, too small, too large: each says why', () async {
    final few = await withTurns(2, context: {'keepRecentTurns': 5});
    addTearDown(few.dispose);
    await expectLater(
      serviceOf(few)
          .compress(startRef: 'm0', endRef: 'm2', cancel: CancelToken()),
      throwsA(
        isA<ToolFailure>().having(
          (e) => e.message,
          'message',
          contains('not enough turns'),
        ),
      ),
    );

    final small = await withTurns(3, context: {'minCompressTokens': 100000});
    addTearDown(small.dispose);
    await expectLater(
      serviceOf(small)
          .compress(startRef: 'm0', endRef: 'm2', cancel: CancelToken()),
      throwsA(
        isA<ToolFailure>().having(
          (e) => e.message,
          'message',
          contains('larger span'),
        ),
      ),
    );

    final large = await withTurns(3, context: {'maxCompressTokens': 1});
    addTearDown(large.dispose);
    await expectLater(
      serviceOf(large)
          .compress(startRef: 'm0', endRef: 'm2', cancel: CancelToken()),
      throwsA(
        isA<ToolFailure>().having(
          (e) => e.message,
          'message',
          contains('too much to summarize'),
        ),
      ),
    );
  });

  test('a covering block hides the one it covers, and says so', () async {
    final h = await withTurns(6);
    addTearDown(h.dispose);
    final service = serviceOf(h);
    final first = await service.compress(
      startRef: 'm2',
      endRef: 'm4',
      summary: 'first fold',
      cancel: CancelToken(),
    );
    final second = await service.compress(
      startRef: 'm0',
      endRef: 'm6',
      summary: 'second fold',
      cancel: CancelToken(),
    );
    final active = service.status()['active_blocks'] as List;
    expect(active, hasLength(1));
    expect((active.single as Map)['id'], second.id);
    expect(
      () => service.restore(first.id),
      throwsA(
        isA<ToolFailure>().having(
          (e) => e.message,
          'message',
          contains('covered by'),
        ),
      ),
    );
    service.restore(second.id);
    expect('${h.engine.session.store.apiMessages()}', contains('question 1'));
  });

  test('a summary no smaller than its range is refused', () async {
    final h = await withTurns(3);
    addTearDown(h.dispose);
    await expectLater(
      serviceOf(h).compress(
        startRef: 'm0',
        endRef: 'm2',
        summary: 'question 0 answer 0 ' * 200,
        cancel: CancelToken(),
      ),
      throwsA(
        isA<ToolFailure>().having(
          (e) => e.message,
          'message',
          contains('not smaller'),
        ),
      ),
    );
  });
}
