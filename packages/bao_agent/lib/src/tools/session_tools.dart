import 'dart:io';

import '../engine/session.dart';
import '../permissions/decision.dart';
import '../util/json.dart';
import 'tool.dart';

/// Keeps the agent's todo list.
class TodoWriteTool extends Tool {
  const TodoWriteTool();

  @override
  String get name => 'TodoWrite';

  @override
  String get description => '''维护本次会话的待办清单，用户会在对话旁看到它。每次调用都会替换整个列表：每次都发送全部条目及其状态（pending、in_progress 或 completed）。

工作有好几步（三步及以上）时、用户给出一串要做的事时、或这能让用户看清你的进度时，用它。只改一处、或一个问题就能回答时，不要用。

推进过程中：
- 开始时先把步骤写下来；发现新的就补上，不再重要的就删掉。
- 始终只保留一项 in_progress：开始前标上，做完立刻完成它，不要拖到后面和其他项一起完成。
- 只有确实做完才标记完成。测试没过、错误未解决、工作只做了一半，它保持 in_progress，并新增一条说明卡在哪里。
- 每条都写两遍：content 说要做什么（"运行测试"），activeForm 说正在做什么（"正在运行测试"）。''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'todos': {
        'type': 'array',
        'description': '当前完整的列表',
        'items': {
          'type': 'object',
          'properties': {
            'content': {'type': 'string', 'minLength': 1},
            'status': {
              'type': 'string',
              'enum': ['pending', 'in_progress', 'completed'],
            },
            'activeForm': {'type': 'string', 'minLength': 1},
          },
          'required': ['content', 'status', 'activeForm'],
          'additionalProperties': false,
        },
      },
    },
    'required': ['todos'],
    'additionalProperties': false,
  };

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAllow();

  @override
  bool isConcurrencySafe(Map<String, Object?> input) => false;

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final key = context.run.contextKey;
    final old = context.session.todos[key] ?? const [];
    final todos = [
      for (final raw in asList(input['todos']))
        {
          'content': '${asMap(raw)['content'] ?? ''}',
          'status': '${asMap(raw)['status'] ?? 'pending'}',
          'activeForm':
              '${asMap(raw)['activeForm'] ?? asMap(raw)['content'] ?? ''}',
        },
    ];
    // All done: the list is cleared.
    final kept = todos.every((todo) => todo['status'] == 'completed')
        ? <Map<String, Object?>>[]
        : todos;
    context.session.todos[key] = kept;
    return ToolOutput(
      'The to-do list is updated. Keep it current as you work, and go on with '
      'the item in progress.',
      result: {'oldTodos': old, 'newTodos': todos},
    );
  }
}

/// Puts questions to the user, with options to pick.
class AskUserQuestionTool extends Tool {
  const AskUserQuestionTool();

  @override
  String get name => 'AskUserQuestion';

  @override
  String get description => '''向用户提一到四个选择题并等待回答：用于偏好、尚未确定的要求，或在几种做法之间由用户来定的选择。自己能查到的（读代码或跑一下）就不要问。

- 每个问题给两到四个选项：一个简短的标签，再加一句说明选中它意味着什么。用户随时可以自己写答案，所以不要加"其他"选项。
- 设 multiSelect 时，可以选多个。
- 如果你自己会选其中一个，把它放在第一位，并在标签末尾加"（推荐）"。
- 计划模式下，趁计划还没定下来时问。要让计划获批，调用 ExitPlanMode；不要问计划是否已经就绪。''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'questions': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 4,
        'description': '一到四个问题',
        'items': {
          'type': 'object',
          'properties': {
            'question': {
              'type': 'string',
              'description':
                  '完整的问题，以问号结尾',
            },
            'header': {
              'type': 'string',
              'description': '最多 12 个字符的标签，概括这个问题，例如 "Database" 或 "Scope"',
            },
            'options': {
              'type': 'array',
              'minItems': 2,
              'maxItems': 4,
              'description': '两到四个选项；用户随时可以自己写答案',
              'items': {
                'type': 'object',
                'properties': {
                  'label': {
                    'type': 'string',
                    'description': '选项，一到五个词',
                  },
                  'description': {
                    'type': 'string',
                    'description':
                        '选中它意味着什么，或之后会发生什么',
                  },
                  'preview': {
                    'type': 'string',
                    'description': '选项获得焦点时显示在旁边：布局草图、代码示例',
                  },
                },
                'required': ['label', 'description'],
              },
            },
            'multiSelect': {
              'type': 'boolean',
              'default': false,
              'description': '是否允许选多个选项',
            },
          },
          'required': ['question', 'header', 'options', 'multiSelect'],
        },
      },
      'answers': {
        'type': 'object',
        'description': '用户的回答，由宿主填入',
      },
      'annotations': {
        'type': 'object',
        'description':
            '用户对这些问题的备注，由宿主填入',
      },
      'metadata': {'type': 'object', 'description': '供宿主自用'},
    },
    'required': ['questions'],
    'additionalProperties': false,
  };

  @override
  bool get requiresUserInteraction => true;

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  @override
  bool isConcurrencySafe(Map<String, Object?> input) => false;

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAsk(
    message: 'Answer questions?',
    requiresUserInteraction: true,
    classifierApprovable: false,
  );

  @override
  Future<String?> validate(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final questions = asList(input['questions']);
    final texts = <String>{};
    for (final q in questions) {
      final question = '${asMap(q)['question'] ?? ''}';
      if (!texts.add(question)) return 'Question texts must be unique';
      final labels = <String>{};
      for (final option in asList(asMap(q)['options'])) {
        if (!labels.add('${asMap(option)['label'] ?? ''}')) {
          return 'Option labels must be unique within each question';
        }
      }
    }
    return null;
  }

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final answers = asMap(input['answers']);
    if (answers.isEmpty) {
      return ToolOutput.error('The user did not answer the questions.');
    }
    final said = [
      for (final MapEntry(:key, :value) in answers.entries) '"$key"="$value"',
    ].join(', ');
    return ToolOutput(
      'The user answered: $said. Carry on with these answers.',
      result: {'questions': input['questions'], 'answers': answers},
    );
  }
}

/// Enters plan mode: the agent explores and plans before it changes
/// anything.
class EnterPlanModeTool extends Tool {
  const EnterPlanModeTool();

  @override
  String get name => 'EnterPlanMode';

  @override
  String get description => '''经用户同意后把会话切到计划模式：你只做探索并写计划，在用户批准之前不做其他改动（ExitPlanMode）。

工作的形态还没定下来时，值得这么做：需要做设计决策的功能、跨多个文件或改变现有代码行为的改动、有不止一种合理做法的任务，或必须先调研才能说清涉及什么的任务。小而明确的修复、已经写明具体做法的指令、只需阅读就能回答的问题，不要用。

计划模式下，读代码看现在是怎么做的，定下方案，需要用户拿主意的地方用 AskUserQuestion 问，把计划写进计划文件，然后调用 ExitPlanMode。''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': <String, Object?>{},
    'additionalProperties': false,
  };

  @override
  bool get changesMode => true;

  @override
  bool isEnabled(AgentSession session) => session.permissionMode != 'plan';

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAsk(message: 'Enter plan mode?');

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    if (!context.run.isMain) {
      return ToolOutput.error('Only the main agent can enter plan mode.');
    }
    context.session.setPermissionMode('plan', byModel: true);
    return ToolOutput(
      'Plan mode is on. Explore and design, changing nothing but the plan '
      'file: read the code, see how similar things are done here, weigh the '
      'approaches, ask the user where a choice is theirs (AskUserQuestion), '
      'then write the plan to the plan file and call ExitPlanMode.',
      result: {'message': 'Entered plan mode'},
    );
  }
}

/// Puts the plan written to the user, to be started.
class ExitPlanModeTool extends Tool {
  const ExitPlanModeTool();

  @override
  String get name => 'ExitPlanMode';

  @override
  String get description => '''请用户批准你写进计划文件的计划（文件名在计划模式提示里）；用户批准后，计划模式结束。计划是从那个文件读的，所以要先把计划写进去：用户看到的就是这个文件。

只在计划完成时调用，且只用于会改动代码的工作，不要用它汇报调研发现。未定的事项先用 AskUserQuestion 敲定；不要问计划是否就绪：调用这个工具本身就是在问。''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'plan': {
        'type': 'string',
        'description': '计划内容，未写入计划文件时提供（否则从文件读取）',
      },
    },
    'additionalProperties': true,
  };

  @override
  bool get changesMode => true;

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  /// The plan written, and where, for the user to see.
  @override
  Map<String, Object?> observableInput(
    Map<String, Object?> input,
    AgentSession session,
  ) {
    if (input['plan'] is String && input['planFilePath'] is String) {
      return input;
    }
    final path = session.planFilePath;
    String? plan = asString(input['plan']);
    if (plan == null) {
      try {
        plan = File(path).readAsStringSync();
      } on FileSystemException {
        plan = null;
      }
    }
    return {...input, 'plan': ?plan, 'planFilePath': path};
  }

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAsk(
    message: 'Exit plan mode?',
    requiresUserInteraction: true,
    classifierApprovable: false,
  );

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final session = context.session;
    final path = session.planFilePath;
    String? plan = asText(input['plan']);
    final file = File(path);
    if (plan == null && file.existsSync()) plan = file.readAsStringSync();
    if (session.permissionMode == 'plan') {
      session.setPermissionMode(
        session.modeBeforePlan ?? 'default',
        byModel: true,
      );
    }
    return ToolOutput(
      plan == null
          ? 'Plan mode is over: go ahead.'
          : 'The user approved your plan. Carry it out, starting with your '
                'to-do list if you keep one.\n\n'
                'The plan is kept at $path for reference.\n\n'
                '## The approved plan\n$plan',
      result: {'plan': plan, 'isAgent': !context.run.isMain, 'filePath': path},
    );
  }
}
