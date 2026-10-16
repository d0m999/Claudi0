# OpenCode 2 插件契约移植与验证（2026-10-16）

状态：实现已完成；自动验证通过；本机真实宿主事件流已观测；真实提示音听音验收未完成。

用户报告 OpenCode 不触发 Claudio 提示音。定位为宿主升级：本机 OpenCode 由 1.18.34 升级到
`2.0.27`（安装于 2026-10-12），v2 更改了插件 API 契约，Claudio 桥接插件从未加载成功。

## 根因证据（本机只读）

- OpenCode server 日志（`~/.local/share/opencode/log/opencode.log`）每次启动都有：

  ```
  WARN failed to load plugin target=~/.config/opencode/plugins/claudio.js
  cause="PluginModule.LoadError: Plugin must export a default definition with an
  id and an effect or setup function. (SchemaError: Missing key at
  ["default"]["effect"], Missing key at ["default"]["setup"]))"
  ```

  同目录的第三方 `agentbridge2.js` 同样失败，属于宿主性契约变更，不是 Claudio 独有。
- v2.0.27 二进制内插件 schema 只接受 default 导出 `{ id, setup }` 或 `{ id, effect }`；
  V1 的 `{ id, server }`（返回 hooks 对象）被拒绝，插件不注册任何回调。
- `opencode --version` 输出由裸版本 `1.18.34` 变为 `opencode v2.0.27`，
  `SemanticVersion(parsing:)` 只接受点分数字串，导致 helper 的
  `HostActivationScope.additionalHost` 判活失败：`claudio doctor` 报
  `✗ OpenCode 已有 claudi0 连接但宿主不可用：未检测到兼容的 OpenCode CLI`；
  手工 `claudio hook opencode UserTurnStarted …` 返回 0 但不写回执（installation 仍钉在
  Oct 6 的 `host=1.18.34` 作用域）。最后一个成功 opencode 回执为 2026-10-07 23:41:54，
  与升级时间吻合。

## 移植依据（可复核来源）

- OpenCode 官方 V1→V2 插件迁移指南（dev.opencode.ai/v2/docs/build/plugins/migrate-v1）：
  V1 实现不在 V2 运行；V2 读 default 导出的 `id` 与 `setup(ctx)` 并忽略 `server`；
  同一默认导出可同时暴露 `server()` 与 `setup()`（V1 对象入口点支持自 1.18.29 起）；
  `chat.message` 的 V2 对应是 `ctx.session.hook("prompt", …)`；V1 的 `event` 回调变为
  `ctx.event.subscribe({ signal })` 异步迭代；cleanup 由 `setup` 返回函数承担。
- v2.0.27 二进制事件目录（strings 提取）与 `@opencode-ai/plugin`/`@opencode-ai/sdk`
  dev 通道类型（2026-10-14）交叉核对：会话生命周期事件为
  `session.execution.started/succeeded/failed/interrupted`、
  `session.step.started/streamed/ended/failed`、`session.tool.*`、`session.retry.scheduled`、
  `session.synthetic`、`session.created/updated/deleted`、`permission.asked/replied/rejected`、
  `question.asked/replied/rejected` 与 `form.created/replied/cancelled`；错误名沿用
  `APIError`、`ProviderAuthError`、`UnknownError`、`MessageOutputLengthError`、
  `StructuredOutputError` 等既有集合。
- **本机真实事件流观测**：临时 V2 插件（`{ id, setup }` + `ctx.event.subscribe`）接入本机
  server 后捕获：2.0.27 插件事件为 `{ type, data }` 扁平载荷（新版 SDK 为
  `{ type, properties }` 且家族名带 `next` 段，移植同时兼容两种形状并忽略未知事件）；
  `session.created`、`session.execution.started/succeeded/failed`、`session.inbox.*`、
  `session.step.started`、`session.synthetic`、`session.retry.scheduled` 均真实到达插件流；
  **`ctx.session.hook("prompt")` 只对真实用户提示触发**（载荷
  `{ sessionID, messageID, prompt, metadata, delivery }`），而 `session.inbox.delivered`
  对合成与自动执行同样投递——因此只有 prompt 准入可以作为“真实用户输入”证据，
  与 V1 只信任 `chat.message` 的规则一致。观测还确认 server 每活跃目录各实例化一次插件且
  事件流全局共享，故排放按进程内事件身份认领去重（跨进程仍由 helper 既有宿主级去抖兜底）。

## 已实现的候选事件（契约不变）

| 公共事件 | V1 证据（1.18.34） | V2 证据（2.0.27） |
| --- | --- | --- |
| `task_start` | `chat.message` 真实用户输入 + 执行中的 assistant 消息 | `session.hook("prompt")` 准入 + `session.execution.started` + `session.step.started` |
| `stop` | 终态消息 + 对应 idle | `session.execution.succeeded` |
| `stop_failure` | 终态错误消息 + 会话错误 + idle | `session.execution.failed` 且错误名属于既有五种终态 kind |
| `notification` | `permission.asked` / `question.asked` | `permission.asked`；`question.asked` 或 `form.created`（V2 表单提问） |
| `subagent_stop` | 子会话成功终态 + idle | 子会话（`session.created` 带 `parentID`）`session.execution.succeeded` |

取消（`session.execution.interrupted`）、可恢复错误（`session.retry.scheduled`）、
合成提示（`session.synthetic` 与 prompt 的合成 parts）、压缩续写、缺身份或终态证据不触发；
桥接 payload、hook 命令格式与 helper 契约保持不变。会话身份以 `session.created` 或
`ctx.session.get({ sessionID })` 有界查得（V1 为 `client.session.get({ path: { id } })`）。

## 配置、隔离与隐私

- 插件仍以 `integrations/opencode/claudio.js` 为唯一源：default 导出
  `{ id, server, setup }`；V1（1.18.29+）走 `server()` 与返回 hooks，V2 走 `setup(ctx)`；
  两侧各自投影必要字段后才入队，不保留提示、消息部件、工具输入输出、提问、答复或错误正文。
- `render`／`inspect` 增加了上一版（仅 V1）模板 SHA，旧安装可识别为自有并迁移轮换安装代次，
  不会被误判为第三方文件。
- helper 的 additional-host 版本探测从任意版本行提取数字 token（接受 `opencode v2.0.27`
  与裸 `1.18.34`），门槛仍为 OpenCode `>= 1.18.34`；版本身份原样进入 activation scope。
- 版本作用域随输出格式变化，旧安装在新 helper 下需要重连一次；断开先撤销当前代次。

## 自动证据

| 检查 | 本轮结果 | 证据边界 |
| --- | --- | --- |
| helper executable harness | **5,599 checks，0 failures**（连续三次） | 编译与隔离 fixture／回归合同；新增版本行解析与旧模板迁移场景 |
| OpenCode 插件状态 harness | **69 scenarios passed** | V1 37 项合成上游事件不变；V2 32 项覆盖准入、执行终态、失败、取消、子会话、提问／授权、去重、隐私、队列上限、双实例认领、cleanup、`{ sessionID }` 查身份 |
| 新增来源 CLI 子进程合同 | **242 checks passed；Debug 与 Release** | 真实 helper 子进程、假宿主版本（含 `opencode v2.0.27` 变体）、隔离配置、静音音频 |
| JS 嵌入一致性 | **PASS** | 嵌入模板与唯一源逐字节一致 |
| Swift 格式 lint（改动文件） | **PASS** | `swift-format lint --strict` |
| GUI executable harness | **24,927 checks，19 failures** | 14 项为 SourceScannerSuite 自造并撤回的绊线证据；5 项为既有原生 `PanelSettingsHandbackSuite` 焦点失败，与本改动无关 |
| 本机真实事件流观测 | 已捕获（见上） | 证明 V2 事件与 prompt 准入真实存在；不代表提示音听音 |
| 本机端到端真机回合 | **两个回执均写入** | 见下 |

## 本机端到端验证（2026-10-16 凌晨）

用 `scripts/dev-bundle.sh` 构建本机 arm64 ad-hoc app（GUI 二进制超出 7,000,000 B 预算：
带改动 7,031,352 B、HEAD 基线 7,014,968 B，超预算属工作树既有状态；本次以
`CLAUDIO_GUI_BYTES_PER_ARCH=7200000` 仅为本机验证放行，不作为发布证据），启动后：

1. `claudio doctor`：`✓ OpenCode 已收到事件；支持 2/5 类提醒；按会话身份与执行／终态证据桥接`。
2. 以本地 OpenAI 兼容假 Provider 驱动一次真实 `opencode run` 回合（真实宿主事件流、
   真实 plugin 加载、真实 helper 播放与回执）：
   `UserTurnStarted` 与 `ResponseCompleted` 两个回执均在当次回合写入，
   `playback_result` 均为 `played`， installation 为当前代次。
3. 实测修复两个真实缺口：OpenCode 2 的 `ctx.session.get` 只接受 `{ sessionID }`
   （`{ path: { id } }` 抛 SchemaError，曾令会话永远未知）；同一回合的两次 helper
   生成只差数毫秒，曾因 helper 安装锁非阻塞竞争丢一个回执，现由插件串行生成修复。
4. 人工听音未验证（本机无人耳确认）；真实授权提问（`permission.asked`/`form.created`）
   与真实失败终态未在本机触发。

## 仍未完成的验收

- 真实提示音（`task_start`／`stop` 等）的逐项人工听音未完成。
- 真实授权提问（`permission.asked`/`form.created`）与真实失败终态未在本机触发过。
- OpenCode 2 事件契约仍在快速演变（`next` 家族改名、`properties` 载荷）：移植同时兼容
  两种形状并忽略未知事件，但未来版本需要重新核对真机事件流。
- Release 构建的打包体积预算（工作树既有超支）、Intel 架构、Developer ID 签名、公证与发布均未重跑。
