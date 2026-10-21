import 'package:baocode/search/session_index.dart';
import 'package:flutter_test/flutter_test.dart';

/// The index narrows a search without ever hiding a hit.
void main() {
  test('words and Chinese pairs are what a conversation is found by', () {
    final words = SessionIndex.tokensOf('Login 登录 page');
    expect(words, containsAll(['login', 'page', '登录']));
    expect(SessionIndex.tokensOf('中'), contains('中'));
  });

  test('only conversations holding every word are candidates', () {
    final index = SessionIndex()
      ..set('a', 'Fix the login page')
      ..set('b', '登录页面 fix')
      ..set('c', 'Unrelated');
    expect(index.candidates('login'), {'a'});
    expect(index.candidates('登录'), {'b'});
    expect(index.candidates('fix login'), {'a'});
    // A part of a word, or one no conversation has: a scan, not "none".
    expect(index.candidates('ogin'), isNull);
    expect(index.candidates('login missing'), isNull);
    expect(index.candidates(''), isNull);
  });

  test('a forgotten conversation is not a candidate', () {
    final index = SessionIndex()
      ..set('a', 'login')
      ..remove('a');
    expect(index.candidates('login'), isNull);
  });
}
