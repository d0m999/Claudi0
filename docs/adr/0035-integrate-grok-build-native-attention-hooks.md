---
status: accepted
---

# Grok Build 首版只接收有明确语义的原生关注事件

采用用户确认的 Grok Build 首版计划，以本机 `grok 1.0.62` 为首个验收基线，新增独立的
`grok-build` Host／Product／Surface，复用公共五事件、接入维护、安装代次、来源提示与提醒生命周期。
首版有三条独立绑定：主会话 `StopFailure → stop_failure`、
`Notification(permission_prompt) → notification`，以及精确
`PreToolUse(ask_user_question) → notification`。提问只展示「即将提问」，不形成待接手提醒。
`UserPromptSubmit` 无法可靠区分人工输入与自动唤醒；`Stop`、`SubagentStop` 仍是可阻止的结束
尝试，因此三者明确保持尚未实现。取消、拒绝授权、普通 idle 与工具失败不映射为执行中断。
Grok 的来源摘要可由当前任一已准入绑定的真实回执提升为「已收到事件」，不等待尚未实现的
任务开始；逐绑定证据仍独立校验，授权回执不能激活提问意图。

Grok 默认加载 Claude compatibility hooks，故共享 helper 必须在 Claude 回调与旧 `play` 入口
先识别 runner 保留的 `GROK_*` 身份及有界 Grok payload，安静拒绝兼容调用，避免重复播放、
误写 Claude 活动／回执与错误来源。原生 Grok 入口则同时核对 runner 身份和严格 payload；
重复键、别名冲突、错误字段类型与主／子会话混淆失败关闭。错误按 session＋prompt、提问按
session＋tool-use 去重；授权通知没有请求 ID，沿用通知去抖与提醒版本，不能推断授权已解决。
1.0.62 的 forced ask 可在 `bypassPermissions` 客户端自动批准时仍派发 `permission_prompt`；
因此授权通知只接受已知 `default`／`auto`／`plan` 模式，bypass、未知或缺失模式拒收。

仅管理有效绝对 `GROK_HOME`（否则 `~/.grok`）中的 `hooks/claudio.json`，显式超时 2 秒。
只有完整已知模板证明所有权；外来、空白、编辑或重复绑定文件均拒绝覆盖／删除。使用既有锁、
CAS、一次备份与安装 scope；scope 包含版本、配置根摘要和 binding 版本。显式 OFF 先保存并撤销
接收资格，清理失败仍保持关闭；GUI 退出与静默不补播。Claude compatibility 设置、第三方 hooks
与其他来源不由本适配器改写。

新增来源继续遵守 ADR 0024：Debug／additional-host acceptance 可见三个候选绑定；普通 Release
只接纳已有经审阅真实回调、原生横幅和人工听音证据的绑定，无合格绑定时隐藏产品入口。
首版使用默认组；取得 ADR 0005 所需的两个目录及关联 worktree 真实目录通道证据后才开放工作区
资格。提问意图继续恒用默认组。导航复用已有可信终端证据与协调器，应用切换成功不移除提醒。

依据固定上游版本的 [hooks 合同](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-pager/docs/user-guide/10-hooks.md)、
[payload schema](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-hooks/src/event.rs)
与 [runner 身份注入](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-hooks/src/runner/command.rs)。
本决定扩展 ADR 0024／0025，不增加配置、声音或提示的第二个 owner。
实际证据和未完成项见 [验证记录](../validation/grok-build-2026-10-21.md)。
