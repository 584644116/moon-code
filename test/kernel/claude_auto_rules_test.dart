import 'package:baocode/kernel/claude_code/claude_auto_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('allow rules that bypass auto mode', () {
    test('a rule with no pattern admits every command', () {
      expect(isDangerousAutoAllowRule('Bash'), isTrue);
      expect(isDangerousAutoAllowRule('Bash(*)'), isTrue);
      expect(isDangerousAutoAllowRule('PowerShell'), isTrue);
      expect(isDangerousAutoAllowRule('PowerShell(*)'), isTrue);
    });

    test('interpreters and shells are dangerous in the shapes rules take', () {
      for (final rule in [
        'Bash(python:*)',
        'Bash(python*)',
        'Bash(python *)',
        'Bash(python -c:*)',
        'Bash(node:*)',
        'Bash(npm run:*)',
        'Bash(ssh:*)',
        'Bash(sudo -u root:*)',
        'PowerShell(iex:*)',
        'PowerShell(pwsh:*)',
        'PowerShell(python.exe:*)',
        'PowerShell(start-process -Verb:*)',
        'PowerShell(new-object:*)',
      ]) {
        expect(
          isDangerousAutoAllowRule(rule),
          isTrue,
          reason: '$rule would run code without the classifier',
        );
      }
    });

    test('ordinary project commands are left alone', () {
      for (final rule in [
        'Read',
        'Edit',
        'Bash(git status)',
        'Bash(git commit:*)',
        'Bash(npm install:*)',
        'Bash(npm test:*)',
        'PowerShell(Get-ChildItem:*)',
        'mcp__github__create_issue',
      ]) {
        expect(
          isDangerousAutoAllowRule(rule),
          isFalse,
          reason: '$rule does not run arbitrary code',
        );
      }
    });

    test('any allow rule for Agent starts subagents unweighed', () {
      expect(isDangerousAutoAllowRule('Agent'), isTrue);
      expect(isDangerousAutoAllowRule('Agent(Explore)'), isTrue);
      expect(isDangerousAutoAllowRule('Task'), isTrue);
    });

    test('the effective settings are read for the allow list', () {
      expect(
        dangerousAutoAllowRules({
          'permissions': {
            'allow': ['Read', 'Bash(python:*)', 'Agent', 42],
            'deny': ['Bash(curl:*)'],
          },
        }),
        ['Bash(python:*)', 'Agent'],
      );
      expect(dangerousAutoAllowRules(const {}), isEmpty);
      expect(dangerousAutoAllowRules(null), isEmpty);
      expect(dangerousAutoAllowRules({'permissions': 'not a map'}), isEmpty);
    });

    test('a rule is Tool or Tool(content), nothing else', () {
      expect(parsePermissionRule('Bash(python:*)'), (
        tool: 'Bash',
        content: 'python:*',
      ));
      expect(parsePermissionRule('Agent'), (tool: 'Agent', content: null));
      expect(parsePermissionRule('Bash(python:*'), isNull);
      expect(parsePermissionRule(''), isNull);
    });
  });
}
