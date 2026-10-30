# Kimi Code Stop 主轮落盘判定（2026-10-29）

状态：主 `Stop` 已作为 acceptance 候选实现，并通过真实 Kimi 2.3.3 主/子任务回调验证；
`StopFailure` 继续未实现；人工听音、运行中 TUI 热加载和普通 Release 准入未完成。

实现基线：Claudio `b944d80438dd018b57d53962f4c4e1cf8d301f6c` 之上的未提交工作区。
2026-10-30 修复：marker 只在活动事实提交或可靠暂存后写入；metadata 按首个 LF 完整读取。
宿主：Kimi Code `2.3.3`；会话 wire `protocol_version = "1.5"`。

## 为什么不能用 Stop payload

真实 hook 取证（临时 hook，运行后按字节恢复原配置）显示：

- `Stop`：`hook_event_name`、`session_id`、`cwd`、`client_type`、`stop_hook_active`；没有
  `turn_id`、`origin_kind` 或 agent 身份。
- `TurnStarted`：有 `turn_id`、`origin_kind`（`user` / `system_trigger`）、`origin_name`。
- 子 agent 的 `TurnStarted` 是 `system_trigger` / `subagent`，但它产生的 `Stop` 与主 `Stop`
  字段完全相同；一个主任务 + 两个并行子任务会产生 3 个不可区分的 `Stop`。
- `StopFailure` 只有 `error_type` / `error_message`，同样没有主/子身份。

因此不能把每个 Kimi `Stop` 直接映射成完成提示。

## 落盘事实

会话目录 `~/.kimi-code/sessions/*/session_<id>/` 中：

- `state.json` 有 `agents` 名册（`main` / `sub`、`parentAgentId`），但
  `lastTurnReason` 在 Stop hook 进入时仍可能为空，不可作为实时判据。
- `agents/main/wire.jsonl` 只记录主 agent 的轮次：
  - `agent.turn.ended`：`turnId`、`outcome`（实测 `done`）
  - `turn.ended`：`agentId: main`、`turnId`、`reason: completed`
  - `prompt.completed`：`agentId: main`、`promptId`
  - `subagent.spawned / started / completed` 也只出现在主 wire 中，但没有额外的
    `agent.turn.ended`。
- 时序实测：主 `Stop` hook 进入时，当前轮的 `agent.turn.ended` 已经写入；子 agent `Stop`
  进入时，main wire 最后仍是 `subagent.*` / `context.*` / `llm.request`，没有新的主轮结束。
  第二轮主任务产生新的 `turnId: 1`。

## 实现

新增 helper-only `ClaudioHookInput/KimiStopTranscriptAdmission.swift`，避免把 wire 读取和
Kimi schema 链接进 GUI 体积敏感的可执行文件：

1. CLI 先校验 `Stop` 基础 payload（`client_type`、session、cwd、`stop_hook_active` 类型）。
2. 在 `KIMI_CODE_HOME`（默认 `~/.kimi-code`）的 `sessions/*/<session_id>/agents/main/wire.jsonl`
   中先按首个 LF 完整读取 metadata（受 128 KiB 上限约束），再只读尾部；要求 metadata
   `protocol_version == "1.5"`。
3. 取最后一条 `agent.turn.ended`，只有 `outcome == "done"` 才继续。
4. 用 `~/.claudio/integrations/kimi-stop-transcript/` 下的 per-session 0600 marker
   （FileLock + `Data.write(options:.atomic)`）去重；同一 `turnId` 的子/重复 Stop 不提醒。
   CLI 只准备 `HostEventSource` 和消费闭包，不写 marker；共享 runner 在 `.deduplication`
   许可内复验安装和授权后，由 marker 锁内的消费闭包先发布活动事实，只有活动已提交或可靠
   暂存才写 marker。活动失败保留旧 marker，合法重试仍可发布。
5. 回执、活动、工作区、静音和提示仍走既有 runner 路径。核心 parser 只接受 Stop 基础字段，
   主轮身份由 admission 负责。
6. wire 不可读、版本未知、目录/文件是符号链接或 marker 损坏时一律失败关闭。

配置由 4 条 hook 升级为 5 条（`TurnStarted`、`Stop`、`PermissionRequest`、`PreToolUse`、
`SubagentStop`），全部 `timeout = 2`。`Stop` binding 改为
`kimi-code:Stop:stop:transcript_main_turn_only:v1`，展示文案为
“按主 agent 落盘轨迹判断；仅主轮结束提醒”。`StopFailure` 仍为
`interfaceSupportedNotImplemented`。

## 自动检查

| 检查 | 结果 |
| --- | --- |
| helper 完整 executable harness | **6265 checks，0 failures** |
| GUI background harness | **15391 checks，0 failures** |
| 新增宿主 CLI 合同（Debug + Release） | **363 checks passed** |
| 签名 app 体积 | **6,994,880 B**（预算 7,000,000 B） |
| helper 体积 | **2,825,328 B**（预算 3,250,000 B） |

2026-10-30 修复后复跑：helper **6403 checks，0 failures**；新增宿主 CLI 合同 **369 checks
passed**（Debug + Release）。当前机器只有 CommandLineTools，缺少 `SwiftUIMacros` 宏插件，
GUI background harness 与签名体积未能重跑，仍沿用上表 2026-10-29 记录并标记未验证。

本次实现顺带守住了 16 KB 页边界：wire 读取与 marker 在 helper-only target；共享 parser
只增加 Stop 基础校验，最终签名 GUI 未超预算。

## 真实宿主回调

安装代次 `088BDA88-BA30-4FD3-8008-38524C8EB477`，5-hook 配置，`acceptance=true`。

主任务 + 一个子任务，headless Kimi 2.3.3：

| 时间 | 事件 | 结果 |
| --- | --- | --- |
| 21:26:26 | `TurnStarted` | `task_start.wav`，PID 94784 |
| 21:26:49 | `SubagentStop` | `subagent_stop.wav`，PID 95673，一次 |
| 21:26:53 | 主 `Stop` | `stop.wav`，PID 95869，一次 |

`Stop` 回执为 `kimi-code:Stop:stop:transcript_main_turn_only:v1`，`playback_result: played`。
随后在同一会话运行第二轮，marker 从 `turn_id: 0` 变为 `turn_id: 1`，`Stop` 回执更新，
状态显示“支持 4/5 类提醒”。

原始 payload、wire 快照和 ACP 观测保存在私有
`~/.claudio/integrations/evidence/kimi-stop-payload-2026-10-29/`，不进入 Git；未记录
prompt/response 到文档。

## 未完成与边界

- `StopFailure` 未实现：尚无主任务失败样本的实时时序；不能用子 agent 的失败冒充。
- 助手只确认 `afplay` 启动和参数，未主观听音；真实横幅仍需用户观察。
- 运行中的 Kimi TUI 需重启或让宿主重新加载配置；旧 4-hook 会话不会自动获得 Stop。
- Stop 仍只是 acceptance 候选，普通 Release 的 `verifiedBindings` 不增加。
- 依赖 Kimi 私有 wire 1.5；版本变化会失败关闭，而不是退回误报。
- TUI 热加载、其他 Kimi 版本、VoiceOver、键盘焦点、Developer ID、公证与发布未验证。
