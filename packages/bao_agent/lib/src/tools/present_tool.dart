import '../permissions/decision.dart';
import '../util/json.dart';
import 'tool.dart';

/// The most files one call hands over.
const presentMaxFiles = 8;

/// Hands the user what was delivered: the files to open first, and a line
/// on each. The app shows them as a card, not as another step of the work.
class PresentTool extends Tool {
  const PresentTool();

  @override
  String get name => 'Present';

  @override
  List<String> get aliases => const ['present'];

  @override
  String get description => '''把你交付的成果交给用户：最多八个文件，每个附一句说明它是什么。应用会在对话旁以卡片展示，用户不用读完整轮就能打开。

当工作产出了可看或可留存的东西时用它：报告、页面、图片、一组文档。每个文件的路径按项目中的写法给出；说明里写清它为什么在这儿（"摘要"、"幻灯片"）。用户只是要求改一个文件、或答案只有文字时，不要用。''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'summary': {
        'type': 'string',
        'description': '一句话说明交付了什么',
      },
      'files': {
        'type': 'array',
        'minItems': 1,
        'maxItems': presentMaxFiles,
        'description': '要展示的文件，第一个排在最前',
        'items': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'minLength': 1},
            'note': {
              'type': 'string',
              'description': '这是什么，几个词说明',
            },
          },
          'required': ['path'],
          'additionalProperties': false,
        },
      },
    },
    'required': ['files'],
    'additionalProperties': false,
  };

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAllow();

  @override
  bool isConcurrencySafe(Map<String, Object?> input) => true;

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final seen = <String>{};
    final notes = <String, String>{};
    final files = <String>[];
    for (final raw in asList(input['files'])) {
      final file = asMap(raw);
      final path = '${file['path'] ?? ''}'.trim();
      if (path.isEmpty || !seen.add(path)) continue;
      notes[path] = '${file['note'] ?? ''}'.trim();
      files.add(path);
      if (files.length == presentMaxFiles) break;
    }
    if (files.isEmpty) {
      return ToolOutput.error('Error: present needs at least one file.');
    }
    return ToolOutput(
      'Presented ${files.length} '
      '${files.length == 1 ? 'file' : 'files'} to the user.',
      result: {
        'files': [
          for (final path in files)
            {
              'path': path,
              if (notes[path]!.isNotEmpty) 'note': notes[path],
            },
        ],
      },
    );
  }
}
