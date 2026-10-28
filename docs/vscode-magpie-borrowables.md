# VS Code 与 magpie：值得借鉴和集成的点

> 编写日期：2026-10-28，2026-10-29 按实际源码校订。参照对象：`microsoft/vscode`（MIT，HEAD `55d17505`）与 `yetone/magpie`（MIT），两者已克隆到 `D:/DM/4/vscode` 与 `D:/DM/4/magpie`。
> 本文只写**两边都没有、而 BaoCode 缺**的项；凡已确认 BaoCode 已有的，列在 §6「已核实无需再做」。
> 第一版只读了官方文档，**有 5 处事实错误**；本版全部按源码改正，并在 §7 列出改动，凡引自源码的都给了精确路径与行号。

---

## 0. 结论先行

1. **模型层最大的缺口是「换一家」**。Codex 协议已经有粘性选号与换号（`lib/models/codex/codex_balancer.dart`，仅 55 行；入口 `lib/models/proxy/model_proxy.dart:678 _openCodex`），但 anthropic / openaiChat / openaiResponses 三条路**一次失败就把上游错误直接返回**（`lib/models/proxy/model_proxy.dart` 的 `:276`、`:511`、`:636` 三处 `if (answer.statusCode >= 400)`），中间没有任何重试或换上游。magpie 的「路由组 + 失败分类 + 休息」正好补这里，而且它的「只在尚未吐出字节时才换」与 BaoCode 现有的 `stream_restart` 契约天然一致。
2. **IDE 侧最划算的一项不是新功能，是把底子接上**：`packages/bao_editor` 里已经有完整的 Monaco `SnippetParser` 与 `SnippetSession`（`packages/bao_editor/lib/monaco/vs/editor/contrib/snippet/browser/snippet_parser.dart`、`snippet_session.dart`，接线在 `editor_surface_controller.dart:106/:2499`），缺的只是「读 `<data>/User/snippets/*.code-snippets` 并把用户片段并入补全列表」这一层。做完就等于有了 VS Code 的用户代码片段。
3. **有两个恒真桩是真实的安全窟窿**，不只是「功能没做」：`lib/debug/service/debug_host.dart:175` 的 `requestWorkspaceTrust(...) async => true` 与 `:187` 的 `runTask(...) async => TaskRunResult.success`。一旦任务系统真做起来，打开一个不可信仓库就会直接执行它的 `preLaunchTask`。**Workspace Trust 必须排在任务系统之前**。
4. **隐私掩码值得做，但要做成默认关**。BaoCode 现在只有诊断包上传前的 `scrubSecrets`（`lib/diagnostics/diagnostics_bundle.dart:160`），从不碰发给模型的请求体。magpie 的做法（发出去之前换成占位符、收到回复再还原）可行，真正的难点是**流式还原**（见 §2.1），而且它用真实事故换来的三条约束（id 绝不打码、凭据字段名排除、签名包着的对象原样保留）必须一起搬。
5. **明确不建议**：profiles、设置云同步、替别人家 agent 改配置文件、Bun 插件宿主、OTLP 导出、1.6 GB 本地 PII 模型。理由见 §5。

---

## 1. 许可与边界

| 项目 | 许可 | 允许的用法 | 禁止 |
| --- | --- | --- | --- |
| `microsoft/vscode` | MIT | 移植实现或重写；逐段移植时保留 MIT 版权与许可文本 | 无（除非引入其 Node 扩展宿主的设计，那会撞上 `docs/extensions.md` 的既定决策） |
| `yetone/magpie` | MIT | 同上 | 不引入 Go 运行时、Bun、本机常驻 daemon |

先例：`lib/models/proxy/translate/NOTICE.md` 已经保留了 Microsoft 的版权头，照这个格式办。

**不可改变的行为边界**沿用 `docs/optimization-iteration-plan.md` §2：`control_request`/`control_response` 子类型语义、会话 JSONL 行类型与 `parentUuid`、`KernelEvent`/`ChatItem` 形状、权限优先级、`lib/channel/` 契约。

**两处特别提示**：

- 加故障转移**不得**改变 `packages/bao_agent/lib/src/api/anthropic_client.dart` 现有的重试曲线（500ms×2ⁿ、上限 32s、0–25% 抖动、最多 10 次），那是附录 A 的 A-6 决定。本文说的「重试」在**代理层**，是换一家而不是重试同一家。
- 代理层换家**只在尚未向客户端写出任何字节时**发生。这与 A-7「已提交输出后不再重试」以及 `stream_restart` 契约一致，magpie 自己也是这么做的。

---

## 2. magpie

### 2.1 隐私掩码（最值得借鉴，也最难）

**机制**（源码：`internal/redact/redact.go`、`writer.go`、`json.go`、`ids.go`、`shape.go`、`rules.go`）

- **占位符不是随机后缀，是 HMAC**（`redact.go:591-600`）：
  ```go
  func tag(kind, v string) string {
      h := hmac.New(sha256.New, key())
      h.Write([]byte(kind + "\x00" + v))
      return "{{" + kind + "_" + strings.ToLower(b32.EncodeToString(h.Sum(nil))[:8]) + "}}"
  }
  ```
  `b32` 是 `base32.StdEncoding.WithPadding(NoPadding)`；`key()` 从磁盘读一个持久密钥（`0o600`）。因为 key 持久、HMAC 确定，**同一个值在重启后仍是同一个占位符** —— 这是 prompt cache 与 thinking 签名能跨进程存活的真正原因，比「内存里记住映射」更强。`placeholder()` 才把 `p → v` 记进 `values`。
- **映射表有上限**（`redact.go:539-541`）：`const maxValues = 200_000`；`makeRoom()` 满了就删**最旧的一半**并 `reindexKnown()`。被删掉的值如果又出现，会重新占位（同一个 tag，所以文本不变）。
- 两套检测：规则式（API key、私钥、token、邮箱、**通过校验和**的卡号/证件号），加上可选的本地模型（姓名、地址、密码；1.6 GB，CPU 跑）。
- 还原覆盖三处：流式文本、tool-call 参数、普通回复。
- **只在内存**，不落盘。审计只记 kind、长度、头几个字符。
- 三种动作：Mask / Warn / Block。分类可单独关（secrets、personal data，更细的 passport / IBAN / MAC / public IP），也能加自定义词与模式。
- `example.com` / `.test` / `.invalid` 的邮箱不动（文档示例用的地址不该被打码）。
- **失败关闭两层**：`plugins/redact/redact.go` 的 `InUse()` 在设置读不出来时返回「开启」；模型跑不起来（没下好、OOM）时请求返回 503，绝不按原样发出去。PII 模型退避：`gpuLoadTimeout` 40s、`gpuRetryAfter` 10min 起翻倍到 2h、失败保持 `heldBack` 30s 起翻倍到 10min。
- 顺序：网关中间件看到的是**脱敏前**的 body（`gateway-middleware.md`），脱敏在更上游。
- 坑（README 自己承认）：模型看到的是 `{{API_KEY_…}}`，所以「这个 token 为什么被拒」这类任务做不了，要靠 Never mask 放行。

**必须一起搬的三条约束**（这些是 magpie 用真实事故换来的，漏掉任何一条都会出问题）：

1. **id 绝不打码**（`ids.go:24-29` 及全文）。后端生成的 id（UUID、≥32 位 hex：行 id、请求 id、会话 id、commit id）**必须原样发出** —— 模型要读它、匹配它、写回 tool call，后端按字符查找。`noIDs(s, found)` 用 `slices.DeleteFunc` 删掉落在 id 内部或跨越 id 的命中（但用户自定义词不删）。真实事故：手机号规则在 `…-a13800138000` 末尾命中、银行卡规则跨 UUID 分组命中 `4111-1111-1111-9007`，id 被切掉半个占位符。另外 cua-driver 的 computer-use 元素 token（`s0000002a:14`）若被打码，模型点的是「nothing」（#3782）。
2. **凭据字段名要排除**（`credentialField`）：字段名末词是 `id`/`ids`/`uuid`/`guid`，或含 `page`/`next`/`cursor`/`continuation`/`csrf`/`xsrf`/`trace`/`request`/`idempotency`/`sync`/`nonce`/`hash`/`digest`/`checksum`/`sha`/`fingerprint`/`etag`，或单词是 `key` —— 都不当凭据。`nameWords` 把 `next_page_token`/`nextPageToken`/`X-Next-Page-Token` 统一切成 `next,page,token`。
3. **签名包着的对象原样保留**（`json.go:63-66` 的 `signatureKeys = ["signature","thoughtSignature","thought_signature","encrypted_content"]`；`scan()` 返回 `signed` 路径集合）。厂商封签的内容由厂商自己校验，改一个字符就废。同理 `keepIn()`：tool call 的 `arguments` 里键是工具的（`signature`/`name`/`user_id` 那里存的是 agent 写的，不能当厂商的），只有 `data:` 开头的值保留；`defs`（工具定义、schema、grammar）里**只脱敏 `description`**，因为其余部分厂商当结构读 —— 在 Lark grammar 的规则名里脱掉 `pd`（`update_hunk` 中的）会让厂商 400 "Invalid lark grammar"（#1911）。

**BaoCode 怎么落地**

复用 `diagnostics_bundle.dart:160 scrubSecrets` 的规则表（`sk-`/`gh[pousr]_`/`github_pat_`/`AKIA`/`authorization`/`x-api-key`/`cookie`/`*_token`/PEM 私钥），把它从「诊断包上传前」搬到 `lib/models/proxy/` 的请求路径上，再加一条还原路径。要新增的东西：

1. `Masker`：`String mask(String)` 与 `String restore(String)`。占位符按 magpie 的 `tag()` 做（HMAC + 持久 key + base32 前 8 位），这样跨重启稳定，不需要把映射表写盘。映射表内存上限取 `maxValues` 同量级（BaoCode 单会话可降到 2 万）。
2. **流式还原**是关键难点，magpie 的解法值得整套照搬（`writer.go` 332 行）：
   - **模式判定**（`decide`）：有非 identity 的 `Content-Encoding` → 原样透传；`Content-Type` 含 `event-stream` → 流式；`Content-Type` 为空但首字节以 `event:`/`data:`/`:` 开头 → 流式（"the ChatGPT backend streams without saying so"）；否则整体。
   - 非透传时 **`h.Del("Content-Length")`** —— 还原后的长度与原来不同。
   - 按 `\n\n` / `\r\n\r\n` 切事件（`eventEnd`）。
   - **`": keepalive"` 注释行立即放行**（`commentLines`）。原因写在注释里（#2402）：被扣住时 agent 在厂商静默推理期间什么都听不到，代理被挂断。这条极容易被漏掉，却是最容易引发「卡住」的。
   - **扣住与接力**：`held{ctx, path, tail, full, cut}`。一个事件若以「可能是占位符开头」的文本结尾，就整个扣住；下一个事件若 `p.ctx == ctx && hasPath(data, p.path)`（同 type / item_id / index / output_index / content_index）就写 `p.cut`、把 `p.tail` 接到新事件前面。`ctx` 由 `name + "|" + eventCtx(data)` 拼成。
   - **`partialTail` 必须在还原之前找**（`redact.go:1386-1426`）：`braceTail` 找最后一个 `{`（或 `{{`），`len(t) >= maxPlaceholder+4 || strings.Contains(t, "}}")` 就不算；`body` 去掉 `{` 与空格后为空（即只有 `{`、`{{`、`{{ `）算；首字符必须字母；`j` 扫完 word 字节后，剩下的只能是空或单个 `}`；`j < len(body)` 时还要 `placeholderBody.FindString(body[:j]) == body[:j]` 才算。注释点明理由：「so a placeholder whose last brace is still to come isn't put back without it and the brace left behind」。
   - **`braces` 容错**（`redact.go:1348-1377`）：模型可能写 `{{ PHONE_b5puzbfv }}`（带空格）、丢一个括号（`{{X}` 或 `{X}}`）、或改大小写，都要还原。`canonical(body)` 把 case 规整回 `{{大写类型_小写哈希}}`。单边一个 `{` 是文本自己的（代码里的 `{X`），不动。
   - `maxPlaceholder = len("{{") + maxKind + len("_") + 8 + len("}}")`。
   - `Finish()`：`whole` 模式走 `restoreJSON`；`stream` 模式先写残留 `pending.full`，再对剩余缓冲 `restore(...)`。
   - `Put()` 记录每个占位符还原了几处，供审计界面展示。
3. tool-call 参数是 JSON 字符串，且 `mask` 有 `escaped` 参数（`redact.go:800-815`）：当 s 自身是 JSON 文本（tool call 的 arguments）时，用 `unescapedView` 让 finder 按厂商读到的方式匹配（`\n` 前的 `@mcp.tool` 不是地址，`\n` 前的 `jo@quill.dev` 也不算它的字母），并且值不跨转义边界；还原时再 `jsonEscape` 回去。注释记着真实事故：按纯文本读时 `\n` 的 `n` 成了 `n@mcp.tool` 的首字母、反斜杠留在占位符前（`\{{EMAIL_…}}`），arguments 不再是合法 JSON，Ollama Cloud 每轮重放都 400 "invalid tool call arguments"（#3022）。**BaoCode 的 translate 层已经有拼接，但要按这个 escaped 语义处理，不能简单对每个 delta 做字符串替换。**
4. 审计条目与并排对比界面。BaoCode 可以在 `lib/settings/pages/` 加一个小页面，不必做完整请求日志。

**判断**：值得做，但**默认关**、只做规则式（不引入 1.6 GB 模型 —— 桌面应用里多一个必须下载的大模型会直接破坏 README 主打的那个「16MB 安装包」定位）。开关放在隐私页（与 `lib/settings/pages/browser_page.dart` 同级新建一个），设置键建议 `privacy.maskSecrets`。

**实现成本修正**：magpie 这块是 `internal/redact/` 下 **9482 行**（含大量测试），仅 `redact.go` 就 1456 行。不要按「几百行的小功能」排期。BaoCode 若只做 secrets 一类（不做 PII、不做中文姓名/地址），可以压到约 1200–1800 行（含测试），但 §2.1 列的那三条约束与流式接力的复杂度省不掉。

### 2.2 路由组与故障转移

**值是什么**（magpie `docs/reference.md` + `docs/subsystems/gateway-routing.md`）

| 模式 | 行为 |
| --- | --- |
| `smart`（默认） | 在还有余量的订阅里，选**最先续期**的那个 |
| `order` | 第一个能答就用，不能答才下一个 |
| `rotate` | 每轮换下一个成员 |
| `usage` | 用得最少的优先（半衰期 1 小时） |
| `pace` | 每周剩余份额 ÷ 到续期的剩余小时数，最缺额度先让 |
| `weight` | NGINX 式平滑加权轮询，权重 1–1000 |
| `free` | 免费模型优先 |
| `fast` | 按首 token + 200 token 的预计时间排 |

- 组可以嵌套（上限 8 层），一个嵌套组算一个成员。
- **亲和**（`stays=`，源码 `internal/gateway/affinity.go`）：`auto`（默认）/ `session` / `turn` / `off` / `strict`。`auto` 的精确判据是 **`cacheWorth = 1024`**（`affinity.go:51`）与 **`cacheCold = 5 * time.Minute`**（`:54`）：同一轮内粘住；跨轮只有在上一请求既读过又写过至少 1024 token 的厂商缓存、且 5 分钟内答过才粘住。亲和永远不会救活休息中的账号，也不会留在 98% 用满的账号上。
- **两个文档里没有、源码里有的常量**：`chatGPTCold = time.Hour`（`:65`）—— ChatGPT 后端给 Codex 保留提示缓存一小时，所以 Codex 账号的「冷」判据是一小时而不是五分钟；`hourCache`（`:117-146`）专门记 Anthropic 的 `ephemeral_1h_input_tokens`，「1 小时断点在任何 5 分钟断点之前」，所以它 `warm` 到最后一小时。注释记着 #2302：`Stays: Auto` 曾在一个 1 小时写入后 5 分钟就把对话当成「冷」搬走了。
- `stickKeep = 24 * time.Hour`（`:71`）、`sticksKept = 512`（`:73`）—— 对话的记忆上限。
- 阈值：Smart 与周节奏在 **90%** 降级、**98%** 再降；`order` 只在 **100%** 停。
- 周节奏 = 剩余周份额 ÷ 到续期的小时数（最小 1）。两个周窗口取较低的那个，相差十分之一算并列。小时比较是**字面**的：13:55 与 14:05 不同，14:05 与 14:55 相同。
- 无周窗口时（Claude Enterprise）由 5 小时窗口说了算。

**失败分类与休息（源码 `internal/gateway/fallback.go`、`routing.go`，全部精确常量）**

`routing.go:161-200` 的常量块：

| 常量 | 值 | 含义 |
| --- | --- | --- |
| `creditRest` | 30min | 余额耗尽：等充值 |
| `quotaRest` | 15min | 配额耗尽且没说何时恢复 |
| `longestWait` | 1h | 厂商自己给的「何时再试」最多信这么久 |
| `longestQuota` | 8d | 一周窗口 + 一天 |
| `longestRetry` | 10min | 一直失败时的上限 |
| `longestRateRest` | 30min | 限流休息结束就复发时的上限 |
| `rateForget` | 30min | 距上次限流休息结束这么久之后算新限流（从 1 分钟起） |
| `verifyRest` | 30min | Google 要求验证的账号 |
| `verifyHold` | 1min | 被验证拒绝后这么久内不再问 |
| `restrictedRest` | 2h | 厂商限制账号（WorkBuddy 403 11140，#1849）—— 需申诉不是等 |
| `slowRests` | 2 | 连续两次慢启动才休息 |
| `slowForget` | 30min | |

另有 `fallback.go:37` 的 `fallbackCooldown = time.Minute`。

**退避算法**（`routing.go:1140-1220` 的 `default` 分支）：`routed.failures[counted]++`，`n := routed.failures[counted]`，然后
```go
d, r.By, r.Failures = min(fallbackCooldown<<min(n-1, 10), c.p.RestCapOr(longestRetry)), "backoff", n
```
即 1min → 2 → 4 → 8 → … 上限 `longestRetry`=10min。**模型自己的计数单独累加**（`routed.failures[c.restID()]`），因为 #2241：一个账号服务多个模型时，兄弟模型的成功会清掉账号计数，导致一直失败的模型永远只休息 1 分钟。

- 回退顺序：可用账号 → 路由顺序 → 开了 Sink 时限流过的排最后 → provider 回退模型 → 休息中的排最后。
- 429 且配额耗尽：休息到恢复；**只有尚未吐出任何字节时**才立刻换下一个候选。
- 休息时长优先级：厂商在拒绝里给的 reset → 上次读到 98%/100% 的那个窗口的 reset → `Retry-After` 或限流 reset 头（**上限 1 小时**）→ 否则 **15 分钟**。
- 窗口满时**排除 401/403**（`!unserved && status != 401 && status != 403`）：注释说明为什么 —— 一个缓存里读到 98% 会把正常账号一直锁到窗口重置（plugins#243）。
- `RestCapOff = -1`（`provider/concurrency.go:333`）即 `rest-cap: off`：只对 `failOther`（无法解释的失败：5xx、连接断）关掉休息，**仍然**休息 401/403、模型不支持、配额/余额耗尽、限流。
- 安全过滤拒绝**不休息任何人**（`protectionWords`，`fallback.go:1352`：`response protection is unavailable`）。

**`retryable(status, body)` 的完整逻辑**（`fallback.go:1419-1440`，可直接照抄）：

```go
body = wordsOf(body)              // 解码后的词也匹配（#1669）
switch {
case overflowed(status, body):    // 对话对模型太长，在每个账号上都一样长：告诉 agent，让它压缩
    return false
case status == 401, 402, 403, 404, 408, 429, status >= 500:
    return true
case modelRetired(status, body):  // 另一家可能还在服务这个模型
    return true
case status >= 400 && provider.EdgeBlocked(body):  // 厂商防火墙拦了地址（阿里云 405 挡在 zcode.z.ai 前）
    return true
case status == 400, 422:
    return quotaWords.Match(body) || unservedWords.Match(body) || refusedWords.Match(body) ||
           shapeWords.Match(body) || unsaidWords.Match(body) || regionWords.Match(body) || wrongEndpoint(status, body)
}
return false
```

**「上下文溢出」的判定比想象的严格**（`gateway.go:7502-7545`）。`overflowed` 只在 `status ∈ {400, 413, 422}` 且 `tooLong` 为真时成立；`tooLong` 还要求：
- 状态不在 5xx、不是 429；
- 消息不含 `max_tokens` / `max_output_tokens` / `max_completion_tokens`（那是回复额度，不是对话太长，压缩没用）；
- 不匹配 `paceWords = (?i)rate.?limit|per (minute|hour|day)|\bTP[MD]\b|please wait|try again later|throttl`（Bedrock 的 "Too many tokens, please wait" 是限流不是溢出；被误判成溢出的话 Claude Code 会压缩、再压缩、直到 thrashing 放弃）；
- 才去匹配 `tooLongRe` 那个很长的厂商话术表（含中文 `上下文(长度)?(超|过长)`、`超(过|出)(了)?(模型)?(的)?(最大)?上下文`）。

**`lateRests`**（`fallback.go:1448`）：回复已开始后中断的，`!tooLong(400,msg) && !refusedWords && !protectionWords && !strings.Contains(msg, emptyReply)` —— 对话太长、厂商读请求时就拒绝、模型生成空输出，都不休息。

**`tooLongUnsaid`**（`fallback.go:1456-1470`，`unsaidMargin = 1.2`）：有些厂商不明说，只说「capacity issues」（Devin 502）、「Invalid request parameters」（WorkBuddy 400）、「Error in upstream response」（Qoder 400），其实都是对话远超窗口。`estimate` 按 4 字节/token，实测 Devin 报 173954 token 而估算 151851，所以只超出 **1/5 以上**才算真的超。

**Sink 的实现很轻**（`internal/gateway/sink.go`，154 行）：`sink(key, now)` 记 `sinking{at, n}`（n 是单调序号）；`sunkAt(c)` 先查 `c.restID()` 再查 `c.restKey()`；`sinkOrder` 排序时先沉底的排后面沉底的之前。`sinks(on, routing)` 只在 `on && !goesRound(routing) && routing != provider.Manual` 时生效（轮转模式本来就在轮转，手动组只有一个成员）。**状态只在内存，重启即失**。动机（文件头注释）：一个账号一直答到被限流、休息一结束又拿到所有请求，是最容易被厂商风控盯上的。

**BaoCode 怎么落地（最小可用版）**

不要照搬八种模式。按 BaoCode 的形态，只需要：

1. `RoutingGroup`：一组上游 + 一种模式。模式只要三种 —— `order`（默认）、`rotate`、`usage`。`smart` 需要读每家配额，BaoCode 目前只有 Codex 能读，其它上游读不到，做了也是瞎猜。
2. **落点在 `lib/models/proxy/model_proxy.dart` 的三个失败点**（已核实行号）：`:276`（`_handle` 的 anthropic 路径）、`:511`（`_forward` 的主路径）、`:636`（`_passThrough`）。三处现在都是 `if (answer.statusCode >= 400) { … return … }`，把上游错误直接吐给客户端。要做的是把这三处统一到一个 `_attempt(provider, ...)` 里，失败时按 `retryable` 判定是否换下一个候选。注意 `:636` 那处还有 `countTokens` 分支，换家时要跳过它。
3. 复用 `CodexBalancer` 已有的粘性思路。它的文件头注释已经把理由写清楚了：「A conversation is kept on the account it went to while that one can take it: its prompt is cached there, and its reasoning encrypted for it.」实现只有 55 行（`_remembered = 2000`、`_sticky`、`_turns`、`pick`、`forget`），泛化成本很低。`stays=auto` 的 1024 token + 5 分钟判据可以留到第二批，第一批只做「同轮粘住 + 失败即换」。
4. 休息表放在 `lib/models/`，键是 `provider.id` 或 `provider.id/accountId`，值与 `CodexWindow` 的 `resetsAt` 同构，可以直接复用 `LimitResetPanel` 与 `limit_reset_panel.dart` 的「到点自动隐藏」逻辑。
5. **错误分类表单独一个文件**，照着上面列的写，并把「上下文溢出不重试」写进注释说明原因。这张表是本项里最该照抄的部分 —— 它每一条都对应一个真实事故编号。
6. **不要做 Sink 的第一版**。它的价值只在「多账号同一家」时显现，而 BaoCode 只有 Codex 有多账号。等真的有多账号用户抱怨再说。

**判断**：值得移植。这是模型层最大的价值。工作量估计：错误分类表 + 换家循环约 300–500 行（含测试），粘性泛化约 100 行，休息表约 150 行。

### 2.3 请求台账（`usage.jsonl`）

magpie 的网关把每个请求写成 `usage.jsonl`，`served.json` 记账号的最后服务时刻（重启后仍在）。查询接口 `GET /v1/magpie/usage/requests` 支持 `offset`/`limit`（≤500）与 `period`/`day`/`agent`/`provider`/`model`/`account`/`callerKey`/`purpose`/`failed`/`retried`/`q`/`via`。外部上报 `POST` 最多 5000 条 / 32 MiB，`rid` 幂等（跨重启）。

字段：必填 `t`、`agent`、`provider`、`model`、`rid`；可选 `in`、`out`、`cache_read`、`cache_write`、`cache_write_1h`、`reasoning`、`ms`、`ttft_ms`、`first_text_ms`、`flow_ms`、`status`、`cost`、`effort`、`session`、`err`。

**规模修正**：magpie 这块是 `internal/usage/` 下 **80+ 个文件**（`ledger.go`、`usage.go`、`served.go`、`observe.go`、`period_range.go`、`request_page.go`、`request_cells.go`、`request_disk.go`、`request_pairs.go`、`request_spill.go`、`request_snapshot.go`、`reported.go`、`heatmap.go`、`summary_cache.go`、`probes.go`、`window_holds.go`、`codex_identity.go`、`codex_used.go`、`purpose.go`、`zone.go`、`session_provider.go`、`gateway_sessions.go`、`priced_blocks.go`、`block_price.go`、`caller_provider.go`，外加四个平台的 `log_change_*.go` 与 `request_disk_map_*.go`）。这是「给几百人用的网关」的规模，**不要照搬**。

**BaoCode 怎么落地**：现在代理层只有两处 `debugPrint('Model proxy: $error')`（`model_proxy.dart:232`、`:316`），出问题基本没法排查。一个 JSONL 台账（`<data>/logs/proxy/usage.jsonl`，按天滚动、默认保留 7 天、可关）成本极低、收益直接：能回答「这一轮为什么慢」「哪家在上游 429」「缓存命中率到底多少」。字段取上面列表的子集，加 `rid` 去重。**不要**做 OTLP 导出、不要做回放（magpie 自己也没有回放接口）、不要做 spill/heatmap/summary_cache 这些为大数据量设计的东西。

**判断**：值得做，优先级仅次于 §2.2。工作量约 200–300 行。

### 2.4 上游预设

magpie 有 `magpie provider add <preset> <key>`，一个预设就是 baseURL + 协议 + 认证方式 + 模型清单。BaoCode 的 `site/featured/upstreams.json` 已经做了一半（推荐卡片，来自线上、缓存 5 分钟），但那是「推荐注册」而不是「预填表单」 —— 用户仍要自己填协议、URL、模型名。把它扩成 `{"protocol","baseUrl","auth","models","roles"}` 就能一键建好一个 provider。

**判断**：值得做，成本低。注意 `upstream_import.dart` 的安全性决定不能松 —— 链接里仍然只允许 name/protocol/url/key，`env`/`headers` 这类能执行代码的字段绝不从链接进。

### 2.5 其它看过但不建议的

| 项 | 为什么不做 |
| --- | --- |
| 替 ~70 个 agent 改配置文件 | magpie 是「多 agent 的路由中枢」；BaoCode 是 Claude Code 的 GUI，写别人家的配置既超出定位，也让「改坏别人的环境」变成自己的责任。而且它要做到「保留注释与格式、原子写、`.lock` 旁置、`.bak` 写前副本」才能安全，投入不小。 |
| Bun 插件宿主 + `onRequest`/`onEvent`/`onResponse` | 与 `docs/extensions.md` 的既定决策（提交 `a572d6a` 移除 Node 扩展宿主）直接冲突。三个钩子的契约值得记下来（返回对象=替换、`undefined`=原样、`null`=丢弃；超时 250ms、每事件 50ms；失败开放），但 BaoCode 若要这类能力，应该做成 Dart 侧的编译期扩展点，不是运行时插件。 |
| 意图路由（用小模型给每轮分类） | 需要常驻分类器与缓存，且 BaoCode 的轮次语义由 Claude Code 决定，代理层拿不到「用户轮次」的可靠边界。 |
| 限流 lane（`MaxConcurrency`/`QueueLimit`/`QueueWait`/`MaxRPM` 滚动 60s） | 桌面单用户场景收益有限。若确有上游 RPM 限制，做一个「单 key 滑动窗口 RPM 上限 + 排队」的阉割版即可，不要 lane 与 `phase`。 |
| OTLP 导出 | 桌面应用没有采集端。台账 JSONL 足够。 |
| Docker / 远程 magpie / LAN 共享 / 同步到 WebDAV-S3-GitHub | 与桌面应用形态无关。 |
| 1.6 GB 本地 PII 模型 | 见 §2.1。 |

---

## 3. VS Code

### 3.1 用户代码片段（最划算）

**值是什么**（源码：`src/vs/workbench/contrib/snippets/browser/snippetsFile.ts`、`snippetCompletionProvider.ts`、`src/vs/editor/contrib/snippet/browser/snippetVariables.ts`）

- 位置：语言特定 `<User>/snippets/<lang>.json`；全局用 `.code-snippets` 后缀；项目级放 `.vscode/` 下可共享。JSON 但**用 JSONC 解析**（`src/vs/base/common/json.ts` 的 `parse`，允许注释与尾逗号）。
- **文件结构支持一层嵌套**（`snippetsFile.ts` 的 `JsonSerializedSnippets`）：`{ [name]: snippet | { [name]: snippet } }`。判据是 `isJsonSerializedSnippet(thing) = isObject(thing) && Boolean(thing.body)` —— 有 `body` 就直接是片段，否则再往里遍历一层。VS Code 自己写出的「按语言分组」文件就是嵌套的。
- 片段对象字段：对象键（名字）、`prefix`（string 或 string[]）、`body`（string 或 string[]）、`description`（也接受数组，join）、`scope`（仅全局文件，逗号分隔的语言 id）、`include`/`exclude`（glob，string 或 string[]）、`isFileTemplate`。`body` 不是字符串就**整条丢弃**（不报错）。
- `scope` 的取法：有 `defaultScopes`（语言特定文件，即文件名决定）就用它，否则用 `snippet.scope` 按逗号切分 trim，否则空数组（= 全语言）。
- **`include`/`exclude` 的匹配规则**（`isFileIncluded`）：`getMatchTarget(pattern) = pattern.includes('/') ? uriPath : basename(uriPath)` —— **带斜杠的 pattern 匹配全路径，不带斜杠的只匹配文件名**。先跑 `exclude`（命中即排除），再跑 `include`（命中即保留，都不命中则排除）。`matchGlob(pattern, target, { ignoreCase: true })`。
- 语法：`$1`/`$2`（升序）、`$0`（永远最后，退出片段模式）、重复 tabstop **联动**、`${1:默认}` 可嵌套、`${1|一,二,三|}` 选择、`$name` 或 `${name:默认}` 变量、`${var/regex/format/options}` 变换。反斜杠转义 `$`、`}`、`\`，选择里还要转 `,` 与 `|`。
- 变量名：`TM_SELECTED_TEXT`、`TM_CURRENT_LINE`、`TM_CURRENT_WORD`、`TM_LINE_INDEX`（0 基）、`TM_LINE_NUMBER`（1 基）、`TM_FILENAME`、`TM_FILENAME_BASE`、`TM_DIRECTORY`、**`TM_DIRECTORY_BASE`**（文档没有，源码有）、`TM_FILEPATH`、`RELATIVE_FILEPATH`、`CLIPBOARD`、`WORKSPACE_NAME`、`WORKSPACE_FOLDER`、`CURSOR_INDEX`、`CURSOR_NUMBER`；`CURRENT_*` 系列（含 `CURRENT_TIMEZONE_OFFSET`、`CURRENT_TIMEZONE_NAME`）；`RANDOM`（6 位十进制）、`RANDOM_HEX`（6 位十六进制）、`UUID`（v4）；`BLOCK_COMMENT_START`、`BLOCK_COMMENT_END`、`LINE_COMMENT`（按语言）。
- **变量解析器的实现细节**（`snippetVariables.ts`，7 个 resolver 类，`CompositeSnippetVariableResolver` 按顺序问，第一个返回非 undefined 的胜出）：
  - `TM_FILENAME_BASE`：去掉最后一个 `.` 之后；**`idx <= 0` 时返回原名**，所以 `.git` 保持 `.git`、`foo.` 变 `foo`。
  - `TM_DIRECTORY`：`dirname === '.'` 时返回空串，否则 `labelService.getUriLabel(dirname(uri))`。
  - `RELATIVE_FILEPATH`：`getUriLabel(uri, { relative: true, noPrefix: true })`。
  - `CLIPBOARD`：多光标时按 `_selectionIdx`/`_selectionCount`/`_spread` 分摊。
  - `SnippetSession` 的组装顺序（`snippetSession.ts:567-575`）：model → clipboard → selection → comment → time → workspace → random。
- 变换的格式修饰符：`/upcase`、`/downcase`、`/capitalize`、`/camelcase`、`/pascalcase`、`/snakecase`、`/kebabcase`；条件 `:+`、`:?…:…`、`:-`。
- **补全的匹配是「锚点 + 子串」，不是前缀匹配**（`snippetCompletionProvider.ts`）：算锚点（词起点与每个非词字符），然后 `isPatternInWord(anchor.prefixLow, …, snippet.prefixLow, …)` —— 所以 `fc` 能命中 `for-const`。两条额外规则：① 锚点前缀以空白开头而片段前缀不是，跳过该锚点；② 触发字符模式下要求 `snippet.prefixLow.startsWith(triggerCharacterLow)`。
- **自动闭合对的「吃掉」**：光标右侧字符是某自动闭合对的闭合符、起始位置字符是同一对的开符、且片段前缀以开符开头以闭符结尾时，`endColumn++`（"Eat the character that was likely inserted because of auto-closing pairs"）。
- **排序**：`sortText = \`${snippet.snippetSource === SnippetSource.Extension ? 'z' : 'a'}-${snippet.prefix}\`` —— 用户/工作区片段永远排在扩展片段之前。
- **同名去重**（`_disambiguateSnippets`）：按 label 排序后，同名的那几个把 label 改成 `"{0}, {1}", prefix, snippet.name`。
- 与补全的关系：片段**混在** IntelliSense 列表里；`editor.tabCompletion: "on"` 才支持「打前缀按 Tab 展开」；`editor.action.insertSnippet` 可绑键，传内联 `snippet` 文本或 `langId`+`name`。
- 细节：未知变量名保留其 `${name:default}` 的默认文本（`Variable.resolve` 返回 false 时不动 `_children`）；要输出字面量 `$MyVar` 得写 `\\$MyVar`。
- 与 TextMate 的差异：不支持「插值 shell code」与 `\u`。

**BaoCode 现状（已逐行核对）**：底层全有且是忠实移植。`packages/bao_editor/lib/monaco/vs/editor/contrib/snippet/browser/snippet_parser.dart` 有 `SnippetParser`、`Text.escape`、`Placeholder.compareByIndex`/`toTextmateString`、`Choice`、`Transform`（含 `FormatString`）、`Variable`、`SnippetVariableResolver`；`snippet_session.dart` 有 `SnippetEdit`、`OneSnippet`、`SnippetVariableValues.resolve`、`SnippetSession.create`；测试在 `packages/bao_editor/test/monaco/vs/editor/contrib/snippet/browser/snippet_parser_test.dart`。接线在 `packages/bao_editor/lib/monaco/flutter/editor_surface_controller.dart:105-106`（`SnippetSession? _snippet`）、`:2425`（`inSnippetMode`）。补全侧只处理 LSP 的 snippet（`packages/bao_editor/lib/monaco/vs/editor/contrib/suggest/browser/completion_model.dart:31/:60` 的 `isSnippetKind`）。

**未知变量的行为与 VS Code 一致，没有偏差** —— `snippet_session.dart:14-15` 的注释写得很清楚：「Variables resolve through a caller callback (see [SnippetVariableValues]); unknown variables keep their default text as upstream does.」VS Code 的 `Variable.resolve` 在 resolver 返回 undefined 时也不动 `_children`。这一条我第一版报告里说错了，已在 §7 更正。

**缺的**：文件读取（JSONC）、一层嵌套的识别、`scope`/`include`/`exclude` 过滤、把用户片段作为**另一个 provider** 并入补全列表、`TM_*` 变量解析器、锚点式匹配、`a-`/`z-` 排序、同名去重。

**判断**：值得做，**这是 IDE 侧第一优先**。工作量小、用户可见收益大、无契约风险。设置键用 `editor.snippetSuggestions`、`editor.tabCompletion`（与 VS Code 同名，用户从 VS Code 迁过来能直接生效）。注意 `lib/` 下**目前没有任何用户片段目录的引用**（`grep "code-snippets\|User/snippets"` 只命中 `lib/extensions/vsix/extension_manifest.dart:324` 的 `case 'snippets':`，那是 VSIX 扩展贡献的片段）—— 所以这是纯新增，不涉及改造现有路径。

### 3.2 Workspace Trust（先补窟窿）

**值是什么**（源码：`src/vs/workbench/services/workspaces/common/workspaceTrust.ts`）

- 打开文件夹从「受限模式」开始；横幅 + 状态栏徽章 + 命令 `Workspaces: Manage Workspace Trust`；**空窗口默认完全信任**（`isEmptyWorkspace()` 时直接 `updateWorkspaceTrust(trusted)`，不写 uri 表）。
- 粒度：单个文件夹，或**父文件夹**（信任级联到所有子目录，子目录上不再出现「不信任」按钮）。多根工作区里新增文件夹会提示，拒绝则整个工作区转入受限。
- 受限模式禁用：**AI agent、终端、任务、调试、工作区设置、扩展**。终端可用 `terminal.integrated.allowInUntrustedWorkspace` 放行。任务连**枚举**都要先问（Tasks > Run Task）。工作区设置里被跳过的子集可用 `@tag:requireTrustedWorkspace` 筛出。扩展用 `@workspaceUnsupported` 看哪些受限。
- 扩展声明：`extensions.supportUntrustedWorkspaces` → `{ "esbenp.prettier-vscode": { "supported": true, "version": "6.4.0" } }`。
- 设置：`security.workspace.trust.enabled` 默认 `true`、`startupPrompt` 默认 `never`、`emptyWindow` 默认 `true`、`untrustedFiles` 默认 `prompt`、`banner` 默认 `untilDismissed`。CLI 有 `--disable-workspace-trust`。
- 信任状态与 Agents 窗口共享 —— 不可信工作区在两个地方都挡住 agent。

**实现的关键点（照抄这几条就够）**：

1. **查询是「最长父路径优先」**（`doGetUriTrustInfo`，`:374-410`）：`getCanonicalUri(uri)` 之后，遍历 `_trustStateInfo.uriTrustInfo`，用 `extUri.isEqualOrParent(uri, trustInfo.uri)` 挑 `fsPath.length` **最大**的那条。所以父目录信任 + 子目录显式不信任时，子目录的不信任生效。`setTrustedUris` 里还要 `removeTrailingPathSeparator`。
2. **「不信任」是删记录，不是存 false**（`doSetUrisTrust`，`:430-436`）：取消信任时 `filter` 掉该 uri 的记录。信任时跳过虚拟资源与远程授权、已存在则不重复加。
3. **父目录已信任时，子目录不能再被单独设为不信任**（`canSetParentFolderTrust()`，`:604-611`）—— 这与第 1 条的最长匹配配合：只有「先信任了子目录」再「信任父目录」时才会出现两条记录。
4. **只有 `Schemas.file` 与 `'vscode-vfs'` 可能不信任**（`:594`）。
5. 几个短路：`!isWorkspaceTrustEnabled()` → 信任；`agentSessionsWorkspace` 永远信任；虚拟资源信任；远程授权信任。

**BaoCode 现状**：`lib/debug/service/debug_host.dart:175` 恒真，唯一调用点 `lib/debug/service/debug_service.dart:254`。没有受限模式（grep `restrictedMode|RestrictedMode|untrusted` 只命中终端 shell integration 的 nonce 信任）。

**判断**：值得做，**而且必须在任务系统之前**。实现只要四步：① 一张信任表（`<data>/User/trusted.json`，存「已信任的 uri 列表」，查询时取最长父路径 —— 照第 1 条，不要存 `{path: bool}`）；② `requestWorkspaceTrust` 真实现 —— 弹确认框、记住选择；③ 受限时挡住 `runTask`、调试启动、终端新建（给 `allowInUntrustedWorkspace` 的放行开关）；④ 工作区设置里标记 `security.*` 之外的一小撮「需要信任」的键。注意 BaoCode 还要决定**是否让不可信工作区挡住 Claude Code 本身** —— 建议挡，并明说理由（agent 会跑命令）。

### 3.3 任务系统与 problem matcher

**值是什么**（`code.visualstudio.com/docs/debugtest/tasks`）

- task 字段：`label`、`type`（`shell` | `process`，或扩展贡献的类型如 `npm`/`gulp`）、`command`、`args`（字符串，或 `{value, quoting: "strong"|"weak"|"escape"}`）、`group`（如 `"test"` 或 `{kind:"build", isDefault:true}`）、`dependsOn`（默认并行，`dependsOrder:"sequence"` 串行）、`isBackground`、`problemMatcher`、`presentation`（`reveal`/`revealProblems`/`focus`/`echo`/`showReuseMessage`/`panel`：`shared`|`dedicated`|`new`/`clear`/`close`/`group`）、`runOptions`（`reevaluateOnRerun`/`runOn`：`default`|`folderOpen`/`instanceLimit`/`instancePolicy`：`prompt`|`silent`|`terminateNewest`|`terminateOldest`|`warn`）、`options`（`cwd`/`env`/`shell`，可按平台）、`hide`、`windows`/`linux`/`osx` 覆盖。
- 只有 `command`/`args`/`options` 接受变量替换（`${file}`、`${workspaceFolder}`、`${config:...}`、`${command:...}`）。
- matcher 顶层：`owner`、`fileLocation`（`["relative","${workspaceFolder}"]` 或 `"absolute"` 或 `"autoDetect"`）、`source`、`severity`、`pattern`、`background`、`base`、`applyTo`。
- `pattern` 每项的字段都是**捕获组索引**：`regexp`、`file`、`line`、`column`、`location`、`endLine`、`endColumn`、`code`、`severity`、`message`、`loop`、`kind`。`file`/`line`/`message` 必需；`kind:"file"` 时不需要 `line`。`severity` 不给就全按 error。
- `background`：`activeOnStart`、`beginsPattern`、`endsPattern` —— 用来判断 watch 任务这一轮跑完了。
- 多行 pattern 是数组，**必须匹配每一连续行**，跳过的行要写 `{"regexp":"^.*$"}` 占位。
- 内置 matcher：`$tsc`、`$tsc-watch`、`$jshint`、`$jshint-stylish`、`$eslint-compact`、`$eslint-stylish`、`$go`、`$mscompile`、`$lessc`、`$node-sass`。可用 `base` 继承再覆盖。
- **内置 pattern 的精确正则**（`src/vs/workbench/contrib/tasks/common/problemMatcher.ts:1560-1627`，可直接照抄）：
  ```ts
  lessCompile:     /^\s*(.*) in file (.*) line no. (\d+)$/                       // message:1, file:2, line:3, kind:Location
  jshint:          /^(.*):\s+line\s+(\d+),\s+col\s+(\d+),\s(.+?)(?:\s+\((\w)(\d+)\))?$/  // file:1,line:2,character:3,message:4,severity:5,code:6
  jshint-stylish:  [ /^(.+)$/ {file:1},
                     /^\s+line\s+(\d+)\s+col\s+(\d+)\s+(.+?)(?:\s+\((\w)(\d+)\))?$/ {line:1,character:2,message:3,severity:4,code:5,loop:true} ]
  eslint-compact:  /^(.+):\sline\s(\d+),\scol\s(\d+),\s(Error|Warning|Info)\s-\s(.+)\s\((.+)\)$/  // file:1,line:2,character:3,severity:4,message:5,code:6
  eslint-stylish:  [ /^((?:[a-zA-Z]:)*[./\\]+.*?)$/ {file:1},
                     /^\s+(\d+):(\d+)\s+(error|warning|info)\s+(.+?)(?:\s\s+(.*))?$/ {line:1,character:2,severity:3,message:4,code:5,loop:true} ]
  go:              /^([^:]*: )?((.:)?[^:]*):(\d+)(:(\d+))?: (.*)$/               // file:2,line:4,character:6,message:7
  ```
- **内置 matcher 的 `fileLocation` 逐个核对结果**（`fillDefaults()`，`:1946-2030`）：

  | matcher | fileLocation | filePrefix | applyTo | 备注 |
  | --- | --- | --- | --- | --- |
  | `msCompile` | `Absolute` | — | `allDocuments` | |
  | `lessCompile` | `Absolute` | — | `allDocuments` | `severity: Error`，`deprecated: true` |
  | `gulp-tsc` | `Relative` | `${workspaceFolder}` | `closedDocuments` | |
  | `jshint` | `Absolute` | — | `allDocuments` | |
  | `jshint-stylish` | `Absolute` | — | `allDocuments` | |
  | `eslint-compact` | `Absolute` | `${workspaceFolder}` | `allDocuments` | |
  | `eslint-stylish` | **`Absolute`** | — | `allDocuments` | |
  | `go` | `Relative` | `${workspaceFolder}` | `allDocuments` | |

- **`$tsc` / `$tsc-watch` 的真身在扩展里，不在 core**：`extensions/typescript-language-features/package.json:3060-3127`。
  - pattern：`"^([^\\s].*)[\\(:](\\d+)[,:](\\d+)(?:\\):\\s+|\\s+-\\s+)(error|warning|info)\\s+TS(\\d+)\\s*:\\s*(.*)$"`，`file:1, line:2, column:3, severity:4, code:5, message:6`。
  - `tsc`（`:3072-3084`）：`owner: typescript`、`source: ts`、**`applyTo: "closedDocuments"`**、**`fileLocation: ["relative", "${cwd}"]`**（不是 `${workspaceFolder}`）。
  - `tsc-watch`（`:3108-3127`）：同上，`background: { activeOnStart: true, beginsPattern: /^\s*(?:message TS6032:|\[?\D*.{1,2}[:.].{1,2}[:.].{1,2}\D*(├\D*\d{1,2}\D+┤)?(?:\]| -)) (Starting compilation in watch mode|File change detected\. Starting incremental compilation)\.\.\./, endsPattern: /^\s*(?:message TS6042:|...)(?:Compilation complete\.|Found \d+ errors?\.) Watching for file changes\./ }`。
  - `tsgo-watch`（`:3085-3106`）：`beginsPattern: /^build starting at .*$/`，`endsPattern: /^build finished in .*$/`。
- `fileLocation` 缺省时是 `Relative`（`ProblemMatcherParser.parse`/`createProblemMatcher`，`:1638` 起，`:1682`）。

**BaoCode 现状**：`runTask` 恒成功、`cancelTasks` 空、`executeCommand` 返回 null、`evaluateWhen` 恒真（`lib/debug/service/debug_host.dart:187`、`:191`、`:194`、`:173`）。没有 problem matcher、没有任务定义解析（`tasks.json` 只在 `lib/debug/service/debug_service.dart:141-142` 被读来拿 `inputs`）。`workbench.action.tasks.*` 的 8 个命令只存在于键位表与标题表。

**判断**：值得做，但**排在 Trust 之后**，并且要砍掉一块：因为不做扩展宿主，`type` 只支持 `shell` 与 `process`，扩展贡献的 `npm`/`gulp` 这类类型不支持（普通 npm 脚本仍可用 `shell` + `npm run`）。problem matcher 只需内置 5 个（`$tsc`、`$tsc-watch`、`$eslint-stylish`、`$go`、`$node-sass`）加内联 matcher。`presentation`/`runOptions` 可先只做 `reveal`/`panel`/`clear` 与 `runOn`。

收益具体：`preLaunchTask` 现在是个空壳 —— 三个调用点（`lib/debug/service/debug_service.dart:281` compound 的、`:426` 单配置的、`:639` 的 `postDebugTask`）拿到的是恒 `success`，做完之后「编译完再调试」才真的成立；problems 面板也终于有 `problemMatcher` 这个除 LSP 诊断之外的第二个来源。

### 3.4 括号对着色

**值是什么**（源码：`src/vs/editor/common/core/misc/textModelDefaults.ts:13-16`、`src/vs/editor/common/model/bracketPairsTextModelPart/colorizedBracketPairsDecorationProvider.ts`）

- **默认开启**：`bracketPairColorizationOptions: { enabled: true, independentColorPoolPerBracketType: false }`。我第一版报告说「默认 false」是**错的**（那是文档的过时说法），已更正。
- **不是 6 色取模，是 30 个 CSS 类**。`getInlineClassNameOfLevel(level) => \`bracket-highlighting-${level % 30}\``（`:101-102`）。注释声称「we use a number that is a lcm of all numbers from 1 to 6」，但 30 并不是 lcm(1..6)（那是 60）—— 30 能被 1、2、3、5、6 整除，唯独 4 余 2。**注释与代码不一致，照代码的 30 抄即可**，不要按注释去推 60。
- 主题侧：`colors = [editorBracketHighlightingForeground1 … Foreground6]`，`.map(c => theme.getColor(c)).filter(c => !!c).filter(c => !c.isTransparent())`，然后 `for (let level = 0; level < 30; level++) { const color = colorValues[level % colorValues.length]; collector.addRule(...) }`。**最终颜色 = `level % 30` 选类，类内再 `level % 实际有效色数`** —— 所以用户只配 3 个颜色时，30 个类里是按 3 循环的。
- 无效括号：`bracket.isInvalid` 时用 `unexpectedClosingBracketClassName = 'unexpected-closing-bracket'`，颜色取 `editorBracketHighlightingUnexpectedBracketForeground`。
- `independentColorPoolPerBracketType` 时用 `bracket.nestingLevelOfEqualBracketType`（每种括号类型各算一层），否则用 `bracket.nestingLevel`。
- `enabled` 为 false 时不产生装饰；装饰**不渲染到 minimap**（`:47` 注释）。
- **`maxBracketPairs` 之类的性能阈值键在当前源码里不存在** —— 我第一版说「施工前读源码核实」的那个猜测可以作废，不需要担心这项。

**BaoCode 现状**：完全没有（grep `bracketPairColorization|independentColorPool` 在 `lib/` 与 `packages/bao_editor/lib/` 零命中）。已有 `packages/bao_editor/lib/monaco/flutter/bracket_matching.dart`：`defaultBracketPairs = [('(',')'),('[',']'),('{','}')]`、`BracketMatch = ({int open, int openLength, int close, int closeLength})`、`matchBracket(...)`。

**一处必须说清的偏差**：`bracket_matching.dart:16-20` 的文件头已经写明「without standard token types, brackets inside strings and comments are not ignored; the search is bounded by [maxLines] lines in each direction instead of a time budget」。这对**配对高亮**只是偶发误判，但对**对着色**会明显出错 —— 一个含大量括号的正则字符串会被着成很深的颜色，而且因为着色是按嵌套深度算的，错误的深度会**传染给它后面所有的括号**。所以做着色时要么接受这个偏差并在文件头记录，要么先给 `matchBracket` 补一个「按语言配置的字符串/注释区间」查询（`packages/bao_editor/lib/monaco/flutter/language_configuration_assets.dart` 与 `packages/bao_editor/lib/monaco/vs/editor/common/languages/language_configuration.dart` 里已有各语言的 `comments`/`brackets` 配置，可以接；`bracket_matching.dart:1-2` 目前只从后者 `show CharacterPair`）。

**判断**：值得做，但**先决定字符串/注释怎么办**。若接受偏差，是半天的事；若要修，得先补区间查询，会大一些。

### 3.5 Hot Exit

**值是什么**（源码：`src/vs/workbench/services/workingCopy/common/workingCopyBackupTracker.ts`）

- 备份延迟只有两档：`DEFAULT_BACKUP_SCHEDULE_DELAYS = { ['default']: 1000, ['delayed']: 2000 }`（`:91-94`），即 **1 秒 / 2 秒**，不是我第一版猜的更长的节流。
- 选哪档（`getBackupScheduleDelay`，`:226-237`）：`workingCopy.backupDelay` 是数字就用它；`Untitled` 一律 `default`；否则 `filesConfigurationService.hasShortAutoSaveDelay(resource) ? 'delayed' : 'default'`。
- `hasShortAutoSaveDelay`（`filesConfigurationService.ts:411-423`）：`getAutoSaveConfiguration(resource).isShortAutoSaveDelay`，而 `isShortAutoSaveDelay = autoSaveDelay <= DEFAULT_AUTO_SAVE_DELAY`，其中 `DEFAULT_AUTO_SAVE_DELAY = 1000`（`:128`）。即**用户把自动保存调到 1 秒以内时，备份延迟反而更长（2 秒）** —— 因为那时自动保存已经在频繁写盘，备份不必那么急。
- 备份写到 `Backups/workspaces.json` 与 `<workspaceId>/` 下，启动时按工作区认领；`files.hotExit` 控制何时备份。

**BaoCode 现状**：完全没有（grep `hotExit|hot_exit|restoreUnsaved|backup` 零命中）。脏状态只在内存：`lib/ide/ide_debug_host.dart:247-249 isDirty`、`:260 save`。已有 `files.autoSave`（`lib/ide/ide_workbench.dart:627-652`：`_autoSave` 支持 `off`/`afterDelay`/`onFocusChange`/`onWindowChange`，默认 `off`；`_autoSaveDelay` 默认 1 秒），但 `off` 时（默认）崩溃即丢。已有的 `_autoSaves(doc) => doc.dirty && doc.isFile && !doc.deleted` 这个判据可以直接复用为「该备份哪些」。

**判断**：值得做。数据目录已经有 `User/` 布局，加 `<data>/Backups/<workspaceId>/` 即可；`.build-installer.bat` 那种安装包场景更需要这个（升级重启时用户不该丢改动）。实现要点：只在 `dirty` 且 `isFile` 时写、写盘延迟照 VS Code 的 1s/2s（自动保存延迟 ≤1s 时用 2s）、启动时按路径+修改时间认领（文件已被外部改过就不要静默覆盖，弹对比）。

### 3.6 次一档

| 项 | 现状 | 判断 |
| --- | --- | --- |
| `when` 子句补 `=~` / `in` / `not in` / `<` `>=` | `lib/keybindings/when_expression.dart:15-16` 明列不支持；带这些子句的键位**永不生效**，且不报错 | **值得做**。这不是新功能，是「从 VS Code 导入的键位静默失效」的正确性问题。源码侧的完整语法是 `KEY [ ('==' \| '!=' \| '<' \| '<=' \| '>' \| '>=' \| 'not' 'in' \| 'in') value ]` 与 `KEY '=~' REGEX`（`contextkey.ts:108-115`）。两个实现细节：① `=~` 的正则有 `regexParsingWithErrorRecovery: true`（`:134-138`），`/src//` 会被当作 `/src\//` 接受；② `_value()`（`:500-518`）把 `in` 本身也当作一个值（因为真有扩展写 `"when": "languageId == in"`），且默认分支**不消费 token**、返回空串（支持 `"when": "foo == "`）。`ContextLookup` 已经在，加正则与比较只要改 `parse` 与 `evaluate` 两个地方 |
| Call Hierarchy / Type Hierarchy | LSP 协议层零命中（`lsp_protocol.dart`），只有 codicon 图标 | 可选。LSP 方法很轻（`textDocument/prepareCallHierarchy` → `callHierarchy/incomingCalls` / `outgoingCalls`），但 UI 要新做；可以复用 `_showReferences` 的 peek 视图（`ide_workbench.dart:2588`）。要同时在 `lsp_client.dart` 的 capabilities 里声明支持 |
| documentColor 颜色装饰器 | 零命中 | 可选，小而独立。在 `lsp_client.dart` 加 `colorProvider` 能力 + 一个装饰器即可 |
| Sticky Scroll | 编辑器侧零命中；`packages/bao_editor/lib/monaco/flutter/editor_surface.dart:92` 的注释明说不在支持范围（「there are no … sticky scroll …」）。注意 `lib/chat/chat_history_view.dart:442-451` 的 `_stickyIndices` 是**聊天消息置顶**，与此无关 | 可选，纯体验。要做的话，`editor_folding.dart` 的语法树选择逻辑可以复用，但要新写滚动时的固定层渲染 |
| 自动端口转发 | `lib/remote/` 有专用转发（只为本机模型代理），无自动发现 | 可选但成本高。`remote.autoForwardPortsSource` 的 `process`/`output` 两种探测依赖进程表与终端输出解析，SSH 远程下还要过 RPC。先用「手动转发一个端口」的 UI 更实际 |
| `editor.codeActionsOnSave` | 零命中（只有 `editor.formatOnSave`：`lib/ide/ide_editor.dart:108/:142-144`，用在 `:2563`） | 可选，小。`formatOnSave` 的路径（`lib/ide/ide_editor.dart:2563`）已经在了，加「保存前跑哪些 code action」是同一处的扩展 |
| profiles / 设置云同步 | 都没有（`lib/keybindings/keybindings_sync.dart` 只是让键位跟随配置文件，不是云同步） | **不建议**。BaoCode 是单窗口桌面应用，设置本来就一份；云同步要新后端，与「自更新 + 遥测 + 诊断上传」已有的三个外联面叠在一起不划算 |

---

## 4. 建议的落地顺序

按「收益 ÷ 成本」排，并标出依赖。工作量是按源码读下来的量级估的，不是拍脑袋。

**批次 A：先补正确性与安全**

| # | 项 | 估计 | 依赖 |
| --- | --- | --- | --- |
| A1 | Workspace Trust 落地（把 `lib/debug/service/debug_host.dart:175` 的恒真桩换掉） | 300–500 行 | 无。**必须在 C3 之前** |
| A2 | `when` 子句补 `=~` / `in` / `not in` / 比较 | 100–150 行 | 无 |
| A3 | 用户代码片段（§3.1） | 400–600 行 | 无 |

**批次 B：模型层**

| # | 项 | 估计 | 依赖 |
| --- | --- | --- | --- |
| B1 | 上游失败分类 + 跨上游/跨 key 故障转移 + 休息表（§2.2）—— **本文价值最大的一项** | 550–750 行 | 无。建议先只做「同轮粘住 + 失败即换」，1024 token/5 分钟判据留第二批 |
| B2 | 代理层请求台账（§2.3） | 200–300 行 | 无 |
| B3 | 上游预设（§2.4） | 100–200 行 | 无 |

**批次 C：IDE 体验**

| # | 项 | 估计 | 依赖 |
| --- | --- | --- | --- |
| C1 | 括号对着色（先定字符串/注释策略，§3.4） | 半天（接受偏差）／ 2–3 天（修区间查询） | 无 |
| C2 | Hot Exit（§3.5） | 300–400 行 | 无 |
| C3 | 任务系统 + problem matcher（§3.3） | 800–1200 行 | **必须在 A1 之后** |
| C4 | Call Hierarchy / documentColor / Sticky Scroll | 各自 200–400 行 | 无 |

**批次 D：需单独评估**

| # | 项 | 说明 |
| --- | --- | --- |
| D1 | 隐私掩码（默认关，只做规则式，§2.1） | 1200–1800 行。难点是流式还原与 id 保护。建议先做一个只覆盖 tool-call 参数、不覆盖流式文本的最小版验证思路 |
| D2 | 价格表 | 优先级低：cost 由 Claude Code 自己上报（`engine.dart:484` 的 `total_cost_usd`），只有「跨上游后想知道谁花的」才有意义 |
| D3 | 自动端口转发 | 成本高（进程探测 + 终端输出解析 + SSH RPC），收益小。先用「手动转发一个端口」的 UI 更实际 |

---

## 5. 不建议做的（连同理由）

1. **profiles、设置云同步** —— §3.6。单窗口桌面应用，设置本来就一份；云同步要新后端，与「自更新 + 遥测 + 诊断上传」已有的三个外联面叠在一起不划算。
2. **替其它 agent 改配置文件** —— BaoCode 不写任何别家的配置（grep `.codex/config`、`.gemini/`、`opencode`、CC Switch 全零命中），这是定位而不是缺陷。而且 magpie 要做到「保留注释与格式、原子写、`.lock` 旁置、`.bak` 写前副本」才能安全，投入不小。
3. **Bun / Node 插件宿主** —— 与 `docs/extensions.md` 的既定决策冲突（`a572d6a` 移除 Node 扩展宿主）。
4. **OTLP 导出、Docker、远程网关、LAN 共享、同步到 WebDAV/S3/GitHub** —— 桌面应用没有对应场景。
5. **1.6 GB 本地 PII 模型** —— 与「16MB 安装包、0.18s 启动、120MB 内存」的定位直接冲突。
6. **完整的八种路由模式与意图路由** —— 读不到配额的模式（`smart`/`pace`）做出来是瞎猜；意图路由拿不到可靠的轮次边界（轮次语义由 Claude Code 决定）。
7. **限流 lane 与 `phase`** —— 单用户场景收益有限。若确有上游 RPM 限制，做一个「单 key 滑动窗口 RPM 上限 + 排队」的阉割版即可。
8. **Sink 的第一版** —— 只在「多账号同一家」时显现价值，而 BaoCode 只有 Codex 有多账号。

---

## 6. 已核实无需再做（避免重复劳动）

- 多根工作区：`lib/workspace/project_workspace.dart` 已有 `.code-workspace` 读写。
- 自动保存：`lib/ide/ide_workbench.dart:627-652` 已有 `files.autoSave`/`files.autoSaveDelay`。
- 终端 profile：`lib/ide/terminal/terminal_profiles.dart` 已移植。
- peek 式引用：`lib/ide/ide_workbench.dart:2588 _showReferences`，主题里有 `peekView*`。
- minimap、breadcrumbs、folding、inlay hints、CodeLens、semantic tokens：`packages/bao_editor/lib/monaco/flutter/` 下都有。
- LSP 的 snippet 补全：`packages/bao_editor/lib/monaco/vs/editor/contrib/suggest/browser/completion_model.dart:31/:60`（`isSnippetKind`）。
- 片段解析与展开：`packages/bao_editor/lib/monaco/vs/editor/contrib/snippet/browser/snippet_parser.dart`、`snippet_session.dart` —— 与 VS Code 逐行对应，**只缺文件层与变量解析器**。
- DAP 调试客户端、`launch.json` 解析、断点/变量/调用栈：`lib/debug/`。
- 键位导入、`when` 表达式框架：`lib/keybindings/`（只缺 §3.6 那几样运算符）。
- 诊断包脱敏：`lib/diagnostics/diagnostics_bundle.dart:141 redactHome`、`:160 scrubSecrets`。
- 会话全文索引、导出：`lib/search/`。
- 技能/子代理/命令/规则/MCP/hooks 一处管理：`lib/customize/`。
- Codex 多账号粘性选号与配额窗口：`lib/models/codex/`（`codex_balancer.dart` 仅 55 行，`codex_api.dart:127-140` 已有 `stripReasoningItems` 与 `isInvalidEncryptedContent`）。
- 推理签名校验：`lib/models/proxy/translate/signature.dart`（167 行，移植自 CLIProxyAPI）已有 `SignatureProvider`、`isValidGptReasoningSignature`、`isValidGrokEncryptedContent`、`kimiThinkingSignatureLengths`。

---

## 7. 相对第一版的更正（只看过文档时写错的）

第一版只读了官方文档与 README，以下 5 处与源码不符，本版已全部改正：

| # | 第一版的说法 | 源码实际 | 出处 |
| --- | --- | --- | --- |
| 1 | 括号着色 `editor.bracketPairColorization.enabled` **默认 false** | **默认 true** | `textModelDefaults.ts:13-16` |
| 2 | 颜色池最多 6 色，按深度取模 | **30 个 CSS 类**，`level % 30`；主题色再按 `level % colorValues.length` 循环 | `colorizedBracketPairsDecorationProvider.ts:101-102`、`:125` |
| 3 | `$tsc` 的 fileLocation 是 `["relative","${workspaceFolder}"]` | **`["relative","${cwd}"]`**，且 `applyTo: closedDocuments` | `extensions/typescript-language-features/package.json:3072-3084` |
| 4 | `$eslint-stylish` 把路径当相对工作区 | **`Absolute`** | `problemMatcher.ts:1946-2030` 的 `fillDefaults()` |
| 5 | BaoCode 的未知变量处理「与 VS Code 略有偏差，值得核对」 | **完全一致**，无偏差 | `snippet_session.dart:14-15` 注释 + VS Code `Variable.resolve` |

另有两处路径写错：

- `requestWorkspaceTrust` 在 `lib/debug/service/debug_host.dart`，不是 `lib/debug/debug_host.dart`。
- 第一版把「括号着色的 `maxBracketPairs` 等性能阈值」标为「施工前读源码核实」—— 实际这些键**在当前源码里不存在**，这个待办可以划掉。

**教训**：VS Code 的官方文档在默认值与实现细节上会过时（第 1 条尤其典型），magpie 的 README 省略了大量常量。这类「要照抄具体数字」的调研，必须读源码。
