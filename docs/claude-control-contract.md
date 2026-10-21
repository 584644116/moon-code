# 与 Claude Code 的接触面：BaoCode 实际依赖哪些

这份文档记录 **BaoCode 真正消费的 Claude Code 契约**，不是 CLI 的完整格式镜像。目的只有两个：改代码时知道哪一层能放心改，CLI 升级时知道先看哪里。

原则沿用 cc-switch 的做法：

- 只记产品真正消费的字段，不为了"覆盖完整"去扩后端。
- 没进界面的上游字段，不写进契约。
- 每一条契约配一个测试；上游没说死的东西，靠测试兜，不靠猜。

代码位置：`lib/kernel/claude_code/`，测试：`test/kernel_test.dart`。

## 目录

1. [三层稳定性](#1-三层稳定性)
2. [第一层：落盘产物](#2-第一层落盘产物)
3. [第二层：公开 CLI 参数](#3-第二层公开-cli-参数)
4. [第三层：control 通道](#4-第三层control-通道)
5. [容错约定](#5-容错约定)
6. [改代码时怎么用这份文档](#6-改代码时怎么用这份文档)

## 1. 三层稳定性

BaoCode 和 Claude Code 有三个接触面，稳定程度差得很远：

| 层 | 内容 | 上游怎么保证 | 坏了会怎样 |
|---|---|---|---|
| 一 | 会话 `.jsonl` 文件、`settings.json` | 落盘格式，改得慢 | 历史读不出来，不影响正在跑的会话 |
| 二 | `claude -p --input-format stream-json --output-format stream-json` 的命令行参数 | 公开文档化 | 起不来，用户立刻看见 |
| 三 | `control_request` / `control_response` 的 subtype | **没有公开承诺** | 单个功能失灵，容易被当成"偶发 bug" |

改造时的优先级是反的：**能用第一层就不用第二层，能用第二层就不用第三层**。cc-switch 完全不碰第三层，只读落盘文件，所以它升级 CLI 时几乎不用改代码——这是它的规模能这么小的原因。

## 2. 第一层：落盘产物

最稳的一层。读坏了一行，跳过那一行就行。

### 2.1 会话文件

位置：`$CLAUDE_CONFIG_DIR/projects/<编码后的 cwd>/<session id>.jsonl`，一行一个 JSON 对象。

BaoCode 消费的字段：

| 字段 | 用途 | 缺失时 |
|---|---|---|
| `uuid` | 消息身份、分支回溯的锚点 | 该行不参与分支 |
| `parentUuid` / `logicalParentUuid` | 分支树 | 视为链的起点 |
| `type` | `user` / `assistant` / `attachment` 等 | 跳过 |
| `isSidechain` / `isMeta` | 子代理消息、CLI 内部注入 | 视为普通消息 |
| `sessionId` | 会话归属 | 用文件名 |
| `cwd` | 项目归属 | 沿用上一条 |
| `timestamp` | 排序、显示时间 | `DateTime.tryParse` 失败则不排序 |
| `custom-title` / `ai-title` | 会话标题 | 用首条 prompt |
| `attachment.type == "goal_status"` | `/goal` 的落盘状态 | 无 goal |

实现：`packages/bao_remote/lib/src/claude/claude_sessions.dart`。

**已经做到的容错**（`packages/bao_remote/lib/src/claude/claude_sessions.dart:274`）：

```dart
Map<String, Object?>? _decode(String line) {
  try {
    return (jsonDecode(line) as Map).cast<String, Object?>();
  } on Object {
    return null;
  }
}
```

坏行返回 `null`，调用处用 `?_decode(line)` 收进列表时自动过滤（`claude_sessions.dart:193-196`）。**新增解析时要沿用这个写法**，不要直接 `jsonDecode`。

**未消费但已知的类型**（照 cc-switch 的做法，读到时跳过即可）：`file-history-*`、`queue-operation`、`mode`、`summary`。

### 2.2 跨机器读到的同一个文件：RPC 边界

会话文件有两种读法：本机的直接读盘，远程项目的经 SSH 到远端 `bao_remote` 再回来。**后者是另一层风险**——桌面端和远端主机可能跑着不同版本的 BaoCode。

所以 `ClaudeSessionSummary.fromJson` / `ClaudeProjectSummary.fromJson` / `ClaudeHistoryPage.fromJson` 三个解析器都改成**返回可空**：

- 缺 `id` / `cwd` / `path` 的会话 → `null`，该会话不列出，列表其余照常。
- 缺 `title` → 空标题，会话仍列出。
- `updatedAt` 是 double 或字符串 → 按数字读；完全没有 → 放在 epoch（排序最末），会话仍列出。
- 页里某一行不是 Map → 跳过该行，其余行照常。

**做法的差别**：第一层（本机读盘）的容错在"跳过一行"；这一层在"跳过一条"——因为这里一条就是一件东西。两者都不让一个坏字段带走整次请求。

测试：`test/remote/claude_wire_contract_test.dart`（12 个）。

### 2.3 设置文件

`settings.json`、`models.json`、`auth.json`。BaoCode 只读模型与 effort 相关字段，**不写凭证**。

这条边界要守住：`auth.json` 里的东西（不管是 OAuth 还是 API key）属于 Claude Code，BaoCode 不复制、不改、不删。

## 3. 第二层：公开 CLI 参数

启动命令（`lib/kernel/claude_code/claude_code_transport.dart` 的注释里记着）：

```
claude -p --input-format stream-json --output-format stream-json
```

这些参数是文档化的，改得慢。BaoCode 用的还有 `--resume`、`--model`、`--add-dir`、`--permission-mode`、`--mcp-config`（SDK server）等，见 `ClaudeLaunch` 的字段。

这一层出错是**立刻可见的**：进程起不来，会话开不了。所以它不需要额外的护栏，出问题用户马上知道，也有明确的报错。

## 4. 第三层：control 通道

最脆的一层。CLI 没有承诺过这些 subtype 存在、也没承诺过字段不变。它出错的样子最糟：某个功能悄悄失灵，看起来像偶发 bug。

### 4.1 BaoCode 发出的 subtype

| subtype | 用途 | 位置 |
|---|---|---|
| `initialize` | 建立会话，拿命令表与能力 | `claude_code_kernel.dart:576`、`:2117` |
| `set_permission_mode` | 切换权限模式 | `claude_code_kernel.dart:583`、`:3110` |
| `set_model` | 改模型 | `claude_code_kernel.dart:2569`（`_modelChange`） |
| `apply_flag_settings` | 改 effort、plan 期自动模式等 | `claude_code_kernel.dart:2710`、`:3139`、`:3245` |
| `rename_session` | 改会话标题 | `claude_code_kernel.dart:615`、`:1221` |
| `cancel_async_message` | 撤回排队消息 | `claude_code_kernel.dart:1039` |
| `rewind_conversation` | 回退对话 | `claude_code_kernel.dart:1106` |
| `rewind_files` | 回退文件 | `claude_code_kernel.dart:1190` |
| `mcp_status` | 问 MCP 服务器状态 | `claude_code_kernel.dart:1243`、`:1285` |
| `mcp_authenticate` | 触发 MCP 登录 | `claude_code_kernel.dart:1267` |
| `file_suggestions` | 输入框里的 `@` 补全 | `claude_code_kernel.dart:609`、`:1357` |
| `get_hooks_listing` | 反推 `/goal` 状态 | `claude_code_kernel.dart:1947` |
| `get_usage` | 账号用量 | `claude_code_kernel.dart:2093` |
| `get_context_usage` | 上下文窗口占用 | `claude_code_kernel.dart:2247` |
| `get_settings` | 读回生效设置 | `claude_code_kernel.dart:2601` |

`set_permission_mode` 送的是 `_mode`：Plan 时是 `plan`，否则是 `_cliApproval`。`_cliApproval` 对两种模式做了映射：Full access 以 `acceptEdits` 送（CLI 在 root 下不接受 `bypassPermissions`）；Auto 在 Claude Code 自己的分类器跑不了的模型上（另一家 provider 的、或它标注不支持 Auto 的）以 `default` 送，由 `_permission` 本地分类后直接应答。换模型时 `_selectModel` 会重发；`--resume` 的 init 回填只作为起点，随后按当前选择重发（见 `_reported` 对映射值的处理）。

### 4.2 BaoCode 应答的 subtype（CLI 发来的）

| subtype | 用途 | 位置 |
|---|---|---|
| `can_use_tool` | 工具权限请求 | `claude_code_kernel.dart:1740` |
| `elicitation` | MCP 服务器要用户填表 / 开链接 | `claude_code_kernel.dart:1742` |
| `mcp_message` | SDK MCP server 的工具调用 | `claude_code_kernel.dart:1744` |

### 4.3 `control_response` 的配对

请求带 `request_id`（形如 `baocode-N`），应答按 `request_id` 配回去，默认超时 60 秒（`lib/kernel/claude_code/control_channel.dart`）。

**改 subtype 名称、改字段名，都要同步改本文档和对应测试。** 不要让第三层的知识只活在代码里。

### 4.4 最特殊的一个：`/goal`

`/goal` 的状态是**反推**的，不是直接读的（`lib/kernel/claude_code/claude_goal.dart`）：

- `get_hooks_listing` 返回里 `source=sessionHook`、`type=prompt` 的 Stop hook；
- 会话文件里的 `goal_status` 行。

CLI 的输出几乎不提 goal。**这是三层里最脆的一处**：两处反推都失效时，goal 功能整个消失，而且没有任何报错。改这块要格外小心，也必须配测试。

已经加上的护栏（这次补的）：

- `hookedGoal`（`lib/kernel/claude_code/claude_goal.dart`）不再 `listing['hooks'] as List`，改用 `_list()`：`hooks` 不是列表时返回"没有 goal"，而不是抛异常。
- `keptGoal` 里的 `iterations` / `tokens` 改用 `_int()`：写成 double 或字符串也读得出来。
- `_readGoalNow`（`claude_code_kernel.dart:1939`）整体包了 `try/catch`。**这条最关键**：它是个没人 await 的 future，抛出的异常没有任何调用者能接住，goal 会静默消失，日志里只有一条 unhandled future 错误。现在异常被就地接住并 `debugPrint`，goal 下次问起时重新推导，不留半成品状态。

## 5. 容错约定

### 5.1 读上游数据：不抛，不丢

**规则**：读 CLI 给的任何字段，都不假设类型。

`lib/kernel/claude_code/claude_code_translator.dart` 底部有四个辅助函数（`_string`、`_int`、`_text`、`_bool`），它们对任何输入都返回 `null` 而不是抛异常：

```dart
/// A whole number, however it was written: a proxy may send one as a
/// double, or as the text of one.
static int? _int(Object? value) => switch (value) {
  final int value => value,
  final num value => value.toInt(),
  final String value => int.tryParse(value.trim()),
  _ => null,
};
```

**为什么要有 `_int` 而不用 `as int?`**：`as int?` 对 `2500.0` 和 `"2500"` 都会抛异常。走代理、走网关时，数字被写成 double 或字符串是真实发生过的。原来 `as int?` 只要类型不对，异常会顺着 `_receive` 冒到 `listen` 的回调外面，**整条消息连同后面的内容一起丢**。

**为什么要有 `_text`**：`TodoWrite` 的 `subject` 这类字段，走代理时可能被写成数字。

### 5.2 一条消息读不懂，不能带走整场对话

`lib/kernel/claude_code/claude_code_kernel.dart:1605`：

```dart
void _receive(Map<String, Object?> message) {
  if (_control?.receive(message) ?? false) return;
  // What the CLI says is not all this version knows: a message it shapes
  // another way, or says something new in, is one to go on without, not
  // one that ends the conversation. See _lost.
  try {
    _handle(message);
  } catch (error, stack) {
    _lost(message, error, stack);
  }
}
```

`_lost`（`claude_code_kernel.dart:1711`）做三件事：

1. `debugPrint` 出出错的消息类型与异常；
2. 每种 kind 只往界面插一条 warning 通知（`_lostKinds` 去重），避免刷屏；
3. 会话继续。**异常不会冒到 `listen` 外面。**

这条护栏的价值在于：**CLI 说了一个新消息类型，或者某个字段换了写法，用户丢的是一条通知，不是整段对话。**

### 5.3 局部坏了跳过局部，不是跳过整条

一个消息里有多个内容块时，某个块读不懂只跳过那一个块：

```dart
case 'tool_use':
  // A call is known by what it is called and where it is filed:
  // without both there is nothing to show of it. The other blocks
  // of this message are still said.
  final toolId = _string(block['id']);
  final name = _string(block['name']);
  if (toolId == null || name == null) continue;   // 不是 return
```

**这里是 `continue` 而不是 `return`**：`return` 会让同一消息里它后面的文本块也一起消失。

### 5.4 契约测试

每个消费的字段一个测试，用内联 JSON 片段，不依赖录制的整段会话：

- `test/kernel_test.dart` → `a message shaped another way is still read, its parts as they are written`：tool_use 的 `id`/`name` 写成数字时，跳过该块、保留前后文本。
- `test/kernel_test.dart` → `a whole number written as a double or as text is read as one`：`retry_delay_ms` 为 `2500.0`、`"2500"`、`2500` 时读出同样的秒数；缺失时不丢消息。
- `test/kernel_test.dart` → `a message not understood is said to be lost, once per kind, and the conversation goes on`：同样的坏消息发三次只出一条通知，其后的 `result` 仍被读到。
- `test/remote/claude_wire_contract_test.dart` → 12 个，覆盖 RPC 边界的三个解析器（见 2.2）。
- `test/kernel_test.dart` → `the hooks say whether one is in effect, and which` 里补了 `hooks` 不是列表的三种情况（字符串、null、没有这个键），都返回 null 而不是抛。

**加新字段时照这些的样子加一个。** 内联片段比录制文件好维护：录制文件会随 CLI 版本过期，而内联片段永远说明"我要保证的是什么"。

## 6. 改代码时怎么用这份文档

- **想加功能**：先问能不能只读落盘文件（第一层）。能，就别碰 control 通道。
- **要改 control subtype**：先改本文档的表格，再改代码，再补测试。三样缺一样都算没改完。
- **CLI 升级后功能失灵**：按三层顺序查。先看 `_lost` 有没有打出新消息类型（第三层），再看能不能退回落盘读取（第一层）。
- **不要为了"覆盖完整"去读没进界面的字段**。读了就要维护，就要跟着上游改。

## 附：本次改造改了什么

### 第一批（容错解析 + 单条消息护栏 + 契约文档）

- `claude_code_translator.dart`：新增 `_int` / `_text` / `_bool` 三个容错辅助函数；把 10 处会抛异常的硬转换（`as String`、`as int`）改为返回 `null` + 判空跳过；`_assistant` 里读不懂的块改为 `continue` 而不是 `return`。
- `claude_code_kernel.dart`：`_receive` 拆成 `_receive` + `_handle`，外层包 `try/catch`；新增 `_lost` 与 `_lostKinds`。
- `test/kernel_test.dart`：新增三个契约测试。
- 本次改造前：`test/kernel_test.dart` 97 个测试通过；改造后 100 个通过。4 个路径/环境相关失败在改造前就存在（Windows 路径分隔符、claude locator），与本次改动无关。

### 第二批（落盘优先层的两个缺口）

- `packages/bao_remote/lib/src/claude/claude_sessions.dart`：`ClaudeSessionSummary.fromJson` / `ClaudeProjectSummary.fromJson` 改为返回可空、逐字段容错；新增 `_time` 辅助函数。
- `packages/bao_remote/lib/src/claude/claude_history_page.dart`：`ClaudeHistoryPage.fromJson` 按行容错。
- `packages/bao_remote/lib/src/client/remote_client.dart`：两处调用点改为按项目/条目过滤。
- `lib/kernel/claude_code/claude_goal.dart`：`hookedGoal` 与 `keptGoal` 去掉会抛的硬转换。
- `lib/kernel/claude_code/claude_code_kernel.dart`：`_readGoalNow` 整体包 `try/catch`。
- `test/remote/claude_wire_contract_test.dart`：新建，12 个契约测试。

**关于"落盘优先"这件事的实测结论**：BaoCode 的历史读取**本来就是落盘优先的**——`_replay`（`claude_code_kernel.dart:2392`）从会话文件读，`_decode` / `_branch` / `_summarize` / `_fork` 每一处都已有 `try/catch` 或前置类型检查。所以这一层不需要"改成落盘优先"，需要的是把剩下几个**跨机器边界**的解析器补齐，以及给 `/goal` 那个没人接的 future 补护栏。这两件事这一批都做了。
