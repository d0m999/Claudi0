# Codex 当前客户端异步提问与 Claudio 反应探针（2026-09-27）

## 结论

当前根客户端的 `request_user_input_async` 在两次受控调用中均返回
`accepted: true`，当前会话 rollout 也各写入一条精确的
`response_item/function_call` 和同请求的 `function_call_output`。用户随后澄清：
**问题在 Codex TUI 可见，未出现的是 Claudio 铃音或提示**。先前把“没看见”
解释为 Codex 问题界面缺失，是错误的；当前澄清至少确认了第二轮的问题界面。
第一轮的 TUI 可见性没有逐轮单独确认。

两轮都**没有启动 ClaudioGUI 开发观察器，也没有安装 Codex 提问 hook**；复核时
没有 ClaudioGUI 进程。因此没有 Claudio 反应符合测试设置，不能记为播放器或提示
故障。TUI 的人工可见性不能自动升级为 Claudio 可消费的可靠**明确输入请求**信号。

## 只读采集

- 以当前根会话身份精确定位当日单个 rollout 文件，校验普通文件与当前用户所有权，
  两次均从新 EOF 开始；没有扫描或回读旧会话。临时诊断程序复用
  [`CodexQuestionObservationJSON`](../../gui/Sources/ClaudioGUICore/CodexQuestionObservation.swift)
  的选择性解析，只输出记录类型、相对时间、精确候选工具名和本次运行内的请求序号。
  问题、选项、答案、原始行、路径及原始请求身份不进入输出。
- 单次读取上限 64 KiB、单行 32 KiB，最多输出 128 条类型记录。第一轮观察约
  70.0 秒，第二轮约 90.0 秒；两轮都无解析失败、积压失败或未完成行。此程序
  只用于诊断记录 shape，不充当产品的明确请求识别器。
- 两轮均未启用 Claudio 开发观察、安装提问 hook 或修改用户配置。现有
  `~/.codex/hooks.json` 在测试前后 SHA-256 均为
  `5c4b19ca1ce6e929aa03557965b5dc4115ba835f72f9d695c1a2b55b647d952d`，
  且没有 `PreToolUse` 槽位。无预期 Claudio 铃音或提示。两轮结束后，临时
  诊断源码、可执行文件及脱敏摘要均已按精确文件清单删除。

## 两次结果

| 场景 | rollout 中的本次请求 | 客户端反馈 |
| --- | --- | --- |
| 第一轮，观察约 70 秒 | `request_user_input_async` 调用于观察开始后约 4.665 秒出现；同请求结果约 4.775 秒出现 | 起初反馈语义不清；TUI 可见性未逐轮确认，Claudio 未启用 |
| 第二轮，观察约 90 秒；调用后立即结束回复 | 调用于约 4.433 秒出现，同请求结果于约 4.591 秒出现；原回复约 12.826 秒完成，约 24 秒后收到新一轮用户消息 | 用户澄清 Codex TUI 看到了问题；Claudio 未启用、未响应 |

第一轮共 21 条新增类型记录；第二轮共 44 条。两轮均没有解析到
`event_msg/request_user_input` 或 App Server 的 `item/tool/requestUserInput` 类型；
本地 rollout 的缺席不证明其他通道不存在事件。第二轮在原回复完成后，确实继续
观察到了新一轮的 `task_started` 和用户消息类型记录。用户的 TUI 可见性反馈来自
人工观察，rollout 只证明调用和结果；两轮未启用的 Claudio 路径没有声音或提示证据。

## 决定与剩余门槛

停止重复未启用 Claudio 的异步测试。提前提醒并显式开启隔离开发观察器后的
[一次受控验收](codex-development-notice-probe-2026-09-27.md)已获得真实 TUI 问题、
人工听音和横幅可见反馈；横幅文案未看清。当前根客户端仍
没有精确 `PreToolUse` 的真实回调、当前安装 receipt 或可靠待答来源；隔离 CLI 的
hook 命中不能自动外推。Codex 提问正式 binding 继续不安装、不启用。
