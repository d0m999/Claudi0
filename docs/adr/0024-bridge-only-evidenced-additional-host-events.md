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
配置和合成回执不能补齐证据。用户本次要求先完成实现与自动验证，故集合保持为空。
DEBUG 或显式 `CLAUDIO_ADDITIONAL_HOST_ACCEPTANCE` 构建用于后续隔离验收，不意味着
正式发布支持。此条件使来源可以逐绑定取得证据，避免把来源级 ready 借给未观察的事件。

本决定扩展 ADR 0012／0013／0018 的现有来源及提醒边界，没有新增提示生命周期或配置
所有者。自动证据与未完成验收见 [验证记录](../validation/opencode-kimi-code-2026-10-04.md)。
