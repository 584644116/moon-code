import 'package:bao_remote/claude.dart' show ClaudeHistoryPage;
import 'package:bao_remote/local.dart'
    show ClaudeProjectSummary, ClaudeSessionSummary;
import 'package:flutter_test/flutter_test.dart';

/// What a remote host says of its sessions, read as loosely as it may be
/// written. The host is BaoCode of another version (or a release of it
/// ahead of this one), so a field it leaves out or shapes otherwise costs
/// that one item — never the whole listing, and never an exception only
/// the caller's error handler would see.
void main() {
  group('a session off the wire', () {
    test('is read as it is written', () {
      final session = ClaudeSessionSummary.fromJson({
        'id': 'abc',
        'title': 'Fix the parser',
        'updatedAt': 1700000000000000,
        'cwd': '/work/app',
        'path': '/work/app/abc.jsonl',
      });
      expect(session, isNotNull);
      expect(session!.id, 'abc');
      expect(session.title, 'Fix the parser');
      expect(session.cwd, '/work/app');
      expect(session.path, '/work/app/abc.jsonl');
      expect(
        session.updatedAt,
        DateTime.fromMicrosecondsSinceEpoch(1700000000000000),
      );
    });

    test('without a title is listed nameless, not dropped', () {
      final session = ClaudeSessionSummary.fromJson({
        'id': 'abc',
        'cwd': '/work/app',
        'path': '/work/app/abc.jsonl',
        'updatedAt': 1,
      });
      expect(session?.title, '');
    });

    test('whose time was written another way still has one', () {
      for (final at in <Object?>[1700000000000000.0, '1700000000000000']) {
        final session = ClaudeSessionSummary.fromJson({
          'id': 'abc',
          'cwd': '/work/app',
          'path': '/work/app/abc.jsonl',
          'updatedAt': at,
        });
        expect(session?.updatedAt.microsecondsSinceEpoch, 1700000000000000);
      }
    });

    test('whose time is missing altogether is put at the epoch, not '
        'dropped', () {
      final session = ClaudeSessionSummary.fromJson({
        'id': 'abc',
        'cwd': '/work/app',
        'path': '/work/app/abc.jsonl',
      });
      expect(session, isNotNull);
      expect(session!.updatedAt, DateTime.fromMillisecondsSinceEpoch(0));
    });

    test('without what makes it one is left out', () {
      // A number where the id should be, or nothing to open.
      for (final json in [
        {'cwd': '/work/app', 'path': '/x.jsonl', 'updatedAt': 1},
        {'id': 17, 'cwd': '/work/app', 'path': '/x.jsonl', 'updatedAt': 1},
        {'id': 'abc', 'path': '/x.jsonl', 'updatedAt': 1},
        {'id': 'abc', 'cwd': '/work/app', 'updatedAt': 1},
      ]) {
        expect(ClaudeSessionSummary.fromJson(json), isNull, reason: '$json');
      }
    });
  });

  group('a project off the wire', () {
    test('has the sessions that can be read, and only those', () {
      final project = ClaudeProjectSummary.fromJson({
        'path': '/work/app',
        'sessions': [
          {'id': 'a', 'cwd': '/work/app', 'path': '/a.jsonl', 'updatedAt': 2},
          // Not one: no path to read.
          {'id': 'b', 'cwd': '/work/app', 'updatedAt': 1},
          // Not a session at all.
          'a_session_not_a_dict',
          null,
          {'id': 'c', 'cwd': '/work/app', 'path': '/c.jsonl', 'updatedAt': 3},
        ],
      });
      expect(project, isNotNull);
      expect(project!.path, '/work/app');
      expect([for (final s in project.sessions) s.id], ['a', 'c']);
    });

    test('with no sessions list is a project with none', () {
      final project = ClaudeProjectSummary.fromJson({'path': '/work/app'});
      expect(project, isNotNull);
      expect(project!.sessions, isEmpty);
    });

    test('with sessions not a list is a project with none', () {
      final project = ClaudeProjectSummary.fromJson({
        'path': '/work/app',
        'sessions': 'a',
      });
      expect(project?.sessions, isEmpty);
    });

    test('without a folder to be in is left out', () {
      expect(ClaudeProjectSummary.fromJson({'sessions': []}), isNull);
      expect(ClaudeProjectSummary.fromJson({'path': 17}), isNull);
    });
  });

  group('a page of a conversation off the wire', () {
    test('keeps the lines that are lines', () {
      final page = ClaudeHistoryPage.fromJson({
        'entries': [
          {'type': 'user', 'uuid': 'a'},
          'not a line',
          {'type': 'assistant', 'uuid': 'b'},
        ],
        'earlier': 'a',
      });
      expect([for (final e in page.entries) e['uuid']], ['a', 'b']);
      expect(page.earlier, 'a');
    });

    test('with no lines is a page with none, not an exception', () {
      for (final json in [
        <String, Object?>{},
        {'entries': null},
        {'entries': 'a'},
      ]) {
        expect(ClaudeHistoryPage.fromJson(json).entries, isEmpty, reason: '$json');
      }
    });

    test('whose earlier mark is not one begins the conversation', () {
      final page = ClaudeHistoryPage.fromJson({
        'entries': [
          {'type': 'user', 'uuid': 'a'},
        ],
        'earlier': 17,
      });
      expect(page.earlier, isNull);
      expect(page.entries, hasLength(1));
    });
  });
}
