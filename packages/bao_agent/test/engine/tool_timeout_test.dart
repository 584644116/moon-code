import 'dart:async';

import 'package:bao_agent/src/tools/tool.dart';
import 'package:bao_agent/src/util/cancel.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tool that declares a deadline is given up on; one that does not is
/// left to the turn.
void main() {
  test('a call past its deadline is answered as a timeout', () async {
    final cancel = CancelToken();
    final output = await callWithTimeout(
      () => Future<ToolOutput>.delayed(
        const Duration(milliseconds: 50),
        () => const ToolOutput('late'),
      ),
      timeout: const Duration(milliseconds: 5),
      cancel: cancel,
    );
    expect(output.isError, isTrue);
    expect(output.text, contains('timed out after 5ms'));
    expect(cancel.isCancelled, isTrue);
  });

  test('no deadline leaves the call alone', () async {
    final output = await callWithTimeout(() async => const ToolOutput('ok'));
    expect(output.text, 'ok');
    expect(output.isError, isFalse);
  });

  test('a failure after the deadline is not unhandled', () async {
    final completer = Completer<ToolOutput>();
    final output = await callWithTimeout(
      () => completer.future,
      timeout: const Duration(milliseconds: 5),
      cancel: CancelToken(),
    );
    expect(output.isError, isTrue);
    completer.completeError(StateError('late'));
    await Future<void>.delayed(Duration.zero);
  });
}
