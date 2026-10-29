import 'bot_folders.dart';

/// None on the web.
class DataBotFolders implements BotFolders {
  @override
  String? get root => null;

  @override
  void make(String folder) {}

  @override
  void delete(String folder) {}

  @override
  String readMemory(String folder) => '';

  @override
  void writeMemory(String folder, String text) {}
}
