---
status: accepted
---

# 新增来源只桥接有身份和终态证据的事件

采用 2026-10-04 用户确认的 OpenCode／Kimi Code 首版计划，继续保持五个公共 `Event`。
OpenCode 与 Kimi Code 各自拥有独立 Host／Surface、配置根和安装代次；GUI、CLI 与诊断
读取同一份适配器快照。配置、接口支持、当前实现与当前安装回执保持独立事实。

OpenCode 通过 Claudio 自有 `server` 插件接入，`UserTurnStarted`、`ResponseCompleted`、
`ResponseFailed`、`PermissionRequested`、`QuestionAsked`、`SubagentCompleted` 是 Claudio
定义的桥接事件。任务开始需要已确认主会话、真实用户输入及实际执行消息；响应结束需要
对应终态消息和本条响应的 idle。取消、可恢复错误、插件初始化错误和 task 工具返回不能
冒充失败或子会话成功。缺少必要身份或证据时不触发。

Kimi Code 使用新版独立配置根，任务开始只接收 `origin_kind == user` 的 `TurnStarted`；
授权请求使用 `PermissionRequest`，精确 `PreToolUse(AskUserQuestion)` 仅表示提问意图。
`SubagentStop` 仅表示成功，缺少具体子任务身份；`Stop`／`StopFailure` 缺少主／子 agent
身份，首版保持尚未实现。旧 Python Kimi、OpenCode Desktop、自动答复／审批和精确导航
不纳入本次，新增来源按 ADR 0005／0018 使用默认声音组。

自有 JS 随 helper 嵌入并随 app 交付；OpenCode 现有 JSONC 保持原字节。Kimi 的自有 TOML
块以原字节增删，不通过重序列化保存；不支持的语法或已修改的自有内容保持原样并报告
冲突。两者复用锁、一次备份、CAS、安装代次和最小回执；版本、有效配置根摘要与绑定
版本进入激活作用域。非法输入和旧安装不能写活动、消费请求身份、播放或生成当前回执。

打包的 Release helper 使用 `-Osize`，使新增插件及保守 TOML 解析器仍满足现有可执行
体积预算；GUI 继续使用原有 full LTO／`-Osize` 合同。hook 的输出、退出码、路径、
strip 和功能合同由 CLI 子进程及打包检查复核。

正式构建的启用集合只接纳已有真实宿主回调、原生提示与听音证据的绑定；harness、静态
配置和合成回执不能补齐证据。2026-10-04 实现阶段集合为空；2026-10-06 逐绑定
真实验收后，只将已审阅绑定写入 `AdditionalHostReleasePolicy.verifiedBindings`。
DEBUG 或显式 `CLAUDIO_ADDITIONAL_HOST_ACCEPTANCE` 构建用于后续隔离验收，不意味着
正式发布支持。此条件使来源可以逐绑定取得证据，避免把来源级 ready 借给未观察的事件。

本决定扩展 ADR 0012／0013／0018 的现有来源及提醒边界，没有新增提示生命周期或配置
所有者。自动证据与未完成验收见 [验证记录](../validation/opencode-kimi-code-2026-10-04.md)。

2026-10-06 的真实宿主、用户原生提示／听音确认与封包结果见
[逐绑定验收记录](../validation/opencode-kimi-code-2026-10-06.md)。未观察绑定继续关闭。

2026-10-16 OpenCode 2.0.27 起宿主更改了插件契约（default 导出须含 `id` 与 `setup()`，
V1 返回 hooks 对象的 `server()` 写法会被 schema 拒绝；事件经 `ctx.event.subscribe()`
异步订阅、载荷为 `{ type, data }`；`chat.message` 对应 `ctx.session.hook("prompt")`）。
本决定定义的六个桥接事件及其证据规则不变：插件改为同一 default 导出同时提供
`server()`（1.18.29+）与 `setup()`（2.x），任务开始仍以“已确认主会话、真实用户输入
（prompt 准入）、实际执行消息”为证据，`session.inbox.delivered` 因对合成与自动执行
同样投递而不作为用户输入证据；helper 侧增加 OpenCode 2 品牌版本行
（`opencode v2.0.27`）的数字版本提取，激活作用域门槛不变。适配依据、本机真实事件流
观测与未完成的真机听音验收见
[移植验证记录](../validation/opencode-v2-plugin-2026-10-16.md)。

2026-10-18：随 ADR 0005 同日修订放开目录适用来源证据门，OpenCode／Kimi Code 已接入事件的
payload 目录命中工作区规则时使用工作区声音配置，不再一律使用默认组；目录缺失、非法或不匹配
仍回落默认组。上文「新增来源按 ADR 0005／0018 使用默认声音组」按本修订理解。

2026-10-21：Grok Build 的独立原生 hooks、Claude compatibility 来源防护与三条候选绑定见
[ADR 0035](0035-integrate-grok-build-native-attention-hooks.md)。它继续采用本决定的逐绑定发布证据门槛。

2026-10-29：Kimi Code `Stop` 以主 agent 落盘 wire 作为身份证据实现。实测 `Stop` payload 没有
主/子 agent 身份，而 `agents/main/wire.jsonl` 的 `agent.turn.ended` 只在主轮结束时出现；子
agent `Stop` 不产生该记录。admission 因此放在 helper-only 的
`ClaudioHookInput/KimiStopTranscriptAdmission.swift`，只读 wire 尾部，要求
`protocol_version == "1.5"`、`outcome == "done"`，并用 per-session `turnId` marker 去重；
未知版本、不可读文件或符号链接一律失败关闭。共享 runner 只接收预校验来源，核心 parser
只校验 Stop 基础字段。`Stop` 仍是 acceptance 候选，普通 Release 不增加
`verifiedBindings`；`StopFailure` 仍无主/子失败身份，继续未实现。证据见
[验证记录](../validation/kimi-stop-transcript-2026-10-29.md)。
