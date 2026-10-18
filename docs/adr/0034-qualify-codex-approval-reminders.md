---
status: accepted
---

# 按当前轮次的审批路由筛选 Codex 授权提醒

2026-10-18 用户要求修复 Forkwise 会话中后台自动审批引发的连续授权横幅，保留人工授权提醒。
`PermissionRequest` 发生在审批路由完成之前，不能独立证明需要用户操作；人工审批和后台
`auto_review` 的 `permission_mode` 均可能为 `default`。

helper 在既有接收资格和安装身份检查之后、播放与来源提示之前，读取回调指定会话当前轮次的
`approvals_reviewer`。只有明确的 `user` 保留原声音、提示及 `.permission` 原因；
`auto_review`、缺失、冲突或无法验证的输入均静默。静默不占用播放去抖槽，不补播。
合法回调继续记录实际活动与 `muted` 回执；回执表示回调已到达，不表示用户被要求授权。
其他宿主、事件绑定、声音配置、第三方 hooks 及审批策略不变。

这是 [ADR 0012](0012-use-ephemeral-event-source-notices.md) 的授权提示资格修订，
并为 [ADR 0018](0018-separate-question-intent-and-observation-evidence.md) 的会话读取边界
增加仅限真实 `PermissionRequest` 回调的只读元数据适配器。它不启用提问观察原型、不生成
额外事件、不订阅或接管 App Server，也不从工具输出缺失推断等待状态。

## 证据与读取边界

元数据解析器属于 helper 内部的 `ClaudioHookInput` target，由 CLI 注入共享 Core 的类型化
审批路由接口。未注入时返回无法确认；GUI 只链接共享类型，不链接 transcript 解析器。
打包时核对真实 GUI/helper 二进制，防止解析器或其 Codable 元数据进入 GUI。

- stdin 必须有唯一且类型正确的事件、模式、会话、轮次及 transcript 路径字段，最大 64 KiB。
  子代理使用 `agent_id` 对应的会话身份；存在时不回退到父会话。
- 只打开当前接入根 `~/.codex/sessions` 内被指定的 `.jsonl` 文件，不扫描目录或其他会话。
  逐层固定目录描述符、拒绝链接和非正规文件，验证文件归属与单一硬链接。
  文件名和首行 `session_meta.id` 必须同时匹配会话。
- 首行读取上限 64 KiB；从末尾按 64 KiB 块反向读取，最多 8 MiB，单条记录最多 1 MiB。
  最新 `turn_context.turn_id` 必须匹配此次回调；不跨过新轮次寻找旧的人工策略。
  更晚的冲突设置、未写完的记录、读取中替换或变化均返回无法确认。
- 中间 JSONL 字节只在本次同步调用中暂存；仅解释记录类型与身份、审批路由字段，忽略消息、
  命令和结果内容。它们及会话路径、身份不进入日志、回执、活动、配置或新缓存。
  不增加后台进程、轮询、重试、队列或 hook 超时；遵守 ADR 0031 的执行策略边界。

## 能力限制与验证

当前宿主的 hook 没有“授权框已显示”字段，rollout 也不持久化 `ExecApprovalRequest`。
本适配器确认的是**本轮交给用户审批的路由**。其他 PermissionRequest hook 后续自动放行
时，仍不能凭该路由证明最终 UI 已出现；需要宿主提供更晚的明确人工请求事件才能消除此限制。
rollout 格式不是稳定公开 API，旧版本、结构变更、超过读取上限或非标准会话根会静默；
因此不声称所有宿主版本都保留了人工提醒。未来有正式路由字段或请求事件时应替换此读取边界。

隔离回归通过真实 `handleHostHook` 入口验证连续九次自动审批零声音/零提示、随后人工审批
正常送达且不被去抖吞掉，并覆盖子会话、长历史、身份不符、配置冲突、截断、越界和特殊文件。
测试使用临时目录、合成 transcript 和播放器/通知 sender 替身，不向运行中的 GUI 重放 hook。
这些检查不证明真实宿主弹框、原生横幅或真实音频验收；也不代表已更新安装中的应用。

协议依据：[Codex hooks](https://learn.chatgpt.com/docs/hooks)、
[automatic review](https://learn.chatgpt.com/docs/sandboxing/auto-review)，以及
[Codex hook runtime](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/core/src/hook_runtime.rs)、
[rollout policy](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/rollout/src/policy.rs)。
