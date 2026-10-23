import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/default_permission.dart';
import 'package:baocode/kernel/thinking_display.dart';
import 'package:baocode/settings/response_language.dart';

void main() {
  group('thinking display', () {
    test('is shown unless set to omitted', () {
      expect(ThinkingDisplay.parse(null), ThinkingDisplay.summarized);
      expect(ThinkingDisplay.parse('summarized').shown, isTrue);
      expect(ThinkingDisplay.parse('omitted').shown, isFalse);
      expect(ThinkingDisplay.parse('something else').shown, isTrue);
    });

    test('starts Claude Code with the display chosen', () {
      final shown = ClaudeLaunch(cwd: '/p');
      final shownAt = shown.arguments.indexOf('--thinking-display');
      expect(shown.arguments[shownAt + 1], 'summarized');

      final hidden = ClaudeLaunch(cwd: '/p', thinkingDisplay: 'omitted');
      final hiddenAt = hidden.arguments.indexOf('--thinking-display');
      expect(hidden.arguments[hiddenAt + 1], 'omitted');
    });
  });

  group('reply language', () {
    test('reads the names Claude Code uses, and nothing else', () {
      expect(ResponseLanguage.parse(null), isNull);
      expect(ResponseLanguage.parse(''), isNull);
      expect(ResponseLanguage.parse('Chinese'), ResponseLanguage.chinese);
      expect(ResponseLanguage.parse(' japanese '), ResponseLanguage.japanese);
      expect(ResponseLanguage.parse('klingon'), isNull);
    });

    test('is a flag setting, and absent when not chosen', () {
      final chosen = ClaudeLaunch(cwd: '/p', language: 'chinese');
      final args = chosen.arguments;
      final at = args.indexOf('--settings');
      expect(jsonDecode(args[at + 1])['language'], 'chinese');

      expect(ClaudeLaunch(cwd: '/p').settings.containsKey('language'), isFalse);
    });
  });

  group('default permission', () {
    test('is ask unless another is chosen', () {
      expect(DefaultPermission.parse(null), DefaultPermission.ask);
      expect(DefaultPermission.parse('default'), DefaultPermission.ask);
      expect(DefaultPermission.parse('acceptEdits').mode, 'acceptEdits');
      expect(DefaultPermission.parse('auto').mode, 'auto');
      expect(DefaultPermission.parse('bypassPermissions').mode, 'default');
    });
  });
}
