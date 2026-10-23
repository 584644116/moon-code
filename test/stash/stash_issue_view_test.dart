import 'package:baocode/forge/forge_accounts.dart';
import 'package:baocode/forge/forge_api.dart';
import 'package:baocode/forge/forge_ref.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/models/secret_store.dart';
import 'package:baocode/stash/stash_disk.dart';
import 'package:baocode/stash/stash_forge.dart';
import 'package:baocode/stash/stash_issue_view.dart';
import 'package:baocode/stash/stash_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../forge/forge_test.dart' show FakeForgeHttp;

const issueUrl = 'https://github.com/o/r/issues/3';

void main() {
  late FakeForgeHttp http;
  late StashStore store;
  late StashForge forge;

  setUp(() async {
    http = FakeForgeHttp()
      ..on('GET', 'https://api.github.com/user', (_) => {'login': 'leo'})
      ..on('POST', 'https://api.github.com/repos/o/r/issues', (request) {
        final json = request.json! as Map;
        return {
          'number': 9,
          'title': json['title'],
          'body': json['body'],
          'state': 'open',
        };
      });
    final accounts = ForgeAccounts(http: http, secrets: MemorySecretStore());
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

  Widget app(int id) => MaterialApp(
    localizationsDelegates: const [AppLocalizations.delegate],
    home: Scaffold(
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) => Column(
          children: [
            StashIssueChip(forge: forge, note: store.byId(id)!),
            StashIssueSyncBanner(forge: forge, note: store.byId(id)!),
          ],
        ),
      ),
    ),
  );

  Iterable<String> sent() =>
      http.requests.where((r) => r.method != 'GET').map((r) => r.method);

  testWidgets('a stash of a repository\'s project is published as its issue '
      'once the user confirms what goes', (tester) async {
    final note = (await tester.runAsync(
      () => store.create(
        body: 'Crashes, see /Users/leo/app/log.txt',
        project: '~/code/baocode',
      ),
    ))!;
    await tester.runAsync(
      () => store.update(note.id, (note) => note.title = 'Crash on save'),
    );
    await tester.pumpWidget(app(note.id));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.text('Not an issue yet'), findsOneWidget);

    await tester.tap(find.text('Not an issue yet'));
    await tester.pumpAndSettle();
    expect(find.text('Keep it local'), findsOneWidget);
    await tester.tap(find.text('Publish as an issue of o/r…'));
    await tester.pumpAndSettle();
    expect(find.text('Publish as an issue of o/r'), findsOneWidget);
    expect(find.text('Crash on save'), findsOneWidget);
    expect(find.text('Crashes, see /Users/leo/app/log.txt'), findsOneWidget);
    // A path on this machine pointed out; nothing sent yet.
    expect(find.text('  /Users/leo/app/log.txt'), findsOneWidget);
    expect(sent(), isEmpty);

    await tester.tap(find.text('Send Anyway'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(sent(), ['POST']);
    expect(store.byId(note.id)!.issue, 'https://github.com/o/r/issues/9');
    expect(find.text('o/r#9'), findsOneWidget);
  });

  testWidgets('kept local, it is not offered again', (tester) async {
    final note = (await tester.runAsync(
      () => store.create(body: 'Just mine', project: '~/code/baocode'),
    ))!;
    await tester.pumpWidget(app(note.id));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.tap(find.text('Not an issue yet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep it local'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(store.byId(note.id)!.local, isTrue);
    expect(find.text('Local only'), findsOneWidget);
    expect(sent(), isEmpty);
  });

  testWidgets('a project that is no repository: nothing about issues', (
    tester,
  ) async {
    final note = (await tester.runAsync(
      () => store.create(body: 'Notes', project: '~/code/cursor-docs'),
    ))!;
    await tester.pumpWidget(app(note.id));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.text('Not an issue yet'), findsNothing);
    expect(find.text('Local only'), findsNothing);
  });

  testWidgets('changed here, it says so, and pushes only once confirmed', (
    tester,
  ) async {
    final item = ForgeItem(
      ref: ForgeRef.parse(issueUrl)!,
      title: 'Uploads fail',
      state: ForgeState.open,
      body: 'On 503.',
    );
    final note = (await tester.runAsync(
      () => forge.import([item], project: '~/code/baocode'),
    ))!.single;
    await tester.pumpWidget(app(note.id));
    await tester.pump();
    expect(find.text('o/r#3'), findsOneWidget);
    expect(find.textContaining('not on o/r#3 yet'), findsNothing);

    await tester.runAsync(
      () => store.update(note.id, (note) => note.body = 'On 503, every time.'),
    );
    await tester.pump();
    expect(find.text('Changes here are not on o/r#3 yet.'), findsOneWidget);
    await tester.tap(find.text('Push'));
    await tester.pumpAndSettle();
    expect(find.text('Push changes to o/r#3'), findsOneWidget);
    expect(find.text('On 503, every time.'), findsOneWidget);
    expect(sent(), isEmpty);
  });
}
