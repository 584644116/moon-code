import 'bot_folders_stub.dart'
    if (dart.library.io) 'bot_folders_io.dart'
    as platform;

/// Where the bots' folders are, and what is kept in each: its memory, in
/// `MEMORY.md`. Replaceable under test.
abstract interface class BotFolders {
  /// The data folder's `bots/` (none on the web).
  factory BotFolders.data() = platform.DataBotFolders;

  /// The folder holding the bots' own, and their list; null where there is
  /// none.
  String? get root;

  void make(String folder);
  void delete(String folder);

  /// What [folder]'s bot remembers; empty for nothing.
  String readMemory(String folder);
  void writeMemory(String folder, String text);
}

/// Kept only while it lives, under test.
class MemoryBotFolders implements BotFolders {
  MemoryBotFolders([this.root = '/bots']);

  @override
  final String? root;

  final Set<String> folders = {};
  final Map<String, String> memories = {};

  @override
  void make(String folder) => folders.add(folder);

  @override
  void delete(String folder) {
    folders.remove(folder);
    memories.remove(folder);
  }

  @override
  String readMemory(String folder) => memories[folder] ?? '';

  @override
  void writeMemory(String folder, String text) => memories[folder] = text;
}
