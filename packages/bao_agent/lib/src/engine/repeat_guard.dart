import 'dart:convert';

/// Notices a model calling the same tool with the same input over and over,
/// and says so once at each threshold. It only advises: the call still runs,
/// and a new user message starts the count again.
class RepeatGuard {
  RepeatGuard({this.thresholds = const [3, 5, 8], this.previewChars = 500});

  /// The repeat counts that earn a reminder.
  final List<int> thresholds;

  /// How much of the input the reminder shows.
  final int previewChars;

  String? _key;
  int _count = 0;

  /// Starts again: a new user message is a new attempt.
  void reset() {
    _key = null;
    _count = 0;
  }

  /// Records a call of [name] with [input], and returns the reminder to give
  /// the model when this is one of [thresholds]; null otherwise.
  String? record(String name, Map<String, Object?> input) {
    final args = jsonEncode(_canonical(input));
    final key = '$name\u0000$args';
    if (key == _key) {
      _count++;
    } else {
      _key = key;
      _count = 1;
    }
    if (!thresholds.contains(_count)) return null;
    final shown = args.length <= previewChars
        ? args
        : '${args.substring(0, previewChars)}…';
    return 'You have called $name with the same input $_count times in a '
        'row. Look at the last result: if it did not help, change the '
        'approach or end the turn instead of repeating the call.\n'
        'Input: $shown';
  }

  /// [value] with map keys sorted, so the same input in another order is
  /// the same call.
  static Object? _canonical(Object? value) => switch (value) {
    final Map map => _sorted(map),
    final List list => [for (final item in list) _canonical(item)],
    _ => value,
  };

  static Map<String, Object?> _sorted(Map map) {
    final entries = map.entries.toList()
      ..sort((a, b) => '${a.key}'.compareTo('${b.key}'));
    return {
      for (final entry in entries) '${entry.key}': _canonical(entry.value),
    };
  }
}
