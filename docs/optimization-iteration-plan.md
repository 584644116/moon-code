# BaoCode 优化迭代方案（最终合并版）

> 本文把 2026-10-21 的多角色分析、`docs/reference-integration-plan.md` 中已完成的批次 1–4，以及对 `deepseek-harness`（下称 dsh）的机制核对合并成一份可执行的路线图。
>
> `reference-integration-plan.md` 继续保留为批次 1–4 的施工记录和状态表；**后续迭代以本文为准**。
>
> 编写日期：2026-10-21
>
> 本轮只做方案，不改代码。

---

## 0. 结论先行

1. **批次 1–4 已经把“上下文可逆管理”这条主线打通**：可逆折叠、稳定引用、CCR 卸载、`retrieve_tool_result`、压缩阈值按答案预留、保留最近一轮对话、microcompaction 保护错误/媒体/已卸载结果。相关测试除既有基线失败外均通过。
2. **dsh 最大的价值不是再给一套压缩算法，而是补齐“工具执行层”的四个缺口**：
   - 大结果在进入模型前就被工具自己截断，中段永久丢失（Bash 的 `_truncate`）；
   - 同一工具同参数反复调用时没有提醒；
   - 工具没有统一的超时预算（目前只有 Bash 的 input timeout、WebFetch 的 60 秒）；
   - 审批没有风险标签，也没有独立审计记录。
3. **dsh 的 compaction / retry / subagent / offload 设计与 BaoCode 已实现的部分高度同构**，说明方向正确；只需要补“按模型可配”“字符级剪枝”“空回答分类”这些增量，不需要推翻现有实现。
4. **明确不采纳**：Cordis 插件树、append-only 事件日志 + `deriveMessages()`、token-meter 的回放计价、Windows ACL 沙箱、终端工具、插件化 profile/bundle。它们要么与 BaoCode 的 Kernel 抽象重复，要么会显著扩大运行时和平台风险。
5. **下一轮 P0 共 7 项**，全部可以在不改变 `control_request` / `control_response` 既有语义、不改变会话 JSONL 既有行类型的前提下完成；其中 4 项落在 `lib/chat/panels/`、`lib/chat/composer/` 和 `packages/bao_agent` 的工具执行层，风险最低，应先做。

---

## 1. 许可与参照边界

| 项目 | 形态 | 许可 | 本方案允许的用法 | 明确禁止 |
| --- | --- | --- | --- | --- |
| `D:\DM\4\deepseek-harness` | Node/TypeScript，Cordis 插件树 | **MIT**（Copyright (c) 2026 DeepSeek） | 借鉴机制与参数，用 Dart 独立实现；若未来直接移植代码，必须保留 MIT 版权与许可文本 | 不把 Node 运行时或其插件体系引入 BaoCode；不整段搬运 TypeScript |
| `D:\DM\4\ZCode` | TypeScript | Apache-2.0 | 借鉴权限守卫、风险分级、失败分类、压缩策略；独立重写 | 不整段搬运；直接引用时保留版权与 NOTICE |
| `D:\DM\4\claudecodeui` | Web/Node | AGPL-3.0-or-later | **只提炼交互与产品思路** | 不复制任何代码到 GPL-3.0 的 BaoCode |
| `D:\DM\4\claude-code-best` | 逆向工程快照 | 无 LICENSE | 只把协议与会话格式当事实参考 | 不复制代码；不随产品分发 |
| `D:\DM\4\billion-context` | Node/TS | MIT + 强制署名附加条款 | 借鉴可逆范围压缩、前缀缓存友好折叠、CCR、父链只读回退 | 不作为 Dart 库嵌入；不作为 sidecar 随包分发；不复制代码 |

> 本文所有“借鉴 dsh”的条目都是**设计参照 + Dart 独立实现**，不产生 MIT 署名义务；如果实施时决定逐段移植其实现，必须在该文件头保留 MIT 许可文本，并在 `docs/reference-integration-plan.md` 记录来源。

---

## 2. 不可改变的行为边界

### 2.1 宿主协议与会话格式

1. `control_request` / `control_response` 的既有子类型、字段、返回形状不变：`initialize`、`can_use_tool`、`set_permission_mode`、`set_model`、`get_settings`、`mcp_status`、`rewind_files`、`stop_task` 等。
2. 新增能力只以**新增子类型**或**新增可选字段**出现；老宿主不认识时可忽略。
3. 会话文件 `<config>/projects/<cwd>/<session>.jsonl` 的既有行类型、字段、`parentUuid` / `logicalParentUuid` 语义不变。只允许新增可忽略的 `system` 子类型和可选字段；子代理 `agent-<id>.jsonl` 命名不变。
4. `KernelEvent`、`ChatItem`、`ToolCallItem`、`Interaction*` 的既有形状不变；上下文管理工具仍不显示为工具卡片。

### 2.2 `lib/channel/` 的行为契约（改动前必须逐条核对）

以下内容视为渠道侧的对外契约，任何迭代都不得改变：

1. `AccountAdapter` 的构造方式和字段：`site`、`send`、`credential`、`onCredential`、`now`（`lib/channel/account/account_api.dart:162`）。
2. `AccountAdapter` 的公开方法签名与语义：`signedIn`、`profile`、`keys`、`reveal`、`groups`、`create`、`signOut`、`forget`、`renewed`、`protocolFor`。
3. new-api 适配器的登录/刷新事实：cookie 中的 `new_api_refresh`，刷新端点 `/api/user/auth/refresh`（`lib/channel/account/newapi_adapter.dart`）。
4. sub2api 适配器的登录/刷新事实：localStorage 中的 `refresh_token`，刷新端点 `/api/v1/auth/refresh`（`lib/channel/account/sub2api_adapter.dart`）。
5. 凭据只经 `SecretStore` 持久化，不得写入日志、诊断包、会话 JSONL 或移动端 link 消息。
6. `ChannelGate` 的 `ChannelStage` 状态机与 `find` / `retry` / `confirmAgain` / `_take` / `_drop` / `_dropAccount` 的既有语义（`lib/channel/channel_gate.dart:9`、`:39`）。
7. 渠道请求的 URL 路径、方法、请求体字段、错误分类不得改变；新增字段只能是可选的、服务端可忽略的。
8. 任何涉及渠道适配的改动都标记 **需回归验证**，至少跑 `test/channel/account_test.dart`、`test/channel/account_send_test.dart`、`test/channel/channel_setup_test.dart`、`test/settings/accounts_page_test.dart`。

### 2.3 权限语义

1. 既有规则优先级不变：**deny → ask → 工具自身 → 模式 → allow → ask**。
2. 不新增“规则型拒绝”；新增的只能是更广的**询问**，并沿用现有 `safetyCheck`。
3. `bypassPermissions` 下原本就会询问的安全检查（`_askedInFullAccess`，`lib/kernel/claude_code/claude_code_kernel.dart:3285`）仍然询问。
4. 审批超时按拒绝处理，默认 600 秒、`permissions.approvalTimeoutSeconds = 0` 关闭，交互式工具不超时（`packages/bao_agent/lib/src/engine/agent_loop.dart:1300`）。
5. 新增的风险标签只做展示与审计，**不改变 allow/deny 判定**；“失败关闭”路径保持。
6. 涉及权限的改动标记 **需回归验证**，至少跑 `packages/bao_agent/test/engine/permissions_test.dart`、`test/kernel_test.dart`、`packages/bao_agent/test/engine/controls_test.dart`。

### 2.4 移动端 link 协议

1. `LinkMethods` 的既有方法名与参数不变（`packages/bao_link/lib/src/protocol.dart`）。
2. `LinkSessionUpdate` 只允许新增可选字段；旧版移动端忽略后必须仍能正常显示（`:507`）。
3. 配对、X25519、安全码、二维码 token 的既有流程不变。
4. 涉及 link 的改动标记 **需回归验证**，至少跑 `packages/bao_link/test/` 下相关测试和 `lib/link/workspace_bridge.dart` 的现有测试。

---

## 3. dsh 机制核对：已有、补强、不采纳

| dsh 机制 | dsh 的关键做法 | BaoCode 现状 | 结论 |
| --- | --- | --- | --- |
| `packages/spill/spill-policy` | 超预算结果写入私有文件，模型只看到首尾预览 + 路径 + 读取提示；保存失败时退回原结果 | `Bash._truncate` 在进入引擎前丢掉中段（`bash_tool.dart:286`、`:391`）；`_offloadIfLarge` 只能看到截断后的文本（`agent_loop.dart:908`） | **补 P0-2**：先留全文，再让 offload 决定占位 |
| `packages/compaction/compaction-basic` | `floor(min(W×0.8, W−O−65536))`，保留 `W−O` 的 16%，工具对平衡，溢出重试 1 次 | 已实现阈值 `max(W×0.5, W−(min(maxOutput, 21000)+13000))`、保留最近一轮、失败熔断（`compaction.dart:87`） | **已对齐，补 P1-1**：按模型可配 + 溢出重试 |
| `packages/compaction/compaction-tool-result-pruner` | 单条结果超过 8192 码点 → 头 4096 + 尾 1024 | 只有按“组”清除的 microcompaction（`compaction.dart` `_microKeepGroups = 5`） | **补 P1-2**：字符级剪枝，先于整组清除 |
| `packages/compaction/compaction-image-offload` | `IMAGE_OFFLOAD_REQUIRED` 时永久省略最旧图片，重试不占普通重试预算 | 请求失败只按普通错误重试；没有图片卸载 | **补 P1-10**，先确认供应商错误形状 |
| `packages/llm/llm-retry` | `EMPTY_RESPONSE` / `RATE_LIMIT` / `SERVER` / `TIMEOUT` / `TRANSPORT` 分类，5 次、500ms→10s、10% 抖动 | 已有 429/5xx/网络/`Retry-After`、最多 10 次、`stream_restart`（`anthropic_client.dart:120`）；“The answer ended early”只是泛化 `retryable`（`:274`） | **补 P0-4**：空回答单独分类与计数 |
| `packages/guard/repeat-tool-reminder` | 同参数连续 3/5/8 次时提醒，500 字符参数预览，建议性、不阻断，新用户消息清零 | 无 | **补 P0-3** |
| `packages/guard/timeout-policy` | 工具在 `ToolDefinition` 声明 `timeoutMs`，统一包装为 `TOOL_TIMEOUT` | Bash 有 input `timeout`（`bash_tool.dart:334`），WebFetch 固定 60 秒（`web_tools.dart:248`），其余无 | **补 P0-5** |
| `packages/interaction/user-approval` | `ask` / `never`，应答者缺失即失败关闭，`approval/asked`、`approval/decided` 只写审计日志 | 已有权限模式、审批超时、`can_use_tool`（`agent_loop.dart:1281`）；无风险标签、无审计 | **补 P0-6**：本地风险标签 + 本地审计文件 |
| `packages/interaction/permission-presets` | 把 sandbox 与 approval 组合成预设 | 已有权限模式与工作模式，但无 sandbox 组合 | 暂不采纳，见 P2 |
| `packages/sandbox/sandbox-policy` | `read-only` / `workspace-write` / `danger-full-access`，默认 `read-only` | 只有 Bash 的 `dangerouslyDisableSandbox` 参数与 Codex kernel 的 sandbox 选项；没有统一文件沙箱 | **P2 观察，不落地** |
| `packages/sandbox/sandbox-windows-acl` | 受限令牌、能力 SID、Low 完整性 | 无 | **不采纳**：平台侵入性过强，见 §6 |
| `packages/goal/goal-round-driver` | agent idle 时按 `maxGoalRounds` 自动续轮，人类消息让行 | 有 `GoalPanel`、`setGoal` / `clearGoal` / `dismissGoal`（`lib/chat/chat_session.dart:762`），但不会自动续轮 | **P2-1** |
| `packages/schedule/tool-schedule` | `after_seconds` / `at` / `every_seconds` / `daily` / `weekly` / `cron` 六选一 | 有 `QueuePanel` 的排队消息，无定时 | **P2-2** |
| `packages/session-query/session-log-export` | 会话树 + 子会话 + 附件打成 ZIP，`/export` | 无导出 | **补 P1-3** |
| `packages/deliverables/workspace-changes` | 每轮文件快照、行数、diff，最多 500 文件 | 有 `FileChange`、`ChangeReview`、`change_tree.dart`，但没有“本轮改动”汇总卡 | **补 P1-4** |
| `packages/deliverables/tool-present` | 模型声明交付物，最多 8 个文件 | 无 | **补 P1-4** 的展示部分 |
| `packages/context/session-reference` | `@[label](dsh-session:…)`，每条消息最多 3 个来源，附不受信任警告 | 有会话搜索，但 composer 无跨会话引用 | **补 P1-8** |
| `packages/session-query/session-query-sqlite` | SQLite FTS5 全文索引 | 内存搜索（`lib/search/conversation_search.dart`） | **补 P1-9** |
| `packages/llm/token-meter` | 回放日志、确定性估算、仅在请求 envelope 完全一致时复用 provider usage | 已有 `estimateTokens`、`lastUsage`、`ContextUsage` | **不采纳回放**；只借鉴“估算与 provider usage 分开”的原则 |
| Cordis 插件树 / profiles / bundles | 一切皆插件、seam 组合 | `AgentKernel` + capability interfaces + `KernelRegistry`（`lib/kernel/agent_kernel.dart`、`lib/kernel/kernel_registry.dart`） | **不采纳**：抽象目标相同，重复建设 |
| append-only 事件日志 + `deriveMessages()` | 持久日志是唯一事实源 | `SessionStore` 已经以 JSONL 为事实源并提供投影 | **不采纳**：现有模型更简单 |
| `packages/experimental/tool-terminal` | 6 个交互式终端工具 | 有 `bao_pty` 的 UI 终端 | **不采纳**：与 Bash 重复，且交互协议复杂 |
| `packages/lsp/tool-lsp` | 4 个只读 LSP 操作 | 无 | **P2-3** |

---

## 4. P0：下一轮必须完成（低协议风险、直接改善日常体验）

> 成本口径：**S** ≤ 0.5 人日，**M** ≈ 1–2 人日，**L** ≈ 3–5 人日。
>
> 所有 P0 都不改 `control_request` / `control_response` 的既有字段语义，不改会话 JSONL 既有行类型。

### P0-1 上下文用量与压缩阈值同源

- **问题**：`contextUsage()` 用 `session.compactBuffer` 当“压缩缓冲区”（`packages/bao_agent/lib/src/engine/engine.dart:608`），而自动压缩实际在 `Compaction.threshold` 触发（`compaction.dart:87`）。`compactBufferOf` 对 ≥100k 窗口固定返回 33000（`session.dart:496`），阈值预留却是 `min(maxOutput, 21000) + 13000 = 34000`。面板因此把 1000 token 算进了“已用”，而不是“缓冲区”；小窗口（<100k）则恰好一致。这会让用户对“还剩多少可写”的判断偏移。
- **依据**：本仓库实现；dsh `compaction-basic` 把 `threshold` 与 `headroomTokens` 作为同一个配置派生（设计参照）。
- **落点**：
  - `packages/bao_agent/lib/src/engine/engine.dart:588` `contextUsage()`：`buffer` 改为 `window - Compaction.thresholdOf(window, maxOutput: ...)`，或直接暴露 `compaction.threshold` 的“预留区”。
  - `packages/bao_agent/lib/src/engine/compaction.dart:95` `thresholdOf`：保持唯一真源；必要时新增 `reserveOf(window, maxOutput:)` 供 UI 调用。
  - `lib/kernel/kernel_types.dart:116` `ContextSegment` / `:126` `ContextUsage`：可新增可选的 `triggerTokens`、`reserveTokens`，不改既有字段。
  - `lib/chat/panels/context_usage_panel.dart` `ContextUsagePanel`：在缓冲区上显示“压缩触发线”，文案从 `engine.dart:618` 的“Autocompact buffer”改为可解释的“为回答与请求预留”。
- **协议/存储**：`get_context_usage` 响应只新增可选字段；会话文件不变。
- **新增/测试**：扩展 `packages/bao_agent/test/engine/controls_test.dart` 的 `get_context_usage` 断言；新增 `context_usage_math_test.dart` 覆盖 32k / 128k / 200k / 1M 四种窗口。UI 侧扩展 `test/chat/` 下现有面板测试（若存在 `context_usage_panel` 的 widget 测试，则在其内加断言）。
- **成本**：S。
- **需回归验证**：是（`get_context_usage` 的响应形状）。

### P0-2 大工具结果“先留全文，再截断”

- **问题**：Bash 在工具内部就把 stdout/stderr 截到 30000 字符，`_truncate` 只保留首尾各一半，中段永久丢失（`packages/bao_agent/lib/src/tools/bash_tool.dart:21`、`:286`、`:391`）。等结果进入 `agent_loop._offloadIfLarge` 时，已经没有完整文本可卸载（`agent_loop.dart:908`）。`OffloadedResult` 的预览也只取开头（`compression_blocks.dart:90`），没有路径、没有尾部。
- **依据**：dsh `spill-policy`（MIT，设计参照）：超过 `maxInlineTokens` 的结果写入私有文件，模型看到首尾预览、字节数与读取提示；保存失败时退回原结果。
- **落点**：
  - `packages/bao_agent/lib/src/tools/bash_tool.dart:286`：把完整输出（设硬上限，例如 4 MiB）交给 `ToolOutput`；不再在工具内丢中段。若超过硬上限，仍按现有方式截断并明确说明。
  - `packages/bao_agent/lib/src/engine/agent_loop.dart:908` `_offloadIfLarge`：超过 `contextCcrMinTokens` 时，把全文写入 `<session 文件同目录>/tool-results/<tool_use_id>.txt`，占位符带 `head` / `tail` 预览、字节数、路径和 `retrieve_tool_result` 提示；写文件失败时退回当前“全文留在 JSONL”的行为。
  - `packages/bao_agent/lib/src/engine/compression_blocks.dart:90` `OffloadedResult`：新增可选的 `path`、`bytes`、`headChars`、`tailChars`；`entry()` / `fromEntry()` 只增字段。
  - `packages/bao_agent/lib/src/engine/context_compression.dart` 的 `toolResultContent(id)`：优先读 `path`，读不到再读会话记录。
  - `packages/bao_agent/lib/src/tools/context_tools.dart:250` `RetrieveToolResultTool`：无需改 schema，`offset` / `limit` 已足够。
- **协议/存储**：会话 JSONL 只新增可选字段；新增 `tool-results/` 目录，不改变既有文件命名。CLI kernel 不受影响（工具在 CLI 内执行，BaoCode 不接管）。
- **新增/测试**：新增 `packages/bao_agent/test/engine/spill_test.dart`（大结果写文件、预览首尾、读回、写失败回退）；扩展 `tools_test.dart` 的 Bash 长输出用例与 `context_tools_test.dart`。
- **成本**：M。
- **需回归验证**：是（`_offloadIfLarge` 的投影、`retrieve_tool_result` 的 golden、长输出测试）。

### P0-3 重复工具调用提醒

- **问题**：模型可能以完全相同的参数连续调用同一工具，消耗轮次和 token，却没有进展。BaoCode 没有检测。
- **依据**：dsh `repeat-tool-reminder`（MIT，设计参照）：连续 3/5/8 次提醒，参数预览上限 500 字符，只建议、不阻断，新用户消息清零。
- **落点**：
  - 新增 `packages/bao_agent/lib/src/engine/repeat_guard.dart`：按 `(toolName, canonicalJson(input))` 计数，维护每个 agent 的独立状态；在工具结果追加后返回一条可选的提醒文本。
  - `packages/bao_agent/lib/src/engine/agent_loop.dart:860` `_appendResult` 之后：以 `isMeta: true` 的 user 消息追加提醒（与现有 followUp 机制一致），或作为 `NoticeItem` 由宿主显示；不新增工具、不改协议。
  - 计数在收到新的真实用户消息时清零；子代理按 `agentId` 独立。
- **协议/存储**：只新增可忽略的 `isMeta` 消息；会话格式不变。
- **新增/测试**：新增 `packages/bao_agent/test/engine/repeat_guard_test.dart`（3/5/8 触发、新用户消息清零、不同 agent 隔离、不同参数不触发）。
- **成本**：S。
- **需回归验证**：否（若作为 meta 消息写入，则 `request_test.dart` 的请求快照需确认不包含提醒；建议默认只在达到阈值时写入）。

### P0-4 空回答的定向恢复

- **问题**：供应商偶尔返回 `end_turn` 但没有文本（只有 reasoning、或完全没有 content）。当前 `anthropic_client.dart:274` 把它归为 `'The answer ended early'` 的泛化可重试错误，与网络/5xx 共用同一预算；重试次数用尽后用户只看到一条普通错误。
- **依据**：dsh `llm-retry`（MIT，设计参照）：`EMPTY_RESPONSE` 是独立分类，单独计数、单独提示。
- **落点**：
  - `packages/bao_agent/lib/src/api/anthropic_client.dart:274`：新增 `ApiFailureKind.emptyResponse`（枚举在 `packages/bao_agent/lib/src/api/model_client.dart:40`），`_retryableType` / `_error` 映射到该分类。
  - `packages/bao_agent/lib/src/api/anthropic_client.dart:120` `stream()`：空回答最多重试 2 次（可配），超过后抛出带可读原因的 `ApiError`；不改变现有 429/5xx 的 10 次预算。
  - `packages/bao_agent/lib/src/engine/agent_loop.dart`：捕获该错误时，若本轮已有工具结果，提示模型“上一次回答为空，请基于已有结果继续”，而不是直接结束整个会话。
- **协议/存储**：无。
- **新增/测试**：扩展 `packages/bao_agent/test/engine/request_test.dart` 或新增 `api/empty_response_test.dart`，用假客户端返回空 content + `end_turn`，断言重试次数、错误分类与最终提示。
- **成本**：S–M。
- **需回归验证**：是（API 重试行为）。

### P0-5 工具级超时

- **问题**：除 Bash 的 input timeout 和 WebFetch 的固定 60 秒外，其他工具没有统一预算。一个卡住的 MCP 调用、`TaskOutput`、浏览器工具或子代理工具可以拖住整个轮次。
- **依据**：dsh `timeout-policy`（MIT，设计参照）：工具在定义上声明 `timeoutMs`，统一包装为 `TOOL_TIMEOUT` 结构化错误；未声明的工具原样委派。
- **落点**：
  - `packages/bao_agent/lib/src/tools/tool.dart:87` `Tool`：新增 `Duration? get timeout => null;`，只读、无默认值，避免改变既有工具行为。
  - `packages/bao_agent/lib/src/engine/agent_loop.dart:1074` `tool.call(...)`：有 `timeout` 时用 `Future.timeout` 包装，超时返回 `ToolOutput.error('Error: tool call timed out after <ms>ms')`，并设置错误码（若 `ToolOutput` 支持）。
  - 先给 `WebFetch`（替代裸 60 秒）、`TaskOutput`、MCP 工具和浏览器工具声明超时；Bash 保持自己的 input timeout，避免双层计时。
- **协议/存储**：只有工具结果文本与 `is_error`，无协议变化。
- **新增/测试**：新增 `packages/bao_agent/test/engine/tool_timeout_test.dart`（声明超时的工具被中断、未声明的不受影响、取消优先于超时、超时后轮次继续）。
- **成本**：S–M。
- **需回归验证**：是（`tools_test.dart` 的 shell 输出/退出码用例，确认未受双层计时影响）。

### P0-6 审批风险标签与本地审计

- **问题**：`ApprovalRequest` 只有 `toolName`、`reason`、`preview`、`alwaysAllowLabel`（`lib/kernel/kernel_types.dart:527`），用户看到的是一段描述，无法一眼判断“是否会删文件 / 是否可撤销 / 是否触网”。同时没有本地审计记录，事后无法回答“这次为什么被允许”。
- **依据**：ZCode 的 `RiskLevel`（Apache-2.0，设计借鉴）；dsh `user-approval` 的 `approval/asked` + `approval/decided` 审计思路（MIT，设计参照）。
- **落点**：
  - `lib/kernel/kernel_types.dart:527` `ApprovalRequest`：新增可选的 `risk`（枚举：read / write / destructive / network / credential）、`reversible`（bool?）、`source`（kernel / mcp / hook / sdk）。
  - `lib/kernel/claude_code/claude_code_kernel.dart:1665` 和 `:1954`：构造 `ApprovalRequest` 时根据工具名与 input 计算风险；不依赖 CLI 返回新字段。
  - `lib/chat/panels/interaction_panel.dart` `_ApprovalPreview`：显示风险 chip 与“可撤销/不可撤销”；危险操作（删除、强推、凭据路径）用醒目颜色，但不改变按钮语义。
  - 新增 `packages/bao_agent/lib/src/engine/approval_audit.dart`：在 `agent_loop.dart:1279` 的 `hostRequest('can_use_tool', …)` 前后写 `<config>/approvals/<session>.jsonl`，记录 `asked` / `decided`、工具名、风险、决定、耗时；不写入会话 JSONL。
  - `packages/bao_agent/lib/src/config/settings.dart`：新增 `approvalAuditEnabled`（默认 true）与保留天数。
- **协议/存储**：内置 kernel 可在 `can_use_tool` 请求中新增可选 `risk` / `reversible` 字段（老宿主忽略）；CLI kernel 不依赖新字段，风险在本地计算。会话 JSONL 不变。
- **新增/测试**：新增 `packages/bao_agent/test/engine/approval_audit_test.dart`（allow / deny / timeout 三种记录）；扩展 `test/kernel_test.dart` 的审批翻译断言；UI 侧扩展 `test/chat/` 下 interaction panel 测试。
- **成本**：M。
- **需回归验证**：是（`can_use_tool` 请求形状、审批 UI）。

### P0-7 浏览器敏感工具确认

- **问题**：`browser_evaluate`（`lib/browser/browser_tools.dart:278`）可以在已登录的标签页里执行任意 JavaScript；`browser_intercept`（`lib/browser/browser_intercept.dart:339`）和 `browser_watch`（`lib/browser/browser_watch.dart:569`）能读取/改写网络与页面状态。这些工具通过 SDK MCP 桥暴露给 CLI，BaoCode 自身没有独立的风险确认；在 `bypassPermissions` 或自动分类器放行时，用户可能没有看到明确提示。
- **依据**：ZCode 的风险分级与 dsh `user-approval` 的“敏感操作前取得一次性决定”（均为设计借鉴/参照）。
- **落点**：
  - `lib/browser/browser_tools.dart`：为 `browser_evaluate` 增加本地风险判定（脚本是否读取 `document.cookie`、`localStorage`、`sessionStorage`、`fetch`/`XMLHttpRequest`，是否导航到非用户给定 URL）。
  - `lib/kernel/claude_code/claude_code_kernel.dart:1665`：把该风险带入 `ApprovalRequest.risk`，让 `interaction_panel` 显示“此脚本可读取登录态”之类的说明。
  - `lib/browser/browser_intercept.dart` / `browser_watch.dart`：对“改写请求体/响应体”“监听所有标签页”给出一次性确认；只读查询不额外询问。
  - `lib/settings/pages/browser_page.dart`：新增“敏感浏览器工具总是询问”开关（默认开）；关闭时仍受 `bypassPermissions` 的既有语义约束。
- **协议/存储**：风险字段只在内置 kernel 的 `can_use_tool` 中新增可选字段；CLI 侧由本地计算。无会话格式变化。
- **新增/测试**：新增 `test/browser/browser_risk_test.dart`（cookie/localStorage/fetch/导航四类判定）；扩展 `test/kernel_test.dart` 的 SDK 工具审批用例。
- **成本**：M。
- **需回归验证**：是（浏览器工具与 SDK 工具审批）。

---

## 5. P1：紧随其后（产品完整度与成本控制）

### P1-1 压缩策略按模型可配 + 溢出重试

- **问题**：`Compaction.thresholdOf` 目前是全局公式，`maxOutput` 来自模型目录；不同模型（长输出、低窗口、供应商差异）没有单独策略。压缩后如果仍然超出窗口，没有“再压一次”的溢出重试。
- **依据**：dsh `compaction-basic`（MIT，设计参照）：`thresholdRatio`（默认 0.8）、`headroomTokens`（65536）、`retainRatio`（0.16）、`maxOverflowRetries`（1）、`modelPolicies`。
- **落点**：`packages/bao_agent/lib/src/engine/compaction.dart:87` 的 `thresholdOf` 与 `compaction.dart` 的 `compact()`；`packages/bao_agent/lib/src/config/settings.dart` 的 `contextManagement` 段；`packages/bao_agent/lib/src/engine/session.dart:493` 的 `compactBuffer` 只保留为兼容别名。
- **协议/存储**：无；压缩仍写既有 `compact_boundary`。
- **测试**：扩展 `compaction_rounds_test.dart`（按模型覆盖、溢出重试一次、保留比例边界）。
- **成本**：M。**需回归验证**：是（压缩阈值与 `get_context_usage`）。

### P1-2 单个工具结果字符级剪枝

- **问题**：microcompaction 只在“组”级别清除整个结果，粒度太粗；一个 20000 字符的日志和一个小 `Read` 被同等对待。
- **依据**：dsh `compaction-tool-result-pruner`（MIT，设计参照）：超过 8192 码点 → 头 4096 + 尾 1024 + 省略标记；只在压力下触发。
- **落点**：`packages/bao_agent/lib/src/engine/compaction.dart` 的 `microcompact()`：在整组清除之前，先对单条大结果做字符级剪枝；保护 `is_error`、图片、文档、已卸载结果（沿用现有 `_hasMedia` 与 `offloadedToolResults` 检查）。
- **协议/存储**：剪枝结果只影响发送给模型的投影；原结果仍在会话文件中。
- **测试**：扩展 `compaction_rounds_test.dart`（8192 边界、头尾长度、保护错误/媒体）。
- **成本**：S。**需回归验证**：否。

### P1-3 会话日志 ZIP 导出

- **问题**：用户无法把一次会话（含子代理与附件）整体导出给同事或存档；目前只能翻 JSONL。
- **依据**：dsh `session-log-export`（MIT，设计参照）：会话树 + 子会话 + 附件打成 ZIP，`/export` 命令，浏览器下载；流式、有界。
- **落点**：
  - 新增 `lib/search/session_export.dart`：读取 `<config>/projects/<cwd>/<session>.jsonl`、同目录 `subagents/agent-*.jsonl`、附件目录，流式写 ZIP。
  - `lib/chat/chat_session.dart`：新增 `exportSession()`；`lib/chat/panels/` 增加菜单项；`/export` 斜杠命令接入现有命令分发。
  - 设置项：导出是否包含附件（默认包含）、单文件上限。
- **协议/存储**：只读会话文件，不改变格式；ZIP 结构为新增产物。
- **测试**：新增 `test/search/session_export_test.dart`（含子代理、附件、空会话、损坏行跳过）。
- **成本**：M。**需回归验证**：否。

### P1-4 本轮改动卡与交付物

- **问题**：`ChangeReview` / `change_tree.dart` 能看累计改动，但用户很难回答“这一轮 agent 到底动了什么”；也没有“模型声明的交付物”这一层。
- **依据**：dsh `workspace-changes`（每轮文件快照、行数、diff，最多 500 文件）与 `tool-present`（最多 8 个交付文件）（MIT，设计参照）。
- **落点**：
  - `lib/chat/chat_models.dart:681` 的 `FileChange`：`added` / `removed` 已有，只需新增可选 `turnId`（用于按轮分组）。
  - `lib/chat/review/change_review.dart`、`lib/chat/panels/activity_strip.dart`：新增“本轮改动”分组，显示文件数、增删行数、可展开 diff。
  - 新增 `packages/bao_agent/lib/src/tools/present_tool.dart`：模型声明交付物（最多 8 个），结果进入一个 `PresentItem`；`lib/chat/panels/` 渲染为交付物卡。
  - `lib/kernel/claude_code/claude_code_translator.dart`：把 `present` 的工具调用翻译成卡片（仅内置 kernel；CLI 不提供该工具）。
- **协议/存储**：`present` 只在内置 kernel 的工具表出现；会话 JSONL 只新增普通工具调用行。
- **测试**：新增 `packages/bao_agent/test/engine/present_test.dart`；UI 侧新增/扩展 `test/chat/` 的 change review 测试。
- **成本**：M。**需回归验证**：是（工具表与翻译器）。

### P1-5 MCP 面板细化

- **问题**：`McpServersPanel` 目前主要显示服务器状态；工具、资源、提示、错误详情不足，排障困难。
- **依据**：dsh 工具目录与 `mcp_status` 的既有协议事实（协议参考）；产品交互参考 claudecodeui（仅思路）。
- **落点**：`lib/chat/panels/mcp_servers_panel.dart`、`lib/kernel/kernel_types.dart:237` `McpServer`（新增可选的 `tools` / `resources` / `prompts` / `lastError`）。
- **协议/存储**：`mcp_status` 响应只新增可选字段；无会话格式变化。
- **测试**：扩展 `test/kernel_test.dart` 的 MCP 状态翻译；UI 侧扩展面板测试。
- **成本**：M。**需回归验证**：是（MCP 状态）。

### P1-6 诊断包与日志秘密清洗

- **问题**：`packDiagnostics` / `packDiagnosticsSync` 只做 `redactHome`（`lib/diagnostics/diagnostics_bundle.dart`），没有对 API key、bearer token、cookie、渠道 refresh token 的清洗。
- **依据**：安全审计视角；ZCode 的 `provider-business-error` 对错误信息的处理（Apache-2.0，设计借鉴）。
- **落点**：`lib/diagnostics/diagnostics_bundle.dart`：新增 `scrubSecrets(String)`，覆盖 `sk-…`、`Bearer …`、`x-api-key`、`cookie`、`new_api_refresh`、`refresh_token`；在打包前对日志、设置、错误文本统一调用。新增测试用假值断言不泄漏。
- **协议/存储**：无。
- **测试**：新增 `test/diagnostics/scrub_test.dart`（多种 token 形态、JSON、多行、误报边界）。
- **成本**：S。**需回归验证**：否。

### P1-7 移动端上下文与压缩状态

- **问题**：`LinkSessionUpdate` 带 items、choices、changes、tasks，但没有上下文用量/压缩状态（`packages/bao_link/lib/src/protocol.dart:507`）；手机上无法判断会话是否接近压缩。
- **依据**：本仓库能力补齐；dsh 的 token-meter 只借鉴“压力可被消费方共享”的原则（MIT，设计参照）。
- **落点**：`packages/bao_link/lib/src/protocol.dart:507` `LinkSessionUpdate` 新增可选 `context`（总/已用/触发线/是否已压缩）；`lib/link/workspace_bridge.dart:796` 填充；`docs/mobile-link.md` 更新字段表。
- **协议/存储**：只新增可选字段；旧版移动端忽略。
- **测试**：扩展 `packages/bao_link/test/` 的序列化往返测试；`lib/link` 现有测试。
- **成本**：M。**需回归验证**：是（移动端协议）。

### P1-8 跨会话引用

- **问题**：用户在一个会话里想引用另一个会话的结论，只能复制粘贴；搜索能找到，但不能作为结构化引用进入上下文。
- **依据**：dsh `session-reference`（MIT，设计参照）：`@[label](dsh-session:…)`，最多 3 个来源，附“不受信任背景”警告，预算受限。
- **落点**：
  - `lib/chat/composer/file_mentions.dart` / `suggestion_menu.dart`：新增会话提及（复用现有文件提及的交互）。
  - `lib/search/conversation_search.dart`：提供按 id 读取会话摘要的能力。
  - `packages/bao_agent`：新增会话引用解析，把引用内容作为第二条 user 消息注入，附固定警告；超出预算时先丢弃较早消息，再缩短文本。
- **协议/存储**：提示层新增内容，会话文件只记录普通 user 消息；不改变 `@file` 语义。
- **测试**：新增 `packages/bao_agent/test/engine/session_reference_test.dart`；composer 测试。
- **成本**：M。**需回归验证**：否。

### P1-9 会话全文索引

- **问题**：`conversation_search` 在内存中扫描 JSONL，会话多时慢，且无法做稳定的相关度排序。
- **依据**：dsh `session-query-sqlite`（MIT，设计参照）：SQLite FTS5。
- **落点**：`lib/search/conversation_search.dart` / `conversation_search_io.dart`：新增可选索引层（SQLite 或本地倒排文件），索引损坏/缺失时回退到现有扫描；索引只读会话文件，不成为事实源。
- **协议/存储**：新增索引文件，不改会话格式。
- **测试**：新增 `test/search/conversation_index_test.dart`（增量更新、删除会话、损坏回退、中文分词边界）。
- **成本**：M–L。**需回归验证**：否（但如果引入 SQLite 依赖，需评估各平台打包体积与许可）。

### P1-10 图像卸载

- **问题**：长会话中图片会持续占用上下文；供应商返回“图片过大/过多”时，当前只会按普通错误重试。
- **依据**：dsh `compaction-image-offload`（MIT，设计参照）：`IMAGE_OFFLOAD_REQUIRED` 时永久标记最旧图片为省略，重试不占普通预算。
- **落点**：`packages/bao_agent/lib/src/api/anthropic_client.dart`、`packages/bao_agent/lib/src/engine/compaction.dart`、`packages/bao_agent/lib/src/engine/session_store.dart` 的投影。
- **不确定**：Anthropic 兼容供应商返回的错误码/文案并不统一，需先用真实失败样本确认分类条件；在确认前不落地。
- **协议/存储**：投影层替换图片为占位文本；会话文件保留原图。
- **成本**：M。**需回归验证**：是（图片请求与投影）。

---

## 6. P2：可选、成本高或平台风险大

### P2-1 Goal 自动续轮

- **依据**：dsh `goal-round-driver`（MIT，设计参照）。
- **落点**：`lib/chat/chat_session.dart:762` 的 goal 系列方法；`lib/chat/panels/goal_panel.dart`；新增 `maxGoalRounds`、人类消息让行、取消不自动重启。
- **成本**：M。**风险**：自动续轮可能放大费用，必须默认关闭、显式开启。

### P2-2 定时任务

- **依据**：dsh `tool-schedule`（MIT，设计参照）。
- **落点**：新增 `lib/chat/schedule/`；复用 `QueuePanel` 的展示；调度器只在应用运行时生效。
- **成本**：M。**风险**：后台唤醒与多端一致性，需先定义“应用关闭时是否补跑”。

### P2-3 LSP 工具

- **依据**：dsh `tool-lsp`（MIT，设计参照）。
- **落点**：`packages/bao_agent` 新增只读 LSP 工具；`bao_editor` 已有编辑器侧能力可复用。
- **成本**：L。**风险**：语言服务器生命周期、Windows 路径、超时。

### P2-4 权限预设（sandbox + approval 组合）

- **依据**：dsh `permission-presets`（MIT，设计参照）。
- **落点**：`packages/bao_agent/lib/src/permissions/`、`lib/settings/pages/`。
- **成本**：M。**前置**：先有统一 sandbox 语义，否则只是改名。

### P2-5 OS 文件沙箱

- **依据**：dsh `sandbox-policy` / `sandbox-windows-acl`（MIT，设计参照）。
- **结论**：**当前不做**。Windows ACL 方案会对工作区安全描述符做常驻修改（Low 完整性标签、能力 SID、`FILE_DELETE_CHILD` 拒绝），影响超出 BaoCode 进程生命周期；macOS/Linux 还需要各自实现。先用“权限询问 + 危险命令检测 + 可撤销改动”覆盖主要风险。
- **成本**：L–XL。**风险**：平台安全、卸载残留、与其他工具的兼容。

### P2-6 明确不采纳

| 机制 | 不采纳原因 |
| --- | --- |
| Cordis 插件树 / profiles / bundles | `AgentKernel` + capability interfaces + `KernelRegistry` 已覆盖同样的扩展点；引入插件树会重复抽象并扩大启动成本 |
| append-only 事件日志 + `deriveMessages()` | `SessionStore` 已以 JSONL 为事实源并提供投影；重写会破坏会话兼容 |
| token-meter 回放计价 | BaoCode 已有 `estimateTokens` 与 provider `usage`；回放引擎复杂度高，收益主要是确定性，当前不需要 |
| 终端工具（6 个） | 与 Bash 重复；交互式终端已有 `bao_pty` UI，模型侧再暴露一套会增加协议与安全面 |
| Windows ACL 沙箱 | 见 P2-5 |
| `always` 无上限重试模式 | 会与 BaoCode 的失败熔断、审批超时冲突；无头场景应由显式配置控制 |

---

## 7. 角色视角 → 条目映射

| 角色视角 | 最关心的条目 |
| --- | --- |
| 终端使用者 | P0-1（用量可解释）、P0-3（少绕圈）、P0-6（审批看得懂）、P1-3（导出）、P1-4（本轮改了什么） |
| 对话与评审 UI | P0-1、P0-6、P1-4、P1-5、P1-10 |
| Agent 内核 | P0-2、P0-3、P0-4、P0-5、P1-1、P1-2、P2-1 |
| 上下文压缩与成本 | P0-1、P0-2、P1-1、P1-2、P1-10 |
| MCP、扩展与技能 | P1-5、P1-8、P2-3 |
| 远程、移动与多端 | P1-7、P1-3 |
| 可观测性与调试 | P0-6（审计）、P1-3（导出）、P1-6（脱敏）、P1-9（搜索） |
| 安全与隐私 | P0-6、P0-7、P1-6、P2-5 |

---

## 8. 执行批次与验收

> 原则：先 `lib/chat/panels/`、`lib/chat/composer/` 与工具执行层，后 `lib/channel/` 与权限；每批单独提交；只跑相关测试，不跑全量。

### 批次 5：上下文用量 + 重复提醒 + 工具超时（无协议风险）

- 条目：P0-1、P0-3、P0-5。
- 测试：
  - `cd packages/bao_agent && flutter test test/engine/controls_test.dart test/engine/compaction_rounds_test.dart test/engine/repeat_guard_test.dart test/engine/tool_timeout_test.dart`
  - 若改到 UI：`flutter test test/chat/` 下对应面板测试。
- 验收：`get_context_usage` 的数值在 32k / 128k / 200k / 1M 窗口下自洽；重复提醒只在 3/5/8 次触发；超时只影响声明了 `timeout` 的工具。

### 批次 6：大结果全文保留 + 字符级剪枝

- 条目：P0-2、P1-2。
- 测试：
  - `cd packages/bao_agent && flutter test test/engine/spill_test.dart test/engine/tools_test.dart test/engine/context_tools_test.dart test/engine/compaction_rounds_test.dart`
- 验收：Bash 长输出可在 `retrieve_tool_result` 中完整读回；写文件失败时行为与现在一致；microcompaction 先剪枝后清组。

### 批次 7：空回答 + 压缩策略

- 条目：P0-4、P1-1、P1-10（若错误样本确认）。
- 测试：
  - `cd packages/bao_agent && flutter test test/engine/request_test.dart test/engine/compaction_rounds_test.dart test/api/empty_response_test.dart`
- 验收：空回答单独计数并给出可读提示；压缩阈值按模型覆盖生效；溢出时最多再压一次。

### 批次 8：安全与审批

- 条目：P0-6、P0-7、P1-6。
- 测试：
  - `cd packages/bao_agent && flutter test test/engine/permissions_test.dart test/engine/approval_audit_test.dart`
  - 仓库根：`flutter test test/kernel_test.dart test/browser/browser_risk_test.dart test/diagnostics/scrub_test.dart`
- 验收：风险 chip 显示但不改变 allow/deny；审计文件只记录本地决定；诊断包不含任何 token/cookie。

### 批次 9：产品完整度

- 条目：P1-3、P1-4、P1-5、P1-8。
- 测试：`flutter test test/workspace/session_export_test.dart test/chat/` 下相关测试；`cd packages/bao_agent && flutter test test/engine/present_test.dart test/engine/session_reference_test.dart test/engine/mcp_test.dart`
- 验收：导出的 ZIP 能解开且包含子代理；本轮改动卡与累计改动不重复计数；MCP 面板能显示工具/资源/错误。

### 批次 10：移动端与搜索

- 条目：P1-7、P1-9。
- 测试：`flutter test packages/bao_link/test/ test/search/conversation_index_test.dart test/link/`
- 验收：旧版 `LinkSessionUpdate` 反序列化仍可用；索引缺失/损坏时回退到现有搜索。

### 批次 11（可选）：P2

- 条目：P2-1、P2-2、P2-3、P2-4。
- 每项单独评估，不与 P0/P1 混合提交。

---

## 9. 回归基线与测试纪律

1. `packages/bao_agent` 的 `test/engine/`、`test/units/` 在**干净树**上固定有 15 条 Windows 环境失败，不能当作回归。失败清单见 `C:\Users\z1515\.claude\projects\D--DM-4-baocode\memory\bao-agent-pre-existing-test-failures.md`，核心是路径分隔符、shell 行为、plugin 加载、settings 分层、memory loader。
2. 判据是“失败集合与基线一致”，不是“全绿”。
3. 只跑与改动相关的测试；不跑全量。
4. Flutter SDK 在 `D:\DM\_sdk\flutter`；跑完测试后清理生成的平台目录。
5. 触及 `lib/channel/`、权限、`control_request`/`control_response`、`LinkMethods`、会话 JSONL 的改动，必须在提交说明中标注 **需回归验证** 并列出所跑测试。

---

## 10. 风险与待确认

| 事项 | 状态 | 处理 |
| --- | --- | --- |
| 图片卸载的供应商错误形状 | 不确定 | 先收集真实失败样本；未确认前 P1-10 不落地 |
| 移动端旧版本兼容 | 需回归 | `LinkSessionUpdate` 只加可选字段；跑 `packages/bao_link/test/` |
| SQLite 依赖的打包体积与许可 | 待评估 | 若不可接受，改用本地倒排索引，保持同一接口 |
| dsh 代码直接移植的 MIT 署名 | 未触发 | 当前只借鉴设计；若移植，补版权头与文档记录 |
| OS 沙箱 | 明确不做 | 用权限询问 + 危险命令检测 + 可撤销改动覆盖 |
| 自动续轮/定时任务的费用放大 | 有风险 | 默认关闭、显式开启、设上限 |

---

## 11. 一句话执行建议

**先做批次 5（P0-1 / P0-3 / P0-5），再做批次 6（P0-2 / P1-2），然后批次 8（P0-6 / P0-7 / P1-6）；批次 7 取决于空回答与图片错误样本，批次 9–10 按产品节奏推进，P2 不排期。**
