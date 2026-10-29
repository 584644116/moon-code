import 'package:bao_link/bao_link.dart' show BotAbility, BotProactive;
import 'package:path/path.dart' as p;

export 'package:bao_link/bao_link.dart' show BotAbility, BotProactive;

/// A bot as the user made it: who it is ([identity], their words), what it
/// may do ([abilities]), when it may write first ([proactive]). Its
/// conversation runs in a folder of its own ([folder]), where its memory
/// is kept too (see bot_store.dart).
class Bot {
  const Bot({
    required this.id,
    required this.name,
    required this.folder,
    this.avatar,
    this.identity = '',
    this.abilities = const {},
    this.proactive = const BotProactive(),
    this.assistant = false,
  });

  /// [json] as kept, its folder in [root].
  static Bot? fromJson(Object? json, {required String root}) => switch (json) {
    {'id': final String id, 'name': final String name} => Bot(
      id: id,
      name: name,
      folder: p.join(root, id),
      avatar: json['avatar'] as String?,
      identity: json['identity'] as String? ?? '',
      abilities: {
        for (final name in (json['abilities'] as List?) ?? const [])
          ?BotAbility.values.asNameMap()[name],
      },
      proactive: switch (json['proactive']) {
        final Map<String, Object?> proactive => BotProactive.fromJson(
          proactive,
        ),
        _ => const BotProactive(),
      },
      assistant: json['assistant'] == true,
    ),
    _ => null,
  };

  final String id;
  final String name;

  /// Where its conversation runs, and its memory is kept.
  final String folder;

  /// An emoji; none for its name's first letter.
  final String? avatar;

  /// Who it is and how it talks, as the user wrote it.
  final String identity;
  final Set<BotAbility> abilities;
  final BotProactive proactive;

  /// The one the app starts with, which is not deleted.
  final bool assistant;

  bool can(BotAbility ability) => abilities.contains(ability);

  Bot copyWith({
    String? name,
    String? avatar,
    bool clearAvatar = false,
    String? identity,
    Set<BotAbility>? abilities,
    BotProactive? proactive,
  }) => Bot(
    id: id,
    name: name ?? this.name,
    folder: folder,
    avatar: clearAvatar ? null : avatar ?? this.avatar,
    identity: identity ?? this.identity,
    abilities: abilities ?? this.abilities,
    proactive: proactive ?? this.proactive,
    assistant: assistant,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'avatar': ?avatar,
    'identity': identity,
    'abilities': [
      for (final ability in BotAbility.values)
        if (abilities.contains(ability)) ability.name,
    ],
    'proactive': proactive.toJson(),
    if (assistant) 'assistant': true,
  };
}
