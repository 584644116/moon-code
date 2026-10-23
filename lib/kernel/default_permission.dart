/// Settings → General → Claude Code: the permission mode a new agent
/// starts in (`chat.defaultPermissionMode`), as Claude Code's
/// `permissions.defaultMode`.
///
/// The last mode picked in a conversation is deliberately not carried
/// over: full access (or any other mode) chosen for one task would
/// otherwise start every new agent in it. A conversation keeps its own
/// choice while it is open, and comes back to it when reopened.
enum DefaultPermission {
  /// Ask before acting: Claude Code's own default.
  ask('default'),

  /// Accept the edits it proposes without asking.
  acceptEdits('acceptEdits'),

  /// Act on its own, within the rules set for it.
  auto('auto');

  const DefaultPermission(this.mode);

  /// The mode as `--permission-mode` names it.
  final String mode;

  static const settingKey = 'chat.defaultPermissionMode';
  static const fallback = DefaultPermission.ask;

  static DefaultPermission parse(Object? setting) => switch (setting) {
    'acceptEdits' => DefaultPermission.acceptEdits,
    'auto' => DefaultPermission.auto,
    _ => fallback,
  };

  /// Read as each new agent starts, after the user's settings.json
  /// changes; none where there are no settings (tests), the fallback then.
  static DefaultPermission Function()? current;

  static DefaultPermission now() => current?.call() ?? fallback;
}
