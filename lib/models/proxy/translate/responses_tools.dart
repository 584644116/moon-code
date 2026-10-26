// The tools a Responses request declares, as the two directions of the
// proxy need them: the request side sends them to an upstream as Claude's,
// and the response side needs to know how each call comes back.

import 'json_value.dart';

/// The one argument a freeform tool is sent as, since Claude's tools take
/// an object: what the model puts there is the call's `input`, as source.
const freeformInputKey = 'input';

/// A tool as a Responses request declares it.
class DeclaredTool {
  const DeclaredTool({
    required this.name,
    required this.namespace,
    required this.freeform,
    this.description = '',
    this.parameters,
  });

  /// The name the call comes back under, flattened: a namespace's members
  /// are `<namespace><name>`, the name Codex matches a call to.
  final String name;

  /// The namespace it belongs to, when it is a namespace's member: Codex
  /// needs it beside the name, as its calls carry both.
  final String? namespace;

  /// Whether it takes its input as freeform source rather than a JSON
  /// object: Codex's `exec`, answered with `custom_tool_call`.
  final bool freeform;

  final String description;

  /// A function tool's parameters, as it declared them.
  final JsonValue? parameters;
}

/// The tools [request] declares: its top-level `tools`, and the
/// `additional_tools` items of its `input` (Responses Lite, where Codex
/// declares them in the conversation instead).
List<DeclaredTool> declaredToolsOf(JsonValue request) {
  final out = <DeclaredTool>[];
  void addAll(JsonValue tools) {
    if (!tools.isArray) return;
    for (final tool in tools.array) {
      _collect(out, tool, null);
    }
  }

  addAll(request.get('tools'));
  final input = request.get('input');
  if (input.isArray) {
    for (final item in input.array) {
      if (item.get('type').string == 'additional_tools') {
        addAll(item.get('tools'));
      }
    }
  }
  return out;
}

void _collect(List<DeclaredTool> out, JsonValue tool, String? namespace) {
  final name = tool.get('name').string;
  switch (tool.get('type').string) {
    case 'function':
      if (name.isEmpty) return;
      out.add(
        DeclaredTool(
          name: namespace == null ? name : '$namespace$name',
          namespace: namespace,
          freeform: false,
          description: tool.get('description').string,
          parameters: tool.get('parameters'),
        ),
      );
    case 'custom':
      if (name.isEmpty) return;
      out.add(
        DeclaredTool(
          name: namespace == null ? name : '$namespace$name',
          namespace: namespace,
          freeform: true,
          description: tool.get('description').string,
        ),
      );
    case 'namespace':
      // Not a tool itself: its members are, flattened under its name.
      final members = tool.get('tools');
      if (!members.isArray) return;
      for (final member in members.array) {
        _collect(out, member, name);
      }
  }
}

/// [tools] by the name a call comes back under.
Map<String, DeclaredTool> toolsByName(List<DeclaredTool> tools) => {
  for (final tool in tools) tool.name: tool,
};
