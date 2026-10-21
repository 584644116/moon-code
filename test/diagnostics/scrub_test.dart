import 'package:baocode/diagnostics/diagnostics_bundle.dart';
import 'package:flutter_test/flutter_test.dart';

/// A diagnostics bundle must not carry a working credential.
void main() {
  test('a bearer token and an api key are written over', () {
    expect(
      scrubSecrets('Authorization: Bearer abc.def.ghi'),
      'Authorization: Bearer ***',
    );
    expect(
      scrubSecrets('{"api_key":"plainvalue123"}'),
      '{"api_key":"***"}',
    );
    expect(
      scrubSecrets('x-api-key: 0123456789abcdef'),
      'x-api-key: ***',
    );
  });

  test('a cookie and a refresh token are written over', () {
    expect(
      scrubSecrets('Cookie: session=abc; new_api_refresh=xyz'),
      'Cookie: ***',
    );
    expect(
      scrubSecrets('{"refresh_token":"rt_1234567890"}'),
      '{"refresh_token":"***"}',
    );
    expect(
      scrubSecrets('POST /api/v1/auth/refresh refresh_token=rt_1234'),
      'POST /api/v1/auth/refresh refresh_token=***',
    );
  });

  test('a private key is written over', () {
    const key = '-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----';
    expect(scrubSecrets(key), contains('***'));
    expect(scrubSecrets(key), isNot(contains('MIIE')));
  });

  test('an ordinary line is left as it is', () {
    const line = 'context: 12000 tokens, keyboard shortcut, key value pairs';
    expect(scrubSecrets(line), line);
  });
}
