# OpenCode、Kimi Code、Grok Build 的 hook 适配调研

调研日期：2026-10-04。结论来自官方文档、固定版本源码及上游测试源码阅读；没有安装或运行这些宿主，没有取得真实回调、目录证据或人工听音证据。本次只新增此文档。

## 结论与版本范围

三个工具都有接入机制。建议按 **新版 Kimi Code → Grok Build → OpenCode** 实施：Kimi 有明确的用户来源字段，Grok 需要先解决兼容配置的身份隔离，OpenCode 需要插件和会话状态判断。这是依据下述接口与 Claudio 现有结构作出的工程判断，不是实测工期或完整事件覆盖承诺。

| 宿主 | 本次源码基线 | 接入机制与默认位置 |
| --- | --- | --- |
| OpenCode | `v1.18.34`，[`aec0b9a6d8898f68f923aaf08b7306d931fd9d76`](https://github.com/anomalyco/opencode/commit/aec0b9a6d8898f68f923aaf08b7306d931fd9d76) | JS/TS plugin：全局 `~/.config/opencode/plugins/`，项目 `.opencode/plugins/`；也可在配置的 `plugin` 数组注册包。[官方插件文档](https://opencode.ai/docs/plugins/) |
| Kimi Code 新版 | `2.1.1`，[`f67e6398fb3210ad8ace970e2dfd5bcc984ed61f`](https://github.com/MoonshotAI/kimi-code/commit/f67e6398fb3210ad8ace970e2dfd5bcc984ed61f) | 命令 hook：`~/.kimi-code/config.toml` 中的 `[[hooks]]`，JSON stdin。[Hooks](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/hooks.html) |
| Grok Build | 官方仓库快照 [`2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8`](https://github.com/xai-org/grok-build/commit/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8) | 命令 hook：全局 `~/.grok/hooks/*.json`，项目 `.grok/hooks/*.json`；也支持 TOML 配置。[Hooks](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-pager/docs/user-guide/10-hooks.md) |

这里的 Grok CLI 指官方 **Grok Build**，安装后的命令是 `grok`；官方仓库定期从内部仓库同步，源码快照不等于已安装二进制版本。[产品与源码说明](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/README.md)

Kimi 的旧 Python `MoonshotAI/kimi-cli` 与新版 TypeScript `MoonshotAI/kimi-code` 必须区分。官方迁移说明允许二者共存；旧数据在 `~/.kimi/`，新版默认使用 `~/.kimi-code/`，并支持 `KIMI_CODE_HOME`。不能仅凭发现 `.kimi` 目录就认定新版可用，也不能套用旧版 Notification subtype、工具名和 hook 表。本次建议优先适配新版；没有确认三者各项能力的最低支持版本。[迁移说明](https://www.kimi.com/code/docs/kimi-code-cli/guides/migration.html)、[新版数据位置](https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/data-locations.html)

## Claudio 五事件候选映射

以下是设计候选，不是 Claudio 当前已实现的 capability。条件和缺口属于映射的一部分，不能删除条件后标成“5/5 已支持”。

| Claudio 公共事件 | OpenCode | Kimi Code 新版 | Grok Build |
| --- | --- | --- | --- |
| `task_start` 用户发起 | `chat.message`；需排除 synthetic 消息、`noReply` 与子会话 | 优先 `TurnStarted`，matcher `^user$`；与 `UserPromptSubmit` 二选一 | `UserPromptSubmit` 也覆盖自动唤醒；缺可靠 human-origin 判别时只列部分支持 |
| `stop` 响应结束 | `session.idle` 加本轮终态判断；不能直接把 idle 当成功 | `Stop` 是可被 veto 的结束尝试；主／子身份缺口待解 | `Stop` 至少过滤 `reason == "end_turn"`，排除 session teardown；仍是可被 veto 的 gate |
| `stop_failure` 执行中断 | 经过分类的 `session.error`；排除取消、可恢复错误和非会话错误 | `StopFailure`；需核实主／子事件归属 | `StopFailure` 对应错误终止；`StopCancelled` 单独处理 |
| `notification` 等待介入 | `permission.asked`；`question.asked` 可作为明确输入请求候选 | `PermissionRequest`；精确提问工具的 `PreToolUse` 只作提问意图 | `Notification` 的 `permission_prompt`；`idle_prompt` 仅普通信息；提问 `PreToolUse` 只作意图 |
| `subagent_stop` 子任务结束 | 按 session `parentID` 与子会话终态归并；不能直接套 `tool.execute.after(task)` | `SubagentStop`；当前缺稳定子 agent ID | `SubagentStop`；按 `phase`、`subagentId` 和实际时点验证去重 |

映射依据及限制见下列各节的一手源码。`stop` 的现有用户语义是“响应结束”，不证明整个项目完成、没有后台工作或所有第三方结束 hook 已放行。

## OpenCode：薄插件桥接

**配置与入口。** 官方 plugin 接收 JS 上下文和事件对象，可以取得 `directory`、`worktree`、SDK client。适配时由 Claudio 自有插件挑选必要字段，构造有界 JSON 交给短命 helper。插件只做协议转换，声音配置、播放和回执继续由 Claudio 拥有。[插件接口](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/plugin/src/index.ts)

**生命周期与错误处理。** 普通 plugin trigger 顺序 `await`，事件回调通过 `void` 调用；桥接必须自行处理异步错误、设置短超时，不修改宿主传入的模型／工具输出。全局、项目、本地和 npm 安装方式可能同时生效，安装器应检测自己的重复注册。[加载与派发源码](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/plugin/index.ts)、[加载顺序](https://opencode.ai/docs/plugins/#load-order)

**用户开始。** `chat.message` 不能单独证明用户刚发起任务：后台结果和其他 synthetic 输入也经过消息入口，`noReply` 消息也可能触发。需要结合消息来源、session 父子关系及消息 ID；身份不完整时不能猜测。[消息入口](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/session/prompt.ts)

**结束和失败。** `session.idle` 是状态变化；cancel、没有运行中 runner 的 cancel、错误清理都可能回到 idle。`session.error` 也可能包含可恢复的 context overflow；插件初始化错误还可能没有 sessionID。需要一个有界、按会话和本轮身份关联的 adapter 状态，避免错误／取消之后又播放正常结束音。[状态定义](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/session/status.ts)、[运行与取消](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/session/run-state.ts)、[处理器](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/session/processor.ts)

**授权、提问与子任务。** `permission.asked` 有专门权限请求身份；`question.asked` 在请求写入 pending 后、等待答复前发布，包含请求 ID 与 sessionID，可作为明确输入请求的来源候选。对应 replied/rejected 事件可用于识别答复／撤销，但需另行落实 Claudio 提醒生命周期合同。子任务可后台运行，`task` 工具返回不代表子会话结束。[权限请求](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/permission/index.ts)、[提问实现](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/question/index.ts)、[task 工具](https://github.com/anomalyco/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/tool/task.ts)

## Kimi Code：原生命令 hook，保留身份缺口

**配置合同。** `[[hooks]]` 严格允许 `event`、`matcher`、`command`、`timeout` 四个字段；不要照抄 `async: true` 或增加自有配置字段。默认超时 30 秒，允许 1–600 秒；匹配的命令并行执行。适配器应保留既有 TOML 内容和第三方规则，以绝对 helper 路径与显式短超时安装自有条目。[配置 schema](https://github.com/MoonshotAI/kimi-code/blob/f67e6398fb3210ad8ace970e2dfd5bcc984ed61f/packages/agent-core-v2/src/features/externalHooks/configSection.ts)、[命令匹配](https://github.com/MoonshotAI/kimi-code/blob/f67e6398fb3210ad8ace970e2dfd5bcc984ed61f/packages/agent-core-v2/src/features/externalHooks/internal/matchHooks.ts)

**输入与声音行为。** stdin 包含 `hook_event_name`、`session_id`、`client_type`、`cwd` 等 snake_case 字段。命令 cwd 是会话项目目录；这仍只是协议声明，不是 Claudio 的目录证据。Claudio 命令保持零 stdout/stderr、正常退出 0，避免向模型附加内容或阻断宿主。[官方输入协议](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/hooks.html)

**开始、结束与身份。** `TurnStarted` 提供 `origin_kind` 和 `turn_id`，用 `^user$` 可排除 task/system trigger。`UserPromptSubmit` 发生在可被阻断的提交阶段，不要同时安装两个开始信号。`Stop` 发生在 step 结束判断中，其他 hook 可以让模型继续；这一 feature 也注入子 agent，而当前 Stop payload 缺少 `agent_id`／`turn_id`。不能仅因有 Stop 事件就宣布主响应结束的完整支持。[agent hook 调用点](https://github.com/MoonshotAI/kimi-code/blob/f67e6398fb3210ad8ace970e2dfd5bcc984ed61f/packages/agent-core-v2/src/features/externalHooks/agent/agentExternalHooksService.ts)、[feature 注入](https://github.com/MoonshotAI/kimi-code/blob/f67e6398fb3210ad8ace970e2dfd5bcc984ed61f/packages/agent-core-v2/src/features/externalHooks/externalHooksFeature.ts)

**子任务与提问。** `SubagentStop` 的事件专有字段是 `agent_name`／`response`，没有稳定子 agent ID，精确关联和去重仍有缺口。`PreToolUse` 精确匹配 `AskUserQuestion` 只能生成 Question Intent；`TaskStarted(kind=question)` 也在真正 question request 执行前发布，不携带真正问题请求 ID，不能据此升级成 Explicit Input Request。新版普通 `Notification` 是后台任务状态通知，不应套用旧版的 `permission_prompt` 示例。[会话 hooks](https://github.com/MoonshotAI/kimi-code/blob/f67e6398fb3210ad8ace970e2dfd5bcc984ed61f/packages/agent-core-v2/src/features/externalHooks/session/sessionExternalHooksService.ts)、[问题后台任务](https://github.com/MoonshotAI/kimi-code/blob/f67e6398fb3210ad8ace970e2dfd5bcc984ed61f/packages/agent-core-v2/src/agent/tools/ask-user-question/question-background-task.ts)、[事件表](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/hooks.html#event-reference)

## Grok Build：独立配置与跨宿主隔离

**配置建议。** 使用 Claudio 独占的全局 `~/.grok/hooks/claudio.json`，沿用 `hooks → Event → matcher group → command` 结构。全局／项目／配置／插件规则会合并，项目 hook 受 folder trust 约束。保持声音命令短时、无决策输出；当前未确认可照搬 Claude 的 `async` 字段。[发现规则](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-hooks/src/discovery.rs)、[配置 parser](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-hooks/src/config.rs)

**最关键的兼容问题。** Grok 默认兼容扫描 Claude/Cursor hooks；源码对 Claude 扫描还受 compatibility 开关和是否已导入的状态约束。因此已存在的 `claudio hook claude-code ... --installation-id ...` 可能被 Grok 执行。Claudio 现入口主要依据 argv 中的 HostID 和安装代次；据此推断存在重复播放或把 Grok 回调记为 Claude 的风险，本次没有实测重现。Grok 的去重键包含原始 command，新增 `grok` 命令并不会自动合并旧 `claude-code` 命令。[兼容与去重](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-hooks/src/discovery.rs)、[Claudio CLI](../helper/Sources/claudio/Subcommands.swift)、[命令生成](../helper/Sources/ClaudioCore/HookCommandMatching.swift)

适配时应在 Claudio 自有入口／自有条目范围解决来源校验与兼容迁移。不能为了去重直接关闭全部 Claude compatibility 或删除用户第三方 hooks。Grok runner 注入 `GROK_HOOK_EVENT`、`GROK_SESSION_ID`、`GROK_WORKSPACE_ROOT`，可作为来源判别所需证据的一部分；实际判别合同需实现并验证。[runner](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-hooks/src/runner/command.rs)

**JSON 与事件语义。** Grok 原生字段以 camelCase 为主，如 `sessionId`、`promptId`、`workspaceRoot`；还提供部分 snake_case aliases。其中 `hookEventName` 使用 snake_case 事件值，`hook_event_name` 使用 PascalCase 事件值，须独立解析。`UserPromptSubmit` 对自动唤醒和子会话也触发；当前其 payload 没有明确 human-origin 字段，不能按名称直接等同 Claudio“用户发起”。[事件 schema](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-hooks/src/event.rs)、[prompt gate 派发](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-shell/src/session/acp_session_impl/hook_dispatch.rs)

`StopFailure` 和 `StopCancelled` 是不同结果；用户中断、拒绝授权、max-turns、no-progress 不应自动变成 API 错误。`Stop` 需过滤 session-end 的额外 observe fire，并考虑其他 Stop hook 阻止结束后的重复。`idle_prompt` 在失败／取消后也可能出现，只能用作普通 idle 信息。各事件的身份字段不同：不能假设每种事件都有 `subagentType`；`SubagentStop` 则另有 `phase` 与子 agent 身份。[终止分类](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-shell/src/session/acp_session_impl/turn_end_hooks.rs)、[Stop 与 idle 合同](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-pager/docs/user-guide/10-hooks.md)

**等待介入。** 上游有 PTY 测试要求：自动允许的工具不触发 `Notification/permission_prompt`，真正权限 UI 等待时才触发；本次只阅读，未执行该测试。`PreToolUse` 精确匹配真实工具 ID `ask_user_question` 可提供提问意图，但此次未确认 `UserQuestionAsked` 到通用 Notification hook 的完整投影，不能宣称明确待答提醒已可直接接入。[权限测试](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-pager-pty-harness/tests/pty_e2e/permission_prompt_hook_chimes_only_on_real_wait.rs)、[提问工具](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-tools/src/implementations/grok_build/ask_user_question/mod.rs)

## Claudio 实施位置与验收边界

Claudio 本次基线为 `main@f106df47b5931ab952107a2b1b3cf295fd1f9a06`。调研开始时工作树干净；当前三个新宿主均未进入产品来源 registry。

| 现有 owner／入口 | 后续需要的工作 |
| --- | --- |
| [HostIntegrationModels.swift](../helper/Sources/ClaudioCore/HostIntegrationModels.swift) | 增加独立 Host Product／Host Surface 与版本化 binding；分别标记 support、implementation、activation；未证实的映射保留部分支持或未实现 |
| [HostIntegrationAdapter](../helper/Sources/ClaudioCore/HostIntegrationManager.swift) | 各宿主各自实现 inspect/connect/repair/disconnect，拥有原生配置和独立锁、备份、scope；共享快照供 GUI／CLI／诊断读取 |
| [HostHookRunner.swift](../helper/Sources/ClaudioCore/HostHookRunner.swift)、[CLI](../helper/Sources/claudio/Subcommands.swift) | 增加宿主输入验证；仍由现入口完成播放、当前代次校验和脱敏回执；OpenCode 仅增加协议桥接 |
| [Event.swift](../helper/Sources/ClaudioCore/Event.swift)、[ADR 0018](adr/0018-separate-question-intent-and-observation-evidence.md) | 保持五个公共事件；提问复用 notification 声音，Question Intent 与 Explicit Input Request 分开 |
| [WorkspaceSurfaceEligibility](../helper/Sources/ClaudioCore/WorkspaceSoundRules.swift)、[ADR 0005](adr/0005-use-global-sound-defaults-with-sparse-surface-overrides.md) | 目前只开放 Claude Code／Codex；新增来源先使用默认组，逐事件取得真实 cwd 证据后再开放工作区 |

当前命令格式为 `claudio hook <host> <nativeEvent> --installation-id <UUID>`；现二进制尚不接受这三个新 HostID。这里没有提供可立即安装的 Claudio 配置片段，以免把拟议 adapter 当作已实现接入。

实施时先验证可明确绑定的开始／授权等事件，再处理结束、失败、子任务和提问的身份缺口。每个宿主应覆盖：

- 自有配置的幂等安装、修复、卸载、第三方内容保留；Grok 另测与 Claude 兼容加载共存、Kimi 另测新旧版共存。
- 普通完成、错误终止、用户取消、可恢复错误、自动唤醒、前台／后台子任务；不得因同一轮多个信号重复播放。
- 当前安装代次的真实回调与断开后的迟到回调；逐 binding 和 subtype 记录证据。
- 有界字段校验、超时、helper 不可用、零输出、静音与播放失败；不保存 prompt、response、问题正文或完整原始 payload。
- 两个真实目录及相关 worktree 的逐事件 cwd 验证；声音播放尝试、人工听音、原生提示和工作区资格分别验收。

后续行为变更按 [CONTRIBUTING.md](../CONTRIBUTING.md) 建立 issue／实施范围并运行相应 harness。本文属于调研证据，不是已实现、当前激活、发布或正式验收结论。
