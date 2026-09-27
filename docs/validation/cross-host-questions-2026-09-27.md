# 跨宿主提问提醒：实现与验收记录（2026-09-27）

基线：`47882d7daf49a1d67b327bb4b33fe311dcc7f8ba`。本次为未提交的工作区实现。
合同见[正式开发计划](../../plan/PLAN-CROSS-HOST-QUESTIONS.md)和
[ADR 0018](../adr/0018-separate-question-intent-and-observation-evidence.md)。

同日后续已解除工具链与测试布局阻塞：标准命令使用默认构建器和 SDKROOT 26.5，
完整 GUI **10,928 checks，0 failures**，Debug 构建及 Release 本地打包通过。
最新三宿主 5/5、4/5、4/5 交付状态和当前候选验收见
[正式交付记录](host-event-delivery-2026-09-27.md)。下方早期工具链失败保留为过程记录。

## 交付状态

| 范围 | 实现 | 验收状态 |
| --- | --- | --- |
| Claude Code `AskUserQuestion` | 精确 `PreToolUse` binding、严格入口、请求去重、声音和瞬时提示 | 自动化通过；真实 Claude 在服务连接阶段返回 403，回调、当前安装、听音未验证 |
| 共享能力与展示 | 五事件聚合、按提醒类型展示回执；旧授权回执不激活新类型 | 完整 GUI harness 通过；当前 Release 候选的原生与真实宿主门禁待验 |
| Codex 验证原型 | 显式 DEBUG 开关、单文件 EOF 增量 reader、GUI 生命周期、独立来源 | 合成合同及根线程真实异步意图捕获通过；调整独立测试音量后，一次真实异步问题的声音和提示经人工确认 |
| Codex hook 入口证据 | 隔离 CLI 0.157.1 的精确 `PreToolUse` 探针，不安装 Claudio hook | 同步两次、异步一次真实命中；当前 TUI 两组临时 hook 显示 Trusted，但本代理提问与 `Bash` 对照均为 0 回调，根客户端工具路径仍未验证 |
| Codex App Server 只读探针 | 独立进程读取一个新建隔离 CLI 的待答线程摘要；另一次只读当前根线程 | 原 CLI 仍能回答；当前根线程在独立进程中为 `notLoaded`，共享代理控制 socket 不可连接；没有实时输入请求事件或只读订阅证据 |
| Codex 当前客户端异步观察 | 从当前根会话新 EOF 只读观察；另一次显式启用 DEBUG Claudio；分别做未信任与受信任的临时 hook 测试 | 用户确认 TUI 测试问题可见，开发观察的另一次真实问题获人工听音和横幅确认；受信任提问与 `Bash` 对照均未收到本代理工具调用回调，明确请求门槛未通过 |
| Codex 正式接入 | 未增加提问 binding | 明确输入请求及跨客户端 P0 门槛未通过，尚未选择正式入口 |
| WorkBuddy 提问 | 未增加 matcher | 缺少 Desktop 真实工具名、回调与请求身份证据 |

Claude 探针详见[受控运行记录](claude-question-probe-2026-09-27.md)。Codex 的公开接口、
本机 schema、入口对照、Vibe Island 版本化只读证据和 WorkBuddy 缺口见
[入口证据记录](cross-host-question-entry-2026-09-27.md)；隔离 CLI 的真实
`PreToolUse` 见[受控探针](codex-question-hook-probe-2026-09-27.md)，独立 App Server
归属测试见[只读探针](codex-appserver-read-probe-2026-09-27.md)，当前客户端的
两次异步界面测试见
[可见性记录](codex-current-client-async-visibility-probe-2026-09-27.md)。构建或
合成回调不替代真实宿主验收。显式开发观察的最新人工听音见
[受控验收](codex-development-notice-probe-2026-09-27.md)；当前 TUI 的受信任 hook
与 `Bash` 对照见[独立记录](codex-current-client-trusted-hook-probe-2026-09-27.md)。

## 主要实现

- 五个公共 `Event` 不变。Claude 新类型复用 `notification`；matcher 为
  `^(AskUserQuestion)$`，工具名、字段合同和 schema revision 由同一描述拥有。
- 入口在副作用前拒绝错误事件、近似工具名、错误字段类型、缺少身份、敏感重复键、
  截断/超限/超时和失效安装。`tool_input` 必须是对象，内容不进入回执或消费记录。
- 提问身份消费与旧的 1.5 秒播放抑制分离。消费表只存摘要和时间，256 条、30 分钟；
  满额或锁/存储失败关闭。静默或启动失败仍消费该请求，不补播；合法重复回调如实
  写活动和 `debounced` 回执。不同请求可分别播放，紧邻 Stop 不被旧锁吞掉。
- Connect / Repair / Disconnect 保留既有 binding ID、第三方 handler 和未知字段。
  新增 `PreToolUse` 不扩大 legacy `claudio play` 的清理所有权。
- `questionIntent` 只瞬时展示“即将提问”，不改变同会话已有“需要你”。明确输入请求、
  idle、提醒到期和移除继续使用既有规则。覆盖率以五事件计算，回执以 binding 校验。
- Codex 原型从显式文件的新 EOF 开始；只在内存选择必要元数据。开发观察进入唯一
  `EventNoticeModel`，带独立 run/provenance，不生成 hook receipt、当前激活或活动计数。
  新来源没有目录证据，使用默认组。关闭、锁屏、睡眠和退出撤销运行代次与在途播放许可。

## 提问开发阶段的自动化记录

此表记录先前执行结果；最新完整门禁、工具链修复和本地包证据见上方链接。

| 命令 / 检查 | 结果 |
| --- | --- |
| `swift run --package-path helper claudio-tests` | **4146 checks，0 failures**；新增 DEBUG 诊断流经写盘台账精确审计 |
| helper `--questions` | **374 checks，0 failures**；包含新增 legacy hook 所有权回归 |
| `bash scripts/test-hook-cli-contract.sh` | **通过**；包括真实 CLI stdin、静默退出、旧代次、非法零副作用、首次静默与重复回调 |
| `swift run --package-path gui claudio-gui-tests` | **阻断**：标准构建缺少 `xcstringstool` |
| `swift build -c debug --package-path gui --product ClaudioGUI` | **阻断**：同上 |
| 替代 GUI Debug build（下方命令） | **通过**；包含 GUI 观察运行时 |
| 替代 GUI `--question-intent` | **175 checks，0 failures** |
| 替代 GUI `--question-integration-contract` | **2157 checks，0 failures** |
| 替代 GUI `--event-attention` | **534 checks，0 failures**；含模型/原生挂载及合成压力测试 |
| 替代 GUI 完整 harness | **未完成**：既有 `SettingsSoundsLayoutSuite.swift:72` 的 Vision OCR 挂起；采样后终止本次测试进程 |
| `jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings` | **通过** |
| Swift 严格格式检查 | 40 个涉及文件中 39 个通过；既有 `ClaudeCodeHooksTransformSuite.swift` 保留基线 95 条诊断，新增诊断已修正 |
| `git diff --check` | **通过** |
| `scripts/verify-settings-experience.sh <baseline>` | **未完成**：脚本要求干净 HEAD，拒绝当前未提交工作区 |

替代工具链仅用于获得本机编译与定向合同证据，不把它写成标准门禁通过：

```bash
env -i PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  /usr/bin/swift build --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -c debug --package-path gui --product ClaudioGUI
```

定向 harness 使用同一 build system / SDK 和对应参数。`native` build system 自身有
工具链弃用警告；不因此更改仓库构建系统。压力样本为 1000 事件 / 10 秒、p95 **2.913 ms**、
首次 badge **100.600 ms**、987 batches；它不是宿主到声音或真实窗口的端到端延迟。

## 真实根线程与人工验收

本次临时 DEBUG app 使用独立 bundle ID、`CLAUDIO_TEST_ROOT` 和 `CLAUDIO_TEST_HOME`，
内置 `minimal-chime`、notification 开启、音量 0.4。没有覆盖现有安装，没有连接真实
Claude/Codex/WorkBuddy hook。精确目标由根线程身份与文件名关联；启动时只从 EOF 观察。

第一次实际异步问题的只读探针识别了调用意图，但用户报告声音和提示都没有出现。
“焦点保持”的反馈发生在无提示条件下，不能算非抢焦点通过。核查发现测试状态根中缺少
运行时声音包，bootstrap 报 `selected_pack_unresolvable`；已补全独立状态根的声音包和
helper。首轮没有记录 reader 退休原因，提示缺失的原因仍未确认，不能用声音包问题解释。

随后在开发运行时增加固定状态码诊断，不输出身份、路径、参数或原始记录。第二次从新
EOF 启动后，实际异步问题得到 `reader_started → model_accepted → player_started`。
`player_started` 只证明系统播放器进程启动。用户随后明确反馈第二次仍未听到声音、
未看到提示，故声音和可见提示验收**未通过**，非抢焦点仍**未验证**。程序记录与
用户体验之间的缺口尚未定位，不能由进程启动或模型接受推断提醒成功。

用户要求下次测试前先明确提醒。后续受控验收按以下顺序执行：先说明即将测试的声音、
提示和预计触发时间，等待用户明确回复准备好，再启动新的观察代次并触发问题；
测试后分别收集听音、可见提示与焦点结果。验收问题本身不能同时充当提前提醒。
在收到第二次反馈的当轮只更新记录，没有再次启动实例或触发测试。

用户随后明确回复准备好。第三次独立 DEBUG 实例预先放入 `minimal-chime` 声音包，
并使用同一 `notification.mp3`（约 0.52 秒）。在测试音量 0.4 的首次调用中，用户
询问预期声音，未对该次听音与提示给出肯定或否定反馈；开发诊断记录了模型接受、
窗口位于活动空间且无遮挡、播放器正常退出。明确说明声音种类后，仅将该实例的
测试音量改为 0.8，再触发一次真实异步问题。用户确认**听到一次铃音，也看到
“即将提问／开发观察”**。开发诊断同样记录 `model_accepted`、窗口 `visible / ordered /
active_space / unoccluded / not_key` 和 `player_exited_successfully`。用户当时没有在
输入，因此本轮不能证明非抢焦点。测试音量变化与声音说明同时发生，不能单独归因
前两轮未获听音反馈的原因。第三次真实宿主样本仍只证明调用意图，未升级为明确待答。

随后单独测试提示窗口的焦点行为。使用新的隔离 DEBUG 实例和一个空的私有 rollout
fixture；先提醒用户并等待其回复就位，再让用户把光标留在可编辑文本框中输入。
约 10 秒后只向该 fixture 追加一条带新请求身份、当前时间的**合成** `function_call`，
没有问题、选项或答案内容。GUI 从新 EOF 观察，记录 `model_accepted`、窗口
`visible / ordered / active_space / unoccluded / not_key` 和
`player_exited_successfully`。用户确认听到铃音、看到提示，且提示期间文字继续落在
原文本框，**原生提示窗口的非抢焦点验收通过（开发合成触发）**。这个试验不证明
Codex 宿主问题界面本身的焦点行为，也不产生真实宿主回调或当前安装回执。

第三次真实异步实例和焦点实例均已关闭。两次隔离运行各自核对启动前五个用户文件
摘要，均为 **5/5 不变**；焦点 fixture 只写入 190 bytes 的合成记录，没有生成
hook receipt 或活动文件。前述第二轮 `~/.codex/config.toml` 的摘要变化仍保持原样，
没有归因或覆盖恢复。

本机 Computer Use 对临时 app 的两次读取超时，应用进程实际已启动；没有把这种超时
或构建结果当作界面可见证据。这个运行不能建立 Codex 的 `PreToolUse` 回调或可靠明确
待答证据，也不能建立 Claude 当前安装回执。

第二次运行在已接受问题之后遇到超长新记录，报告 `reader_lineTooLarge` 并关闭观察；
没有自动重启或历史回放。这说明正常开发活动也可能触发当前保守预算，正式入口不能
从这一次短窗口样本推导。两个临时 GUI 进程均已停止；观察路径未生成 hook receipt
或活动文件。

清理时核对启动前保存的五个文件摘要：`~/.claudio/config.json`、
`~/.claude/settings.json`、`~/.codex/hooks.json`、`~/.workbuddy/settings.json` 均不变。
`~/.codex/config.toml` 在验收期间摘要发生变化。探针只保留摘要，没有原文件副本，因此
无法据此判断改动来源或内容；保留当前文件，未做覆盖恢复。临时 app、固定码日志和
探针留在私有临时目录，未进入 Git；未覆盖现有安装。

## 开发原型的复现入口

源码入口：[GUI 生命周期](../../gui/Sources/ClaudioGUI/EventNoticeRuntime.swift)、
[串行观察运行时](../../gui/Sources/ClaudioGUI/CodexQuestionObservationSession.swift)、
[有界 reader](../../gui/Sources/ClaudioGUICore/CodexRolloutObservationReader.swift)。

先构建 DEBUG GUI，再对一个已确认身份的单文件显式开启观察。以下占位符必须替换为
独立开发配置根和目标；不应把根目录扫描或旧会话内容当作参数发现步骤。

```bash
CLAUDIO_TEST_ROOT=<private-development-state> \
CLAUDIO_TEST_HOME=<private-development-home> \
CLAUDIO_DEV_CODEX_QUESTION_OBSERVER=1 \
CLAUDIO_DEV_CODEX_ROLLOUT_PATH=<absolute-rollout-file> \
CLAUDIO_DEV_CODEX_SESSION_ID=<matching-session-uuid> \
  gui/.build/arm64-apple-macosx/debug/ClaudioGUI
```

开发配置根需要有效声音配置和声音包。Release 忽略此观察入口。超过单行/积压预算、
格式变化或权限异常会终止当前代次；重新开启或生命周期恢复从新 EOF 开始，不回放。

## 仍未验证

- Claude 真实提问回调、当前安装 receipt、真实问题界面及听音。
- Codex 根客户端的同步提问和同步/异步 `PreToolUse`、可靠明确请求、快答/取消/自动答
  关联；当前客户端至少一次异步问题在 Codex TUI 可见，但最近两轮没有运行 Claudio；
  App Server 只读订阅已有线程及根客户端归属。隔离 CLI 的一次只读调用未
  接管原 CLI 问题，同步/异步 `PreToolUse` 与同步 Plan mode 问题界面也已实测；
  这些结果不等于根客户端当前安装证据。
- WorkBuddy Desktop 的新提问工具和回调。
- 实机锁屏/睡眠/退出恢复；键盘遍历、VoiceOver、明暗主题、中英文原生布局、既有提醒
  阅读/移除的人工验收。原生提示窗口的非抢焦点已由合成触发和人工输入确认；其余
  自动化状态合同不替代人工结果。
- 设置干净 HEAD 固定基线门禁、正式候选的安装验收、双架构、Developer ID 签名与公证。
  同日后续完整 GUI harness、Debug 构建、本地 Release 打包、体积和 ad-hoc 签名检查已通过；
  临时 Debug app 的开发记录不代替正式候选验收或发布。
