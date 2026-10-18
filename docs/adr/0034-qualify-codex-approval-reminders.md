---
status: accepted
---

# 按请求的审批路由筛选 Codex 授权提醒

2026-10-18 用户要求修复 Forkwise 会话中后台自动审批引发的连续授权横幅，保留人工授权提醒。
`PermissionRequest` 发生在审批路由完成之前，不能独立证明需要用户操作；人工审批和后台
`auto_review` 的 `permission_mode` 均可能为 `default`。

helper 在既有接收资格和安装身份检查之后、播放与来源提示之前，要求**此次请求实际审批人**的
明确证据。只有确证的 `user` 保留原声音、提示及 `.permission` 原因；`auto_review`、缺失、
冲突或无法验证的输入均静默。静默不占用播放去抖槽，不补播。
合法回调继续记录实际活动与 `muted` 回执；回执表示回调已到达，不表示用户被要求授权。
其他宿主、事件绑定、声音配置、第三方 hooks 及审批策略不变。

## 同轮切换修订（现行 · 2026-10-18）

原实现用匹配 `turn_id` 的 `turn_context.approvals_reviewer` 推断当前请求路由，前提不成立。
客户端通过 `turn/settings/update` 更换审批人时，上游只替换内存中的 `next_step_settings`；
rollout 的初始 `TurnContext.config` 快照不更新，也不产生 `thread_settings_applied`。
同一份 hook 输入与 rollout 因而可能对应不同审批人，轮次、子会话身份和设置记录均不能消除歧义。

当前宿主 `PermissionRequest` 输入没有请求级审批人字段，rollout 也不持久化
`ExecApprovalRequest`。因此撤掉 transcript 路由推断；CLI 专用 `ClaudioHookInput` 中的
`CodexApprovalRoutingResolver` 保留调用接口，但不解释输入或打开任何会话文件，统一返回
`.unavailable`。共享 Core 的类型化路由接口及未注入时的关闭行为保持不变。

这纠正了原实现对路由资格的误判；**当前协议下人工与自动授权回调都会静默，原始“保留人工
授权提醒”的目标尚未达成**。恢复人工提醒必须先取得与此次请求绑定的正式路由字段或更晚的
明确人工请求事件，再独立验证真实宿主行为。不得用初始策略、配置文件、工具名、工具输出缺失
或自造输入字段替代该证据，也不声称路由证据等同于授权框已经显示。

本修订沿用 [ADR 0012](0012-use-ephemeral-event-source-notices.md) 的提示资格与隐私边界，
撤回此前对 [ADR 0018](0018-separate-question-intent-and-observation-evidence.md) 增加的
审批 transcript 读取路径。不启用提问观察原型，不生成额外事件，不订阅或接管 App Server，
不增加后台进程、轮询、重试、队列或 hook 超时，遵守 ADR 0031 的执行策略边界。
路由及输入内容不进入日志、回执、活动、配置或新缓存；GUI 不链接 CLI 适配器。

## 验证边界

隔离回归通过真实 `handleHostHook` 入口验证：初始 `user` 和 `auto_review` 快照在同轮更新
前后都不能确认路由；两次回调保留同一份 hook 输入和 rollout，符合上游未持久化更新的行为。
原实现会在该回归中误判路由，并对初始 `user` 发出声音和提示。

Core seam 另行注入 `.automatic`、`.unavailable` 和 `.user`，验证连续九次静默回调零声音/
零提示、回执和活动计数保留、随后已确认人工请求不被去抖吞掉。`.user` 是测试替身提供的
证据，不能视为当前生产适配器已能确认人工请求。旧的有界读取、身份和特殊文件测试随读取路径
撤销；新增回归不再把改写初始快照当作宿主的同轮切换。

测试使用临时目录、合成 transcript 和播放器/通知 sender 替身，不向运行中的 GUI 重放 hook。
这些检查不证明真实宿主弹框、原生横幅或真实音频验收；也不代表已更新安装中的应用。

协议依据：[Codex hooks](https://learn.chatgpt.com/docs/hooks)、
[automatic review](https://learn.chatgpt.com/docs/sandboxing/auto-review)，以及固定上游版本的
[同轮设置更新](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/core/src/session/step_activation.rs#L373-L383)、
[PermissionRequest 输入定义](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/hooks/src/schema.rs#L298-L318)、
[hook runtime](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/core/src/hook_runtime.rs#L258-L277)、
[rollout policy](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/rollout/src/policy.rs)。
