import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../forge/forge_api.dart';
import '../forge/forge_ref.dart';
import '../forge/forge_view.dart';
import '../ide/ide_button.dart';
import '../ide/ide_menu.dart';
import '../l10n/l10n.dart';
import '../settings/pages/model_dialogs.dart' show ModelDialogFrame;
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import '../workspace/editor_launcher.dart' show openExternal;
import 'stash_forge.dart';
import 'stash_note.dart';
import 'stash_view.dart' show StashBanner, StashChip;

// A stash and the issue it is (docs/stash.md): a stash of a project that
// is a Git repository is one of its issues, kept in step with it, or kept
// here alone if the user says so; one of a project that is none, here.

/// In a stash's detail, beside its status and project: the issue it is
/// (its state and number; opened, its changes sent or let go, or let go
/// itself, from its menu), else where it can be one (published, once the
/// user confirms what goes), else nothing (its project no repository).
class StashIssueChip extends StatefulWidget {
  const StashIssueChip({super.key, required this.forge, required this.note});

  final StashForge forge;
  final StashNote note;

  @override
  State<StashIssueChip> createState() => _StashIssueChipState();
}

class _StashIssueChipState extends State<StashIssueChip> {
  /// [_project]'s repositories, as last asked.
  List<ForgeRepo> _repos = const [];
  String? _project;

  @override
  void initState() {
    super.initState();
    _askRepos();
  }

  @override
  void didUpdateWidget(StashIssueChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.note.project != _project) _askRepos();
  }

  void _askRepos() {
    final project = _project = widget.note.project;
    if (project == null) {
      _repos = const [];
      return;
    }
    unawaited(
      widget.forge.reposOf(project).then((repos) {
        if (mounted && _project == project) setState(() => _repos = repos);
      }),
    );
  }

  StashForge get _forge => widget.forge;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _forge,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final l10n = context.l10n;
    final note = widget.note;
    if (note.ownIssue case final url?) {
      final ref = _forge.refOf(url);
      final link = note.issueOf(url);
      final state = link == null ? null : _forge.stateOf(link);
      return StashChip(
        icon: Codicons.issues,
        leading: ref == null ? null : ForgeStateIcon(ref.kind, state, size: 12),
        label: ref?.fullTag ?? url,
        active: true,
        onTap: (anchor) => unawaited(
          showIdeMenu(context, anchor: anchor, entries: _ownEntries(l10n, url)),
        ),
      );
    }
    if (_repos.isEmpty) return const SizedBox.shrink();
    if (note.local) {
      return StashChip(
        icon: Codicons.lock,
        label: l10n.stashIssueLocal,
        onTap: (anchor) => unawaited(
          showIdeMenu(
            context,
            anchor: anchor,
            entries: [
              IdeMenuAction(
                l10n.stashIssueAllow,
                onSelected: () => unawaited(_forge.allowIssue(note.id)),
              ),
            ],
          ),
        ),
      );
    }
    return StashChip(
      icon: Codicons.cloudUpload,
      label: l10n.stashIssueNotPublished,
      onTap: (anchor) => unawaited(
        showIdeMenu(
          context,
          anchor: anchor,
          entries: ideMenuGroups([
            [
              for (final repo in _repos)
                IdeMenuAction(
                  l10n.stashIssuePublishTo(repo.path),
                  enabled: _forge.accounts.apiFor(repo.host) != null,
                  onSelected: () => unawaited(
                    showStashIssueDialog(
                      context,
                      forge: _forge,
                      note: note,
                      repo: repo,
                    ),
                  ),
                ),
            ],
            [
              IdeMenuAction(
                l10n.stashIssueKeepLocal,
                onSelected: () => unawaited(_forge.keepLocal(note.id)),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  List<IdeMenuEntry> _ownEntries(AppLocalizations l10n, String url) {
    final note = widget.note;
    return ideMenuGroups([
      [
        IdeMenuAction(
          l10n.stashIssueOpen,
          onSelected: () => unawaited(openExternal(url)),
        ),
        IdeMenuAction(
          l10n.stashIssueCopy,
          onSelected: () =>
              unawaited(Clipboard.setData(ClipboardData(text: url))),
        ),
      ],
      [
        IdeMenuAction(
          l10n.stashIssuePush,
          enabled: note.changedHere && _forge.canAsk(url),
          onSelected: () => unawaited(
            showStashIssueDialog(context, forge: _forge, note: note),
          ),
        ),
        IdeMenuAction(
          l10n.stashIssueTakeRemote,
          enabled: note.changedHere && _forge.canAsk(url),
          onSelected: () => unawaited(_forge.takeRemote(note.id)),
        ),
      ],
      [
        IdeMenuAction(
          l10n.stashIssueUnlinkOwn,
          onSelected: () => unawaited(_forge.keepLocal(note.id)),
        ),
      ],
    ]);
  }
}

/// In a stash's detail, over its text: what was changed here is not on
/// its issue yet (send it? let it go?), or both were changed (which?).
class StashIssueSyncBanner extends StatelessWidget {
  const StashIssueSyncBanner({
    super.key,
    required this.forge,
    required this.note,
  });

  final StashForge forge;
  final StashNote note;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: forge,
    builder: (context, _) {
      final url = note.ownIssue;
      if (url == null || !note.changedHere || !forge.canAsk(url)) {
        return const SizedBox.shrink();
      }
      final l10n = context.l10n;
      final tag = forge.refOf(url)?.fullTag ?? url;
      void push() =>
          unawaited(showStashIssueDialog(context, forge: forge, note: note));
      void take() => unawaited(forge.takeRemote(note.id));
      return forge.remoteChanged(note)
          ? StashBanner(
              icon: Codicons.warning,
              iconColor: themeColors['charts.yellow'],
              text: l10n.stashIssueConflict(tag),
              actions: [
                (l10n.stashIssueKeepMine, push),
                (l10n.stashIssueKeepTheirs, take),
              ],
            )
          : StashBanner(
              icon: Codicons.cloudUpload,
              text: l10n.stashIssueChangedHere(tag),
              actions: [
                (l10n.stashIssuePushShort, push),
                (l10n.stashIssueDiscard, take),
              ],
            );
    },
  );
}

/// Publishes [note] as an issue of [repo], or (without) sends its changes
/// to the issue it is: its title and text shown as they go, what should
/// not go out (a path on this machine, a secret) pointed out, the
/// pictures that go with it counted; sent only by the user's click.
Future<void> showStashIssueDialog(
  BuildContext context, {
  required StashForge forge,
  required StashNote note,
  ForgeRepo? repo,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: false,
  barrierLabel: context.l10n.commonDismiss,
  barrierColor: const Color(0x80000000),
  transitionDuration: Duration.zero,
  pageBuilder: (context, _, _) =>
      StashIssueDialog(forge: forge, note: note, repo: repo),
);

class StashIssueDialog extends StatefulWidget {
  const StashIssueDialog({
    super.key,
    required this.forge,
    required this.note,
    this.repo,
  });

  final StashForge forge;
  final StashNote note;

  /// Where it is published; null: its changes go to its issue.
  final ForgeRepo? repo;

  @override
  State<StashIssueDialog> createState() => _StashIssueDialogState();
}

class _StashIssueDialogState extends State<StashIssueDialog> {
  var _sending = false;
  String? _error;

  ForgeRepo? get _repo =>
      widget.repo ??
      switch (widget.note.ownIssue) {
        final url? => widget.forge.refOf(url)?.repo,
        null => null,
      };

  Future<void> _send() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      if (widget.repo case final repo?) {
        await widget.forge.publish(widget.note.id, repo);
      } else {
        await widget.forge.pushEdits(widget.note.id);
      }
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = error is ForgeException ? error.message : '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final note = widget.note;
    final repo = _repo;
    final text = note.issueText;
    final title = note.displayTitle;
    final sensitive = StashForge.sensitive('$title\n$text');
    final pictures = StashForge.localPictures(text);
    final account = repo == null
        ? null
        : widget.forge.accounts.accountFor(repo.host);
    final muted = TextStyle(color: AppColors.textMuted, fontSize: 12);
    final publishing = widget.repo != null;
    return ModelDialogFrame(
      title: publishing
          ? l10n.stashIssuePublishTitle(repo?.path ?? '')
          : l10n.stashIssuePushTitle(
              widget.forge.refOf(note.ownIssue ?? '')?.fullTag ?? '',
            ),
      actions: [
        IdeButton(
          label: sensitive.isNotEmpty
              ? l10n.stashWriteSendAnyway
              : publishing
              ? l10n.stashIssuePublish
              : l10n.stashIssuePushShort,
          spinning: _sending,
          onPressed: _sending ? null : () => unawaited(_send()),
        ),
        IdeButton(
          label: l10n.commonCancel,
          secondary: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(maxHeight: 260),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.border),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: SelectableText(
                text.isEmpty ? l10n.stashIssueNoText : text,
                style: AppFonts.uiCodeStyle(12).copyWith(
                  color: text.isEmpty ? AppColors.textFaint : AppColors.text,
                  height: 1.5,
                ),
              ),
            ),
          ),
          if (pictures > 0) ...[
            const SizedBox(height: 10),
            Text(
              repo?.kind == ForgeKind.gitlab
                  ? l10n.stashIssuePicturesGitLab(pictures)
                  : l10n.stashIssuePicturesGitHub(
                      pictures,
                      GitHubApi.assetsBranch,
                    ),
              style: muted,
            ),
          ],
          if (sensitive.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              l10n.stashWriteSensitive,
              style: muted.copyWith(color: themeColors['charts.yellow']),
            ),
            for (final found in sensitive.toSet())
              Text(
                '  $found',
                style: muted.copyWith(fontFamily: AppFonts.mono),
              ),
          ],
          const SizedBox(height: 10),
          Text(
            l10n.stashWriteAs(account?.login ?? '-', repo?.host ?? ''),
            style: muted,
          ),
          if (_error case final error?) ...[
            const SizedBox(height: 10),
            SelectableText(
              l10n.stashWriteFailed(error),
              style: muted.copyWith(color: themeColors['errorForeground']),
            ),
          ],
        ],
      ),
    );
  }
}
