import 'dart:typed_data';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/forge/forge_accounts.dart';
import 'package:baocode/forge/forge_api.dart';
import 'package:baocode/forge/forge_ref.dart';
import 'package:baocode/models/secret_store.dart';
import 'package:baocode/stash/stash_disk.dart';
import 'package:baocode/stash/stash_forge.dart';
import 'package:baocode/stash/stash_note.dart';
import 'package:baocode/stash/stash_settings.dart';
import 'package:baocode/stash/stash_store.dart';
import 'package:baocode/stash/stash_threads.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

import '../forge/forge_test.dart' show FakeForgeHttp;
import '../workspace/project_workspace_test.dart' show FakeWorkspaceDirectories;

const issueUrl = 'https://github.com/o/r/issues/3';
const pullUrl = 'https://github.com/o/r/pull/7';

void main() {
  late FakeForgeHttp http;
  late ForgeAccounts accounts;
  late StashStore store;
  late StashForge forge;
  var issueState = 'open';

  setUp(() async {
    issueState = 'open';
    http = FakeForgeHttp()
      ..on('GET', 'https://api.github.com/user', (_) => {'login': 'leo'})
      ..on(
        'GET',
        'https://api.github.com/repos/o/r/issues/3',
        (_) => {
          'number': 3,
          'title': 'Uploads fail',
          'state': issueState,
          'labels': [
            {'name': 'bug', 'color': 'd73a4a'},
          ],
        },
      )
      ..on(
        'GET',
        'https://api.github.com/repos/o/r/pulls/7',
        (_) => {
          'number': 7,
          'title': 'Retry uploads',
          'state': 'open',
          'draft': false,
        },
      )
      ..on(
        'POST',
        'https://api.github.com/repos/o/r/issues/3/comments',
        (_) => {},
      )
      ..on('PATCH', 'https://api.github.com/repos/o/r/issues/3', (request) {
        issueState = 'closed';
        return {};
      });
    accounts = ForgeAccounts(http: http, secrets: MemorySecretStore());
    await accounts.signInWithToken(ForgeKind.github, 'github.com', 't');
    store = StashStore(MemoryStashDisk());
    await store.load();
    forge = StashForge(
      store: store,
      workspace: Workspace.mock(),
      accounts: accounts,
      remotes: (folder) async => switch (folder) {
        '~/code/baocode' => ['git@github.com:o/r.git'],
        _ => const [],
      },
    );
  });

  tearDown(() => forge.dispose());

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('a link in its text links the stash to the issue, asked of GitHub '
      'and kept with the link', () async {
    final note = await store.create(body: 'Fix this: $issueUrl please');
    forge.start();
    await settle();
    final link = store.byId(note.id)!.issues.single;
    expect(link.url, issueUrl);
    expect(link.title, 'Uploads fail');
    expect(link.state, 'open');
    expect(forge.itemOf(issueUrl)?.labels.single.name, 'bug');
    // In its file too, for when it cannot be asked.
    expect(StashNote.decode(note.id, store.byId(note.id)!.encode()).issues, [
      link,
    ]);
  });

  test('closed while the stash is not done, it asks; done with the issue '
      'still open, it asks to say so there, and writes only then', () async {
    final note = await store.create(body: issueUrl);
    forge.start();
    await settle();
    expect(forge.closedIssues(store.byId(note.id)!), isEmpty);

    issueState = 'closed';
    await forge.refresh(force: true);
    await settle();
    expect(forge.closedIssues(store.byId(note.id)!).single.url, issueUrl);
    await forge.answer(note.id, [issueUrl]);
    expect(forge.closedIssues(store.byId(note.id)!), isEmpty);

    // Opened again: the question is new.
    issueState = 'open';
    await forge.refresh(force: true);
    await settle();
    await store.update(note.id, (note) => note.status = StashStatus.done);
    expect(forge.openIssues(store.byId(note.id)!).single.url, issueUrl);
    final writes = http.requests.where((r) => r.method != 'GET').length;
    expect(writes, 0);

    await forge.write(note.id, issueUrl, text: 'Fixed in #7', close: true);
    final sent = http.requests.where((r) => r.method != 'GET').toList();
    expect(sent.map((r) => r.method), ['POST', 'PATCH']);
    expect(sent.first.json, {'body': 'Fixed in #7'});
    await settle();
    expect(forge.openIssues(store.byId(note.id)!), isEmpty);
    expect(store.byId(note.id)!.issueOf(issueUrl)?.state, 'closed');
  });

  test('what should not go out is found', () {
    expect(
      StashForge.sensitive(
        'see /Users/leo/app/a.dart with sk-ant-0123456789abcdefghij',
      ),
      ['/Users/leo/app/a.dart', 'sk-ant-0123456789abcdefghij'],
    );
    expect(StashForge.sensitive('Fixed in #7.'), isEmpty);
  });

  test(
    'imported: a stash each, the issue, titled and its text; once',
    () async {
      final repos = await forge.repositories();
      expect(repos.single.repo.path, 'o/r');
      expect(repos.single.project.path, '~/code/baocode');
      final item = ForgeItem(
        ref: ForgeRef.parse(issueUrl)!,
        title: 'Uploads fail [503]',
        state: ForgeState.open,
        body: 'They fail on 503.',
      );
      final notes = await forge.import([item], project: '~/code/baocode');
      final note = notes.single;
      expect(note.title, 'Uploads fail [503]');
      expect(note.project, '~/code/baocode');
      expect(note.body, 'They fail on 503.');
      expect(note.issue, issueUrl);
      expect(note.issues.single.url, issueUrl);
      expect(note.changedHere, isFalse);
      expect(forge.stashOf(issueUrl)?.id, note.id);
      expect((await forge.import([item])).single.id, note.id);
      expect(store.notes, hasLength(1));
    },
  );

  group('kept in step with the projects\' issues', () {
    var canPush = true;
    late List<Map<String, Object?>> open;
    Map<String, Object?> issue(int number, String title, String body) => {
      'number': number,
      'title': title,
      'body': body,
      'state': 'open',
    };

    setUp(() {
      canPush = true;
      open = [issue(3, 'Uploads fail', 'On 503.'), issue(4, 'Dark mode', '')];
      http
        ..on(
          'GET',
          'https://api.github.com/repos/o/r',
          (_) => {
            'permissions': {'push': canPush},
          },
        )
        ..on('GET', 'https://api.github.com/search/issues', (request) {
          final q = request.url.queryParameters['q']!;
          if (q.contains('author:@me')) return {'items': open.take(1).toList()};
          if (q.contains('assignee:@me')) return {'items': <Object>[]};
          return {'items': open};
        });
    });

    test('each open issue a stash, once; one deleted never again', () async {
      await forge.sync();
      expect(
        [for (final note in store.notes) (note.title, note.issue)],
        unorderedEquals([
          ('Uploads fail', issueUrl),
          ('Dark mode', 'https://github.com/o/r/issues/4'),
        ]),
      );
      final uploads = forge.stashOf(issueUrl)!;
      expect(uploads.body, 'On 503.');
      expect(uploads.project, '~/code/baocode');

      await forge.sync();
      expect(store.notes, hasLength(2));

      await store.delete(uploads.id);
      expect(store.ignoredIssues, contains(issueUrl));
      await forge.sync();
      expect(store.notes, hasLength(1));
      expect(forge.stashOf(issueUrl), isNull);
    });

    test('only the user\'s where they cannot push', () async {
      canPush = false;
      await forge.sync();
      expect([for (final note in store.notes) note.issue], [issueUrl]);
    });

    test('none when turned off', () async {
      forge.dispose();
      forge = StashForge(
        store: store,
        workspace: Workspace.mock(),
        accounts: accounts,
        remotes: (folder) async => ['git@github.com:o/r.git'],
        issueSync: () => StashIssueSync.off,
      );
      await forge.sync();
      expect(store.notes, isEmpty);
    });

    test('a stash that links it, or was imported before, is the one', () async {
      final linked = await store.create(body: 'See $issueUrl');
      await store.update(
        linked.id,
        (note) => note.issues.add(StashIssueLink(url: issueUrl)),
      );
      final imported = await store.create(
        body:
            '[o/r#4 Dark mode](https://github.com/o/r/issues/4 "card")\n\n'
            'Mine now.',
      );
      await store.update(imported.id, (note) {
        note.title = 'Dark mode';
        note.issues.add(StashIssueLink(url: 'https://github.com/o/r/issues/4'));
      });
      await forge.sync();
      expect(store.notes, hasLength(2));
      final adopted = store.byId(imported.id)!;
      expect(adopted.issue, 'https://github.com/o/r/issues/4');
      // Not taken over: what differs stays till either changes.
      expect(adopted.issueText, 'Mine now.');
      expect(adopted.changedHere, isFalse);
    });

    test('changed there, it changes here; changed here, it waits to be '
        'pushed; both, the user chooses', () async {
      await forge.sync();
      final id = forge.stashOf(issueUrl)!.id;

      open[0] = issue(3, 'Uploads fail on 503', 'Every time.');
      await forge.sync();
      expect(store.byId(id)!.title, 'Uploads fail on 503');
      expect(store.byId(id)!.body, 'Every time.');
      expect(store.byId(id)!.changedHere, isFalse);

      await store.update(id, (note) => note.body = 'Every time, on Wi-Fi.');
      expect(store.byId(id)!.changedHere, isTrue);
      await forge.sync();
      expect(store.byId(id)!.body, 'Every time, on Wi-Fi.');
      expect(forge.remoteChanged(store.byId(id)!), isFalse);

      open[0] = issue(3, 'Uploads fail on 503', 'Every time, on 4G too.');
      await forge.sync();
      expect(store.byId(id)!.body, 'Every time, on Wi-Fi.');
      expect(forge.remoteChanged(store.byId(id)!), isTrue);

      http.on('PATCH', 'https://api.github.com/repos/o/r/issues/3', (request) {
        final json = request.json! as Map;
        return issue(3, json['title'] as String, json['body'] as String);
      });
      await forge.pushEdits(id);
      final patch = http.requests.lastWhere((r) => r.method == 'PATCH');
      expect(patch.json, {
        'title': 'Uploads fail on 503',
        'body': 'Every time, on Wi-Fi.',
      });
      expect(store.byId(id)!.changedHere, isFalse);
      expect(forge.remoteChanged(store.byId(id)!), isFalse);
    });

    test('its issue closed, it is done; opened again, it is not', () async {
      await forge.sync();
      final id = forge.stashOf(issueUrl)!.id;
      forge.start();
      await settle();

      issueState = 'closed';
      await forge.refresh(force: true);
      await settle();
      expect(store.byId(id)!.status, StashStatus.done);
      // Followed, not asked about.
      expect(forge.closedIssues(store.byId(id)!), isEmpty);

      // Found among the open ones again.
      issueState = 'open';
      await forge.sync();
      expect(store.byId(id)!.status, StashStatus.collected);
    });

    test('kept local: no issue, and not made one again', () async {
      await forge.sync();
      final id = forge.stashOf(issueUrl)!.id;
      await forge.keepLocal(id);
      final note = store.byId(id)!;
      expect(note.ownIssue, isNull);
      expect(note.local, isTrue);
      expect(note.issues, isEmpty);
      await forge.sync();
      expect(store.notes, hasLength(2));
    });
  });

  test('published: its pictures put where the issue shows them, its other '
      'files their names', () async {
    final note = await store.create(body: 'x', project: '~/code/baocode');
    final picture = await store.disk.writeAsset(
      note.id,
      'shot.png',
      Uint8List.fromList([1, 2, 3]),
    );
    final file = await store.disk.writeAsset(
      note.id,
      'log.txt',
      Uint8List.fromList([4]),
    );
    await store.update(note.id, (note) {
      note
        ..title = 'Crash on save'
        ..body =
            'It crashes.\n\n![]($picture)\n\nSee [the log]($file) and '
            '[docs](https://example.com/d).';
    });
    expect(StashForge.localPictures(store.byId(note.id)!.body), 1);
    expect(await forge.reposOf('~/code/baocode'), [
      ForgeRepo(kind: ForgeKind.github, host: 'github.com', path: 'o/r'),
    ]);
    http
      ..on(
        'GET',
        'https://api.github.com/repos/o/r/branches/baocode-stash-assets',
        (_) => {},
      )
      ..on('POST', 'https://api.github.com/repos/o/r/issues', (request) {
        final json = request.json! as Map;
        return {
          'number': 9,
          'title': json['title'],
          'body': json['body'],
          'state': 'open',
        };
      })
      ..fallback = (request) => request.method == 'PUT'
          ? {'content': {}}
          : const ForgeResponse(404, '{}');
    await forge.publish(
      note.id,
      const ForgeRepo(kind: ForgeKind.github, host: 'github.com', path: 'o/r'),
    );
    final put = http.requests.singleWhere((r) => r.method == 'PUT');
    expect(put.url.path, startsWith('/repos/o/r/contents/stash/'));
    final post = http.requests.singleWhere((r) => r.method == 'POST');
    final body = (post.json! as Map)['body'] as String;
    expect(
      body,
      contains('![](https://github.com/o/r/blob/baocode-stash-assets/stash/'),
    );
    expect(body, contains('See the log and [docs](https://example.com/d).'));
    final published = store.byId(note.id)!;
    expect(published.issue, 'https://github.com/o/r/issues/9');
    expect(published.issues.first.url, 'https://github.com/o/r/issues/9');
    // Its text here as it was, pictures and all.
    expect(published.body, contains('![]($picture)'));
    expect(published.changedHere, isFalse);
  });

  test('a workspace\'s folders are its repositories; a folder\'s own '
      'project has its issues first', () async {
    final workspace = Workspace(
      projects: const [Project('api', '/code/api')],
      workspaceDirectories: FakeWorkspaceDirectories(),
    );
    final made = workspace.createWorkspace('web', ['/code/site', '/code/api'])!;
    forge.dispose();
    forge = StashForge(
      store: store,
      workspace: workspace,
      accounts: accounts,
      remotes: (folder) async => switch (folder) {
        '/code/site' => ['https://github.com/o/site.git'],
        '/code/api' => ['git@github.com:o/api.git'],
        _ => const [],
      },
    );
    expect(forge.foldersOf(made.path), ['/code/site', '/code/api']);
    expect(
      [for (final repo in await forge.reposOf(made.path)) repo.path],
      ['o/site', 'o/api'],
    );
    expect(
      {
        for (final (:repo, :project) in await forge.repositories())
          repo.path: project.path,
      },
      {'o/site': made.path, 'o/api': '/code/api'},
    );
  });

  test('the pull requests a conversation links to', () {
    expect(
      stashPullsIn([
        const UserMessageItem(text: 'see $pullUrl'),
        const AssistantTextItem('Opened $pullUrl and read $issueUrl.'),
        const ToolCallItem(
          kind: ToolKind.command,
          target: 'gh pr create',
          output: 'https://gitlab.com/g/app/-/merge_requests/4\n',
        ),
      ]),
      [pullUrl, 'https://gitlab.com/g/app/-/merge_requests/4'],
    );
  });
}
