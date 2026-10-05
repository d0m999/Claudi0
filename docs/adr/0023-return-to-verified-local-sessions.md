---
status: accepted
---

# 返回已验证的本地会话

2026-10-04 用户确认“保留横幅外观，接通本地会话导航”：直接完成原生接入，不再等待 HTML 原型确认。保留现有布局、颜色、尺寸与动画，沿用唯一模型、协调器及已有宿主适配器。接受此决定不等于真实宿主、键盘或 VoiceOver 已验收；实际证据见 [导航验收记录](../validation/session-navigation-2026-10-04.md)。

本决定修订 ADR 0019 及 ADR 0008 中的“正文静态”和“App 打开即收起”历史呈现合同：普通与待接手正文均为独立原生按钮，与已有主操作共享 `SessionNavigationCoordinator.navigateSource`；普通横幅不增加主按钮，关闭独立，阅读轨只展示。正文具有稳定无障碍标识、操作提示与键盘焦点；正文、主按钮、关闭的焦点合并决定阅读暂停。面板与活动诊断通过同一个阅读视图消费完整导航结果，不持有第二份导航状态。

精确返回才收起横幅并移除捕获的待接手版本；深链接接受、来源 App 激活均保留提醒及横幅，就地反馈，继续剩余四秒阅读时间。失败与超时可重试但不重置预算；无法确认来源应用时在面板定位原记录。子 agent 只有源协议明确绑定父会话时才显示“返回父会话”。正常导航交接释放横幅焦点归还责任，不抢回焦点；关闭、第三方应用切换与记录失效取消所属请求，迟到回调不再派发或更新结果。

历史提案 `plan/session-navigation-native.patch` 已由正式源码实现替代，仅供追溯，不应再次应用；其中误传给阅读轨的交互参数未进入正式实现。

`HostEventNotice.navigationEvidence` 是可选、类型化、有限字段的原始来源事实。helper 只采集本机同用户进程身份、内核 TTY 与环境白名单，不执行 AppleScript、tmux 或窗口控制。schema 1、旧 wire、8KiB 限制及声音/回执退出语义不变；坏字段丢弃导航证据，发送超过上限时先剥除证据。原始字段不进入普通日志、回执、配置、活动、磁盘队列。

唯一 `EventNoticeModel` 从已确认来源应用和原始证据解析版本绑定的 `SessionNavigationTarget`，随后释放原始证据和祖先列表。GUI `EventNoticeRuntime` 拥有宿主适配器、IDE 连接和有限的 tmux 来源准备（至多四批，每批 32 条，共享 600ms 准备预算；普通事件在准备能力不足时照常接受）。锁屏、睡眠、禁用、退出取消准备、清空连接注册并更新 epoch。版本过期、新版本与 capabilityGeneration 均使旧动作失效。

统一入口只有一个在途请求；会话定位和已确认来源 App 回退共用原始三秒预算，不能重起计时。结果区分 `requestSent`、`applicationFallback`、`exactReturnConfirmed`、`failed`、`timedOut`、`cancelled`。每步复验版本、应用启动身份、截止时间和焦点归属；已发送的系统动作无法撤回，取消后不再派发下一步或应用迟到结果。首次 Apple Events 权限请求只做只读查询，迟到授权不能继续后续选择/激活。

宿主定位合同：

- Terminal 按精确 TTY 选 tab，绑定存活 shell 的内核启动身份，防止 TTY 复用；读回 front window 与 selected tab TTY，GUI 核对前台应用。
- iTerm2 使用 session ID + TTY 一致性核验，官方 `iterm2:reveal?sessionid=…`，读回窗口、session unique ID 与 TTY，GUI 核对前台应用。
- 本地 tmux 绑定 server 启动身份、私有 socket 与稳定 pane ID；只接受唯一 live client，再核对 client 祖先所属来源应用。内部选择、外层 Terminal/iTerm/IDE 导航及 pane/client 读回全部成功才确认。多个 client、detach 或不同应用实例降级，不按 cwd/title 猜。
- VS Code/Cursor 由用户主动安装配套 VSIX。GUI 私有 Unix stream socket 经内核 peer PID 确认同用户、本窗口扩展来源与 shell 祖先；每窗口独立注册、请求 UUID、实例 UUID、epoch、剩余期限、取消和确认。失连、terminal 退出、reload 使注册失效。只执行固定 focusWindow 与 terminal.show(false)，扩展确认焦点/activeTerminal，GUI 复验来源 App。未连接状态不能推断未安装；扩展状态栏区分未连接、已连接与版本不支持，安装检查与人工安装步骤见 README。
- Codex 桌面仅对已确认 `com.openai.codex` 实例及有效 thread UUID 打开固定 `codex://threads/<id>`，记录 requestSent；没有会话读回，不产生 exactReturnConfirmed。

不接受任意命令或任意 URL，不以标题/目录首个匹配生成目标。不覆盖 SSH、远程 IDE、容器、其他终端或 IDE 原生 AI 面板。

接口依据：[iTerm2 URL scheme](https://iterm2.com/documentation-url-scheme.html)、[VS Code Terminal API](https://code.visualstudio.com/api/references/vscode-api#Terminal)、[VS Code focusWindow](https://code.visualstudio.com/docs/configure/keybindings)、[tmux 官方手册](https://github.com/tmux/tmux/blob/master/tmux.1)、[Codex deep links](https://learn.chatgpt.com/docs/reference/commands)。公开接口用于独立实现，不代表本机真实宿主验收。
