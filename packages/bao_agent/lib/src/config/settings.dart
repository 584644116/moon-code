import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../util/json.dart';
import 'paths.dart';

/// Where a setting came from, lowest precedence first.
enum SettingsSource {
  user('userSettings'),
  project('projectSettings'),
  local('localSettings'),
  flag('flagSettings'),
  policy('policySettings'),
  session('session'),
  cliArg('cliArg');

  const SettingsSource(this.wire);

  /// As the protocol names it (`destination` of a permission update).
  final String wire;

  static SettingsSource? parse(Object? name) =>
      values.where((source) => source.wire == name).firstOrNull;
}

/// A permission rule and where it was set.
class SourcedRule {
  const SourcedRule(this.rule, this.behavior, this.source, {this.root});

  /// `Bash(npm run test:*)`, `Read(//Users/me/**)`, `WebFetch`…
  final String rule;

  /// `allow`, `deny` or `ask`.
  final String behavior;
  final SettingsSource source;

  /// The folder a rule's `/path` is relative to: its settings file's.
  final String? root;
}

/// A hook group (`{matcher, hooks}`) and where it was set.
class SourcedHooks {
  const SourcedHooks(this.event, this.matcher, this.hooks, this.source);

  final String event;
  final String? matcher;
  final List<Map<String, Object?>> hooks;
  final SettingsSource source;
}

/// The settings in effect: the user's, the project's, its local ones, those
/// the session was started with and the organisation's, each over the one
/// before; permission rules and hooks from all of them.
class AgentSettings {
  AgentSettings({
    required this.paths,
    required this.cwd,
    Map<String, Object?> flag = const {},
    Map<SettingsSource, Map<String, Object?>>? layers,
  }) {
    _layers = layers ?? _read(paths, cwd);
    _layers[SettingsSource.flag] = {...flag};
  }

  final AgentPaths paths;
  final String cwd;
  late Map<SettingsSource, Map<String, Object?>> _layers;

  /// Rules allowed or denied for this session only, as the user answered.
  final List<SourcedRule> sessionRules = [];

  Map<String, Object?>? _merged;

  static Map<SettingsSource, Map<String, Object?>> _read(
    AgentPaths paths,
    String cwd,
  ) => {
    SettingsSource.user: readJson(paths.userSettings),
    SettingsSource.project: readJson(p.join(cwd, '.claude', 'settings.json')),
    SettingsSource.local: readJson(
      p.join(cwd, '.claude', 'settings.local.json'),
    ),
    SettingsSource.policy: readJson(
      p.join(AgentPaths.managedDir, 'managed-settings.json'),
    ),
  };

  /// The JSON object in [path]; empty when there is none or it is not one.
  static Map<String, Object?> readJson(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return {};
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map ? decoded.cast<String, Object?>() : {};
    } on Object {
      return {};
    }
  }

  /// Reads the files again (one changed on disk, a rule saved).
  void reload() {
    final flag = _layers[SettingsSource.flag] ?? {};
    _layers = _read(paths, cwd)..[SettingsSource.flag] = flag;
    _merged = null;
  }

  /// Lays [settings] over those the session started with
  /// (`apply_flag_settings`).
  void applyFlag(Map<String, Object?> settings) {
    _layers[SettingsSource.flag] = mergeSettings(
      _layers[SettingsSource.flag] ?? {},
      settings,
    );
    _merged = null;
  }

  Map<String, Object?> layer(SettingsSource source) => _layers[source] ?? {};

  /// All of them, merged.
  Map<String, Object?> get merged {
    if (_merged case final merged?) return merged;
    var result = <String, Object?>{};
    for (final source in const [
      SettingsSource.user,
      SettingsSource.project,
      SettingsSource.local,
      SettingsSource.flag,
      SettingsSource.policy,
    ]) {
      result = mergeSettings(result, _layers[source] ?? {});
    }
    return _merged = result;
  }

  Object? operator [](String key) => merged[key];

  /// The environment the settings add (`env`).
  Map<String, String> get env => {
    for (final MapEntry(:key, :value) in asMap(merged['env']).entries)
      if (value != null) key: '$value',
  };

  String? get model => asText(merged['model']);

  /// Whether the model thinks: unset leaves it to the model.
  bool? get alwaysThinkingEnabled => asBool(merged['alwaysThinkingEnabled']);

  /// The effort set for [model] (`modelSettings`), else for all.
  String? effortFor(String model) =>
      asText(asMap(asMap(merged['modelSettings'])[model])['effortLevel']) ??
      asText(merged['effortLevel']);

  int? get autoCompactWindow => asInt(merged['autoCompactWindow']);

  /// How long a permission question waits for the user before it is taken
  /// as a no; null when it waits as long as the session does. Ten minutes
  /// by default.
  Duration? get approvalTimeout {
    final permissions = asMap(merged['permissions']);
    final raw = permissions['approvalTimeoutSeconds'];
    if (raw == null) return const Duration(minutes: 10);
    final seconds = asInt(raw);
    if (seconds == null) return const Duration(minutes: 10);
    return seconds <= 0 ? null : Duration(seconds: seconds);
  }

  String? get defaultMode =>
      asText(asMap(merged['permissions'])['defaultMode']);

  /// The `contextManagement` settings: folding ranges, offloading large
  /// results, and the nudge that says the context has grown.
  Map<String, Object?> get contextManagement =>
      asMap(merged['contextManagement']);

  bool get contextManagementEnabled => contextManagement['enabled'] != false;

  bool get contextCompressEnabled => contextManagement['compress'] != false;

  int get contextNudgeTokens => _contextInt('nudgeGrowthTokens', 50000);

  int get contextMinCompressTokens => _contextInt('minCompressTokens', 2000);

  int get contextMaxCompressTokens => _contextInt('maxCompressTokens', 60000);

  int get contextKeepRecentTurns => _contextInt('keepRecentTurns', 2);

  int get contextCcrMinTokens => _contextInt('ccrMinTokens', 8000);

  int get contextCcrPreviewChars => _contextInt('ccrPreviewChars', 300);

  int get contextRetrieveInlineChars =>
      _contextInt('retrieveInlineChars', 20000);

  int _contextInt(String key, int fallback) {
    final value = asInt(contextManagement[key]);
    return value == null || value < 0 ? fallback : value;
  }

  bool get disableAllHooks => merged['disableAllHooks'] == true;

  bool? get useAutoModeDuringPlan => asBool(merged['useAutoModeDuringPlan']);

  String? get apiKeyHelper => asText(merged['apiKeyHelper']);

  String get plansDirectory => switch (asText(merged['plansDirectory'])) {
    final dir? => p.isAbsolute(dir) ? dir : p.join(cwd, paths.expandHome(dir)),
    null => paths.defaultPlansDir,
  };

  /// The trailer commits end with and the line pull requests end with;
  /// null leaves the agent's own, empty asks for none.
  ({String? commit, String? pr}) get attribution {
    final attribution = merged['attribution'];
    if (attribution is Map) {
      return (
        commit: asString(attribution['commit']),
        pr: asString(attribution['pr']),
      );
    }
    if (merged['includeCoAuthoredBy'] == false) return (commit: '', pr: '');
    return (commit: null, pr: null);
  }

  /// The plugins switched on (`enabledPlugins`), by `name@marketplace`.
  Map<String, bool> get enabledPlugins => {
    for (final MapEntry(:key, :value) in asMap(
      merged['enabledPlugins'],
    ).entries)
      if (value is bool) key: value,
  };

  /// The folders the agent may work in besides the project.
  List<String> get additionalDirectories => [
    for (final dir in asList(
      asMap(merged['permissions'])['additionalDirectories'],
    ))
      if (dir is String && dir.isNotEmpty)
        p.normalize(
          p.isAbsolute(paths.expandHome(dir))
              ? paths.expandHome(dir)
              : p.join(cwd, dir),
        ),
  ];

  /// Every permission rule, from every source, the session's own last.
  List<SourcedRule> get rules => [
    for (final source in const [
      SettingsSource.policy,
      SettingsSource.flag,
      SettingsSource.local,
      SettingsSource.project,
      SettingsSource.user,
    ])
      for (final behavior in const ['deny', 'ask', 'allow'])
        for (final rule in asList(
          asMap(_layers[source]?['permissions'])[behavior],
        ))
          if (rule is String && rule.trim().isNotEmpty)
            SourcedRule(
              rule.trim(),
              behavior,
              source,
              root: switch (source) {
                SettingsSource.user => paths.configDir,
                SettingsSource.policy => AgentPaths.managedDir,
                _ => cwd,
              },
            ),
    ...sessionRules,
  ];

  /// The hook groups of every source, unless hooks are turned off (the
  /// organisation's still run then, as it may require them).
  List<SourcedHooks> get hooks {
    final managedOnly =
        asMap(_layers[SettingsSource.policy])['allowManagedHooksOnly'] == true;
    return [
      for (final source in const [
        SettingsSource.policy,
        SettingsSource.user,
        SettingsSource.project,
        SettingsSource.local,
        SettingsSource.flag,
      ])
        if (!managedOnly || source == SettingsSource.policy)
          if (!disableAllHooks || source == SettingsSource.policy)
            for (final MapEntry(key: event, value: groups) in asMap(
              _layers[source]?['hooks'],
            ).entries)
              for (final group in asList(groups))
                if (group is Map)
                  SourcedHooks(event, asString(group['matcher']), [
                    for (final hook in asList(group['hooks']))
                      if (hook is Map) hook.cast<String, Object?>(),
                  ], source),
    ];
  }

  /// The settings file [source] is kept in; null for those not in one.
  String? fileOf(SettingsSource source) => switch (source) {
    SettingsSource.user => paths.userSettings,
    SettingsSource.project => p.join(cwd, '.claude', 'settings.json'),
    SettingsSource.local => p.join(cwd, '.claude', 'settings.local.json'),
    _ => null,
  };

  /// Adds [rules] (as [behavior]) to [destination]: its file, or the
  /// session. Saved rules are read back at once.
  void addRules(
    List<String> rules,
    String behavior,
    SettingsSource destination,
  ) {
    final file = fileOf(destination);
    if (file == null) {
      for (final rule in rules) {
        sessionRules.add(SourcedRule(rule, behavior, SettingsSource.session));
      }
      return;
    }
    editJson(file, (json) {
      final permissions = {...asMap(json['permissions'])};
      final list = [...asList(permissions[behavior])];
      for (final rule in rules) {
        if (!list.contains(rule)) list.add(rule);
      }
      permissions[behavior] = list;
      json['permissions'] = permissions;
    });
    reload();
  }

  /// Adds [directories] to those of [destination]'s file (for the session
  /// alone, the caller keeps them).
  void addDirectories(List<String> directories, SettingsSource destination) {
    final file = fileOf(destination);
    if (file == null) return;
    editJson(file, (json) {
      final permissions = {...asMap(json['permissions'])};
      final list = [...asList(permissions['additionalDirectories'])];
      for (final dir in directories) {
        if (!list.contains(dir)) list.add(dir);
      }
      permissions['additionalDirectories'] = list;
      json['permissions'] = permissions;
    });
    reload();
  }

  /// Changes the JSON object in [path] with [edit], and writes it back
  /// whole, made if it was not there.
  static void editJson(String path, void Function(Map<String, Object?>) edit) {
    final json = readJson(path);
    edit(json);
    final file = File(path);
    file.parent.createSync(recursive: true);
    final temp = File('$path.${DateTime.now().microsecondsSinceEpoch}.tmp');
    temp.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(json)}\n',
    );
    temp.renameSync(path);
  }
}
