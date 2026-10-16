# OpenCode／Kimi Code 工作区目录（cwd）回调证据 spike（2026-10-16）

状态：**采集与静态核对完成；两宿主均确认存在可用的逐事件工作区目录通道；各缺个别未触发事件的实证，开放对应工作区资格前须按事件补齐。** 本 spike 只回答「目录能不能拿到、是否正确」，不含开放实现。

## 问题与方法

ADR 0005 要求新来源以「目标事件的实际版本目录回调证据」开放工作区资格。OpenCode 与 Kimi Code
此前只有 Default Group 证据，没有任何工作区目录证据。本轮在本机做带保护的真机观察：

- 只读核对：OpenCode v2 官方插件文档与 `@opencode-ai/plugin`/`@opencode-ai/schema` 2.0.30
  （2026-10-15 npm 发布）类型；Kimi Code 官方 hooks 文档与上游源码 `main`（2026-10-16）。
- 真机观察：OpenCode 侧为临时 V2 探针插件（`{ id, setup }`，`ctx.event.subscribe` +
  `ctx.session.get`，事件信封 `location` 探测 + `ctx.permission.hook`），置于
  `~/.config/opencode/plugins/claudio-probe.js`；Kimi 侧为 `~/.kimi-code/config.toml` 临时
  `[[hooks]]` 观察条（带标记块，6 个事件，指向临时脚本）。两侧只记录事件身份、字段名、
  目录值与「目录 == hook 进程工作目录」布尔；不记录提示、标题、正文或工具内容。
- 宿主配置 0600 备份在先（`~/.claudio-spike-20261016/`），收尾恢复原字节并核对 SHA-256：
  `config.toml` 恢复后与备份逐字节一致（15 个 hook，与采集前相同），探针插件已移除。
- 驱动方式：Kimi Code `--prompt` 非交互回合；OpenCode `opencode run`；A/B 目录为
  `/tmp/claudio-spike-A`、`/tmp/claudio-spike-B`（真实路径经 `/private/tmp` 解析）。
- 本机版本：Kimi Code 2.2.0（即当前最新发布）；OpenCode 2.0.27（2026-10-12 安装）。

## Kimi Code：结论

**每个 hook 事件的 stdin JSON 都带 `cwd`，且等于 hook 进程的实际工作目录；逐目录正确。**
文档承诺与上游源码一致（`matchHooks.ts` 组 payload，`cwd: args.cwd` 恒在），真机观察复证：

| 事件 | 目录 | 记录 | 关键字段（除公共 cwd/session_id 外） |
|---|---|---|---|
| UserPromptSubmit | repo、A、B 各 1+ | cwd 全部正确 | `is_steer`、`prompt`（字段名记录，未存内容） |
| TurnStarted | repo、A、B 各 1+ | cwd 全部正确 | `origin_kind`（user 起源判定可用）、`turn_id` |
| Stop | A×2、B×1 | cwd 全部正确 | `stop_hook_active` |

公共字段含 `client_type`；repo 目录的两次记录还带 `session_title`（字段名层面），A/B 回合未带——不影响目录证据。
注意：当前运行中的会话同样触发了新 hook（配置改动对存活会话生效）。

**缺口（本轮未触发，如实记录）：** `StopFailure`、`PermissionRequest`、`SubagentStop`。
`--prompt` 非交互模式下 Bash 工具被自动放行（perm-probe 文件实际创建，无 PermissionRequest 到达），
提问/子任务事件需交互会话才能补采。另注意已知宿主缺陷：桌面端会话 `cwd: "/"`
（上游 issue #4029），终端 CLI 会话不受影响；插件 manifest 注册的 hook 以插件根为 cwd，
会话目录须走 `config.toml` 的 `[[hooks]]`。

## OpenCode：结论

**目录通道存在且正确，双保险：** 事件信封 `location.directory` 在 155 个事件中 146 个 populated
（按目录 78 A / 68 B 全部正确）；唯一缺信封的三个类型恰是 `session.execution.started`、
`session.execution.succeeded`、`session.usage.updated`——它们都带 `sessionID`，经
`ctx.session.get({ sessionID })` 回查 `Session.Info.location.directory` 全部成功：
108 次查询 0 错误（A 63 / B 45），目录全部正确。`session.created` 数据自带 `location` +
`projectID` + `sessionID`。插件按目录各实例化一次（实例目录分别为 A、B），事件流全局共享。

**缺口（本轮未触发，如实记录）：** `permission.asked`／`form.created` 在 `opencode run`
非交互模式下未出现（与 2026-10-16 v2 移植验证的已知缺口一致）；`session.execution.failed`
（stop_failure 候选）未触发（两轮回合均成功）；子会话未驱动。桌面 GUI 会话的目录行为未观察。

## 与 ADR 0005 证据门的差距

- 已具备：`task_start`/`stop` 链路（Kimi UserPromptSubmit/TurnStarted/Stop；OpenCode
  execution.started/succeeded + session 信封/回查）的逐目录正确证据。
- 待补采（开放对应资格前逐事件 A/B 实证）：Kimi `StopFailure`、`PermissionRequest`、
  `SubagentStop`；OpenCode `permission.asked`（需交互/ask 模式）、失败终态、子会话。
- 桌面宿主（Kimi Desktop `cwd:"/"`、OpenCode GUI）在宿主缺陷修复/另行验证前不计入证据。

## 建议

两宿主的工作区目录通道均已证实可用，建议为「OpenCode／Kimi Code 工作区来源开放」单独立实现
计划（能力目录、`WorkspaceSurfaceEligibility` 证据门内开放、表单与 l10n），未触发事件按上表在
接入验收轮补采；补齐哪个事件开放哪个事件，不齐不开放。本 spike 的日志留在
`~/.claudio-spike-20261016/`（0600），恢复与移除已核对，宿主配置无残留。

## 证据边界

真机回调与目录匹配为本轮实测；自动化与文档核对不冒充未触发事件；人工听音、原生 UI 与发布
门禁不在本 spike 范围。观察脚本与探针插件未入库。
