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
- 官方 Zed 可经 [ADR 0019 的已验证系统 login](0019-open-verified-source-applications.md) 确认来源应用，
  普通既有 terminal 继续走 `applicationFallback`，复用“已打开来源应用，未定位到会话”反馈。
  提醒、横幅剩余阅读时间及原始三秒预算继续保留，不产生 `exactReturnConfirmed`。
  截至 2026-10-09，已核对的 [公开 CLI](https://zed.dev/docs/reference/cli) 与
  [扩展接口](https://zed.dev/docs/extensions/developing-extensions) 未提供本轮可用于 terminal 定位并读回
  确认的入口；这是当前 Claudio 的支持边界，不是对所有未来官方接口的断言。

导航消息和定位协议不接受任意命令或任意 URL，不以标题/目录首个匹配生成目标。不覆盖 SSH、远程 IDE、容器、其他终端或 IDE 原生 AI 面板。

接口依据：[iTerm2 URL scheme](https://iterm2.com/documentation-url-scheme.html)、[VS Code Terminal API](https://code.visualstudio.com/api/references/vscode-api#Terminal)、[VS Code focusWindow](https://code.visualstudio.com/docs/configure/keybindings)、[tmux 官方手册](https://github.com/tmux/tmux/blob/master/tmux.1)、[Codex deep links](https://learn.chatgpt.com/docs/reference/commands)。公开接口用于独立实现，不代表本机真实宿主验收。

Zed 的来源识别、两个同项目 terminal 的模型／协调器重放以及原生检查分别记录在
[2026-10-09 验证记录](../validation/zed-source-navigation-2026-10-09.md)。消息 schema、数据路径和横幅
外观保持现有合同。下述实验不把普通既有 terminal 升级为精确能力。

## 2026-10-09：受管理 PTY 会话的显式实验

用户在原语验证后授权“实现这个技术路径并测试”。Debug helper 增加
`claudio zed-session -- <command> [arguments]`，在新会话开始时拥有外层 PTY，创建内层 PTY 并直接
exec 参数，不经 shell 解释。stdin/stdout/stderr 必须属于同一控制终端，launcher 必须属于该终端的
前台 process group；混合流和后台启动在修改模式与启动前拒绝。小型 C supervisor 保持命令的 job
control；Swift loop 有界透传输入输出、终端协议、尺寸、信号和退出码。退出和暂停时恢复原始
terminal mode、focus-report mode 与共享文件描述符的可变标志；后台继续运行时保持暂停，直到
shell 将任务恢复到前台。它不接管已有 CLI 的 stdin。

只有 Debug GUI 显式启用 `CLAUDIO_ZED_NAVIGATION_PROTOTYPE=1` 才接受这条路由；普通 Release 保持
应用回退。GUI 沿用私有 Unix stream transport，在 `ClaudioPaths.root/zed-navigation.json` 发布 mode 600
的运行期 socket 发现信息。文件只有 schema、epoch、socket 路径和 inode，不保存会话、TTY、命令或
终端内容。注册、焦点报告和 snapshot barrier 在私有 socket 内存中传递；内核 peer UID/PID、双方启动
身份、child 父链、内外层 TTY 和已确认 Zed 实例一致才接受。child 标识内层 PTY 的 supervisor，
实际 CLI 位于其下。重连、退出和隐私清空使旧在途请求失效。
现有 hook wire、schema 1、数据路径和 source provenance 不变；模型仍只保留版本绑定的 typed target。

bridge 独占外层 DEC mode 1004，虚拟化 CLI 自己的 1004 请求与查询，其他字节透传。新 focus-in 必须
属于随机会话身份、内核启动身份和 TTY 一致的目标；旧报告、focus-out、非唯一目标、输入干预、PID
复用及过期 epoch 不可确认成功。snapshot barrier 排除已排队但尚未处理的 focus-out。

原生实验只适用于已复核的官方 Zed 1.23.2、标准配置目录、已核实的 bundled base map、ABC/US 键盘
布局以及**已具有** Accessibility/event posting 权限的 Claudio 进程。默认键位仅支持窗口与 tab 搜索。
Terminal context 的 `cmd-k` 实际绑定清屏，不能用它作为方向 chord 的前缀。分屏方向必须采用
[显式四键实验配置](../validation/zed-managed-navigation-keymap.json)，在 `Workspace` context 将四个专用功能键直接绑定
`workspace::ActivatePaneLeft/Right/Up/Down`，使方向离开 terminal dock 后仍可返回；只接受与该公开文件字节完全相同、属于当前用户的普通
`keymap.json`，不合并或自动安装配置。其他自定义目录/键位、未知版本、读取失败和权限缺失均在派发
前停止，不自动请求或授予权限。配置存在、Zed 已加载绑定、实际焦点返回分别验证。它按具体 AX window
对象选择已有窗口，以固定 tab-next 和 pane-direction 动作有界搜索，不使用标题、cwd、数据库或
command palette 文本猜测目标，不创建窗口、pane 或 terminal。先检查各窗口当前项；有四键且
没有任何受管理焦点时，用向下动作探测已有 terminal dock。屏障读回的唯一当前焦点（包括持续焦点）
仅用于窗口排序，不替代目标自身的新回执。深扫先搜索已知 terminal 的 tab 和相邻 pane，最后才
搜索无回执的 tab，避免 editor/sidebar 耗尽预算。四键不可用时跳过方向动作，保留默认窗口/tab
搜索。目标确认仍必须有请求内的新 sequence、最终屏障与窗口/身份复验。搜索上限为四个窗口、每 pane 至多
16 个 tab 和有限的方向扫掠，全部步骤共享协调器原始三秒预算；AX 单次 IPC 至多 250 ms 且不能超出
剩余期限，`cannotComplete` 只允许进入具体窗口读回，不当作已选择成功或重复派发。复杂、不可达或 zoom 隐藏布局允许
保留失败/超时，不宣称任意布局均能定位。

只有目标新回执、最终仍聚焦、实际前台 Zed、具体 AX focused window 及内核身份复验共同成立才产生
`exactReturnConfirmed`。失败可以在原预算内应用回退；取消后不再执行下一步，迟到回执不更新结果。
已选择的中间 tab/pane 不在取消或截止时间之后自动回滚。横幅外观和提醒/阅读语义沿用现有协调器。

本实验的编译接缝、真实 PTY 透传和原生点击证据分别记录在
[受管理导航验证记录](../validation/zed-managed-navigation-2026-10-09.md)，不得互相替代。
