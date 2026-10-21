import 'dart:convert';
import 'dart:io';

/// The first [bytes] of [file] as text, whole lines only: the line the
/// window ends in is left out. Empty when no line ends within it.
///
/// A session file grows for as long as it is talked in, to hundreds of
/// megabytes; what a listing needs of it is at its two ends (see
/// `_summarize`), so it is read at its two ends.
String readHead(File file, int bytes) =>
    _readWindow(file, bytes, fromEnd: false);

/// The last [bytes] of [file] as text, whole lines only: the line the
/// window starts in is left out (a cut UTF-8 character among them).
String readTail(File file, int bytes) =>
    _readWindow(file, bytes, fromEnd: true);

String _readWindow(File file, int bytes, {required bool fromEnd}) {
  final reader = file.openSync();
  try {
    final length = reader.lengthSync();
    final take = length < bytes ? length : bytes;
    if (take <= 0) return '';
    reader.setPositionSync(fromEnd ? length - take : 0);
    final text = utf8.decode(reader.readSync(take), allowMalformed: true);
    if (take == length) return text;
    if (fromEnd) {
      // The first line was cut by the window; the second is whole.
      final cut = text.indexOf('\n');
      return cut < 0 ? '' : text.substring(cut + 1);
    }
    // The last line was cut by the window; the one before it is whole.
    final cut = text.lastIndexOf('\n');
    return cut < 0 ? '' : text.substring(0, cut + 1);
  } finally {
    reader.closeSync();
  }
}
