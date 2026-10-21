import 'dart:convert';
import 'dart:io';

import '../config/paths.dart';

/// The most one conversation a message refers to adds to it.
const sessionReferenceChars = 8000;

/// The most conversations one message may refer to.
const sessionReferenceSources = 3;

/// What was said in the conversation [id] — the user's and the model's
/// text, not tools' — the newest kept when it is longer than [maxChars];
/// null when there is no such conversation.
String? readSessionReference(
  AgentPaths paths,
  String id, {
  int maxChars = sessionReferenceChars,
}) {
  final found = paths.findSession(id);
  if (found == null) return null;
  final String text;
  try {
    text = File(found).readAsStringSync();
  } on FileSystemException {
    return null;
  }
  final messages = <String>[];
  for (final line in const LineSplitter().convert(text)) {
    if (!line.contains('"type":"user"') &&
        !line.contains('"type":"assistant"')) {
      continue;
    }
    final Object? entry;
    try {
      entry = jsonDecode(line);
    } on Object {
      continue;
    }
    if (entry is! Map<String, Object?>) continue;
    if (entry['isSidechain'] == true || entry['isMeta'] == true) continue;
    final type = entry['type'];
    if (type != 'user' && type != 'assistant') continue;
    if (entry['message'] case final Map<String, Object?> message) {
      final parts = switch (message['content']) {
        final String said => [said],
        final List<Object?> blocks => [
          for (final block in blocks)
            if (block is Map<String, Object?> &&
                block['type'] == 'text' &&
                block['text'] is String)
              block['text']! as String,
        ],
        _ => const <String>[],
      };
      for (final part in parts) {
        final said = part.trim();
        // What the client adds is not the conversation.
        if (said.isEmpty ||
            type == 'user' &&
                (said.startsWith('<') || said.startsWith('[Session '))) {
          continue;
        }
        messages.add(said);
      }
    }
  }
  if (messages.isEmpty) return '';
  // The newest that fit: an earlier message is dropped before a newer one
  // is shortened.
  final kept = <String>[];
  var used = 0;
  for (var i = messages.length - 1; i >= 0; i--) {
    final message = messages[i];
    if (used + message.length + 2 > maxChars) {
      if (kept.isEmpty) {
        kept.add('…${message.substring(message.length - maxChars)}');
      }
      break;
    }
    kept.add(message);
    used += message.length + 2;
  }
  return kept.reversed.join('\n\n');
}
