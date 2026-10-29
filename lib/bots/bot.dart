import 'package:bao_link/bao_link.dart' show BotAbility, BotProactive;
import 'package:path/path.dart' as p;

export 'package:bao_link/bao_link.dart' show BotAbility, BotProactive;

/// A bot as the user made it: who it is ([identity], [gender], [style],
/// their words), what it
/// may do ([abilities]), when it may write first ([proactive]). Its
/// conversation runs in a folder of its own ([folder]), where its memory
/// is kept too (see bot_store.dart).
class Bot {
  const Bot({
    required this.id,
    required this.name,
    required this.folder,
    this.avatar,
    this.gender = '',
    this.signature = '',
    this.identity = '',
    this.style = '',
    this.abilities = const {},
    this.proactive = const BotProactive(),
    this.model,
    this.assistant = false,
  });

  /// [json] as kept, its folder in [root].
  static Bot? fromJson(Object? json, {required String root}) => switch (json) {
    {'id': final String id, 'name': final String name} => Bot(
      id: id,
      name: name,
      folder: p.join(root, id),
      avatar: json['avatar'] as String?,
      gender: json['gender'] as String? ?? '',
      signature: json['signature'] as String? ?? '',
      identity: json['identity'] as String? ?? '',
      style: json['style'] as String? ?? '',
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
      model: json['model'] as String?,
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

  /// As the user put it: a word, or none.
  final String gender;

  /// A line under its name, as the user wrote it.
  final String signature;

  /// Who it is, as the user wrote it.
  final String identity;

  /// How it talks, as the user wrote it.
  final String style;
  final Set<BotAbility> abilities;
  final BotProactive proactive;

  /// The model it runs on; none for the app's.
  final String? model;

  /// The one the app starts with, which is not deleted.
  final bool assistant;

  bool can(BotAbility ability) => abilities.contains(ability);

  Bot copyWith({
    String? name,
    String? avatar,
    bool clearAvatar = false,
    String? gender,
    String? signature,
    String? identity,
    String? style,
    Set<BotAbility>? abilities,
    BotProactive? proactive,
    String? model,
  }) => Bot(
    id: id,
    name: name ?? this.name,
    folder: folder,
    avatar: clearAvatar ? null : avatar ?? this.avatar,
    gender: gender ?? this.gender,
    signature: signature ?? this.signature,
    identity: identity ?? this.identity,
    style: style ?? this.style,
    abilities: abilities ?? this.abilities,
    proactive: proactive ?? this.proactive,
    model: model ?? this.model,
    assistant: assistant,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'avatar': ?avatar,
    if (gender.isNotEmpty) 'gender': gender,
    if (signature.isNotEmpty) 'signature': signature,
    'identity': identity,
    if (style.isNotEmpty) 'style': style,
    'abilities': [
      for (final ability in BotAbility.values)
        if (abilities.contains(ability)) ability.name,
    ],
    'proactive': proactive.toJson(),
    'model': ?model,
    if (assistant) 'assistant': true,
  };
}
