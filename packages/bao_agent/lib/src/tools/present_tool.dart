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
  String get description => '''Hands the user what you delivered: at most eight files, with a line on what each is. The app shows them as a card beside the conversation, so the user can open them without reading the whole turn.

Use it when the work produced something to look at or keep: a report, a page, a picture, a set of documents. Give each file's path as the project has it; the note says why it is there ("the summary", "the slides"). Skip it for a change to one file the user asked for, and for answers that are only text.''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'summary': {
        'type': 'string',
        'description': 'One line on what was delivered',
      },
      'files': {
        'type': 'array',
        'minItems': 1,
        'maxItems': presentMaxFiles,
        'description': 'The files to show, the first first',
        'items': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'minLength': 1},
            'note': {
              'type': 'string',
              'description': 'What it is, in a few words',
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
