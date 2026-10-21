import 'package:bao_agent/src/api/model_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// What went wrong is read off an error before it is retried or shown:
/// a conversation too long is not a key to check, and a busy model is not
/// a certificate to fix.
void main() {
  test('each failure is put in the class that says what to do', () {
    expect(const ApiError('x', status: 429).kind, ApiFailureKind.rateLimit);
    expect(
      const ApiError('x', type: 'rate_limit_error').kind,
      ApiFailureKind.rateLimit,
    );
    expect(const ApiError('x', status: 529).kind, ApiFailureKind.overloaded);
    expect(
      const ApiError('x', type: 'overloaded_error').kind,
      ApiFailureKind.overloaded,
    );
    expect(
      const ApiError('x', status: 401).kind,
      ApiFailureKind.authentication,
    );
    expect(
      const ApiError('x', type: 'permission_error').kind,
      ApiFailureKind.authentication,
    );
    expect(
      const ApiError('prompt is too long', status: 400).kind,
      ApiFailureKind.contextTooLong,
    );
    expect(
      const ApiError('no credit', status: 402).kind,
      ApiFailureKind.billing,
    );
    expect(
      const ApiError('bad model', status: 404).kind,
      ApiFailureKind.invalidRequest,
    );
    expect(
      const ApiError('bad request', status: 422).kind,
      ApiFailureKind.invalidRequest,
    );
    expect(const ApiError('server', status: 503).kind, ApiFailureKind.server);
    expect(
      const ApiError('Could not reach the API', retryable: true).kind,
      ApiFailureKind.network,
    );
    expect(
      const ApiError(
        'HandshakeException: CERTIFICATE_VERIFY_FAILED',
        retryable: true,
      ).kind,
      ApiFailureKind.tls,
    );
    expect(const ApiError('odd', status: 418).kind, ApiFailureKind.unknown);
    expect(
      const ApiError('nothing', emptyResponse: true).kind,
      ApiFailureKind.emptyResponse,
    );
  });

  test('the action says what can be done, and context is its own answer', () {
    expect(const ApiError('x', status: 429).action, contains('Wait a moment'));
    expect(const ApiError('x', status: 401).action, contains('API key'));
    expect(
      const ApiError('prompt is too long', status: 400).action,
      contains('compact'),
    );
    expect(const ApiError('x', status: 503).action, contains('server error'));
    expect(const ApiError('odd', status: 418).action, isEmpty);
  });

  test('a request carries whether it is an errand, and through a copy', () {
    const request = ModelRequest({'model': 'm'});
    expect(request.errand, isFalse);
    expect(request.maxRetries, isNull);
    final errand = request.copyWith(errand: true, maxRetries: 1);
    expect(errand.errand, isTrue);
    expect(errand.maxRetries, 1);
    expect(errand.copyWith(body: {'model': 'n'}).errand, isTrue);
  });
}
