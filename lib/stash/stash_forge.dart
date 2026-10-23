import 'dart:async';

import 'package:flutter/foundation.dart';

import '../forge/forge_accounts.dart';
import '../forge/forge_api.dart';
import '../forge/forge_io_stub.dart'
    if (dart.library.io) '../forge/forge_io.dart'
    as io;
import '../forge/forge_ref.dart';
import '../remote/remote_location.dart';
import '../workspace/workspace.dart';
import 'stash_settings.dart';
import 'stash_note.dart';
import 'stash_store.dart';

/// The stashes' issues and pull requests (docs/stash.md): linked from
/// their text (a link pasted, an issue imported) and from their
/// conversations (see StashThreads); how each is now, asked of its forge
/// as the user (see [ForgeAccounts]) and kept with the link for when it
/// cannot be; what that asks of the user (an issue closed: is the stash
/// done? the stash done: say so on the issue?); and what the user then
/// writes there, only once they confirm it.
class StashForge extends ChangeNotifier {
  StashForge({
    required this.store,
    required this.workspace,
    required this.accounts,
    DateTime Function()? clock,
    Future<List<String>> Function(String folder)? remotes,
    StashIssueSync Function()? issueSync,
  }) : _clock = clock ?? DateTime.now,
       _remotes = remotes ?? io.gitRemoteUrls,
       _issueSync = issueSync ?? (() => StashIssueSync.auto);

  /// The app's, once main() has made it.
  static StashForge? current;

  final StashStore store;
  final Workspace workspace;
  final ForgeAccounts accounts;
  final DateTime Function() _clock;
  final Future<List<String>> Function(String folder) _remotes;
  final StashIssueSync Function() _issueSync;

  bool _started = false;
  bool _disposed = false;
  Timer? _timer;

  /// How often what is linked is asked again while the app runs.
  static const refreshEvery = Duration(minutes: 5);

  /// How long an answer is taken as current.
  static const fresh = Duration(seconds: 60);

  void start() {
    if (_started) return;
    _started = true;
    store.addListener(_storeChanged);
    accounts.addListener(_accountsChanged);
    _timer = Timer.periodic(refreshEvery, (_) {
      unawaited(refresh());
      unawaited(sync());
    });
    _storeChanged();
    unawaited(store.load().then((_) => sync()));
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (_started) {
      store.removeListener(_storeChanged);
      accounts.removeListener(_accountsChanged);
    }
    super.dispose();
  }

  /// [url]'s issue or pull request, if it is one (on a host known).
  ForgeRef? refOf(String url) => ForgeRef.parse(url, kindOf: accounts.kindOf);

  /// [url]'s issue or pull request as last asked this run; null before.
  ForgeItem? itemOf(String url) => _items[url];
  final Map<String, ForgeItem> _items = {};

  /// Why [url] could not be asked last time, if it could not.
  ForgeException? failureOf(String url) => _failures[url];
  final Map<String, ForgeException> _failures = {};

  /// When each link was last asked.
  final Map<String, DateTime> _asked = {};

  /// Whether [url]'s forge has an account to ask it with.
  bool canAsk(String url) => switch (refOf(url)) {
    final ref? => accounts.apiOf(ref) != null,
    null => false,
  };

  // --- Linked from the text ------------------------------------------------------

  bool _collecting = false;

  void _storeChanged() {
    if (_disposed || !store.loaded || _collecting) return;
    unawaited(_collect());
  }

  void _accountsChanged() {
    _failures.clear();
    _asked.clear();
    _pushable.clear();
    notifyListeners();
    unawaited(_collect());
    unawaited(sync());
  }

  /// Links each stash to the issues and pull requests its text links to,
  /// then asks those not asked lately.
  Future<void> _collect() async {
    _collecting = true;
    try {
      final adding = <int, List<String>>{};
      for (final note in store.notes) {
        for (final ref in ForgeRef.allIn(note.body, kindOf: accounts.kindOf)) {
          final url = ref.url.toString();
          if (note.issueOf(url) == null) (adding[note.id] ??= []).add(url);
        }
      }
      if (adding.isNotEmpty) {
        // What an agent wrote meanwhile, read before it is written over.
        await store.reload();
        for (final MapEntry(key: id, value: urls) in adding.entries) {
          final note = store.byId(id);
          if (note == null) continue;
          for (final url in urls) {
            if (note.issueOf(url) == null) {
              note.issues.add(StashIssueLink(url: url));
            }
          }
          await store.save(note, touch: false);
        }
      }
    } finally {
      _collecting = false;
    }
    await refresh();
  }

  // --- How they are now ----------------------------------------------------------

  Future<void>? _refreshing;

  /// Asks the forges how the linked issues and pull requests are now: of
  /// stashes not done, and of those done that are still open (to ask the
  /// user about them); each at most once in [fresh] unless [force]d.
  Future<void> refresh({bool force = false}) => force
      ? _refresh(true)
      : _refreshing ??= _refresh(false).whenComplete(() => _refreshing = null);

  /// Asks [id]'s stash's again, now (shown, it should be current).
  Future<void> refreshNote(int id) async {
    final note = store.byId(id);
    if (note == null) return;
    await _ask([for (final link in note.issues) link.url], force: false);
  }

  Future<void> _refresh(bool force) => _ask([
    for (final note in store.notes)
      for (final link in note.issues)
        if (note.status != StashStatus.done ||
            !link.answered &&
                (link.state != 'closed' && link.state != 'merged'))
          link.url,
  ], force: force);

  Future<void> _ask(List<String> urls, {required bool force}) async {
    final now = _clock();
    final asking = {
      for (final url in urls)
        if (force || !(_asked[url]?.isAfter(now.subtract(fresh)) ?? false)) url,
    };
    final answers = <String, ForgeItem>{};
    await Future.wait([
      for (final url in asking)
        if (refOf(url) case final ref?)
          if (accounts.apiOf(ref) case final api?)
            api
                .item(ref)
                .then((item) {
                  answers[url] = item;
                  _failures.remove(url);
                })
                .catchError((Object error) {
                  _failures[url] = error is ForgeException
                      ? error
                      : ForgeException('$error');
                })
                .whenComplete(() => _asked[url] = now),
    ]);
    if (_disposed) return;
    _items.addAll(answers);
    notifyListeners();
    await _keep(answers);
  }

  /// Keeps what [answers] say with the links (their title, state and
  /// checks), for when they cannot be asked; and a stash's own issue's
  /// with the stash (see [_takeOwn]).
  Future<void> _keep(Map<String, ForgeItem> answers) async {
    if (answers.isEmpty) return;
    bool differs(StashIssueLink link, ForgeItem item) =>
        link.title != item.title ||
        link.state != item.state.name ||
        link.checks != item.checks?.name;
    bool ownDiffers(StashNote note) => switch (note.ownIssue) {
      final url? => switch (answers[url]) {
        final item? => _remoteHash(item) != note.syncedRemote,
        null => false,
      },
      null => false,
    };
    if (!store.notes.any(
      (note) =>
          ownDiffers(note) ||
          note.issues.any(
            (link) => switch (answers[link.url]) {
              final item? => differs(link, item),
              null => false,
            },
          ),
    )) {
      return;
    }
    await store.reload();
    for (final note in store.notes) {
      var changed = false;
      final own = note.ownIssue;
      for (final (i, link) in note.issues.indexed) {
        final item = answers[link.url];
        if (item == null || !differs(link, item)) continue;
        // Its own issue closed or opened again: so is it.
        if (link.url == own && link.state != null) {
          final was = ForgeState.parse(link.state)?.isOpen;
          if (was == true && !item.state.isOpen) {
            note.status = StashStatus.done;
          } else if (was == false &&
              item.state.isOpen &&
              note.status == StashStatus.done) {
            note.status = note.threads.isNotEmpty
                ? StashStatus.implementing
                : StashStatus.collected;
          }
        }
        note.issues[i] = StashIssueLink(
          url: link.url,
          title: item.title,
          state: item.state.name,
          checks: item.checks?.name,
          session: link.session,
          // A state that changed asks anew.
          answered: link.state == item.state.name && link.answered,
        );
        changed = true;
      }
      if (own != null) {
        if (answers[own] case final item?) changed |= _takeOwn(note, item);
      }
      if (changed) await store.save(note, touch: false);
    }
  }

  static String _remoteHash(ForgeItem item) =>
      StashNote.syncHash(item.title, item.body);

  /// [note] as its own issue [item] is, if the issue changed since they
  /// were last the same and the stash did not; else as it was (the two
  /// the same since, it is noted; both changed, the user chooses: see
  /// [remoteChanged]). Whether it changed.
  bool _takeOwn(StashNote note, ForgeItem item) {
    final remote = _remoteHash(item);
    if (remote == note.syncedRemote) return false;
    final local = StashNote.syncHash(note.title, note.issueText);
    if (local == remote) {
      note
        ..synced = local
        ..syncedRemote = remote;
      return true;
    }
    if (note.changedHere) return false;
    note
      ..title = item.title
      ..body = note.withIssueText(item.body)
      ..synced = StashNote.syncHash(item.title, note.issueText)
      ..syncedRemote = remote;
    return true;
  }

  /// Whether [note]'s issue changed since they were last the same (as last
  /// asked): with [StashNote.changedHere], the two to be chosen between.
  bool remoteChanged(StashNote note) {
    final own = note.ownIssue;
    if (own == null || note.syncedRemote == null) return false;
    final item = _items[own];
    return item != null && _remoteHash(item) != note.syncedRemote;
  }

  /// [link]'s state: as just asked, else as kept.
  ForgeState? stateOf(StashIssueLink link) =>
      _items[link.url]?.state ?? ForgeState.parse(link.state);

  // --- What they ask of the user -------------------------------------------------

  /// [note]'s issues closed while it is not done: is it? (Not its own:
  /// it follows that one.)
  List<StashIssueLink> closedIssues(StashNote note) => [
    if (note.status != StashStatus.done)
      for (final link in note.issues)
        if (!link.answered &&
            link.url != note.ownIssue &&
            refOf(link.url)?.kind == ForgeItemKind.issue &&
            stateOf(link) == ForgeState.closed)
          link,
  ];

  /// [note]'s issues still open though it is done: say so there?
  List<StashIssueLink> openIssues(StashNote note) => [
    if (note.status == StashStatus.done)
      for (final link in note.issues)
        if (!link.answered &&
            refOf(link.url)?.kind == ForgeItemKind.issue &&
            (stateOf(link)?.isOpen ?? false) &&
            canAsk(link.url))
          link,
  ];

  /// What [links] of [id]'s stash asked was answered (or set aside).
  Future<void> answer(int id, Iterable<String> links) async {
    final urls = links.toSet();
    await store.reload();
    await store.update(id, (note) {
      for (final (i, link) in note.issues.indexed) {
        if (urls.contains(link.url)) {
          note.issues[i] = link.copyWith(answered: true);
        }
      }
    }, touch: false);
  }

  /// Unlinks [url] from [id]'s stash (its link in the text stays, and
  /// would link it again: taken out of the text too).
  Future<void> unlink(int id, String url) async {
    await store.reload();
    await store.update(id, (note) {
      note.issues.removeWhere((link) => link.url == url);
    }, touch: false);
  }

  // --- Written there, once confirmed ---------------------------------------------

  /// Comments [text] on [url]'s issue or pull request (when not empty),
  /// then closes it when [close] (an issue); as the user, who confirmed
  /// it. Throws [ForgeException].
  Future<void> write(
    int id,
    String url, {
    String text = '',
    bool close = false,
  }) async {
    final ref = refOf(url);
    final api = ref == null ? null : accounts.apiOf(ref);
    if (ref == null || api == null) {
      throw const ForgeException('Not signed in.', status: 401);
    }
    if (text.trim().isNotEmpty) await api.comment(ref, text.trim());
    if (close && ref.kind == ForgeItemKind.issue) await api.close(ref);
    // As it is now first: a state changed asks anew, but this one the user
    // just answered.
    await _ask([url], force: true);
    await answer(id, [url]);
  }

  /// What should not go out in [text] before the user says so: paths on
  /// this machine, and what looks like a secret (an API key, a token, a
  /// private key).
  static List<String> sensitive(String text) => [
    for (final pattern in _sensitive)
      for (final match in pattern.allMatches(text)) match[0]!,
  ];

  static final _sensitive = [
    RegExp(
      r'(?:/Users|/home)/[^\s`"'
      ')]+',
    ),
    RegExp(
      r'[A-Za-z]:\\Users\\[^\s`"'
      ')]+',
    ),
    RegExp(r'\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}'),
    RegExp(r'\b(?:ghp|gho|ghu|ghs|ghr|github_pat|glpat)[-_][A-Za-z0-9_]{16,}'),
    RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
    RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
  ];

  // --- Imported ------------------------------------------------------------------

  /// The folders [project] is: its own, or a workspace's (each of them
  /// may be a Git repository).
  List<String> foldersOf(String project) => [
    if (workspace.workspaceAt(project) case final workspace?)
      ...workspace.folders
    else
      project,
  ];

  /// The repositories [folder]'s Git remotes are (on hosts known): asked
  /// of Git once in [refreshEvery].
  Future<List<ForgeRepo>> _reposIn(String folder) async {
    if (RemoteLocation.isRemote(folder)) return const [];
    final now = _clock();
    final known = _remotesOf[folder];
    if (known != null && now.difference(known.at) < refreshEvery) {
      return known.repos;
    }
    final repos = <ForgeRepo>{};
    try {
      for (final remote in await _remotes(folder)) {
        if (ForgeRepo.fromRemote(remote, kindOf: accounts.kindOf)
            case final repo?) {
          repos.add(repo);
        }
      }
    } on Object catch (error) {
      debugPrint('stash: remotes of $folder: $error');
    }
    _remotesOf[folder] = (at: now, repos: repos.toList());
    return repos.toList();
  }

  final Map<String, ({DateTime at, List<ForgeRepo> repos})> _remotesOf = {};

  /// The repositories [project] is of (its folders' remotes): none where
  /// it is no Git repository (its stashes kept here).
  Future<List<ForgeRepo>> reposOf(String project) async =>
      {for (final folder in foldersOf(project)) ...await _reposIn(folder)}
          .toList();

  /// The repositories the projects are of (by their folders' Git remotes,
  /// on hosts known), each with its project: a folder's own, before a
  /// workspace it is in; those with an account first.
  Future<List<({ForgeRepo repo, Project project})>> repositories() async {
    final found = <ForgeRepo, Project>{};
    final projects = workspace.projects;
    for (final workspaces in [false, true]) {
      for (final project in projects) {
        if ((workspace.workspaceOf(project) != null) != workspaces) continue;
        for (final repo in await reposOf(project.path)) {
          found.putIfAbsent(repo, () => project);
        }
      }
    }
    final list = [
      for (final MapEntry(key: repo, value: project) in found.entries)
        (repo: repo, project: project),
    ];
    list.sort((a, b) {
      final signed =
          (accounts.accountFor(b.repo.host) != null ? 1 : 0) -
          (accounts.accountFor(a.repo.host) != null ? 1 : 0);
      return signed != 0 ? signed : a.repo.path.compareTo(b.repo.path);
    });
    return list;
  }

  // --- The projects' issues, as stashes ----------------------------------------

  /// Whether each repository can be pushed to by the user, as asked.
  final Map<ForgeRepo, bool> _pushable = {};

  Future<void>? _syncing;

  /// Makes the projects' open issues stashes (those the settings say: see
  /// [StashIssueSync]), each once: the stash its issue is, else one that
  /// links it, else a new one; never one whose stash was deleted, or that
  /// was unlinked from it ([StashStore.ignoredIssues]). Those already
  /// stashes are kept in step (see [_keep]).
  Future<void> sync() =>
      _syncing ??= _sync().whenComplete(() => _syncing = null);

  Future<void> _sync() async {
    final mode = _issueSync();
    if (_disposed || mode == StashIssueSync.off || !store.loaded) return;
    final answers = <String, ForgeItem>{};
    for (final (:repo, :project) in await repositories()) {
      final api = accounts.apiFor(repo.host);
      if (api == null) continue;
      try {
        final all =
            mode == StashIssueSync.auto &&
            (_pushable[repo] ??= await api
                .canPush(repo)
                .catchError((Object _) => false));
        final items = <String, ForgeItem>{};
        for (final filter
            in all
                ? const [ForgeIssueFilter.all]
                : const [ForgeIssueFilter.assigned, ForgeIssueFilter.created]) {
          for (final item in await api.issues(repo, filter: filter)) {
            items[item.ref.url.toString()] = item;
          }
        }
        for (final MapEntry(key: url, value: item) in items.entries) {
          if (_disposed) return;
          if (store.ignoredIssues.contains(url)) continue;
          if (stashOf(url) case final note?) {
            answers[url] = item;
            // Imported before it was kept: it is the issue.
            if (note.issue == null && note.ownIssue == url) {
              // Each as it is now: what changes after is kept in step
              // (what differs already, left as it is).
              await store.update(note.id, (note) {
                note
                  ..issue = url
                  ..synced = StashNote.syncHash(note.title, note.issueText)
                  ..syncedRemote = _remoteHash(item);
              }, touch: false);
            }
            continue;
          }
          await _create(item, project: project.path);
        }
      } on ForgeException catch (error) {
        debugPrint('stash: issues of ${repo.path}: ${error.message}');
      }
    }
    if (_disposed) return;
    _items.addAll(answers);
    final now = _clock();
    for (final url in answers.keys) {
      _asked[url] = now;
    }
    notifyListeners();
    await _keep(answers);
  }

  /// A stash that is [item]'s issue, about [project]: its title and text
  /// the issue's.
  Future<StashNote> _create(ForgeItem item, {String? project}) async {
    final url = item.ref.url.toString();
    final note = await store.create(body: item.body.trim(), project: project);
    await store.update(note.id, (note) {
      note
        ..title = item.title
        ..issue = url
        ..synced = StashNote.syncHash(item.title, item.body)
        ..syncedRemote = _remoteHash(item);
      note.issues.add(
        StashIssueLink(url: url, title: item.title, state: item.state.name),
      );
    }, touch: false);
    _items[url] = item;
    _asked[url] = _clock();
    return store.byId(note.id)!;
  }

  // --- Its issue, from the stash -------------------------------------------------

  /// [id]'s stash made an issue of [repo], as the user (who confirmed it):
  /// its pictures put where the issue can show them, links to its other
  /// files left as their names. Throws [ForgeException].
  Future<void> publish(int id, ForgeRepo repo) async {
    final api = accounts.apiFor(repo.host);
    final note = store.byId(id);
    if (api == null) throw const ForgeException('Not signed in.', status: 401);
    if (note == null || note.ownIssue != null) return;
    final title = note.displayTitle;
    final item = await api.createIssue(
      repo,
      title: title,
      body: await _outgoing(api, repo, note.issueText),
    );
    final url = item.ref.url.toString();
    _items[url] = item;
    _asked[url] = _clock();
    await store.reload();
    await store.update(id, (note) {
      note
        ..title = title
        ..issue = url
        ..local = false
        ..synced = StashNote.syncHash(title, note.issueText)
        ..syncedRemote = _remoteHash(item);
      note.issues.removeWhere((link) => link.url == url);
      note.issues.insert(
        0,
        StashIssueLink(url: url, title: item.title, state: item.state.name),
      );
    }, touch: false);
    notifyListeners();
  }

  /// [id]'s stash's title and text, changed here, made its issue's, as
  /// the user (who confirmed it). Throws [ForgeException].
  Future<void> pushEdits(int id) async {
    final note = store.byId(id);
    final url = note?.ownIssue;
    final ref = url == null ? null : refOf(url);
    final api = ref == null ? null : accounts.apiOf(ref);
    if (note == null || ref == null || url == null) return;
    if (api == null) throw const ForgeException('Not signed in.', status: 401);
    final title = note.displayTitle;
    final item = await api.editIssue(
      ref,
      title: title,
      body: await _outgoing(api, ref.repo, note.issueText),
    );
    _items[url] = item;
    _asked[url] = _clock();
    await store.reload();
    await store.update(id, (note) {
      note
        ..title = title
        ..issue = url
        ..synced = StashNote.syncHash(title, note.issueText)
        ..syncedRemote = _remoteHash(item);
    }, touch: false);
    notifyListeners();
  }

  /// [id]'s stash made as its issue is (what was changed here let go).
  Future<void> takeRemote(int id) async {
    final url = store.byId(id)?.ownIssue;
    if (url == null) return;
    var item = _items[url];
    if (refOf(url) case final ref?) {
      if (accounts.apiOf(ref) case final api?) item = await api.item(ref);
    }
    if (item == null) return;
    _items[url] = item;
    await store.reload();
    await store.update(id, (note) {
      note.syncedRemote = null;
      note.synced = null;
      _takeOwn(note, item!);
    });
    notifyListeners();
  }

  /// [id]'s stash no more its issue, nor made one: kept here. The issue is
  /// not made a stash again.
  Future<void> keepLocal(int id) async {
    final note = store.byId(id);
    if (note == null) return;
    final own = note.ownIssue;
    if (own != null) await store.ignoreIssue(own);
    await store.reload();
    await store.update(id, (note) {
      note
        ..issue = null
        ..local = true
        ..synced = null
        ..syncedRemote = null;
      if (own != null) note.issues.removeWhere((link) => link.url == own);
    }, touch: false);
  }

  /// [id]'s stash may be made an issue again (see [keepLocal]).
  Future<void> allowIssue(int id) =>
      store.update(id, (note) => note.local = false, touch: false);

  /// [text] as it goes to [repo]'s issue: its pictures (in the stash's
  /// folder) put there and linked by their address, its other files'
  /// links their names.
  Future<String> _outgoing(ForgeApi api, ForgeRepo repo, String text) async {
    final out = StringBuffer();
    var at = 0;
    for (final match in _links.allMatches(text)) {
      final target = _targetOf(match);
      if (_remote(target)) continue;
      out.write(text.substring(at, match.start));
      at = match.end;
      final bytes = await store.disk.readAsset(_decoded(target));
      final image = match[1]!.isNotEmpty || _isImage(target);
      if (bytes != null && image) {
        final address = await api.uploadImage(
          repo,
          target.split('/').last,
          bytes,
        );
        out.write('${match[1]}[${match[2]}]($address${match[4]})');
      } else {
        out.write(match[2]!.isEmpty ? target.split('/').last : match[2]);
      }
    }
    out.write(text.substring(at));
    return out.toString();
  }

  /// A Markdown link or picture: `!`, its text, its address, its title.
  static final _links = RegExp(
    r'(!?)\[([^\]\n]*)\]\((<[^>\n]+>|[^)\s]+)((?:\s+"[^"\n]*")?)\)',
  );

  static String _targetOf(Match match) {
    final target = match[3]!;
    return target.startsWith('<')
        ? target.substring(1, target.length - 1)
        : target;
  }

  /// How many pictures in [text] are this machine's (to be put where its
  /// issue can show them).
  static int localPictures(String text) => {
    for (final match in _links.allMatches(text))
      if (_targetOf(match) case final target
          when !_remote(target) && (match[1]!.isNotEmpty || _isImage(target)))
        target,
  }.length;

  static String _decoded(String target) {
    try {
      return Uri.decodeFull(target);
    } on FormatException {
      return target;
    }
  }

  static bool _remote(String target) =>
      RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false).hasMatch(target) ||
      target.startsWith('#');

  static bool _isImage(String target) => RegExp(
    r'\.(png|jpe?g|gif|webp|svg|bmp)$',
    caseSensitive: false,
  ).hasMatch(target);

  // --- Imported ------------------------------------------------------------------

  /// The stash [url]'s issue is in, if one is.
  StashNote? stashOf(String url) {
    for (final note in store.notes) {
      if (note.issueOf(url) != null) return note;
    }
    return null;
  }

  /// A stash for each of [items] not in one yet, about [project]: the
  /// issue, kept in step with it (picked by the user: made a stash again
  /// though it was deleted). The stashes, those already there among them.
  Future<List<StashNote>> import(
    List<ForgeItem> items, {
    String? project,
  }) async {
    final notes = <StashNote>[];
    for (final item in items) {
      final url = item.ref.url.toString();
      if (stashOf(url) case final known?) {
        notes.add(known);
        continue;
      }
      await store.unignoreIssue(url);
      notes.add(await _create(item, project: project));
    }
    notifyListeners();
    return notes;
  }
}
