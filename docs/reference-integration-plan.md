# 参考项目集成计划

> 范围：`D:\DM\4\ZCode`、`D:\DM\4\claudecodeui`、`D:\DM\4\claude-code-best`、`D:\DM\4\billion-context` 中**已确认可以集成或借鉴**的能力。
>
> 执行方式：严格按批次逐项实施，不跳过、不中途改方向。每批完成后更新本文末尾的状态表并单独提交；发现必须偏离计划的情况，先停止、在本文件记录原因并征求确认。
>
> 编写日期：2026-10-21

---

## 0. 不可改变的行为边界

以下内容视为对外契约。集成过程中**不得改变**；确需改变时必须在本文单列“兼容处理”，并在实现前说明。

1. **Claude Code CLI 控制协议**
   - 已有 `control_request` / `control_response` 子类型的字段、语义、返回形状不变。
   - 新增能力只能以“新增子类型”或“新增可选字段”的方式出现；老宿主不认识时应可忽略。
   - 不改变 `can_use_tool`、`initialize`、`set_permission_mode`、`set_model`、`get_settings`、`mcp_status`、`rewind_files`、`stop_task` 等已有应答。
2. **会话存储格式**
   - `<config>/projects/<cwd>/<session>.jsonl` 的既有行类型、字段、`parentUuid`/`logicalParentUuid` 语义不变。
   - 只允许新增 `system` 子类型行（`compression`、`compression_restored`、`offload_boundary`）与可选字段；旧版本读到时跳过。
   - 子代理 sidechain 文件路径与 `agent-<id>.jsonl` 命名不变。
3. **Kernel/UI 事件协议**
   - 既有 `KernelEvent`、`ChatItem`、`ToolCallItem`、`Interaction*` 的形状不变。
   - 上下文管理工具在 UI 中**不显示为工具卡片**，只产生既有 `NoticeItem`（`NoticeKind.info`）。
4. **权限语义**
   - 既有规则优先级（deny → ask → 工具自身 → 模式 → allow → ask）不变。
   - 不新增规则型“拒绝”；唯一新增是更广的危险命令/凭据路径**询问**（见 B1-2），沿用现有 `safetyCheck`，在包括 `bypassPermissions` 在内的所有模式下都会询问。
   - B1-3 的审批超时按拒绝处理，属于新增的失败关闭路径；默认 600 秒、可设 0 关闭，交互式工具不超时。
5. **压缩回落**
   - `Compaction` 的 retained-tail fallback、文件恢复、PreCompact/SessionStart hook、连续失败熔断行为保留。
   - 未启用上下文管理时，`toApiMessages()` 的输出必须与现在逐字节一致（用既有 golden/单元测试守住）。
6. **许可与分发**
   - 不把 AGPL-3.0 的 claudecodeui 代码复制进 GPL-3.0 的 BaoCode。
   - 不把无 LICENSE、逆向得到的 claude-code-best 代码复制进来。
   - 不把 billion-context 作为 Dart 库嵌入，也不随包分发其二进制。
   - ZCode 为 Apache-2.0：本计划只借鉴设计并独立实现；如未来直接引用代码，必须保留版权与 NOTICE。

### 0.1 必要的行为变化（单独标记）

以下变化不可避免，均带兼容处理：

| 变化 | 影响 | 兼容/回退 |
| --- | --- | --- |
| 危险命令/凭据路径询问范围扩大（B1-2） | 少数常规删除/强制推送会多一次询问 | 仅询问，不拒绝；用户可当场允许；回退 B1-2 |
| 非交互审批超时（B1-3） | 长时间不回答会按拒绝结束本次工具调用 | 默认 600 秒；`permissions.approvalTimeoutSeconds = 0` 关闭；交互式工具不超时 |
| resume 后已读状态恢复（B1-4） | 刚恢复的会话可直接编辑已读且未变的文件 | 文件变化后仍要求重读；只影响当前会话 |
| 上下文管理工具与压缩视图（B3/B4） | 模型会看到隐藏工具、摘要、占位结果；请求内容变化 | `contextManagement.enabled = false` 整体关闭；关闭后与改动前一致；会话文件只新增可忽略的行 |

---

## 1. 参考项目与许可

| 项目 | 版本/形态 | 许可 | 本计划允许的用法 | 明确禁止 |
| --- | --- | --- | --- | --- |
| ZCode | v3.16.2，TypeScript | Apache-2.0 | 借鉴权限守卫、失败分类、压缩策略；可独立重写 | 不整段搬运；直接引用时须合规署名 |
| claudecodeui | Web/Node | AGPL-3.0-or-later | **只借鉴产品行为与交互思路** | 不复制任何代码到本仓库 |
| claude-code-best | 逆向工程 | 无 LICENSE | 只把协议/会话格式当事实参考 | 不复制代码；不随产品分发；不推荐作为后端 |
| billion-context | 0.1.203，Node/TS | MIT + 强制署名附加条款 | 只借鉴设计，用 Dart 独立实现 | 不作为 Dart 库嵌入；不作为 sidecar 随包分发；不复制代码 |

> billion-context 的附加条款要求：若产品实际使用它，必须在首页、文档和 About 中注明 “uses billion-context” 并附仓库链接。本计划**不引入其代码或运行时**，因此不触发该条款；若未来改为 sidecar，必须重新评估并补署名。

---

## 2. 已完成/已存在的能力（本轮不再改）

以下能力经代码核对已经在仓库中，作为后续集成的基础：

| 能力 | 位置 | 状态 |
| --- | --- | --- |
| 子代理独立上下文、sidechain 文件 | `packages/bao_agent/lib/src/tools/agent_tool.dart`、`session_store.dart` | 已完成（提交 `1334adc`） |
| 子代理卡片最多 200 步 + “省略 N 步”提示 | `lib/kernel/claude_code/claude_code_translator.dart` | 已完成（提交 `1334adc`） |
| 会话摘要按头/尾 64KB 读取，长文件不整读 | `packages/bao_remote/lib/src/claude/claude_session_bytes.dart` | 已完成（提交 `1334adc`） |
| 工具调用结果到达后释放其输入 | `lib/kernel/claude_code/claude_code_translator.dart` | 已完成（提交 `de9f6b5`） |
| 自动模式在非 Claude 供应商模型上由本机分类器判定 | `lib/kernel/claude_code/claude_auto_rules.dart`、`claude_classifier.dart` | 已完成 |
| 自动模式对危险 allow 规则的警告 | `claude_auto_rules.dart`、`test/kernel_test.dart` | 已完成 |
| `reload_plugins` / `reload_extensions` | `packages/bao_agent/lib/src/engine/engine.dart` | 已存在，无需改 |
| `end_session`、`stop_task`、`get_settings`、`mcp_status`、`mcp_toggle`、`mcp_reconnect`、`mcp_authenticate` | `engine.dart` | 已存在，无需改 |
| 重试：429/5xx/网络、`Retry-After`、最多 10 次、`stream_restart` | `api/anthropic_client.dart` | 已存在，本轮只加分类 |
| microcompaction、全量压缩、retained-tail fallback、恢复最近读过的文件、PreCompact/SessionStart hook、连续失败 3 次熔断 | `engine/compaction.dart` | 已存在，本轮增强 |
| CLAUDE.md 记忆层级、`@path` 导入、条件规则、realpath 去重 | `config/memory.dart`、`engine/context.dart` | 已存在，不改 |
| 会话摘要缓存（path+mtime+size） | `bao_remote/lib/src/claude/claude_sessions.dart` | 已存在，不改 |
| 历史会话头/尾扫描 | `bao_remote/lib/src/claude/claude_sessions.dart` | 已完成（提交 `1334adc`） |
| 审批请求在 kernel 内保持；`control_cancel_request` 可解除 | `claude_code_kernel.dart` | 已存在，B1-3 复用 |
| `rewind_files`、checkpoint、rewind 重放 | `engine/checkpoints.dart`、`engine.dart` | 已存在，不改 |

---

## 3. 选定要集成的能力总览

| 编号 | 能力 | 来源 | 解决的问题 | 批次 |
| --- | --- | --- | --- | --- |
| B1-1 | API 失败分类与 errand 重试策略 | ZCode | 摘要/分类等后台请求在 529 上反复重试；错误提示不可操作 | 1 |
| B1-2 | 危险命令与凭据路径守卫扩展 | ZCode | 现有守卫只覆盖 `sudo`/`rm -rf /` 等，git 破坏操作、Windows 删除、凭据文件未覆盖 | 1 |
| B1-3 | 非交互审批超时 | claudecodeui（行为） | 宿主长时间不回答时工具永久挂起 | 1 |
| B1-4 | 恢复会话的已读状态 | claude-code-best（协议事实） | resume 后所有文件都要重读才能编辑 | 1 |
| B2-1 | 可逆区间压缩的存储与重建 | billion-context（设计） | 只能整段压缩，旧消息不可恢复 | 2 |
| B2-2 | 请求视图、稳定 refs 与前缀缓存 | billion-context（设计） | 压缩后请求前缀不稳定，缓存失效 | 2 |
| B2-3 | `ContextCompression` 核心服务 | billion-context（设计） | 压缩/恢复/检索/状态没有统一入口 | 2 |
| B3-1 | 隐藏工具标记与 toolbox 接入 | billion-context（设计） | 上下文工具不应出现在普通工具列表/UI | 3 |
| B3-2 | `compress` 工具 | billion-context（设计） | 模型无法按需折叠旧区间 | 3 |
| B3-3 | `decompress` / `search_context` / `acp_status` | billion-context（设计） | 压缩不可逆、压缩后找不到内容、状态不可见 | 3 |
| B3-4 | 上下文增长提醒 | billion-context（设计） | 模型不知道上下文已增长，错过压缩时机 | 3 |
| B3-5 | 大工具结果 CCR 卸载与 `retrieve_tool_result` | billion-context（设计） | 单个巨大工具结果挤占上下文 | 3 |
| B3-6 | 子会话沿父链只读回退 | billion-context（设计） | 子代理看不到父会话已压缩的内容 | 3 |
| B3-7 | UI 隐藏上下文工具并提示压缩事件 | billion-context（设计） | 内部工具污染对话；用户不知道发生了什么 | 3 |
| B4-1 | 自动压缩阈值使用输出预留与 provider usage | ZCode | 阈值在长输出模型上偏晚/偏早 | 4 |
| B4-2 | 全压缩后保留最近助手轮次原文 | ZCode | 摘要后最近一轮的精确内容丢失 | 4 |
| B4-3 | microcompaction 按助手轮次保留并保护错误/媒体 | ZCode | 按消息条数保留会拆散调用与结果 | 4 |
| B4-4 | 收尾验证与报告 | — | 确认全部完成/放弃项 | 4 |

---

## 4. 批次 1：安全与协议小项

> 目标：不触碰上下文模型，全部可独立回滚。完成后项目可运行，既有测试不回归。

### B1-1 API 失败分类与 errand 重试策略

- **来源**：ZCode `failure-classifier.ts`、`retry-policy.ts`、`retry-budget.ts`（只借鉴分类语义）。
- **问题**：当前 `ApiError.retryable` 是布尔值，调用方无法区分“该等”“该换 key”“该压缩”“该改请求”；摘要、自动模式分类、标题生成等 errand 请求与主请求共用 10 次重试，529 时白白等待。
- **落点**：
  - `packages/bao_agent/lib/src/api/model_client.dart`
    - 新增 `ApiFailureKind`（`rateLimit`、`overloaded`、`authentication`、`contextTooLong`、`billing`、`invalidRequest`、`server`、`network`、`tls`、`cancelled`、`unknown`）。
    - `ApiError.kind` 由 status/type/message 计算；`ApiError.action` 给出可操作的英文提示（不改现有 `message`）。
    - `ModelRequest` 新增 `errand`（默认 `false`）与 `maxRetries`（默认 `null`）。
  - `packages/bao_agent/lib/src/api/anthropic_client.dart`
    - 仅对 `network`/`tls` 中的证书错误作不可重试分类；保持现有退避曲线（500ms×2ⁿ，上限 32s，0–25% 抖动）不变。
    - errand 请求最多重试 1 次；`overloaded`（529）对 errand 不重试。
  - `packages/bao_agent/lib/src/engine/session.dart` `_query()`、`engine/compaction.dart` `_ask()`、`tools/web_tools.dart` 的模型请求：标记 `errand: true`。
- **边界**：不改变主请求的重试次数、退避时间、`stream_restart` 语义；不新增 provider 业务码表。
- **依赖/风险**：低。分类错误会把可重试错误当不可重试；用表单测试覆盖。
- **验收**：
  - 新增 `packages/bao_agent/test/units/api_error_kind_test.dart`：401/403、400 context、402、429、529、500、TLS、断网、取消。
  - 新增/扩展客户端测试：errand 529 只尝试 1 次；主请求 529 仍按原次数重试。
  - 既有 `tools_test.dart`/`edges_test.dart` 中与重试相关的用例不回归。

### B1-2 危险命令与凭据路径守卫扩展

- **来源**：ZCode `guarded/command.ts`、`bash-command-parser.ts`、`path-policy.ts`（只借鉴模式列表）。
- **问题**：`isDangerousWords()` 只覆盖 `sudo`/`doas`、`mkfs`、`dd of=/dev/*`、`rm -rf /|~|$HOME|*|.`；`git reset --hard`、`git clean -fd`、`git push --force`、`find -delete`、`rsync --delete`、Windows `del/rd /s /q`、`robocopy /MIR`、PowerShell `Remove-Item -Recurse -Force` 均未覆盖。凭据目录（`~/.ssh`、`~/.aws`、`~/.gnupg`、`~/.kube`、`~/.config/gcloud`）未列入 `isProtectedPath`。
- **落点**：
  - `packages/bao_agent/lib/src/permissions/shell_command.dart`：扩展 `isDangerousWords()`；解包 `env`/`nohup`/`time`/`command` 等 wrapper 后判断；解析失败返回“未知”仍走 ask。
  - `packages/bao_agent/lib/src/permissions/permission_engine.dart`：`isProtectedPath()` 增加凭据路径段；保持“只 ask、不 deny”，且 `classifierApprovable: false`。
  - 新增 `packages/bao_agent/test/units/dangerous_commands_test.dart`。
- **边界**：不递归分析解释器（`bash -c`、`python -c`）内部命令；不改变 `bypassPermissions` 之外的模式矩阵；不新增拒绝。
- **依赖/风险**：中。误报会让 `rm -rf ./build` 之类的常规命令多问一次；用正反例测试限制。
- **验收**：
  - 正例：`git reset --hard`、`git clean -fdx`、`git push --force`、`find . -name '*.tmp' -delete`、`rsync -a --delete src/ dst/`、`del /s /q build`、`rd /s /q build`、`Remove-Item -Recurse -Force build`、`robocopy a b /MIR`、`nohup rm -rf /`。
  - 反例：`rm -rf ./build`（工作区内）、`git push --force-with-lease`（比 `--force` 安全，不提示）、`find . -name '*.dart'`、`rsync -a src/ dst/`。
  - 凭据路径：`~/.ssh/config`、`~/.aws/credentials`、`~/.kube/config` 编辑时 ask；`.claude/settings.json` 原有行为不变。

### B1-3 非交互审批超时

- **来源**：claudecodeui `approval timeout 55s`（只借鉴行为；参数改为 10 分钟）。
- **问题**：`_hostRequest('can_use_tool')` 没有超时；宿主崩溃/断线时工具调用永久挂起。
- **落点**：
  - `packages/bao_agent/lib/src/engine/engine.dart` `_hostRequest(..., {Duration? timeout})`：超时后向宿主发 `control_cancel_request {request_id}`，从 `_pending` 移除，并抛出 `HostRequestTimeout`（不抛 `Cancelled`，避免中断整个 turn）。
  - `packages/bao_agent/lib/src/engine/agent_loop.dart` `_askUser()`：`userOnly == true` 不超时；否则读取 `session.settings.approvalTimeout`，捕获 `HostRequestTimeout` 并返回 `PermissionDeny('No answer came within …')`。
  - `packages/bao_agent/lib/src/config/settings.dart`：`permissions.approvalTimeoutSeconds`，默认 600，0 表示关闭。
  - kernel 已有 `control_cancel_request` 处理（`claude_code_kernel.dart`），无需改协议。
- **边界**：不改 `can_use_tool` 请求/响应字段；不改变交互式工具（`AskUserQuestion` 等）的无限等待；超时按“拒绝”处理并在工具结果里说明原因。
- **依赖/风险**：中。用户离开 10 分钟会被拒绝；可配置、0 关闭、交互式不超时。
- **验收**：
  - `packages/bao_agent/test/engine/permissions_test.dart` 的 “a question no one answers times out…”：`onPermission` 返回永不完成的 Future，设置 `approvalTimeoutSeconds: 1`，断言工具被拒绝、`sent` 中出现 `control_cancel_request`、结果是错误且文件未变。
  - 交互式工具在同样设置下不会超时（实现上以 `requires_user_interaction` 为条件，无超时）。

### B1-4 恢复会话的已读状态

- **来源**：claude-code-best `seed_read_state = {subtype, path, mtime}`（协议事实）。
- **问题**：resume 后 `mainRun.readFiles` 为空，编辑任何文件都要求先 Read，即使该文件在上一段会话中已读过且未变化。
- **落点**：
  - `packages/bao_agent/lib/src/tools/file_state.dart`：新增 `ReadFileState.seed(path, modified)`，记录“已读但无内容快照”的状态（`partial` 语义），使 `staleness()` 在 mtime 未变时放行、变了要求重读。
  - `packages/bao_agent/lib/src/engine/session_store.dart`：新增 `seedReadState(ReadFileState)`，按 chain 顺序扫描 `Read`/`Write`/`Edit` 工具调用，用该行 `timestamp` 作为 `modified`。
  - `packages/bao_agent/lib/src/engine/engine.dart` `_start()` resume 分支调用；新增控制请求 `seed_read_state`（host → engine），字段 `{path, mtime}`（`mtime` 为毫秒时间戳），用于宿主显式补给。
- **边界**：不改变会话文件格式；不把文件内容塞进内存；只影响“读取前置检查”，不改变实际读文件结果。
- **依赖/风险**：低。时间戳来自会话行；若文件在会话结束后被改过，mtime 更新，仍会要求重读（正确行为）。
- **验收**：
  - 新增 `packages/bao_agent/test/units/resume_read_state_test.dart`：写入带 Read 调用的会话 → resume → 直接 Edit 成功；把文件 mtime 改晚 → Edit 要求重读。
  - 控制协议测试：`seed_read_state` 后可直接 Edit，`mtime` 更新后要求重读。

---

## 5. 批次 2：压缩存储与请求视图

> 目标：先把“可逆区间压缩”的数据模型和请求视图做对，不暴露工具；未启用时输出与现在完全一致。

### B2-1 CompressionBlock 存储与重建

- **来源**：billion-context 的可逆范围压缩（设计）。
- **问题**：现有压缩只有全量 `compact_boundary`，旧消息只能靠 transcript 文件人肉翻找；没有“只压缩某段、以后可恢复”的模型。
- **落点**：
  - `packages/bao_agent/lib/src/engine/session_store.dart`
    - `CompressionBlock {id, startUuid, endUuid, summary, createdAt}`。
    - `List<CompressionBlock> compressionBlocks`、`Map<String, OffloadInfo> offloadedToolResults`。
    - `_load()` 后 `_rebuildCompression()`：按顺序应用 `compression`、`compression_restored`；`compact_boundary` 清空；`offload_boundary` 加入卸载表。
    - `rewindTo()` 后同样重建。
    - `append()` 对三种新 subtype 做增量维护。
  - 新文件 `packages/bao_agent/lib/src/engine/compression_block.dart`（或放在 `session_store.dart` 同文件，视体量）。
- **新行格式**（只新增，不改变既有行）：
  ```json
  {"type":"system","subtype":"compression","block_id":"c1","start_uuid":"…","end_uuid":"…","summary":"…","tokens_before":12000,"tokens_after":800,"created_at":"…"}
  {"type":"system","subtype":"compression_restored","block_id":"c1"}
  {"type":"system","subtype":"offload_boundary","tool_use_id":"toolu_…","tokens":9200,"preview":"…","created_at":"…"}
  ```
- **边界**：不改既有行的字段；旧代码读到新 subtype 时按未知 system 行跳过；`toApiMessages()` 在 blocks/offload 均为空时逐字节不变。
- **依赖/风险**：中。重建顺序、嵌套块、rewind 是易错点；用单元测试覆盖。
- **验收**：
  - `packages/bao_agent/test/units/session_compression_test.dart`：append/load/rewind/compact 后 active 列表正确；无块时 `apiMessages()` 与旧快照一致。
  - 嵌套/覆盖：新块覆盖旧块时旧块不再生效；被覆盖的旧块 `decompress` 报错并指出覆盖者。

### B2-2 请求视图、稳定 refs 与前缀缓存

- **来源**：billion-context 的 prefix-cache-friendly folding（设计）。
- **问题**：如果每次请求重新编号/重排，压缩后前缀缓存全部失效；模型也没有稳定的“消息坐标”来指定压缩范围。
- **落点**：
  - `session_store.dart` 新增：
    ```dart
    ({List<Map<String, Object?>> messages, Map<String, int> refs})
    apiConversation({bool withRefs = false});
    ```
  - 视图构建：从最后一个 `compact_boundary` 之后开始；按 chain 顺序用 active block 的摘要替换 `[startUuid..endUuid]`；摘要作为 `isMeta: true` 的 user 消息；随后交给现有 `toApiMessages()` 做合并/配对。
  - refs：只给可见的 user prompt 分配 `m<chainIndex>`；在文本末尾追加 `<ctx id="m12"/>`。refs 只依赖 chain 下标，压缩/恢复/后续轮次都不变。
  - `agent_loop.dart` `buildRequest()` 使用 `apiConversation(withRefs: true)`，并把 `refs` 存入 `run.apiRefs` 供工具解析。
- **边界**：不带 refs 的 `apiMessages()` 保持原样；refs 只影响发送给模型的内容，不写入会话文件。
- **依赖/风险**：中。摘要消息与相邻 user prompt 会被 `toApiMessages` 合并，这是预期行为（摘要在前、当前问题在后）。
- **验收**：
  - 前缀稳定性测试：连续三次请求，未压缩部分的消息前缀完全相同；压缩只重写被折叠的连续前缀一次。
  - 无块时 `apiConversation().messages` 与 `apiMessages()` 深比较相等。
  - refs 在压缩前后不变；`m<index>` 能解析回正确的 prompt。

### B2-3 ContextCompression 核心服务

- **来源**：billion-context 的 `compress`/`decompress`/`search_context`/`acp_status` 形态（设计）。
- **问题**：压缩/恢复/搜索/状态没有统一入口，工具层会重复实现边界校验。
- **落点**：新文件 `packages/bao_agent/lib/src/engine/context_compression.dart`：
  - `ContextCompression(session, run, model)`。
  - `CompressionStatus status()`：active blocks、saved tokens、CCR 计数、nudge 阈值。
  - `({int start, int end}) resolveRange(String startRef, String? endRef)`：校验 ref、范围大于最小 token、end 之前至少保留 `keepRecentTurns` 个 prompt、范围不超过 `maxCompressTokens`。
  - `Future<CompressionBlock> compress(startRef, endRef, {String? summary})`：可用现有 `Compaction` 的 errand 请求生成摘要；写 `compression` 行；更新 active。
  - `bool restore(String blockId)`：写 `compression_restored`；被覆盖时报错。
  - `List<ContextHit> search(String query, {int limit = 20})`：在当前 store 的全部 chain（含已压缩内容）里搜文本，返回 ref/snippet/所在 block。
  - `String? nudge(int tokens)`：按阈值返回一段提醒文本（由调用方决定是否附加）。
- **边界**：本批不注册工具；不改 `Compaction` 的既有公开行为；摘要生成复用 `session.client`，标记 `errand: true`。
- **依赖/风险**：中高。范围边界、工具调用/结果配对、摘要请求过长是主要风险；B2-1/B2-2 的测试先守住。
- **验收**：单元测试覆盖 resolveRange 的每种拒绝理由、compress→decompress 原文逐条恢复、search 命中已压缩内容、status 数字正确。

---

## 6. 批次 3：上下文工具与 CCR

> 目标：把 B2 的能力以“模型调用、宿主执行、UI 隐藏”的方式接入。

### B3-1 隐藏工具标记与 toolbox 接入

- **落点**：
  - `packages/bao_agent/lib/src/tools/tool.dart`：`bool get hidden => false;`（或 `contextTool` 标记）。
  - `packages/bao_agent/lib/src/engine/toolbox.dart`：`builtIn` 增加 `CompressTool`、`DecompressTool`、`SearchContextTool`、`AcpStatusTool`、`RetrieveToolResultTool`，仅当 `settings.contextManagement.enabled`；`compress` 另受 `compress` 开关控制；`retrieve_tool_result` 另受 `ccrMinTokens > 0` 控制。
  - `packages/bao_agent/lib/src/config/settings.dart`：新增 `contextManagement` 读取器：
    ```text
    enabled (默认 true)
    compress (默认 true)
    nudgeGrowthTokens (默认 50000)
    minCompressTokens (默认 2000)
    keepRecentTurns (默认 2)
    maxCompressTokens (默认 60000)
    ccrMinTokens (默认 8000)
    ccrPreviewChars (默认 300)
    retrieveInlineChars (默认 20000)
    ```
- **边界**：不改变既有工具的排序/名称；`options.tools` 显式白名单仍可排除上下文工具；deny 规则仍可禁用。
- **验收**：toolbox 单元测试：开关关闭时列表与现在完全一致；打开时只多出隐藏工具。

### B3-2 `compress` 工具

- **落点**：新文件 `packages/bao_agent/lib/src/tools/context_tools.dart`。
  - 输入：`{start_ref: string, end_ref?: string, summary?: string, reason?: string}`。
  - 行为：解析 ref → `ContextCompression.compress()`；返回 `{block_id, messages, tokens_before, tokens_after, saved, summary}`（`result` 同结构，供 UI 提示）。
  - 描述告诉模型：用于折叠较早的连续区间；当前问题和最近 `keepRecentTurns` 轮不能压缩；需要保留的精确内容应先记下或依赖 `decompress`。
- **边界**：只压当前 run 自己的 store；子代理不能压父会话；不修改摘要之前的任何消息。
- **依赖/风险**：中。模型可能频繁压缩导致抖动；最小 token、保留轮次、nudge 共同约束。
- **验收**：Harness + FakeModel：构造多轮对话，模型调用 `compress`，下一请求消息数下降且摘要出现；`decompress` 后逐条恢复；非法 ref/过小范围/压到最近轮次均返回清晰错误。

### B3-3 `decompress` / `search_context` / `acp_status`

- **落点**：同一文件。
  - `decompress {block_id}`：恢复；被覆盖/不存在时报错。
  - `search_context {query, limit?}`：大小写不敏感、最多 20 条、每条截断；返回 `{matches: [{source, ref, snippet, block_id?}], total}`；不执行正则。
  - `acp_status {}`：返回 `{enabled, active_blocks: [...], saved_tokens, offloaded: n, offloaded_tokens, nudge_threshold, context_tokens}`。
- **边界**：`search_context` 只读；`acp_status` 只读；`decompress` 只影响当前 run。
- **验收**：压缩后 `search_context` 能搜到被折叠的原文；`acp_status` 的 saved/offloaded 数字与构造数据一致；`decompress` 后请求恢复原文。

### B3-4 上下文增长提醒

- **落点**：
  - `agent_loop.dart` `buildRequest()`：在请求末尾附加一条**不写入会话**的 meta user 文本；`run.lastNudgeTokens` 初始为 0，增长超过 `nudgeGrowthTokens` 时触发并更新。
  - 提醒内容：说明可用 `compress`、`search_context`、`acp_status`，并给出大致 token 数；不命令模型必须压缩。
- **边界**：提醒只存在于本次请求，不进 transcript、不进 rewind；不影响未压缩前缀。
- **验收**：Harness 连续请求，增长到阈值后下一次请求末尾出现提醒；再下一次不重复；会话文件里没有提醒。

### B3-5 大工具结果 CCR 卸载与 `retrieve_tool_result`

- **来源**：billion-context 的 CCR（设计）。
- **问题**：一次 `Bash`/`Grep`/`Read` 可能返回数万 token，直接挤占上下文。
- **落点**：
  - `agent_loop.dart` `_appendResult()`：结果写入会话后，若文本 token ≥ `ccrMinTokens` 且内容可文本化，追加 `offload_boundary`（记录 id/tokens/preview）。**会话与 UI 事件仍保留完整内容**。
  - `session_store.dart`：`toApiMessages()` 对 offloaded id 用占位文本替换：
    ```text
    [Large tool result stored out of context: id=toolu_…, ~9.2k tokens.
     Use retrieve_tool_result with this id, or search_context to find part of it.]
    ```
    并附 `preview` 前 N 字符。
  - `context_tools.dart` `retrieve_tool_result {tool_use_id, offset?, limit?}`：从 chain 找原文；默认内联最多 `retrieveInlineChars`；超出时按 `offset/limit` 分页，返回 `{content, total_chars, next_offset}`。
  - `compaction.dart` microcompaction 占位文本追加 `retrieve_tool_result` 提示。
- **边界**：不卸载图片/文档/非文本结果；不改变会话文件；不改变 UI 展示的完整结果；被 offload 的结果不再被 microcompaction 二次清空。
- **依赖/风险**：中。模型可能不调用 retrieve 而误以为结果丢失；占位文本要明确、preview 要足够。
- **验收**：
  - 单元测试：大结果下一请求出现占位文本；`retrieve_tool_result` 返回原文前缀；分页正确；图片结果不被卸载。
  - UI 测试：工具结果事件仍是完整内容。

### B3-6 子会话沿父链只读回退

- **落点**：
  - `agent_run.dart`：`final AgentRun? parentRun;`。
  - `agent_tool.dart` `_Job.start()`：`AgentRun(..., parentRun: parentRun)`，`_Job` 保存 `context.run`。
  - `context_compression.dart` / `context_tools.dart`：
    - `search_context` 在当前 run 无结果时沿 `parentRun` 向上搜索，最多 8 层；结果标 `source: "parent"`，ref 加前缀 `p1:`、`p2:`。
    - `retrieve_tool_result` 沿父链找 tool_use_id。
    - `decompress` **只允许当前 run**；父链 block 返回“只读，可在父会话恢复”的说明。
    - `compress` 只作用于当前 store。
- **边界**：父链只读；不修改父 store；不递归到兄弟代理；深度上限 8 防环。
- **验收**：父会话压缩 → 子代理 `search_context` 命中父内容并标注来源；子代理 `decompress` 父 block 被拒绝；父 store 的 active blocks 不变。

### B3-7 UI 隐藏上下文工具并提示压缩事件

- **落点**：
  - `lib/kernel/claude_code/claude_code_translator.dart`
    - 常量集合 `_contextTools = {'compress','decompress','search_context','acp_status','retrieve_tool_result'}`。
    - `_toolUse()`：命中集合时只登记 `_tools[id]`，不创建/更新 `ToolCallItem`。
    - `_toolResultOf()`：命中集合时：
      - `compress`：发 `NoticeItem(NoticeKind.info, 'Context compressed: N messages folded, ~X tokens saved.')`。
      - `decompress`：发 `NoticeItem(NoticeKind.info, 'Context restored: N messages are back.')`。
      - 其余：不发提示。
    - `_keepsTool()` 对这些名称返回 false，结果后移除登记。
  - 历史回放走同一路径。
- **边界**：不改变既有工具卡片；不改变 `NoticeItem` 形状；不隐藏模型正文。
- **验收**：`test/kernel_test.dart` 新增：上下文工具调用不产生卡片，`compress`/`decompress` 各产生一条 info 提示；回放同样。

---

## 7. 批次 4：全压缩改进与收尾

### B4-1 自动压缩阈值使用输出预留与 provider usage

- **来源**：ZCode `compact/policy.ts`。
- **落点**：`packages/bao_agent/lib/src/engine/compaction.dart`
  - 阈值改为 `window - min(maxOutput, 21000) - 13000`，并以 `max(window × 0.5, …)` 与现有 `compactBufferOf()` 兜底；`autoCompactWindow` 仍优先。
  - token 估算以最近一次 provider usage 为基线，加上其后的本地估算（现有 `usedTokens()` 已有基线逻辑，补齐输出预留）。
  - 保留 `compactBufferOf()` 作为兜底。
- **边界**：不改变 `autoCompactWindow` 语义；不改变压缩失败回落。
- **验收**：128k/200k/1M 窗口的阈值表测试；既有压缩测试不回归。

### B4-2 全压缩后保留最近助手轮次原文

- **来源**：ZCode `compact-selection.ts`（保留最近 assistant-started round）。
- **落点**：`compaction.dart` `compact()`
  - 摘要行之后，追加最近一轮（从最后一个 user prompt 起，到该轮 assistant 结束）的原始消息，预算 `min(20000, window/10)`，标记 `isMeta: true`、`isRetainedTurn: true`。
  - 摘要文本加一句“最近一轮原文保留在摘要之后”。
- **边界**：只在全量压缩时追加；fallback 已有 retained-tail，不重复；不改变 `toApiMessages()` 的起点规则（boundary 之后）。
- **验收**：压缩后请求中出现 summary → 最近一轮原文；token 预算生效；超长轮次按消息裁剪且不拆散 tool_use/result。

### B4-3 microcompaction 按助手轮次保留并保护错误/媒体

- **来源**：ZCode `compact/microcompact.ts`。
- **落点**：`compaction.dart` `microcompact()`
  - 以“assistant 开始的轮次”分组，保留最近 5 组（替代当前按 4 条消息）。
  - 不清理 `is_error` 的结果、含 `image`/`document` 的结果、已清理/已 offload 的结果。
  - 最小节省阈值保持（当前 `_microMinSaved`），不足不落 boundary。
- **边界**：只改清理范围；不改 `microcompact_boundary` 字段；不改 `toApiMessages()` 的占位语义。
- **验收**：构造 6 组工具轮次，前 1 组被清理、后 5 组保留；错误结果/图片结果不清；调用与结果不被拆散。

### B4-4 收尾验证与报告

- 按第 9 节命令跑相关测试。
- 确认状态表全部为“已完成”或“放弃（有原因）”。
- 更新 `docs/reference-integration-plan.md` 状态与验证记录。
- 提交每个批次；不推送远端，除非用户明确要求。

---

## 8. 放弃项与原因

| 编号 | 放弃项 | 来源 | 原因 |
| --- | --- | --- | --- |
| A-1 | billion-context 作为 Dart 库嵌入或 sidecar 随包分发 | billion-context | Node/TS + Node ≥ 20 运行时，无法作为 Dart 库；sidecar 与 BaoCode 的 `--settings`、自定义供应商代理冲突；MIT 附加署名条款影响面大。只借鉴设计。详见 `reference-repos.md`。 |
| A-2 | 复制 claudecodeui 代码 | claudecodeui | AGPL-3.0-or-later，不能进入 GPL-3.0 仓库。只借鉴行为。 |
| A-3 | 复制 claude-code-best 代码 | claude-code-best | 无 LICENSE、逆向工程；只把协议/会话格式当事实参考。 |
| A-4 | `mcp_set_servers` 中途整表替换 | claude-code-best | 需要完整映射配置、OAuth 状态与失败回滚；中途替换可能丢掉已认证服务器。重启会话即可达到目的。 |
| A-5 | ZCode 的 RiskLevel/capability 与 Plan/Guarded/Yolo 模式矩阵 | ZCode | BaoCode 必须保持 Claude Code 的模式契约（default/acceptEdits/plan/bypassPermissions/dontAsk/auto）；替换会扩大或改变权限语义。只采纳危险命令/凭据路径守卫。 |
| A-6 | ZCode 的重试退避参数（2s 起、60s 上限、50–100% 抖动） | ZCode | 会改变现有等待与限流行为；本计划只采纳分类语义与 errand 策略，保留现有曲线。 |
| A-7 | ZCode 的“已提交输出后不再重试” | ZCode | 会破坏现有 `stream_restart` 与 UI accumulator 契约；当前 UI 已能重置。 |
| A-8 | ZCode 的 prompt-too-long “增加保留轮次 → 截断最旧轮次”两级重选 | ZCode | BaoCode 的 `_summarize()` 已有“每次丢最旧 1/5、最多 4 次”；B4-2 的保留轮次在摘要请求之外，交互差异边际，收益不足。 |
| A-9 | rapid-refill breaker | ZCode | 根因是超大工具结果；B3-5 的 CCR 已直接缓解。额外状态与失败模式收益不足。 |
| A-10 | microcompaction 的空闲 60 分钟触发 | ZCode | BaoCode 在每次请求前都会检查；空闲本身不产生请求，触发没有收益。 |
| A-11 | 摘要流失败后回退非流式请求 | ZCode | 需要新增非流式 API 路径；现有重试层已覆盖大多数失败，复杂度收益不匹配。 |
| A-12 | ZCode 的 MEMORY.md 自动记忆/提取/Dream/recall | ZCode | BaoCode 已有 Claude Code 的 CLAUDE.md 记忆层级；再叠加一套“自动记忆”会造成指令优先级冲突。保留现有体系。 |
| A-13 | CloudCLI 的后台 stdin 30 分钟保活 | claudecodeui | BaoCode 的进程传输已有自己的保活/退出策略；不在本次范围。 |
| A-14 | CloudCLI 的“待审批请求跨应用重启重放” | claudecodeui | kernel 在会话存活期间已保留 pending；跨进程重放属于 UI 状态持久化，不在本次范围。 |
| A-15 | `readPage` 的尾部快速路径 | claudecodeui | 需要同时满足 goal/rewind 的语义；现有整页读取 + head/tail 摘要缓存已足够。 |
| A-16 | `generate_session_title` / `side_question` / `set_max_thinking_tokens` | claude-code-best | 标题生成已由 `quickQuery` 实现；side question 与 thinking token 控制不在本次目标，且会扩张协议面。 |
| A-17 | CCB 的 1MB 分块读取 transcript | claude-code-best | `bao_remote` 已用头/尾 64KB + 必要时整读；分块收益不足。 |
| A-18 | 把上下文工具暴露给用户手动调用 | billion-context | 设计要求“模型调用、宿主执行、UI 隐藏”；手动入口会引入新的 UI 协议。 |

---

## 9. 验证协议

### 9.1 环境

- Flutter SDK：`D:\DM\_sdk\flutter`。
- 跑完 Flutter 相关测试后清理生成的平台目录（`linux/`、`macos/`、`windows/` 若出现未跟踪产物；已跟踪的项目文件不要删）。
- 只跑与改动相关的测试，不跑全量。

### 9.2 已知基线（干净树上就失败，不算回归）

`packages/bao_agent` 在干净树上有固定失败（Windows 路径/shell/plugin 环境问题），判据是“失败集合与基线一致”，不是全绿。已知集合：

- `test/engine/commands_test.dart`：plugins（commands/skills/agents/hooks）
- `test/engine/controls_test.dart`：`get_context_usage`、`get_usage`、`file_suggestions`
- `test/engine/edges_test.dart`：Bash 长输出、plan approved、compaction PreCompact、subagents API fails
- `test/engine/file_tools_test.dart`：Glob 最新优先、Grep 模式
- `test/engine/permissions_test.dart`：plan 模式写计划文件
- `test/engine/tools_test.dart`：shell TaskOutput、shell output/exit codes、shell stop_task
- `test/engine/turns_test.dart`：请求的 system prompt/memory/tools/cache marks
- `test/units/utils_test.dart`：MemoryLoader、settings 分层
- `test/kernel_test.dart`：4 条 Windows 路径/环境相关失败（fork copy path、session cache path、2 条 claude locator）

> 失败清单以 `C:\Users\z1515\.claude\projects\D--DM-4-baocode\memory\bao-agent-pre-existing-test-failures.md` 为准；清单之外的失败才算回归。

### 9.3 每批命令

```powershell
$env:PATH = 'D:\DM\_sdk\flutter\bin;' + $env:PATH
cd D:\DM\4\baocode

# 批次 1
D:\DM\_sdk\flutter\bin\flutter test packages/bao_agent/test/api/api_error_kind_test.dart
D:\DM\_sdk\flutter\bin\flutter test packages/bao_agent/test/units/dangerous_commands_test.dart
D:\DM\_sdk\flutter\bin\flutter test packages/bao_agent/test/units/permissions_units_test.dart
D:\DM\_sdk\flutter\bin\flutter test packages/bao_agent/test/engine/resume_read_state_test.dart
D:\DM\_sdk\flutter\bin\flutter test packages/bao_agent/test/engine/permissions_test.dart --plain-name "times out"
D:\DM\_sdk\flutter\bin\flutter test packages/bao_agent/test/engine/controls_test.dart

# 批次 2/3
D:\DM\_sdk\flutter\bin\flutter test packages/bao_agent/test/engine/session_compression_test.dart
D:\DM\_sdk\flutter\bin\flutter test packages/bao_agent/test/engine/context_compression_test.dart
D:\DM\_sdk\flutter\bin\flutter test packages/bao_agent/test/engine/context_tools_test.dart
D:\DM\_sdk\flutter\bin\flutter test test/kernel_test.dart --plain-name "context tools"

# 批次 4
D:\DM\_sdk\flutter\bin\flutter test packages/bao_agent/test/engine/compaction_test.dart
D:\DM\_sdk\flutter\bin\flutter test packages/bao_agent/test/engine/edges_test.dart
D:\DM\_sdk\flutter\bin\flutter test packages/bao_agent/test/engine/tools_test.dart

# 静态检查
D:\DM\_sdk\flutter\bin\dart analyze packages/bao_agent lib test
```

> 实际测试文件以创建时的名称为准；每批完成后把真实命令补到本节。

### 9.4 验收标准

- 每批新增测试全部通过。
- 既有相关测试与基线相比无新增失败。
- `dart analyze` 无新增 warning/error。
- 项目可启动；上下文管理关闭时行为与改动前一致。
- 每批单独提交，提交信息说明批次号与验证命令。

---

## 10. 状态表

> 状态取值：未开始 / 进行中 / 已完成 / 放弃。
> 每批完成后更新；放弃项必须在第 8 节有原因。

| 编号 | 项目 | 状态 | 提交 | 验证 |
| --- | --- | --- | --- | --- |
| B1-1 | API 失败分类与 errand 重试 | 已完成 | 批次 1 | `api_error_kind_test.dart`、`anthropic_client_test.dart` 全通过 |
| B1-2 | 危险命令与凭据路径守卫 | 已完成 | 批次 1 | `dangerous_commands_test.dart`、`permissions_units_test.dart` 全通过 |
| B1-3 | 非交互审批超时 | 已完成 | 批次 1 | `permissions_test.dart --plain-name "times out"` 通过 |
| B1-4 | 恢复会话已读状态 | 已完成 | 批次 1 | `resume_read_state_test.dart` 4 条全通过 |
| B2-1 | CompressionBlock 存储与重建 | 未开始 | — | — |
| B2-2 | 请求视图、refs、前缀缓存 | 未开始 | — | — |
| B2-3 | ContextCompression 核心 | 未开始 | — | — |
| B3-1 | 隐藏工具与 toolbox | 未开始 | — | — |
| B3-2 | `compress` | 未开始 | — | — |
| B3-3 | `decompress` / `search_context` / `acp_status` | 未开始 | — | — |
| B3-4 | 增长提醒 | 未开始 | — | — |
| B3-5 | CCR 与 `retrieve_tool_result` | 未开始 | — | — |
| B3-6 | 子会话父链只读回退 | 未开始 | — | — |
| B3-7 | UI 隐藏与压缩提示 | 未开始 | — | — |
| B4-1 | 自动压缩阈值 | 未开始 | — | — |
| B4-2 | 保留最近助手轮次 | 未开始 | — | — |
| B4-3 | microcompaction 轮次与保护 | 未开始 | — | — |
| B4-4 | 收尾验证与报告 | 未开始 | — | — |

---

## 11. 回滚与风险

- 每个批次独立提交；按批次 `git revert` 即可回滚。
- 上下文管理可由 `contextManagement.enabled = false` 整体关闭；关闭后请求视图、工具列表、UI 均回到改动前。
- 审批超时可由 `permissions.approvalTimeoutSeconds = 0` 关闭。
- 危险命令守卫是“询问”而非“拒绝”，用户仍可在审批中点允许；如误报过多，可回退 B1-2 而不影响其他批次。
- 会话文件新增行对旧版本是未知 system 行；旧版本跳过，不影响读取。
- 主要风险：压缩边界错误导致工具调用/结果配对失败；由 B2-1/B2-2 的单元测试与“无块时逐字节一致”守住。
