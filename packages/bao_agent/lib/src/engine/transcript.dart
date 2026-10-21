import 'dart:convert';

import '../util/json.dart';

/// [messages] (as the API takes them) told as plain text, for the small
/// model's errands: what was said, and briefly what tools did. The most
/// recent [maxChars] at most.
String transcriptText(
  List<Map<String, Object?>> messages, {
  int maxChars = 30000,
  bool withTools = true,
}) {
  final parts = <String>[];
  for (final message in messages) {
    final role = message['role'] == 'assistant' ? 'Assistant' : 'User';
    final content = message['content'];
    if (content is String) {
      if (!_note(content)) parts.add('$role: ${content.trim()}');
      continue;
    }
    for (final raw in asList(content)) {
      final block = asMap(raw);
      switch (block['type']) {
        case 'text':
          final text = '${block['text'] ?? ''}'.trim();
          if (text.isNotEmpty && !_note(text)) parts.add('$role: $text');
        case 'tool_use' when withTools:
          final input = jsonEncode(block['input']);
          parts.add(
            'Assistant called ${block['name']}: '
            '${input.length > 300 ? '${input.substring(0, 300)}…' : input}',
          );
        case 'tool_result' when withTools:
          final text = _resultText(block['content']).trim();
          parts.add(
            'Tool result${block['is_error'] == true ? ' (error)' : ''}: '
            '${text.length > 400 ? '${text.substring(0, 400)}…' : text}',
          );
      }
    }
  }
  final text = parts.join('\n\n');
  return text.length > maxChars
      ? '…${text.substring(text.length - maxChars)}'
      : text;
}

bool _note(String text) =>
    text.trimLeft().startsWith('<system-reminder>') ||
    text.trimLeft().startsWith('[Request interrupted');

String _resultText(Object? content) => switch (content) {
  final String text => text,
  final List<Object?> blocks => [
    for (final block in blocks)
      if (asMap(block)['type'] == 'text')
        '${asMap(block)['text']}'
      else if (asMap(block)['type'] == 'image')
        '[image]',
  ].join('\n'),
  _ => '',
};

/// About how many tokens [value] (a message, a list of them, a schema)
/// takes: four characters each, an image about 1,600.
int estimateTokens(Object? value) {
  var images = 0;
  void count(Object? v) {
    if (v is Map) {
      if (v['type'] == 'image' || v['type'] == 'document') images++;
      v.values.forEach(count);
    } else if (v is List) {
      v.forEach(count);
    }
  }

  count(value);
  final text = jsonEncode(_withoutData(value));
  return text.length ~/ 4 + _cjkExtra(text) + images * 1600;
}

/// What four-characters-to-a-token leaves out of [text], in tokens.
///
/// A CJK character is one token and not a quarter of one, so a line of
/// Chinese costs four times what its length says: a conversation sized by
/// that alone stays under the window it is compacted at until the API
/// refuses it. Each one is counted at three quarters of a token over the
/// quarter its length already gave, which makes it one in all.
int _cjkExtra(String text) {
  var cjk = 0;
  for (final rune in text.runes) {
    if ((rune >= 0x3400 && rune <= 0x9fff) || // unified ideographs, ext. A
        (rune >= 0x20000 && rune <= 0x2ebef) || // extensions B to F
        (rune >= 0x3000 && rune <= 0x303f) || // CJK punctuation
        (rune >= 0xff00 && rune <= 0xffef)) { // fullwidth forms
      cjk++;
    }
  }
  return (cjk * 3 + 3) ~/ 4;
}

Object? _withoutData(Object? value) => switch (value) {
  final Map<Object?, Object?> map => {
    for (final MapEntry(:key, :value) in map.entries)
      '$key': key == 'data' && value is String && value.length > 200
          ? ''
          : _withoutData(value),
  },
  final List<Object?> list => [for (final item in list) _withoutData(item)],
  _ => value,
};
