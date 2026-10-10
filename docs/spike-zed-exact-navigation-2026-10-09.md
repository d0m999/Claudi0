# 官方 Zed 精确来源导航调查（2026-10-09）

本轮调查官方 Zed 与商业 Vibe Island，并在自建窗口中测试焦点原语。不修改 Zed、不写入 Zed 配置、不向既有 CLI 输入文字或命令、不增加权限。结论按「外部请求入口」「稳定来源身份」「实际定位读回」分别判断；源码里的内部方法不自动等于 Claudio 可调用接口。

## 结论

在本机版本对应的官方 `v1.23.2` 和本轮固定的 `main` 中，未找到可以从 Claudio 请求指定现存 terminal/tab/pane/window、并返回实际焦点身份的 CLI、URL、Extension 或 MCP 接口。这是本轮检查范围内的否定结果，不声称所有未来版本都不可能支持。

追加原生测试后，边界更明确：商业 Vibe Island 1.0.51 的本次点击实际使用 project route，同项目另一 pane 的两次对照未返回来源 pane；自建 PTY 的 tab、pane 和窗口选择则取得 5 次不同身份的新焦点回执。后者验证了一条可继续开发的组合路线，尚未完成自动目标搜索、真实 CLI 透传桥接与最终前台联合确认；Claudio 生产行为继续是应用回退。

有两条值得继续验证的官方原语：

1. **Terminal Threads 的 BEL 通知**：Zed 内部已经持有准确的 terminal、workspace 和窗口身份，点击它自己的通知可定位。这条路径只适用于 Agent Panel 内的 Terminal Threads，不覆盖普通 Terminal Panel / Center Terminal，也没有发现允许 Claudio 直接调用该通知回调的外部接口。[官方说明](https://zed.dev/docs/ai/terminal-threads#notifications)，[v1.23.2 内部回调](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/agent_ui/src/agent_panel.rs#L2719-L2747)
2. **终端 focus reports**：启用终端的 focus-report mode 后，Zed 会向该 PTY 写入 `ESC[I` / `ESC[O`。它可成为事先由 Claudio 管理的 PTY bridge 的定位读回，但它不是「请求定位」接口，也不能通过另开 reader 抢读已有 shell/TUI 的输入来实现。[v1.23.2 Terminal](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/terminal/src/terminal.rs#L2535-L2544)，[view focus 转发](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/terminal_view/src/terminal_view.rs#L1388-L1418)

上述两条是可研究路线；本文件没有把它们记为 Claudio 精确跳转已经实现或验收通过。

## 版本与取证

| 来源 | 固定身份 | 核对方式 |
| --- | --- | --- |
| 官方发布 `v1.23.2` | `c0199504b9cce79bc27524950022ed701bc3ebd5`，2026-10-07，版本 bump | `git ls-remote`、只读浅克隆、`git show` |
| 本轮官方 `main` | `679ad7c30427303f765870c640a04b5ae243da2d`，2026-10-09 | `git ls-remote`、fetch、固定 SHA 文件比较 |
| 终端后端 | 官方 `zed-industries/alacritty`，`4c129667ce56611becdc82de6e28218c80e2e88f` | Zed `Cargo.toml` 依赖锁定，追到被调用的 `tty::new` |

发布源码：[v1.23.2 commit](https://github.com/zed-industries/zed/commit/c0199504b9cce79bc27524950022ed701bc3ebd5)；main 快照：[commit](https://github.com/zed-industries/zed/commit/679ad7c30427303f765870c640a04b5ae243da2d)；[后端依赖](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/Cargo.toml#L529)。官方文档是访问时版本，源码则固定到 commit，不用文档的新功能反推本机旧版本。

## CLI 和 IPC

公开 CLI 主要打开路径、stdin、diff 和 URL，支持 `--add`、`--new`、`--existing` 等打开方式。`--existing` 没有 terminal/tab/pane/window 的来源身份参数。[CLI 文档](https://zed.dev/docs/reference/cli)，[v1.23.2 Args 完整定义](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/cli/src/main.rs#L67-L156)

底层 `CliRequest` 只有 `Open` 和 `SetOpenBehavior`；`Open` 携带 paths、urls、diff、cwd、env 等。`CliResponse` 只有 Ping、stdout/stderr、Exit 和打开方式询问；没有 terminal 枚举、按 PID/TTY/TerminalId 定位或焦点身份读回。[request / response 定义](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/cli/src/cli.rs#L55-L84)

CLI 的 IPC 握手没有隐藏的第二份可用导航协议：`connect_to_cli` 建立的就是上述 typed channels。直接绕过 CLI 打 socket 不能产生 enum 中不存在的请求。[握手](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/zed/src/zed/open_listener.rs#L434-L457)

本轮比较 tag 与 main 的 `crates/cli/src/cli.rs`、`crates/cli/src/main.rs` 无差异。该结论限于上述两个固定 SHA。

## URL 和深链

`OpenRequestKind` 包含 FocusApp、Extension、AgentPanel、InstallSkill、DockMenuAction、schema、settings 和 git 等，没有 terminal 身份。URL parser 接受 `zed-cli://` 握手、`zed-dock-action://<index>`、文件、SSH、extension、skill、agent、settings、git 和 channel 等。[类型](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/zed/src/zed/open_listener.rs#L37-L83)，[解析分支](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/zed/src/zed/open_listener.rs#L157-L211)

`zed://` / `zed://open` 只产生 `FocusApp`。`zed://agent` 接受的查询值是 `prompt`，没有 session/terminal ID；它会打开 Agent Panel，不能据此宣称返回触发事件的 thread。[Agent URL](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/zed/src/zed/open_listener.rs#L223-L234)

Dock action 使用菜单 index，既不是 shell/TTY 绑定，也没有 terminal 焦点读回。按 cwd 打开项目可能命中某窗口，但同项目多个窗口或 terminal 无法唯一证明，因此不满足本任务的精确合同。

本轮比较 tag 与 main 的 `crates/zed/src/zed/open_listener.rs` 无差异。

## Extension API 和 MCP

官方 Extension 文档描述 language、debugger、theme、icon、snippet、MCP server 等能力。Rust `Extension` trait 和 WASM WIT 提供 language server / slash command / context server / debugger 等回调；检查的 WIT 中没有 terminal、pane、window 枚举或 focus 方法。[官方开发文档](https://zed.dev/docs/extensions/developing-extensions)，[Rust trait](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/extension_api/src/extension_api.rs#L69-L260)，[WIT host imports 和资源](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/extension_api/wit/since_v0.8.0/extension.wit#L3-L94)

MCP 在 Zed 的这条集成路径中是 Zed 作为 client 使用 context servers，或转发给 External Agents；Terminal Threads 的原生 CLI 读取自己的 MCP 配置。它不是给 Claudio 连接的 Zed 窗口控制服务。[MCP 官方说明](https://zed.dev/docs/ai/mcp#agent-path-support)，[MCP client](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/context_server/src/client.rs#L23-L62)，[通知类型](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/context_server/src/types.rs#L96-L126)

本轮比较 tag 与 main 的 Extension Rust API 和整个 `crates/extension_api/wit` 无差异。未部署 extension 或 MCP server。

## BEL：普通 terminal 与 Terminal Threads 必须分开

### 普通 Terminal Panel / Center Terminal

终端后端收到 BEL 时向上发 `Event::Bell`；普通 `TerminalView` 只设置 `has_bell`，根据 `terminal.bell` 播放系统 bell，发 Wakeup。此处没有捕获该 terminal 的可点击定位窗口。[Terminal 事件](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/terminal/src/terminal.rs#L1690-L1696)，[普通 view BEL 分支](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/terminal_view/src/terminal_view.rs#L1225-L1231)

因此让普通 shell 输出 BEL 不能作为 Claudio 点击后精确聚焦它的解决方案。

### Agent Panel Terminal Threads

创建 thread 时，AgentPanel 订阅底层 terminal 的 Bell，并以内部 `TerminalId` 标记通知。`TerminalId` 是随机 UUID，由 Zed 创建，并非 hook 里的 shell PID/TTY。[身份](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/agent_ui/src/agent_panel.rs#L153-L174)，[订阅](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/agent_ui/src/agent_panel.rs#L2197-L2221)

通知受 thread 是否可见、是否已有通知、`agent.notify_when_agent_waiting` 等条件控制，不能假设每次 BEL 都会创建新 popup。popup 是 Zed 的 GPUI window；不是带稳定 URI 的 macOS 通知 payload。[条件](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/agent_ui/src/agent_panel.rs#L2625-L2688)，[popup window 类型](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/agent_ui/src/ui/agent_notification.rs#L37-L71)

点击 Zed popup 的 View 按钮发内部 Accepted event；回调激活 application、原窗口、workspace、AgentPanel，再按捕获的 TerminalId 聚焦并清除通知。这已经解决 **Zed 自己的 Terminal Thread 通知** 的精确定位。Claudio 尚无对应的外部 Accepted 请求或焦点身份读回。[按钮](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/agent_ui/src/ui/agent_notification.rs#L183-L200)，[定位回调](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/agent_ui/src/agent_panel.rs#L2719-L2753)

main 的 AgentPanel 文件有其他改动；该定位流程仍在固定 main 的 [2735–2768 行](https://github.com/zed-industries/zed/blob/679ad7c30427303f765870c640a04b5ae243da2d/crates/agent_ui/src/agent_panel.rs#L2735-L2768)。普通 TerminalView / Terminal 文件在本轮比较中无差异。

## Task 复用不是 focus-only API

`task::Spawn` 的 ByName 路径按 task label 等值过滤，并 schedule 所有匹配项；没有按现存 TerminalId 精确选择一个会话。[ByName](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/tasks_ui/src/tasks_ui.rs#L196-L206)，[匹配及调度](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/tasks_ui/src/tasks_ui.rs#L268-L335)

TerminalPanel 内部按 `full_label` 匹配 terminal，再进入 spawn / replace 的行为。`allow_concurrent_runs=false` 控制序列化，不提供「同一任务仍在运行则仅聚焦且保证不重新运行」合同。`replace_terminal` 会创建新 terminal task 后调用 `set_terminal`。因此不能用再次运行 marker task 来安全定位已有交互式 CLI。[选择](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/terminal_view/src/terminal_panel.rs#L662-L711)，[按 label 找 terminal](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/terminal_view/src/terminal_panel.rs#L780-L819)，[重新创建](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/terminal_view/src/terminal_panel.rs#L1096-L1119)

## `WINDOWID` 不能定位 macOS 窗口

Zed 官方后端确实把传入的数值写入 `ALACRITTY_WINDOW_ID` 和 `WINDOWID`；但生产 `Project` 创建 task / shell terminal 时传入的是 `cx.entity_id().as_u64()`，即 Project 的 GPUI entity 身份，不能据变量名假设它是 macOS native window number。同一 Project 的多个 terminal 会共享该传值。[后端写环境](https://github.com/zed-industries/alacritty/blob/4c129667ce56611becdc82de6e28218c80e2e88f/alacritty_terminal/src/tty/unix.rs#L270-L278)，[生产 task](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/project/src/terminals.rs#L241-L256)，[生产 shell](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/project/src/terminals.rs#L445-L460)

此外 GPUI 自己的 `WindowId` 也由 slotmap key 表示，不是 CGWindowID。[定义](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/gpui/src/window.rs#L7165-L7180)。调查时发现 Terminal 的测试使用了 WindowId；沿生产调用重新核对后排除此推断。不能用测试的传值替代生产代码的来源映射。

## 补充：tmux 3.7c 与焦点读回的接合

这一节是 PTY bridge 候选路线的官方上游补查，来源是 `tmux/tmux`，不构成 Zed 自己公开了导航 API。本机 tmux 为 `3.7c`，官方 tag 对应 commit `e476c1230b958df0cb12977517d24b3dc931375b`。

tmux 的 `focus-events` 是 server 选项，默认 off；开启后请求外层 terminal 的焦点报告。官方手册要求改变选项后 detach / attach 已连接 clients。因此不应为本轮探针改变用户已有 tmux server；新建 Claudio 专用隔离 server 可以在初始 attach 前启用。[默认](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/options-table.c#L407-L411)，[手册](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/tmux.1#L4457-L4464)，[请求焦点 mode](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/tty.c#L530-L542)

收到 focus in/out 时，tmux 更新 `CLIENT_FOCUSED`，发 `client-focus-in` / `client-focus-out` hook，并更新内部 pane 焦点。`client_flags` 读回包含 `focused`，`client_pid` 和 `client_tty` 可以帮助绑定实际外层 terminal。[解析及 hook](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/tty-keys.c#L1006-L1014)，[flags](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/server-client.c#L2683-L2695)，[formats](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L1499-L1505)，[PID](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L1546-L1552)，[TTY](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/format.c#L1621-L1627)

但 tmux client 创建时默认设置 `CLIENT_FOCUSED`，所以单次读取 `focused` 可能只是初始值或陈旧状态。要作为精确定位证据，必须绑定实际存活的 client PID/start identity/TTY，并取得本次导航后的 fresh focus-in 回执；仍需验证 Zed 的实际 view focus 和应用/窗口前台共同成立。[初始化](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/server-client.c#L305-L315)

## 补充：窗口身份与遍历动作

这是 PTY bridge 候选路线的 Apple 公共 API / 官方 Zed 源码补查，不是新增产品权限流程。

Apple 的 `CGWindowListCopyWindowInfo` 可枚举当前用户会话的窗口字典，其中 required keys 包含 native `kCGWindowNumber`、owner PID 和 bounds。它只能证明属于已验证 Zed 进程的哪些 native windows 存在；不能单独证明某 shell/TTY 属于其中哪一个，也不能凭同 bounds / 标题消除多个窗口的歧义。[窗口枚举](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:))，[required keys](https://developer.apple.com/documentation/coregraphics/required-window-list-keys)，[native window ID](https://developer.apple.com/documentation/coregraphics/kcgwindownumber)

Apple 公共 Accessibility API 可取得应用的 `AXWindows` 和 `AXFocusedWindow` 对象，再向具体对象执行 `AXRaise`。AXRaise 是窗口层面的操作，仍不保证目标 terminal 聚焦；调用前应检查该调用进程是否已有 Accessibility trust，工具自身的授权不能视为 Claudio 已有授权。本轮未请求权限或尝试这些跨进程操作。[窗口对象](https://developer.apple.com/documentation/applicationservices/kaxwindowsattribute)，[聚焦窗口对象](https://developer.apple.com/documentation/applicationservices/kaxfocusedwindowattribute)，[raise](https://developer.apple.com/documentation/applicationservices/kaxraiseaction)，[perform action 的错误边界](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction)

可验证的候选绑定方式是：Claudio 管理的 bridge 收到 fresh focus-in 时，关联已验证的 Zed PID/start identity 与当时的 focused AX window handle；后续使用前再次核对该对象仍属于原进程的 window 集合，并在导航后取得 terminal 侧 fresh focus-in。这里不需要把 AX 对象强行转换为 CGWindowID。当前没有核实到公共 AX→CGWindowID API；不得采用私有 `_AXUIElementGetWindow` 或假定 `AXWindowNumber` 属性必然存在。

Zed 原生 `PlatformWindow::activate` 内部调用 `makeKeyAndOrderFront`，但外部没有持有该 NSWindow 对象的通道。[native 激活](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/gpui_macos/src/window.rs#L1788-L1801)

普通 pane 内的 `pane::ActivateNextItem` 默认循环现有 items；macOS 默认 keymap 使用 `alt-cmd-right` / `cmd-}`。`workspace::ActivateNextPane` 在当前 pane group 循环。这些动作不提供外部 count/ID，也受用户 keymap 和当前 focus context 影响，必须用目标 PTY 回执终止搜索，不能将动作派发成功视为精确成功。[item 定义](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/workspace/src/pane.rs#L265-L273)，[item 循环](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/workspace/src/pane.rs#L1546-L1558)，[默认键](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/assets/keymaps/default-macos.json#L538-L545)，[terminal pane 循环](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/terminal_view/src/terminal_panel.rs#L1555-L1575)

**不能用盲扫 index 替代循环**：`workspace::ActivatePane(index)` 在 index 超出现有 pane 数时会 split/clone；TerminalPanel 版本还会创建/克隆 terminal pane。试探未知上界会修改用户布局。[workspace 越界分支](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/workspace/src/workspace.rs#L5582-L5594)，[terminal 越界分支](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/terminal_view/src/terminal_panel.rs#L1579-L1599)

MultiWorkspace 有 NextProject / NextThread 动作，但前者遍历 sidebar project headers，目标未打开时会 `open_workspace_for_group`；它不是只循环当前 native window 中存活 workspace 的无副作用枚举。NextThread 把普通 agent threads 和 Terminal Threads 放在同一 sidebar 序列，不包含普通 TerminalPanel 的 tab。[动作](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/workspace/src/multi_workspace.rs#L35-L60)，[NextProject](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/sidebar/src/sidebar.rs#L7175-L7218)，[NextThread 集合](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/sidebar/src/sidebar.rs#L7234-L7275)

## 可继续实施的路线及门槛

| 路线 | 已确认原语 | 仍须解决 | 当前判断 |
| --- | --- | --- | --- |
| 用户直接使用 Zed Terminal Thread 的内建通知 | BEL → 内部准确 TerminalId → 点击精确定位 | 不能覆盖普通 terminal；不是 Claudio 横幅路由 | 官方已有能力，改变使用入口后才适用 |
| Claudio 管理的 PTY bridge + UI 导航 + focus-report 回执 | Zed 支持对目标 PTY 报告 focus in/out | 如何安全选择现存 window/pane/tab；可靠焦点时序；原 CLI 输入输出及 terminal mode 不受损；已有会话不能无缝接管 | 有希望，需要隔离原型和原生 readback，尚未实现 |
| 上游增加按 terminal/process token 导航与读回 | 内部激活 terminal 的方法已存在 | 官方新增公开协议、身份绑定、防 PID/TTY 复用、窗口关闭与权限合同 | 可提上游设计，不可假装当前官方版已支持 |
| cwd、标题、菜单 index、最近窗口或应用前台 | 可打开项目或激活应用 | 同名/同项目/并发无唯一映射 | 不足以返回 exactReturnConfirmed |
| 重放 task / 打私有 CLI socket / MCP extension | 内部 task、IPC、MCP 代码可读 | 没有对应无副作用的外部精确请求和 readback | 本轮排除 |

继续实施必须保持同一来源状态 owner：只在绑定到实际存活 shell/PTY 且读回确认该 terminal 的原生 focus 后才能报告精确成功。应用激活、截图中看见同项目、匹配标题或 source-wiring 检查都不足以替代此证据。

## 本轮证据限制

完成了固定版本官方源码与官方文档调查，以及版本差异核对。随后在本轮新建的独立 Zed 测试窗口中运行两个仅供测试的 PTY focus-report 探针：通过 Window 菜单激活该窗口、再切换现有 terminal item，分别取得 A、B 的 focus-in；打开 command palette 时取得 focus-out。这验证焦点读回原语，尚未实现按来源身份寻找目标 terminal 的导航器。探针到期后恢复 terminal mode，未读取或向用户已有 CLI 会话发送输入。原始记录位于忽略的 `dist/zed-navigation-evidence/focus-return-prototype/focus-A.jsonl` 和 `focus-B.jsonl`。

没有编译 Zed、安装 extension、改配置、触发既有 terminal BEL、改标题、尝试接管既有 TTY或运行真实 agent callback。本文件的可行性判断及隔离探针不等于生产精确导航或完整原生验收。

## 补充：商业 Vibe Island 的 Zed 跳转公开证据

用户追问 Vibe Island 如何实现 Zed 跳转后，转查 Edward Luo 的商业产品：`vibeisland.app`、`vibeislandapp/vibe-island` 和 `edwluo/vibe-island-updates`。不采用 `VoidChecksum/vibe-island`、其 forks、Open Island 或其他同名 clone 的代码作为该产品实现证据。

### 可核查的事实

| 证据 | 能说明的支持粒度 | 不能推导的事实 |
| --- | --- | --- |
| 官网 precise-jump 页面明确把 Zed 列入按终端适配的精确 tab/pane 支持 | 产品作者宣称 Zed 有该能力 | 没有披露 Zed 算法、terminal 身份、readback 或版本边界，不能代替实际验证 |
| `v1.0.50` release 修复 Zed 项目子目录启动 session 跳转 | 返回既有 project workspace，而不是把子目录新开为 workspace | 不证明同 workspace 内多个 terminal/split/tab 能唯一定位 |
| `v1.0.48` changelog 说 terminal jump 校验实际收到 focus 的窗口 | 作者宣称增加窗口 focus 校验 | 没有指定 Zed，也没说明同窗口的 terminal 焦点校验 |
| 社区 README 及 repository tree | 产品支持、issues 和 discussions 仓库 | 不是公开的 Swift 导航实现 |

来源：[官网精确跳转说明](https://vibeisland.app/precise-jump/)，[v1.0.50 release](https://github.com/edwluo/vibe-island-updates/releases/tag/v1.0.50)，[版本 changelog](https://vibeisland.app/changelog/)，[固定 community README](https://github.com/vibeislandapp/vibe-island/blob/fc691d07af1c5bc532b0aab847e18b5dc0c6bfe6/README.md#L43-L51)。该 community main 的固定 SHA 为 `fc691d07af1c5bc532b0aab847e18b5dc0c6bfe6`；`v1.0.50` tag 为 `5272dcc9db9704f881f2a7afc2e3e84305fb98d1`。

### 公开协议不等于 Zed 内建适配实现

Vibe Island 的 Custom Jump Rules 文档公开了一条自定义 URL 协议：先激活目标 app，再把固定的 `session_id`、`cwd`、`tty`、`pid`、`bundle_id`、`tmux_pane` hints 放进 URL，目标 app 自己解析为其内部 tab/pane/window。没有在文档中找到 Zed 特殊 URI 或 Zed 的 custom rule。[官方 Custom Jump Rules](https://vibeisland.app/docs/custom-jump-rules/)

文档要求多 pane 不能只靠 cwd，匹配失败不得新开 pane 或猜相似目标。这是其对第三方目标 app 的公开合同，不能证明官方 Zed 已经有相应 handler，也不能把 VS Code-family 的 dedicated extension 架构直接套到 Zed。[公开 hints / 解析边界](https://vibeisland.app/docs/custom-jump-rules/#pane-aware-terminals)，[VS Code-family extension 说明](https://vibeisland.app/precise-jump/#ide-terminals-via-dedicated-extension)

官网主页 FAQ 的读取结果包含两套并列文案：一套区分精确跳转与其他 terminal 的 app activation / best-effort tab matching，另一套描述点击只将 app 放到前台。精确跳转专项页则明确宣称 Zed 精确 tab/pane。公开页面存在这种粒度不一致时，应以具体版本实现、跳转诊断及真实多 terminal 测试厘清，不按广义营销句子关闭 Claudio 的精确导航验收。[官网 FAQ](https://vibeisland.app/#faq)

### 当前推断与下一步

**公开证据支持的最小结论**：Vibe Island 的版本说明确认 Zed 的 project workspace 定位/复用行为；专项页宣称按终端适配精确 tab/pane。仅据公开资料无法确定它是否对普通 Zed terminal 完成唯一 tab/pane 定位。当前不能回答其具体 Zed 算法已经核实；应继续从已安装官方包中的公开可读脚本/符号取得静态路径，或在两个同项目 terminal 中观察该官方产品的实际结果。前者不等于后者。

本节仅完成公开网页与 community repository 调查，未启动 Vibe Island、修改其配置、调用其服务、修改 Zed 或验证其原生 Zed 跳转。

### 本机官方安装包的静态实现证据

2026-10-09 只读复核 `/Applications/Vibe Island.app/Contents/MacOS/vibe-island`，Info.plist 版本仍为 `1.0.51`，SHA-256 为 `6e791136c591bde9a2c15b39c6efea73ca5450e8aa6f86060abd53a5ad1441f0`，与仓库此前的 [安装包记录](vibe-island-additional-host-integrations-2026-10-04.md) 相同。未执行应用、hook、桥接程序或私有服务。

| 静态事实 | 工程含义及限制 |
| --- | --- |
| Swift `__swift5_fieldmd` 及 context descriptor 中包含 `VibeIsland.ZedResolver` | 确有 Zed 专用 resolver；符号存在不能还原完整调用流程 |
| `VibeIsland.ZedWorkspaceSnapshot` 字段为 `workspaces`；其嵌套 `Workspace` 字段为 `roots`、`terminalDirectories` | 该快照模型按工作区根目录、terminal 工作目录组织；这些字段没有唯一 terminal/pane/window 身份。不能据此断言整个程序完全没有其他身份来源 |
| 二进制字符串含 `Library/Application Support/Zed/db/0-stable/db.sqlite` | 指向官方 Zed 的本地数据库；读取实际运行目录尚需识别 channel / 自定义 user-data-dir |
| 实际 SQL 查询 `kv_store`；按 `session_id` 查询本地 `workspaces` 的 `workspace_id` / `paths`；联表查询 `terminals` 的 `workspace_id` / `working_directory_path` | 明确存在获取工作区和 terminal 目录的查询；该 terminal 查询没有投影 terminal ID、TTY、shell PID 或 pane ID。没有执行其查询，不能由静态 SQL 确认它实际读取的当前 session key |
| 类型/枚举标识含 `zedProject`、`zedOpenProject`，日志含 `zed: project-route` | 与 v1.0.50 的已有项目工作区路由修复相吻合；具体执行参数及失败分支未由字符串证明 |

取证方法为 `strings -a` 和只读 Mach-O / Swift reflection 元数据解析：按 Mach-O section 的虚拟地址到文件偏移映射读取 field descriptor，解析 relative context / parent / field name。没有将附近字符串顺序当作函数调用关系，也没有获得商业版对应源码。

**实现判断（推断）**：当前核实到的商业版 Zed 专用路径，以来源 cwd、Zed 工作区根目录及 terminal 工作目录解析项目工作区，再执行 project route。它提供了值得验证的窗口／工作区级路线；不能由当前证据声称已解决同工作区多 terminal、分屏或 tab 的唯一返回。官网精确 tab/pane 宣称仍需原生多目标对照验证。

Claudio 当前 ADR 0023 不允许按目录首个匹配生成精确目标。即使采用上述工作区路由，也必须保留多候选拒绝、PID/start identity 复验、原始三秒预算及非精确反馈；数据库匹配或 CLI 请求接受不能直接产生 `exactReturnConfirmed`。既有来源识别修复已实现，本节未新增生产导航代码。

### 官方 Zed 数据库与 project CLI 的具体边界

以下是针对上述商业包候选路径的官方 Zed `v1.23.2` 源码复核。它说明 Claudio 若采用只读数据库加公开 CLI 路由必须面对的限制；**没有证实 Vibe Island 实际使用哪些 CLI 参数或如何处理这些分支**。

`kv_store` 的 `session_id` 来源已核实：Zed main 每次启动创建 UUID，`Session::new` 读取旧值，再把新值写到该 key。这是 Zed 应用实例的持久化 session 标记，不是 CLI 的 agent session ID，也不包含 PID、启动身份或 terminal 身份。创建与写入任务在 single-instance 检查之前启动；不能仅凭这个 key 把数据库绑定到事件祖先中的特定存活 Zed 进程。是否存在失败启动实际覆盖 key 的竞态，本轮没有运行验证。[main 初始化与 single-instance 顺序](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/zed/src/main.rs#L346-L383)，[Session 读写](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/session/src/session.rs#L11-L31)，[kv_store schema 与查询](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/db/src/kvp.rs#L20-L28)

数据库文件按 `data_dir()/db/0-<release channel>/db.sqlite` 组织；硬编码 stable 路径不覆盖其他 channel / 自定义数据目录。`workspaces` 的 session 查询能得到 `workspace_id`、根目录和 `window_id`；移除 workspace 时在内存中先清 session，再异步清数据库绑定，工作区行保留供 recent projects 使用。数据库读取是持久化快照，不能消除读取后关闭、移动或切换 workspace 的竞态。[数据库路径](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/db/src/db.rs#L138-L167)，[data_dir 下的 db](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/paths/src/paths.rs#L257-L260)，[session workspaces 查询](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/workspace/src/persistence.rs#L1896-L1929)，[移除清理](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/workspace/src/multi_workspace.rs#L1403-L1430)

`workspaces.paths` 是换行分隔的路径列表，`paths_order` 是逗号分隔的展示顺序；不能直接当 JSON 解码或只取第一条路径。`terminals` 表保存 `workspace_id` / `item_id` / cwd / custom title，没有 PID 或 TTY。cwd 保存发生在后台序列化，task terminal 不进入这条序列化路径；关闭 item 的清理也是序列化过程的一部分。因此 terminal 目录有助于项目归属匹配，不是实时会话身份或焦点回执。[路径序列化](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/util/src/path_list.rs#L106-L139)，[terminal schema](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/terminal_view/src/persistence.rs#L412-L453)，[terminal 保存与清理](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/terminal_view/src/terminal_view.rs#L1957-L2002)

公开 CLI project 路由具有真实复用能力，也具有创建分支：默认 / `--existing` 使用 `MatchExact`，在当前窗口集合中的 workspaces 按路径可见性选匹配，成功后激活窗口及该 workspace；这里没有激活来源 terminal 的代码。`--existing` 还允许未匹配目录作为新 workspace 加入既有窗口；没有匹配时最终调用 `Workspace::new_local`。因此“先只读查询存在的 workspace，再 `zed <roots>`”无法保证不新建：查询到请求之间工作区可以关闭，CLI 本身没有公开 only-existing-workspace、workspace ID 或 native window ID 参数。多个同根目录候选也没有以 shell/TTY 区分的匹配规则。[CLI behavior 映射](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/zed/src/zed/open_listener.rs#L790-L824)，[匹配选择](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/workspace/src/workspace.rs#L10858-L10943)，[未匹配时的窗口复用与新 workspace](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/workspace/src/workspace.rs#L11183-L11229)，[匹配激活和 new_local 分支](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/workspace/src/workspace.rs#L11234-L11299)

数据库里的窗口身份同样不能作原生读回：Zed 写入的 `window_id` 来自 GPUI `window.window_handle().window_id().as_u64()`，这是 slotmap key，不是 macOS `CGWindowID`。`session_window_stack` 也写同一 GPUI ID，通常每 500 ms 后台保存，不能证明此刻 frontmost，也没有公开外部映射到 AX window 对象。CLI 只返回打开操作的 Exit status，不返回所选 workspace/window/terminal ID；status 0 不构成窗口或 terminal 精确确认。[window_id 写入](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/workspace/src/multi_workspace.rs#L1710-L1722)，[GPUI WindowId 类型](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/gpui/src/window.rs#L7165-L7180)，[stack 后台保存](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/session/src/session.rs#L73-L92)，[stack ID 来源](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/session/src/session.rs#L135-L148)，[CLI 返回](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/crates/zed/src/zed/open_listener.rs#L655-L671)

本轮固定 main `679ad7c30427303f765870c640a04b5ae243da2d` 在 workspace 查找中补充了每个 workspace 的 location 检查；这改善多 workspace 混合本地/远程匹配，但没有加入公开 terminal 导航或上述创建竞态的保证。[main 的 location 检查](https://github.com/zed-industries/zed/blob/679ad7c30427303f765870c640a04b5ae243da2d/crates/workspace/src/workspace.rs#L10884-L10900)

**候选路线结论**：只读官方数据库可改善 cwd 子目录对应哪一个 project workspace 的判断，符合商业版 `v1.0.50` 的修复粒度；公开 CLI 可尝试激活匹配项目。它仍不足以安全承诺“只激活已有目标、不新建”或“精确返回同项目中的来源 terminal”。如要求禁止新建且支持普通既有 terminal，仍需额外的已绑定原生窗口身份、可逆且无创建副作用的 terminal 选择原语，以及目标 PTY 的 fresh focus-in 读回。这一节只有源码证据，没有新增生产路由、没有运行 Vibe Island、没有验证真实数据库/CLI 跳转或关闭竞态。

## 继续验证：商业版同项目 terminal 的区分与诊断

用户授权继续研究和测试后，2026-10-09 重新查询两个商业官方 repository 的公开 issues、community discussions 和 release notes。GitHub issue search 在 `vibeislandapp/vibe-island` 与 `edwluo/vibe-island-updates` 内搜索独立词 `Zed` 均返回 0；读取 community 的 7 个 discussions 及本次 API 返回的 comments 未找到 Zed 多目标反馈。读取 updates 的 94 条 releases 后，独立词 `Zed` 仅出现于 `v1.0.40` 的一般准确率改善，以及 `v1.0.50` / `v1.0.51` 的子目录返回既有 project workspace 修复。**这只是本次可检索公开内容没有找到，不证明用户从未报告，也不能用其他 terminal 的 issue 推导 Zed 能力。**[community issues](https://github.com/vibeislandapp/vibe-island/issues)，[community discussions](https://github.com/vibeislandapp/vibe-island/discussions)，[v1.0.40](https://github.com/edwluo/vibe-island-updates/releases/tag/v1.0.40)，[v1.0.51](https://github.com/edwluo/vibe-island-updates/releases/tag/v1.0.51)

### 精化关联类型的只读静态证据

本机商业版仍为 `1.0.51`，本轮独立重新计算 SHA-256 与前节相同。读取 Mach-O `__swift5_fieldmd` 后，明确得到以下关联 payload，而不只是相邻字符串：

| 类型及 descriptor 虚拟地址 | Zed case | payload 的 Swift mangling / demangle |
| --- | --- | --- |
| `VibeIsland.LegacyRoute`，`0x1014f8efc` | `zedProject` | `SS4path_t` → `(path: Swift.String)` |
| `VibeIsland.JumpStep`，`0x1014f93ac` | `zedOpenProject` | `SS4path_t` → `(path: Swift.String)` |

`xcrun swift-demangle` 对 `SS4path_t` 的输出确认路径是该 case 唯一的关联值。这两条 Zed route/step 本身没有 terminal ID、TTY、PID、pane、tab 或 window payload。结合前节 `ZedWorkspaceSnapshot` 只有 roots / terminalDirectories，可提出更具体的判断：**同一 project、相同 cwd 的两条普通 terminal，无法由这条路径 payload 本身区分**。这不是整个商业程序不存在任何其他全局状态的证明，也没有还原其完整函数实现。

### 不导出私人会话报告的诊断方式

商业官方 README 公布的诊断入口为 Settings → About → Export Diagnostic Report。公开 issue 中也提供了本地应用日志路径和 jump 行：`~/Library/Logs/VibeIsland/vibe-island.log`；另一位用户给出 Unified Logging 的 `log stream --predicate 'process == "vibe-island"' --level debug`。这些 issue 分别针对 daemon-hosted Ghostty 与 Warp，属于用户取证方法，不是 Zed 的官方调试协议。本轮没有找到公开的 Zed dry-run、按 terminal ID 执行跳转或直接列出 Zed pane 的诊断入口。[官方 README 诊断入口](https://github.com/vibeislandapp/vibe-island/blob/fc691d07af1c5bc532b0aab847e18b5dc0c6bfe6/README.md#L53-L57)，[日志路径与 jump 行实例](https://github.com/vibeislandapp/vibe-island/issues/166)，[日志流方法](https://github.com/vibeislandapp/vibe-island/issues/127)

本轮主执行 agent 在用户授权后启动既有官方 Vibe Island，进行来源卡片的原生测试。本调查只读上述日志末尾 100 KB，按 JSONL `c == "jump"` 筛选，并脱敏 session token 与本地路径；没有导出诊断包、读取 event 内容或调用私有传输。2026-10-09 `08:57:33Z` 的本次点击日志明确记录：

```text
jump-shadow: ... bundle=dev.zed.Zed ... legacy=zedProject(path: "<local-path>") planned=steps(count=1)
jump route decided
zed: project-route 'Claudio' match=terminalHost
```

因此，**这一次真实点击确实走 project route 的单步 plan**，已经越过仅有静态符号的证据层；它仍没有 terminal/pane 的成功回执。能从另一项目窗口切回 Claudio workspace，并不能区分 Claudio 内此前保留焦点与目标 terminal 被重新选择。主执行 agent 的同项目另一 pane 反例对照及其原生结果需另外记录，不能由上述日志提前判定。未新增生产代码，未修改商业软件、用户配置或任何 hook。

## 本轮原生对照：Vibe Island 1.0.51

继续测试使用既有官方 `/Applications/Vibe Island.app` 和 `/Applications/Zed.app`，没有升级、安装扩展、添加 hook 或接受新权限。本轮与上文的早期静态调查分开：**本轮实际启动并点击了商业 Vibe Island**。仅点击当前任务对应的来源卡片，不向已有 CLI 输入文字或命令。

| 点击时间（UTC）与对照 | 原生观察 | 能证明的范围 |
| --- | --- | --- |
| `08:57:33`，另一 workspace → 当前来源卡片 | Zed 显示 Claudio workspace，来源 terminal 可见 | 项目返回；此前保留的 terminal 焦点不能排除 |
| `09:02:34`，同项目另一 pane 已激活并放大 → 来源卡片 | 放大的仍为对照 pane，未返回来源 pane | 同项目分屏的反例；需排除 zoom 对行为的影响 |
| `09:03:58`，恢复普通布局、保留对照 pane 活动状态 → 来源卡片 | 点击后用 `workspace: toggle zoom` 读回活动 pane，仍为对照 pane | 普通布局下复现分屏反例，来源 pane 没有被重新选择 |
| `09:06:17`，独立 `empty project` 原生窗口 → 来源卡片 | Zed 显示 Claudio workspace，保留对照 pane | 已有项目/窗口路由；没有来源 terminal 的确认 |

活动 pane 的对照通过已观察到的 command palette 动作读回；测试后撤销 zoom，恢复原四区域布局。四次点击的本地 `jump` 日志均为 `legacy=zedProject(path: "<local-path>") planned=steps(count=1)`，随后记录 `zed: project-route 'Claudio' match=terminalHost`；没有从其他宿主的精确返回行为推导 Zed 能力。

**本机该版本、本次配置下，实际验证到的是项目路由，同项目来源 pane 返回失败。**这不是对所有 Vibe Island 版本或配置的断言，也未还原商业实现的全部状态。并行 GUI harness 曾取得系统前台，后续还有其他操作者切换 workspace；本轮没有把“CUA 读到目标窗口”记为完整的最终系统前台验收。

本地脱敏结果留在忽略目录 `dist/zed-navigation-evidence/vibe-native-followup/`。启动前后六个既有宿主配置/插件文件的存在性、字节 SHA-256 和 mode 一致；没有导出私人诊断报告。测试后通过应用菜单退出 Vibe Island，复核其可执行文件不再运行，安装包 SHA-256 与前节一致。官方 Zed 的严格签名复验通过。

## 本轮原生探针：按身份读回 tab、分屏与窗口

在本轮自建的 `empty project` 窗口中，A/B 位于同一 pane 的两个 tab，C 位于新建的右侧 terminal pane。三个 shell 均在同一目录，三个探针分别持有不同 UUID、PID 和 TTY，启用 `1004` focus-report mode；它们只读取自己测试 terminal 的输入，不接管用户已有 CLI。原始 JSONL、探针及分析脚本留在忽略目录 `dist/zed-navigation-evidence/focus-return-prototype/`。

先记录目标已有 sequence，再执行已核实的 command palette 动作或 Window 菜单选择。分析只接受目标 UUID/PID/TTY 一致、sequence 增加、且在本次动作后三秒内的新 `focus-in`。以下时间仅从最后一个选择动作开始计算，包含人工预选之前的所有步骤的完整导航预算没有验证。

| 动作 | 新回执的目标与 sequence | 从选择动作到回执 | 证据 |
| --- | --- | --- | --- |
| B → A：`pane: activate previous item` | A，`4 → 5` | 23 ms | 同目录 tab 可以区分 |
| A → B：`pane: activate next item` | B，`158 → 159` | 11 ms | 反向 tab 读回 |
| C → B：`workspace: activate previous pane` | B，`162 → 163` | 39 ms | 已有分屏选择可以区分 |
| B → C：`workspace: activate next pane` | C，`2 → 3` | 1702 ms | 新回执可读；其后预算内再次失焦，不能据此确认最终成功 |
| Claudio 窗口 → 自建窗口：Window 菜单的具体窗口项 | C，`72 → 73` | 56 ms | 窗口返回与当前 terminal 身份可以关联 |

两项真实负向区间也得到验证：激活另一个原生窗口时，C 没有三秒内的新回执；选择 C 时，同目录的 A 没有新回执。分析脚本另外使用已有旧记录检查 stale receipt 与错误 instance 均被拒绝。这是 **5 项原语匹配、2 项真实负向区间和 2 项记录重放检查**，不是生产 executable harness 的新增检查，也没有产生产品 `exactReturnConfirmed`。

并行焦点变化是本轮的重要限制：一次分屏测试在目标首次回执后又失焦，说明“目标曾收到 focus-in”与“最终仍聚焦”不同。应用前台、所选原生窗口、目标 terminal 最新的 focus 状态需要共同成立；不能只接受第一次回执。probe 的 UUID/PID/TTY 也尚未绑定内核启动身份，未完成 PID 复用防护。

测试后按可执行路径、标签、当前用户与 parent PID 复核并仅停止三个自有 probe，三条日志均以 `stopped` 结束；`finally` 撤销 focus-report mode 并恢复 terminal mode，进程退出已读回。三个 terminal 的 shell 提示符重新可见后，只关闭自建窗口；用户既有 Zed 工作窗口保留。

### 候选实现已经缩小，但产品能力尚未接通

本轮证明官方 Zed 的既有 tab / pane / window 动作和 PTY 焦点回执可以组合，用于事先管理的会话。下一步需要一个从会话开始就拥有外层 PTY 的透传 bridge：绑定进程启动身份与随机会话身份，在原始预算内只执行可逆的已有项选择，并以新回执和最终前台状态共同结束导航。它必须保留 CLI 输入输出、终端协议、窗口尺寸、信号、退出码和取消语义；任何目标不唯一、身份变化、失焦或超时都不能升级为精确成功。

目前仍缺少按事件身份自动寻找任意现存 window/pane/tab 的导航器，以及有真实 CLI 透传验证的 bridge。用户还没有选择未来会话经 Claudio 启动的方式；既有普通 terminal 无法用另一个 reader 安全补上回执。CUA 工具已有的 Accessibility 权限也不代表 Claudio 具有该权限。保持官方 Zed、不增加权限和不接管已有 CLI 的现有边界下，本轮继续保留生产 `applicationFallback`；这些探针结果不被包装成已交付的精确跳转。

## 后续授权与实现：受管理新会话

上述段落记录原语探针结束时的状态。随后用户明确授权“实现这个技术路径并测试”，已在隔离工作树
接通 Debug `claudio zed-session`、私有认证 PTY bridge、版本绑定目标与有界原生导航器。helper 全套
5186 项检查通过；实际 CLI 的 12 个独立内核 PTY 场景全部通过；GUI 来源与受管理导航聚焦测试
122 项通过，包含窗口预算、AX 不确定派发后的读回以及显式键位合同的失败回归。保持普通 Release 与
已有 terminal 的应用回退，新会话须主动经 launcher 启动。

用户确认 Mac 状态后，Computer Use 连接恢复；真实横幅先验证了权限缺失时的应用回退。用户随后
仅为独立检查包授予辅助功能权限。修复 AX IPC 窗口读回后，生产面板与协调器路径已经真实完成
同项目、同目录 A/B tab 的双向 `exactReturnConfirmed`，目标新回执与提醒移除均读回。最新检查包
的跨窗口和分屏仍继续验证，不从原语探针或编译接缝推导其完成。默认 Terminal 的 `cmd-k` 清屏
会覆盖全局方向 chord，故最新实现删除该 chord；分屏需要用户明确安装的四键实验配置，其他
自定义 keymap 拒绝。官方源码依据为
[固定版本默认键位](https://github.com/zed-industries/zed/blob/c0199504b9cce79bc27524950022ed701bc3ebd5/assets/keymaps/default-macos.json#L1354-L1377)。
具体实现条件、结果与未验证范围见
[受管理导航实施与验证](validation/zed-managed-navigation-2026-10-09.md)。

## 2026-10-10 续测结果

以上跨窗口/分屏尚未完成是历史阶段。随后实现了 dock 探测、已知 pane 优先、持续焦点窗口排序
与默认 window/tab 保留，并逐项建立失败回归；最新聚焦检查为 135 / 0。133 项对应检查包已在
官方 Zed 的三 pane、同 pane 两 tab、两个窗口上完成七项生产面板/协调器的精确返回，目标新
focus-in、其他会话失焦与提醒清除均读回。四键上下左右均已实测，context 改为 `Workspace`，
避免离开 terminal 后绑定失效。普通 Release 和既有 terminal 的回退保持不变。

最后 135 项兼容分支已编译，重签后原生工具再次出现 `cgWindowNotFound` 和 inventory 超时，
当前包原生复验与直接横幅正向尚未完成；系统认证此前已完成，不能用旧认证阻塞描述当前状态。
真实 CLI 交互回调仍未验证。阶段与包身份详见[实施记录](validation/zed-managed-navigation-2026-10-09.md)。
