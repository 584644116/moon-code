import 'package:flutter/foundation.dart';

import '../workspace/workspace.dart';
import 'app_platform.dart';
import 'keep_awake_stub.dart'
    if (dart.library.io) 'keep_awake_io.dart'
    as platform;

/// Settings → General → Chat: the machine stays awake while an agent is
/// working (`chat.keepAwakeWhileRunning`), as ZCode's and PI-Desktop's
/// setting of the same name.
///
/// Off by default: a long turn asked for is still the user's to leave, and
/// the screen may turn off either way. Only where the platform offers a
/// way to ask for it (Windows today, see keep_awake_io.dart) is the row
/// shown.
abstract final class KeepAwake {
  static const settingKey = 'chat.keepAwakeWhileRunning';

  /// Off unless turned on: a setting not in the file is [off]'s.
  static bool enabled(Object? setting) => setting == true;

  /// Whether this build can hold the machine awake at all.
  static bool get supported => !kIsWeb && AppPlatform.isWindows;
}

/// Follows [workspace]: while any of its agents runs — a turn, or what it
/// started in the background — the machine is held awake, when the user
/// turned that on; once none does, it is let go.
class KeepAwakeFollow {
  KeepAwakeFollow({
    required Workspace workspace,
    required this.enabled,
    Listenable? changes,
  }) : _workspace = workspace,
       _changes = changes {
    workspace.addListener(_update);
    changes?.addListener(_update);
    _update();
  }

  /// Whether the user wants it, read each time an agent starts or stops,
  /// and when the setting itself changes.
  final bool Function() enabled;

  Workspace? _workspace;
  final Listenable? _changes;
  bool _held = false;

  void _update() {
    final workspace = _workspace;
    if (workspace == null) return;
    final running = workspace.threads.any(
      (thread) =>
          !thread.archived && thread.shownStatus == ThreadStatus.running,
    );
    final hold = running && enabled();
    if (hold == _held) return;
    _held = hold;
    platform.setKeepAwake(hold);
  }

  /// Stops following, letting the machine sleep again.
  void dispose() {
    _workspace?.removeListener(_update);
    _workspace = null;
    _changes?.removeListener(_update);
    if (_held) {
      _held = false;
      platform.setKeepAwake(false);
    }
  }
}
