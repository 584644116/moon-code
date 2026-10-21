import 'package:bao_agent/src/permissions/permission_engine.dart';
import 'package:bao_agent/src/permissions/shell_command.dart';
import 'package:flutter_test/flutter_test.dart';

/// A command that cannot be undone, and a file that holds a key, are
/// asked about in every mode; an ordinary delete and a project file are
/// not.
void main() {
  bool dangerous(String command) =>
      ShellCommand.parse(command).words
          .any((words) => isDangerousWords(words, home: '/Users/me'));

  test('commands that throw away work are dangerous', () {
    for (final command in [
      'git reset --hard',
      'git reset --hard HEAD~1',
      'git clean -fd',
      'git clean -fdx',
      'git clean --force',
      'git push origin main --force',
      'git push -f origin main',
      'git checkout --force main',
      'git checkout -f main',
      'git branch -D old',
      'git branch --delete --force old',
      'find . -name "*.tmp" -delete',
      'rsync -a --delete src/ dst/',
      'rsync -a --delete-after src/ dst/',
      'del /s /q build',
      'erase /S build',
      'rd /s /q build',
      'rmdir /S /Q build',
      'robocopy a b /MIR',
      'robocopy a b /mir',
      'Remove-Item -Recurse -Force build',
      'env nohup rm -rf /',
      'nohup rm -rf /',
      'time -p rm -rf /',
      'command rm -rf /',
      'env -u HOME rm -rf /',
      'sudo -u root rm -rf /',
      'cd x && rm -rf /*',
      'rm -rf /',
      'rm -rf ~',
      'dd if=/dev/zero of=/dev/disk2',
      'mkfs.ext4 /dev/sda1',
    ]) {
      expect(dangerous(command), isTrue, reason: command);
    }
  });

  test('the same commands, done safely, are not dangerous', () {
    for (final command in [
      'rm -rf build',
      'rm file',
      'git status',
      'git push --force-with-lease origin main',
      'git clean -n',
      'git clean -nd',
      'find . -name "*.dart"',
      'rsync -a src/ dst/',
      'del file.txt',
      'rd empty',
      'robocopy a b /E',
      'Remove-Item file',
      'dd if=a of=b',
      'ls /',
      'env rm x',
      'nohup rm x',
      'time ls',
      'command -v rm',
    ]) {
      expect(dangerous(command), isFalse, reason: command);
    }
  });

  test('credential files and folders are protected', () {
    for (final path in [
      '/home/me/.ssh/config',
      '/home/me/.aws/credentials',
      '/home/me/.gnupg/private-keys-v1.d/x.key',
      '/home/me/.kube/config',
      '/home/me/.config/gcloud/application_default_credentials.json',
      '/home/me/.docker/config.json',
      '/home/me/.netrc',
      '/home/me/.pypirc',
      '/home/me/project/id_rsa',
      '/home/me/.claude/settings.json',
    ]) {
      expect(isProtectedPath(path), isTrue, reason: path);
    }
    for (final path in [
      '/home/me/project/lib/main.dart',
      '/home/me/.claude/worktrees/x/file.dart',
      '/home/me/project/.github/workflows/ci.yml',
      '/home/me/project/.gitignore',
    ]) {
      expect(isProtectedPath(path), isFalse, reason: path);
    }
  });
}
