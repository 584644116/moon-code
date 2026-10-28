# 提示词增强：与 WB Enhance Prompt 1.5.5 的对比，以及迭代方案

> 编写日期：2026-10-29。对比对象：`wb-enhance-prompt-share.js`（WB Enhance Prompt 1.5.5-share，社区移植版，非 WorkBuddy/Augment 官方产品）。
> **注意**：该脚本不在本仓库内（是外部提供的单文件）。文中 `wb-enhance-prompt-share.js:NNNN` 的行号指向那份 1740 行的副本，**无法用 grep 在本仓库复核**；其余所有 `lib/…`、`packages/…`、`D:/DM/4/magpie/…`、`D:/DM/4/vscode/…` 的行号均已逐条核对。
> 参照：`docs/vscode-magpie-borrowables.md`（VS Code 与 magpie 的可借鉴项）。
> 本文只写**能带来可验证提升**的改动，每项都给了现状证据、改法、以及「提升是什么」。
>
> **施工状态（2026-10-29）**：§5 的第 1、2、3、4、8 项已实现（见 §6）。第 5、6 项未做；第 7 项依赖代理层故障转移，仍未落地。

---

## 0. 结论先行

**BaoCode 的提示词增强在核心质量上已经领先这个脚本，不需要「照着它重写」。** 它有三样脚本没有的东西：

1. **真的读项目**（`lib/chat/composer/composer_polish.dart:268-276` 的 `_enhanceTools`：`maxTurns: 8`、`readable: [location]`），所以能点名真实的文件与符号；脚本明确禁止模型看任何东西（`DEFAULT_ENHANCE_PROMPT_SYSTEM_TEMPLATE`：「Only the current draft is supplied. No conversation history, repository contents, attachment contents, or tool results are supplied separately. Never claim to have read them.」）。
2. **结构化校验 + 分类拒收**（`_structuralRejection`、`_rewrite` 的 `ComposerPolishRejected`：`heading` / `preamble` / `fenced` / `markers` / `too long` / `empty`），脚本只有「解析失败就整条丢掉」。
3. **保真回填**：composer 的标签/图片/代码/链接各是一个 `⟦n⟧` 标记，回复里丢一个、重一个、编一个都拒收（`composerPolishContent` 返回 null）。脚本没有任何等价机制 —— 它把纯文本直接塞回去。

**但它有 4 处真实短板，值得补**：

| # | 短板 | 现状证据 | 脚本的做法 |
| --- | --- | --- | --- |
| 1 | **只能整条替换，没有「撤销本轮」** | `lib/chat/composer/composer.dart:1394-1405` 只有 `breakUndo` + `replace`，靠编辑器 undo 栈 | 独立撤销按钮 `UNDO_ID`，且用 `closeHistory$` 事务边界 + 探针验证，**永不回退超过本次增强** |
| 2 | **无进度、无耗时、无阶段** | 只有一个 `_polishing` 布尔（`lib/chat/composer/composer.dart:159`），失败才弹通知 | `progress("读取配置")` → `"等待服务响应"` → `"接收响应"` → `"写回输入框"`，每秒刷新耗时与字节数 |
| 3 | **失败即止，没有「保留结果」** | 异常走 `notifications.notify` 后 `return`（`lib/chat/composer/composer.dart:1383-1393`），结果丢失 | `retainedResult` + 设置面板里的只读文本框 + 复制按钮 |
| 4 | **没有输入法（IME）保护** | `_polish` 不检查 `view.composing` | `applyEnhancement` 里 `if (composerController(input)?.view.composing) return {state:"conflict"}` |

另有 3 处**用户可感知但不算缺陷**的差距：脚本可切「创意模式」与「WorkBuddy 原版」两套提示词；脚本能拉 `/models` 列表；脚本有可复制的诊断记录。这些 BaoCode 要么已有更好方案（`models.auxiliary` 设置），要么与桌面应用形态无关。

**最大的一项机会不在脚本里，而在结合 VS Code 与 magpie**：增强是一次**独立的模型调用**，它现在和其它所有调用一样，失败就失败。§3 会给出把 §2.2 的失败分类与换家机制用在增强上的方案 —— 这是本文唯一能带来「成功率」而非「体验」提升的改动。

---

## 1. 两边实现的逐项对比

### 1.1 提示词本身

| 维度 | BaoCode | WB 脚本 | 判断 |
| --- | --- | --- | --- |
| 系统提示长度 | 5 段常量拼接（`_enhanceOpening` + `_enhanceWithTools` + `_enhanceWithToolsWriting` + `_enhanceNoPadding` + `_enhanceClosing`），约 2000 字符 | 创意模式约 6000 字符，WorkBuddy 原版约 1800 字符 | 脚本的创意模式**更细**，尤其是「EVIDENCE AND MISSING CONTEXT」「EXACT CONTENT」两节 |
| 是否读项目 | **读**（最多 8 轮、一次搜索 + 两次读文件） | **不读**，且明令不得声称读过 | BaoCode 明显更好 |
| 语言一致性 | 未显式约束（依赖模型自会跟随） | 用整整一节 + 3 个示例强制「输入什么语言就输出什么语言」 | **脚本更好**，但 BaoCode 有 `chat.responseLanguage`（`lib/settings/response_language.dart`）可复用 |
| 精确保留 | 标记机制（`⟦n⟧`）+ 回填校验 | 提示词里要求「Preserve code blocks, commands, paths, identifiers, configuration values, URLs, and original error messages verbatim」，但**无校验** | BaoCode 更强（有强制校验） |
| 拒绝「写计划而不是写消息」 | 有（`_enhanceNoPadding`：「no summary of your own」「no acceptance checklist beyond how to check the change」） | 有（「Do NOT explain HOW to do things, focus on WHAT」） | 相当 |
| 长度上限 | `after <= before * 6 + 1500`（`enhanceComposerText`） | 创意模式「There is no fixed character limit」；WorkBuddy 原版「maximum length should be around 800 characters」 | 各有取舍。**脚本的创意模式明确反对「长度即质量」**，这一点值得吸收进 BaoCode 的措辞 |
| 换行符 | 未显式要求 | `PARAGRAPH_OUTPUT_RULES`：「Use real newline characters, not literal backslash-n sequences」 | **脚本更好**，这是个真实高频故障 |
| 失败重试 | 有（项目读太长 → 改问「无项目」版；工具没答 → 同样降级） | 无 | BaoCode 更好 |

### 1.2 交互与容错

| 维度 | BaoCode | WB 脚本 | 判断 |
| --- | --- | --- | --- |
| 撤销 | 靠 `TextEditingController` 的 undo 栈（`breakUndo()` 切边界） | 独立按钮 + `closeHistory$` 事务 + 探针校验 + 三重状态判定（已恢复／内容已改／撤销记录已变） | **脚本更稳**：它显式处理「用户已经改过内容」与「撤销记录被别处改动」两种情况 |
| 并发保护 | `_polishing` 布尔 + `_controller.text != before` 检查（`lib/chat/composer/composer.dart:1393`） | `enhanceController !== ac` + `captureTarget`/`resolveTarget` 的任务身份比对 + 导航 epoch | **脚本更严**：它能识别「用户切到另一个对话了」 |
| IME | 无检查 | `view.composing` 检查 | **脚本更好** |
| 进度 | 无 | 阶段 + 耗时 + 字节数，每秒刷新 | **脚本更好** |
| 结果保留 | 无 | `retainedResult` + 设置面板可复制 | **脚本更好** |
| 取消 | 有（`cancel` future → `ClaudeHaikuCancelled`） | `AbortController` + 点击按钮即停 | 相当 |
| 超时 | 25s（无工具）／90s（有工具），`_tierDeadline` | 90s 统一 | BaoCode 分档更合理 |
| 诊断 | `appEvent('composer', ...)` 事件日志 | 面板内 `requestHistory`（最近 8 条）+ 一键复制 | 各有优势：BaoCode 的日志更持久，脚本的更易给用户看 |

### 1.3 模型与连接

| 维度 | BaoCode | WB 脚本 |
| --- | --- | --- |
| 模型选择 | `models.auxiliary` 设置 + `ModelProviders.current.auxiliary(model)`，可按会话模型自动挑 Haiku 档 | 跟随 Codex 全局配置，或手动填 Base URL / Key / 模型 / 协议 |
| 协议 | 通过 Claude Code / 自建 provider 统一 | 显式支持 Responses 与 Chat Completions 两种，且处理了 GLM-5.2 不接受 `store` 的特例 |
| 降级 | Haiku 档失败 → 记入 `_tiersFailed`，之后直接问主模型（`_reply`） | 无 |
| 凭据 | 由 provider 管理 | 自动模式**不落盘**，手动模式存 localStorage |

**判断**：BaoCode 的模型层明显更好（有降级、有统一 provider）。脚本唯一值得吸收的是**「GLM-5.2 这类模型不接受某字段」的特例处理思路** —— 见 §3.3。

---

## 2. 可直接移植的 4 项（成本低、收益明确）

### 2.1 「撤销本轮增强」按钮（最高优先）

**现状问题**：`lib/chat/composer/composer.dart:1394-1405` 用 `breakUndo()` 把增强切成一个独立 undo 步。这在**用户没动过内容**时是够的，但有两个漏洞：

- 用户增强后又打了一个字，再按 Ctrl+Z 只会撤掉那个字，要再按一次才回到增强前 —— 用户不知道要按几次。
- Flutter 的 `TextEditingController` undo 栈有上限，长会话里增强那一步可能已经被挤出栈。

**脚本的做法**（`wb-enhance-prompt-share.js` 里的 `undoAvailability()`）值得照抄的三条判定：

1. 当前内容 == 增强前内容 → 「已恢复增强前内容」，按钮消失；
2. 当前内容 != 增强后内容 → 「内容已修改，不能直接撤销」，**按钮禁用并说明原因**，绝不强行覆盖；
3. 编辑器自己的 undo 记录已变（`nativeUndoTransaction` 探针拿到的 transaction 不回到 `before`）→ 「编辑器撤销记录已变化，不能直接撤销」。

**BaoCode 改法**：在 `lib/chat/composer/composer.dart` 的 `_polish` 里保留 `({String before, String after})? _lastPolish`，在 composer 的工具条上加一个撤销按钮（与 Polish/Enhance 按钮同一排，`lib/chat/composer/composer.dart:1973-1990` 附近）。点击时按上面三条判定决定是否可撤。

**提升**：用户敢点增强。这是「试用 → 常用」的转化关键 —— 现在点错一次要按两次 Ctrl+Z 且可能撤过头。

### 2.2 进度与耗时

**现状问题**：`_polishing` 只是让按钮转圈（`lib/chat/composer/composer.dart:1974-1988`）。有工具时最坏要 90 秒（`_tierDeadline`），用户完全不知道卡在哪。

**脚本的做法**：4 个阶段（读取配置 → 等待服务响应 → 接收响应 → 写回输入框）+ 每秒刷新「已 N 秒 · M 字节」。

**BaoCode 改法**：`_askText` 已经能拿到 `cancel` future；给 `askClaudeHaiku` 加一个可选的 `void Function(String stage)? onStage`，在 `composer_polish.dart` 里透传。UI 侧用**已有的** `IdeNotificationProgress`（`lib/ide/ide_notifications.dart:86-95`，支持 `infinite` 与 `worked/total`）显示，比脚本的 toast 更贴合 BaoCode 的通知中心。

**提升**：90 秒的等待从「不知道死没死」变成「知道在第几步」。这一条对「有工具」的 Enhance 尤其重要。

### 2.3 失败保留结果

**现状问题**：`lib/chat/composer/composer.dart:1383-1393` 捕获 `ComposerPolishException` 后弹通知就 `return`。但**结果其实已经拿到了** —— 失败发生在回填校验（`_rewrite` 的 `markers` / `too long` / `heading` 拒收）或 `_controller.text != before` 的并发检查上。此时模型给的文本是有价值的，用户可能想手动看看。

**脚本的做法**：`retainedResult = {text, at}` + 设置面板的只读 textarea + 「复制结果」。

**BaoCode 改法**：把 `ComposerPolishRejected` 携带的原始回复也存下来（现在 `_rewrite` 在拒收时把 `reply` 丢了 —— `lib/chat/composer/composer_polish.dart:71-72` 的 `class ComposerPolishRejected extends ComposerPolishException { const ComposerPolishRejected(this.reason); }` 只有 `reason`）。给它加一个 `String? raw` 字段，UI 侧在失败通知上加一个「查看结果」的 `IdeNotificationAction`（`notify(..., secondary: [...])` 已支持）。

**提升**：把「失败」变成「需要你看一眼」。拒收理由（`markers` / `too long`）本身也是有用的反馈。

### 2.4 IME 保护

**现状问题**：中文/日文用户正在用输入法打字时点增强，`_controller.text` 里可能是拼音中间态。

**改法**：与 §2.1 合并实现 —— 在 `_polish` 开头检查 `_isComposing`。**这个 getter 已经存在**：`lib/chat/composer/composer.dart:662` 的 `bool get _isComposing => _controller.isComposing;`（注释在 `:657-661`，还记着 #143 那个 macOS 空 composition 的坑）。所以这一项只是**在 `_polish` 开头加一行判断**，成本几乎为零。

**提升**：避免把拼音当提示词发给模型。

---

## 3. 结合 VS Code 与 magpie 的三项（收益更大）

### 3.1 让增强调用走「换一家」（本文最大的一项）

**问题**：增强是一次独立的模型调用，走 `askClaudeHaiku`。它现在有**一档降级**（Haiku 档失败 → 问主模型，`_reply` 的 `_tiersFailed`），但这一档是「同一个 provider 内换模型」，provider 本身失败（401/429/5xx）时没有出路。

**这正是 `docs/vscode-magpie-borrowables.md` §2.2 要补的洞**。一旦代理层有了 `retryable(status, body)` 与换家循环，增强调用**自动受益**，不需要额外改动 —— 因为它走的是同一个 `model_proxy.dart`。

**但要额外做一件事**：增强对「上下文溢出」的处理与对话不同。`retryable` 明确把溢出判为不可重试（让 agent 自己压缩），可增强的输入是**用户草稿**，压缩不了。所以：

- 草稿超过某个长度（建议按 `estimate` 的 4 字节/token 算，超过 8K token）时，**先在本地截断并告知**，而不是发给上游等 400。
- 这与脚本的「800 字符上限」（WorkBuddy 原版）是同一个问题的两种解法：脚本靠限制，BaoCode 可以靠截断 + 明确提示。

**提升**：增强的成功率。现在是「provider 抖一下就失败」，改后是「换一家再试」。

### 3.2 复用 magpie 的失败分类做用户可读的错误

**问题**：`lib/chat/composer/composer.dart:1387-1389` 直接把 `error.message` 塞进通知。而 `error.message` 来自 `_askText` 的 `'$error'`（`_reply` 的 `catch`），是**上游原始错误文本** —— 可能是英文、可能是 JSON 片段。

**magpie 的做法**（`D:/DM/4/magpie/internal/gateway/fallback.go:1419-1440`）把失败分成 quota / unserved / refused / shape / unsaid / region / overflowed 几类，每类有明确的处置。BaoCode 不需要照搬全部，但**至少要有 3 类**：

| 类别 | 用户看到的 | 用户能做什么 |
| --- | --- | --- |
| 配额/限流 | 「增强用的模型额度用完了」 | 换个 auxiliary 模型，或等 |
| 模型不支持 | 「当前模型不支持增强，已改用 X」 | 无需操作（自动降级） |
| 上下文过长 | 「草稿太长（约 N 字），已截断」 | 删减或分段 |

**改法**：在 `lib/chat/composer/composer_polish.dart:328` 的 `_why(Object error) => '$error'.split('\n').first;` 旁边加一个分类函数，把 magpie 的 `quotaWords`/`unservedWords` 正则（`D:/DM/4/magpie/internal/gateway/fallback.go:1175-1338`，已核实的具体模式）裁到 3 类。UI 侧按类别给不同的 `IdeNotificationAction`。

**提升**：失败从「看不懂的英文」变成「知道怎么办」。

### 3.3 一个 VS Code 式的「模型能力探测」

**问题**：脚本处理了 GLM-5.2 不接受 `store` 的特例（`wb-enhance-prompt-share.js` 的 `store` 特例）：

```js
...((s.omitStore || /^(?:[^/]+\/)?glm-5\.2(?:$|[-:])/i.test(s.model)) ? {} : { store: false }),
```

BaoCode 的 `lib/models/proxy/translate/responses_request.dart` 也有类似的特例（`include: ['reasoning.encrypted_content']` 只在 `reasoning` 为真时加）。但这类「按模型名硬编码」会越积越多。

**VS Code 的做法**（`docs/vscode-magpie-borrowables.md` §3.2 提到的 Workspace Trust 声明思路，同构）：把能力声明成**数据**，不是代码里的 if。具体到增强：

```dart
// lib/models/auxiliary_capabilities.dart
const Map<String, AuxiliaryCapabilities> knownModels = {
  'glm-5.2': AuxiliaryCapabilities(omitStore: true),
  // ...
};
```

**提升**：新增特例是加一行数据，不是改一处逻辑。这条成本很低（半天），但能防止 `composer_polish.dart` 和 `responses_request.dart` 各自长出一堆 `if (model.contains(...))`。

---

## 4. 不建议做的

| 项 | 理由 |
| --- | --- |
| 照搬脚本的两套提示词模式（WorkBuddy 原版 / 创意） | BaoCode 已有 Polish 与 Enhance 两个按钮，语义更清楚。再加「模式」会让用户面对 4 个选择。若要吸收创意模式的措辞，改进现有 `_enhance*` 常量即可 |
| 照搬「800 字符上限」 | 那是 WorkBuddy 原版提示词的自限，不是通用最优。BaoCode 的 `before * 6 + 1500` 更合理（增强本就该变长） |
| 照搬 localStorage 存 API Key | BaoCode 的 provider 体系已经管凭据，再开一条存储路径是安全倒退 |
| 照搬 Codex 配置发现（`discoverNative`、React fiber 遍历 6000 节点） | 那是给别人的应用打补丁的技法；BaoCode 自己有完整模型层，没有这个问题 |
| 照搬「跟随 Codex 全局配置」 | BaoCode 有 `models.auxiliary`，语义更准 |

---

## 5. 落地顺序与预期提升

| # | 项 | 成本 | 提升 | 依赖 |
| --- | --- | --- | --- | --- |
| 1 | 撤销本轮增强（§2.1） | 150–250 行 | **敢用**：点错一次不再要按两次 Ctrl+Z | 无 |
| 2 | IME 保护（§2.4） | 1 行（`_isComposing` 已在 `lib/chat/composer/composer.dart:662`） | 中文/日文用户不再把拼音发出去 | 与 1 同处 |
| 3 | 失败保留结果（§2.3） | 80–120 行 | 拒收从「白等」变成「可看」 | 无 |
| 4 | 进度与耗时（§2.2） | 100–150 行 | 90 秒等待可解释 | 无 |
| 5 | 模型能力表（§3.3） | 半天 | 防止特例散落 | 无 |
| 6 | 失败分类 → 用户可读（§3.2） | 150–200 行 | 失败知道怎么办 | 可独立 |
| 7 | 增强走换家（§3.1） | 0 行额外（复用 §2.2 of the other doc）+ 草稿截断约 50 行 | **成功率**：provider 抖动不再直接失败 | **依赖代理层故障转移先落地** |
| 8 | 语言一致性措辞（§1.1） | 改常量 | 中英混输时输出语言更稳 | 无 |

**前 4 项合计约 350–540 行，不依赖任何其它批次，可以立刻做。** 第 7 项是唯一影响成功率的，但要等 `docs/vscode-magpie-borrowables.md` 的批次 B1 先落地。

**一个反直觉的结论**：这个脚本最值得学的不是它的提示词（BaoCode 的更好），而是它的**容错工程** —— 撤销探针、并发身份比对、结果保留、阶段进度。这些恰好是 BaoCode 现在的空白，而且都不依赖模型能力。

---

## 6. 施工记录（2026-10-29）

已落地 §5 的第 1、2、3、4、8 项。第 5、6 项未做，第 7 项仍等 `docs/vscode-magpie-borrowables.md` 的批次 B1（代理层故障转移）。

### 6.1 撤销本轮重写（§5-1）

- `lib/chat/composer/composer.dart`：新增 `({String before, String after, bool enhance})? _lastPolish`，由 `_putPolish` 写入（`breakUndo` + `replace` + `breakUndo`，前后各断一次撤销边界）。
- `bool get _canUndoPolish` 只在 `_controller.text == last.after` 时为真 —— 手改过一个字就不再成立。
- `_handleEditorChanged` 在文本与 `last.after` 不同时清空 `_lastPolish`，按钮随之消失；`_shownOfText()` 加 `undoable` 字段，让工具栏在撤销按钮出现/消失时重建。
- `_undoPolish` 在文本已变时不覆盖（只提示 `composerPolishUndoGone`），文本未变时用同样两次 `breakUndo` 换回原文，所以 ⌘Z 还能再把它撤掉。
- 按钮：`_PolishButton` 加 `undo` 参数，图标 `Codicons.discard`，tooltip 走 `composerPolishUndo` / `composerEnhanceUndo`。

**与脚本的差别（有意的）**：脚本用 `closeHistory$` 事务 + `nativeUndoTransaction` 探针去**验证**原生撤销是否可用，再决定按钮可不可点。BaoCode 不去探测编辑器栈 —— 它自己记着「上一次重写把什么换成了什么」，判据是文本是否还等于 `after`。这比探针简单，也不会因为编辑器实现变化而失效；代价是编辑器里更早的撤销历史与这个按钮互不影响（各管各的）。

### 6.2 IME 保护（§5-2）

`_polish` 开头加 `if (_isComposing) return;`，复用已有的 `lib/chat/composer/composer.dart:691` `_isComposing => _controller.isComposing`（`packages/bao_markdown/lib/src/md_controller.dart:184` 的 `_composing.isValid && !_composing.isCollapsed`）。

注意：**静默返回**，不弹通知。拼音还没上屏时按 Polish，用户想要的多半是「等我打完」，而不是「告诉我为什么不行」。

### 6.3 失败保留结果（§5-3）

- `ComposerPolishRejected` 加可选第二参数 `raw`（`lib/chat/composer/composer_polish.dart:71`），`_rewrite` 的 4 个抛出点（`empty`、结构性拒收、`too long`、`markers`）都带上被丢掉的那段文本。
- 失败通知加 `primary: [IdeNotificationAction(l10n.composerPolishShowResult, …)]`，点了弹 `showIdeDialog`（`IdeDialogType.info`），`detail` 是「原因 + 模型原文」，按钮 Copy 进剪贴板。
- 拒收原因从内部字符串翻成人话：`composerPolishRejectedEmpty` / `Heading` / `Preamble` / `Fenced` / `TooLong` / `Markers`，未知原因原样显示。

**与脚本的差别**：脚本把结果留在设置面板的只读 textarea 里（常驻），BaoCode 放在通知的按钮后（按需）。桌面应用里常驻一块 textarea 会挤占输入区，而通知是可检索的（进通知中心），够用。

### 6.4 进度与耗时（§5-4）

- `composer_polish.dart` 新增 `enum ComposerPolishStage { project, tier, model, fallback }`，`polishComposerText` / `enhanceComposerText` / `_rewrite` / `_reply` 都透传 `onStage`。
- `_reply` 上报的时机：Enhance 有工具时先报 `project`，否则报 `tier`；`ask()` 里按 `after == null` 分 `model`（直接问）与 `fallback`（tier 失败后改问）。
- `lib/chat/composer/composer.dart` 的 `_showPolishProgress` 用 `IdeNotifications.notify(..., progress: IdeNotificationProgress.infinite())`，`Timer.periodic(1s)` 刷新「阶段 + 耗时」，`_endPolishProgress` 在 `finally` 与 `dispose` 里关闭。

**耗时格式**复用 `lib/chat/widgets/agent_step.dart:63-71` 的 `AgentStep.formatDuration`（`46s` / `2m 14s` / `1h 5m`），不另写一套。

**与脚本的差别**：脚本有 4 个阶段且带字节数；BaoCode 只报「在等什么」，不报字节数 —— 增强的响应是一次性 JSON，没有可读的中间进度，报字节数只会是假的精确。

### 6.5 语言一致性措辞（§5-8）

- `_system`（Polish）末尾加：`Write it in the language it is written in, whatever language these instructions are in: a message in Chinese stays in Chinese, a message in English stays in English, and one that mixes them keeps each part in its own. Where a line break belongs, write a real one, never the two characters \n.`
- `_enhanceClosing` 加同样的换行要求（增强提示词已有语言一致性一节）。

**测试约束**：`test/chat/composer_polish_test.dart` 断言系统提示「不含换行、不含双引号」（它作为命令行参数传给 Claude Code）。新增文字里 `\n` 是**两个字符**（`'\n'`），不是真换行 —— 这是有意的，既满足约束，又正是在告诉模型「不要输出这两个字符」。

### 6.6 测试

`test/chat/composer_polish_test.dart` 从 24 条增到 33 条，新增：

| 测试 | 覆盖 |
| --- | --- |
| `the answer thrown away is kept, and why` | `ComposerPolishRejected.raw` 与 `reason` |
| `what it waits on is told as it goes` | 直接问时只有 `model` |
| `the Haiku tier … the tier and then the model itself` | `tier` → `fallback` |
| `Enhance with the project to read: the project first` | `project` |
| `the Undo button puts back what was written, and goes` | 按钮出现、点击回退、随后消失 |
| `typed on after the reply, no Undo button` | 手改后按钮消失 |
| `a reply thrown away: said why, and the answer kept to read` | 通知按钮 + 对话框内容 |
| `an input method still composing: not asked, and the letters kept` | IME 期间不调用，结束后正常 |
| `while it waits, a notification says what it waits on` | 无限进度条、阶段文案、完成后关闭 |

`flutter analyze lib test` 只剩 7 条既有警告（均在未改动的文件里）。

### 6.7 未做的与原因

| 项 | 为什么没做 |
| --- | --- |
| §5-5 模型能力表 | 需要先有第二个真实特例才值得抽象；现在只有一个 `glm-5.2`/`store` 的疑似场景，且它在 `lib/models/proxy/translate/responses_request.dart` 里已有正确写法 |
| §5-6 失败分类 → 用户可读 | 收益真实，但要先把 magpie 的 6 组正则裁到 3 类并逐条验证误判（尤其 `quotaWords` 里 `exceeded` 过宽），是独立的一批活 |
| §5-7 增强走换家 | 依赖 `docs/vscode-magpie-borrowables.md` §4 批次 B1（`lib/models/proxy/model_proxy.dart` 三处失败点的故障转移）；在它落地前做，只会多一层转圈 |
