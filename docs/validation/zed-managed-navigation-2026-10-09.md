# 官方 Zed 受管理会话导航：实施与验证

本记录对应用户授权“实现这个技术路径并测试”。实现位于隔离工作树
`codex/zed-login-navigation`，基线 `7f0533605ff77380f973d3fe1986499ab4f43723`。
未提交、推送或发布；官方 Zed 未替换或重签。以下“当前结果”取代后文历史阶段的状态描述。
后文保留失败、认证与配置恢复的过程，不能将某次历史状态当作当前阻塞。

## 2026-10-10：`70e0251` review 修复补充（未提交）

本次只处理 review 的两个 P2：外层 PTY 输出背压导致 focus-report mode 恢复序列丢失，
以及 Claudio 自身输入不能取消受管理导航。修复保留在 `codex/zed-login-navigation` 工作树；
主仓库原有未提交内容未改动，未 commit、push、创建 PR 或发布。

- PTY 模式写入保留部分写进度，处理 `EAGAIN`／`EINTR`，等待完整写出后才退出或暂停。
  真实双层 PTY 回归先重现原模式未恢复；新增原先开启／关闭、持续背压和信号中断等待场景，
  校验输出字节、退出码、termios 和共享描述符标志。持续背压期间不提前交还终端。
- 请求内同时安装 global／local input monitor，本应用按键、点击和滚动同步撤销资格，仍传递
  原事件。只排除同 marker、同进程的自身派发；结束时移除两个 monitor。真实 AppKit
  `sendEvent` 接缝覆盖输入、传递和清理；搜索／窗口选择／生产协调器接缝覆盖取消后不再激活、
  保留提醒、禁止应用回退。snapshot 失败出口也先复验取消与原截止时间，避免把取消转成回退。
- `swift run --package-path helper claudio-tests --zed-pty-bridge`：85 checks，0 failures。
- `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run --package-path gui claudio-gui-tests --zed-source-navigation`：173 checks，0 failures。
- helper `claudio` 与 GUI `ClaudioGUI` Debug 构建通过；实际 Debug CLI 的
  `python3 helper/Tests/ClaudioCoreTests/zed_pty_fixture.py helper/.build/debug/claudio --cli`：15／15 场景通过。
- 7 个改动／新增 Swift 文件 strict lint、Python fixture 语法、本地化 JSON 与 diff whitespace
  检查通过，包括两个新增未跟踪文件。完整未提交 diff 按 Standards／Spec 两轴只读复核，
  未发现新增 actionable finding。

未运行 helper／GUI 完整 harness、Release 构建或 bundle。未复测真实 Zed、人工点击／键盘、
VoiceOver 或真实 CLI hook 回调；上述合成 PTY 和 AppKit 事件接缝证据不代替这些验收。
日志为 `/tmp/claudio-zed-review-{pty-final,navigation-final,cli-pty-final,debug-build,helper-debug-build}.log`；
红回归为 `/tmp/claudio-zed-review-{pty-red,input-red,input-barrier-red}.log`。

## 当前结果（2026-10-10 续测）

用户已完成系统认证，并暂缓另一会话的原生应用操作。只为独立检查包刷新同范围的签名登记，
系统设置已读回该包开启、普通 Claudio 关闭；没有新增权限范围。以下完整原生矩阵来自 133 项
聚焦检查对应的检查包。最后的 135 项版本增加“四键不可用时继续默认 window/tab 搜索”的兼容
分支，Debug 编译与身份哈希已核对，但重签后 Computer Use 再次失去窗口连接，尚未完成当前
包登记刷新与原生复验。这是工具连接阻塞，不能称系统认证仍未完成。

当前原生布局为同一项目/目录的 A/B tab、上方 E 与下方 B、右侧 C，以及另一个窗口的 D。
从生产面板的来源按钮进入同一模型与协调器，七项均返回 `exactReturnConfirmed`、认证 peer 5；
每次目标取得新 focus-in，其他四个受管理会话失焦，待接手计数与“来源已清除”由界面读回。
请求期间未人工选择目标。fixture 是真实隔离进程调用合成 `hook codex PermissionRequest`，
不是实际 Codex/Claude Code 交互产生的回调。

| 原生对照 | 结果 | 请求内 trace 最后耗时 |
| --- | --- | --- |
| C → 上方 E | 精确返回，E sequence 31 → 32 | 1.264 s |
| E → 下方 B | 精确返回，B 聚焦、其余失焦 | 1.733 s |
| B → A，同 pane、同 cwd | 精确返回，A sequence 7 → 8 | 0.865 s |
| A → B，同 pane、同 cwd | 精确返回 | 0.870 s |
| B → 右侧 C | 精确返回 | 1.071 s |
| 项目窗口 → D 所在另一窗口 | 精确返回 | 0.723 s |
| D → 项目窗口 C | 精确返回 | 0.603 s |

trace 从 native driver 初始化完成后计时，不能将表中耗时当作包含初始化与身份校验的完整点击
耗时。协调器仍覆盖全过程的原始三秒期限。脱敏快照为忽略目录中的
`managed-native-continuous-{pane-E,pane-B,tab-A,tab-B,pane-C,window-D,window-C}.json`。

四键已通过真实左右、上下原语与自动分屏返回验证。临时配置由 `Terminal` 改为 `Workspace`
context：方向离开 terminal dock 后仍可返回。产品只读取完全匹配的显式配置；安装与恢复属于
本轮授权测试，不是产品自动改写。默认 `cmd-k` 清屏前缀已删除。

续测由真实 trace 建立失败回归再修复：无受管理前窗口耗尽预算（124 / 2 → 124 / 0）、editor/sidebar
空 tab 深扫使相邻 pane 饥饿（127 / 3 → 127 / 0）、AX 选择后 terminal dock 未激活（129 / 2 →
129 / 0）、三 pane 几何（131 / 2 → 131 / 0）、持续焦点没有新事件而被错误降序（133 / 2 →
133 / 0）、缺四键时方向拒绝阻断默认 window/tab（135 / 2 → 135 / 0）。持续焦点仅是窗口排序
提示；最终成功仍要求目标的新事件和第二次屏障。有限搜索不承诺覆盖任意复杂或 zoom 布局。

最新两次直接横幅正向尝试均在 Computer Use 获取检查包窗口时超过四秒显示期限，未取得可点击
窗口，也没有完成点击；随后 Zed 和系统设置均返回 `cgWindowNotFound`，应用清单查询超时。
不能把上述面板入口成功当作最新横幅直接点击通过；早期真实横幅权限缺失回退仍只是负向证据。

当前自动门禁：helper 完整 5188 / 0；GUI 聚焦 135 / 0；GUI 完整 15484 / 27。
27 项分别为未改动的 EventAnimationIntegration 1、ReleaseLayout 1、SettingsPresentationTarget 6、
PanelSettingsHandback 17、SettingsNativeShell 2，与下文历史表一致；没有在干净基线运行同门禁，
不宣称已证明是基线失败。GUI Debug 构建、33 个改动 Swift 的 strict lint、本地化 JSON、补丁空白、
当前检查包与官方 Zed 的 strict/deep 签名校验通过。37 个来源哈希与两份包内可执行文件哈希匹配。
视图接线复验 277 / 0；当前普通 Release `scripts/dev-bundle.sh` 构建、ad-hoc 签名及脚本内
体积/导出门禁通过：GUI 6840544 B、helper 3226000 B、正规文件合计 12614677 B，均低于预算。
Release `--help` 无 `zed-session`，当前 Debug 检查包包含此入口。全部是 arm64 本地检查证据。
当前日志副本保留在忽略的 `dist/zed-navigation-evidence/logs/claudio-zed-current-*.log`，
最后兼容分支的红/绿与 Debug 构建记录为同目录的 `claudio-zed-optional-directions-*.log`。

收尾已复验五个自有 fixture 的退出记录与 PID 消失，检查包 GUI/helper 均无运行进程。临时
Workspace 四键文件的 inode/device/UID/mode/完整哈希与安装记录一致，已移动到忽略证据目录，
读回原先不存在 `keymap.json` 的状态。当前不再安装四键。由于 Computer Use 无可操作窗口，
未确认自有测试窗口关闭或新 shell 提示符；没有关闭用户工作窗口、杀官方 Zed 或修改普通权限。

普通 Release 与已有普通 terminal 仍然 `applicationFallback`。本轮交付的是受管理新会话的 Debug
实现和可核验技术路径。真实 CLI 回调、最新直接横幅正向、任意布局、VoiceOver、Intel 与签名
发布仍未验证，不能据本轮结果宣称完整生产验收。

## 已实现的行为

Debug helper 提供 `claudio zed-session -- <command> [arguments]`。它只在新会话开始时管理外层
PTY，创建内层 PTY 并直接 exec 参数；不经 shell 解释，也不附着到已有 CLI。stdin、stdout、stderr
必须属于同一个控制终端，launcher 必须在前台 process group，否则在修改 terminal mode 和启动
命令之前拒绝。C supervisor 保留前台
process group 和 job control，Swift loop 有界透传输入输出、尺寸、信号与退出码。

bridge 独占外层 DEC mode 1004，虚拟化子命令的启用、关闭、保存、恢复和查询；CLI 请求焦点报告时
仍收到对应报告。粘贴中的文字、UTF-8、NUL、裸 Escape、颜色和其他 terminal 协议照常透传。
退出、失败和暂停时恢复原始 terminal 设置、原先的 focus-report mode 与共享描述符的可变标志。
后台 continuation 保持暂停，只有重新成为前台任务才恢复透传。

GUI 显式启用 `CLAUDIO_ZED_NAVIGATION_PROTOTYPE=1` 后，才接受受管理身份。私有 socket 注册同时
复验 kernel peer UID/PID、启动身份、父链、内外 TTY 和已确认 Zed 实例。identity 中的 `child` 是
内层 PTY 的 C supervisor；实际 CLI 位于其下。事件仍使用原有 wire，唯一 `EventNoticeModel` 在释放
原始来源证据前生成版本绑定的 typed target，不另建事件或来源状态。

窗口选择使用具体 AX window 对象，tab 使用官方固定按键，pane 使用显式四键实验配置；搜索已有项，不创建项，不以
标题、cwd 或数据库猜测目标。定位、新回执和最终读回共用协调器原始三秒期限。只有目标 sequence
增加、新 focus-in 在请求内产生、第二次 snapshot barrier 仍唯一聚焦、实际前台应用和 AX focused
window 一致，才返回 `exactReturnConfirmed`。过期身份、旧回执、失焦、用户输入、重连或超时均不能
清除提醒；普通应用回退继续保留提醒与剩余阅读时间。

## 实验边界与入口

本轮原生适配仅接受官方 Zed 1.23.2、标准配置目录、已核实的 bundled base map、ABC/US 键盘布局，
以及 Claudio **已经具有**的 Accessibility/event posting 权限。默认配置支持窗口与 tab 搜索；分屏方向
需要与[四键实验配置](zed-managed-navigation-keymap.json)字节完全相同的 `keymap.json`。Claudio
只读取该文件，不自动安装、合并或修改。缺失四键仅跳过方向，保留默认窗口/tab 搜索；其他
必要前提缺失或未知时在派发前停止，不触发权限请求。最多四个窗口，每个 pane 至多 16 个 tab，并采用有限方向扫掠；
复杂、不可达和 zoom 隐藏布局可能回退或超时。取消后不继续派发，也不在截止时间后回滚中间选择。
搜索失败前可能已经切换过已有 tab/pane，不能把失败解释为没有发生任何原生选择。

普通 Release 没有 `zed-session` 子命令，GUI 也不启用此能力；普通已有 Zed terminal 继续使用
`applicationFallback`。本实现是可测试的 Debug 实验，不代表所有已有会话已支持精确返回。

在源码 Debug 环境中，先给 GUI 设置 `CLAUDIO_ZED_NAVIGATION_PROTOTYPE=1`，随后在官方 Zed 的
**新 terminal** 中使用对应 Debug helper，例如：

```bash
helper/.build/debug/claudio zed-session -- codex
```

本轮独立本地检查包是 `dist/zed-navigation-evidence/Claudio Zed Managed Inspection.app`，bundle ID
`com.claudio.app.zed-managed-inspection`，使用隔离 `CLAUDIO_TEST_HOME`/`CLAUDIO_TEST_ROOT`。
通过该检查包测试时，新 terminal 的 launcher 必须使用相同的隔离运行根：

```bash
CLAUDIO_TEST_ROOT="$PWD/dist/zed-navigation-evidence/managed-native-state/runtime" \
  "$PWD/dist/zed-navigation-evidence/Claudio Zed Managed Inspection.app/Contents/Resources/bin/claudi0" \
  zed-session -- <command> [arguments]
```

上述路径以本工作树根目录为当前目录。检查包不会替换常规安装包。可选 Debug 诊断
`CLAUDIO_ZED_NAVIGATION_DIAGNOSTICS=1` 写固定状态码、认证 peer 数，以及至多 192 项请求内
操作名称、窗口 ordinal、结果和耗时，不写会话 UUID、PID、TTY、argv、按键内容或 CLI 输出。
诊断仍在原有忽略文件内，不改变 wire/schema，也不拥有第二份来源状态。检查包、身份哈希和
完整日志均留在忽略的 `dist/` 中。

## 历史阶段的自动验证

本机为 arm64，Swift 6；GUI 使用已安装的 MacOSX26.5.sdk，以避开当前默认 SDK 的 SwiftUI macro
plugin 问题。具体命令与结果：

| 检查 | 结果 | 证据范围 |
| --- | --- | --- |
| `swift run --package-path helper claudio-tests` | 末轮复验 5188 checks，0 failures | 本次 Zed suite 通过；前一次全套 NVM shim 夹具失败，单独复跑 82 / 0 |
| `swift run --package-path helper claudio-tests --system-login-ancestry` | 96 checks，0 failures | 来源识别回归 |
| helper `--zed-pty-bridge` 聚焦 harness | 82 checks，0 failures | 协议过滤与真实双层 PTY |
| GUI `--zed-source-navigation` 聚焦 harness | 122 checks，0 failures | 来源回退、受管理导航、窗口读回与显式键位合同 |
| 实际 Debug `claudio zed-session` 的独立 Python PTY fixture | 12/12 场景通过 | 实际 CLI 入口与内核 PTY 行为，不涉及桌面 UI |
| GUI Debug `ClaudioGUI` build | 通过 | 编译及链接 |
| GUI 全套 executable harness | 末轮 15471 checks，27 failures | 本次接线失败已消失；既有 8 项及 19 项原生前置失败，单独记录 |
| `CLAUDIO_BUILD_SDK=... bash scripts/dev-bundle.sh` | 通过 | 当前 arm64 普通 Release、ad-hoc 签名与包体检查 |
| `bash scripts/check-release-size.sh dist/claudi0.app` | 通过 | GUI 6840432 B；helper 3226000 B；正规文件总计 12614565 B |
| Release/Debug CLI 入口读回 | 通过 | 普通 Release 不含 `zed-session`；Debug 检查包含该入口 |
| `jq empty`、Swift format strict lint、`git diff --check` | 通过 | 本地化 JSON、改动源码格式与补丁空白 |

GUI 命令均使用以下工具链参数；完整全套不替换为 `swift test`：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  swift run --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  --package-path gui claudio-gui-tests

SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  swift run --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  --package-path gui claudio-gui-tests --zed-source-navigation

swift build -c debug --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --package-path gui --product ClaudioGUI

/usr/bin/python3 helper/Tests/ClaudioCoreTests/zed_pty_fixture.py helper/.build/debug/claudio --cli
```

12 个实际 PTY 场景为：UTF-8/NUL/粘贴/裸 Escape；子命令 focus mode 与原始 mode 恢复；SIGWINCH 与
尺寸；1 MiB 输出及背压；非零退出码；Ctrl-C；job suspension/resume；launcher SIGTERM；不支持协议
时启动前拒绝；私有元数据与两次 snapshot barrier/GUI 断连；混合标准流启动前拒绝；后台启动前拒绝。
暂停恢复场景还模拟 shell 收回前台，再以后台方式 continuation，必须保持暂停且不修改 shell 的
termios 或文件描述符可变标志；最终前台恢复才继续命令。测试只创建自身
合成 PTY，不读取用户 CLI。Darwin 恢复 ICANON 时可设置瞬态 PENDIN，比较仅忽略这一经独立最小
复现核实的内核 rescan bit，其他 termios 字段必须一致。描述符比较覆盖 `F_SETFL` 的可变标志
`O_NONBLOCK/O_APPEND/O_ASYNC`；普通 CLI `--help` 的独立最小复现证实 Darwin exec 会增加一个
不能由 `F_SETFL` 复原的只读 bit，不把它误判为本 launcher 的状态泄漏。

GUI 编译接缝覆盖同项目两个 session、tab/pane/window 搜索、新回执与最终失焦、用户干预、取消及
截止时间；生产模型和协调器只有精确返回才移除捕获的待接手版本。该证据不等于真实桌面点击。

末轮额外建立窗口预算回归：前窗口没有受管理回执、目标位于后窗口当前 terminal 时，原先深扫前
窗口会耗尽三秒。失败证据为 37 checks / 1 failure；导航器现在先选择并读回各窗口当前项，再执行
深层 tab/pane 搜索，聚焦回归 105 项通过。它仍不是任意隐藏布局的穷尽搜索。原生方向 chord 的全部
CGEvent 在派发前准备好、复验预算，同步入队过程中没有中间文件读取或任务挂起。

末轮 PTY 回归先得到 12 场景中的两项失败：暂停仍留下共享 `O_NONBLOCK`，以及后台启动修改了
终端焦点协议。修复后拒绝后台启动，并在暂停前恢复描述符标志；后台 continuation 再次暂停，前台
恢复后重设 raw/nonblocking。实际 Debug CLI 的 12 项与 worker 线程 harness 均通过。

实测曾发现 AsyncParsableCommand 的 worker 线程屏蔽信号，导致实际 CLI 的 SIGWINCH/SIGTERM
失败；C shim 现在保存、解除并恢复该线程信号 mask，harness 在同样的 worker 上执行再验证。
新增 C 模块也使既有手工 `swiftc` 编译探针缺少 module map；现已同时传入 `ClaudioVersionC` 和
`ClaudioPTYC` 的精确 include 路径，正向编译与负向断言均保留。POSIX PTY 流写入的源码审计只允许
两个固定 fd/参数形状的透传原语，不扩大通用文件写入例外。

helper 前一次末轮全套为 5188 checks / 1 failure，失败为 `HostIntegrationModelSuite.swift:68` 的
NVM shim 真实子进程版本读取断言；`--host-integration-model` 单独复跑 82 / 0，随后完整全套复跑
5188 / 0。本轮没有修改该 suite 或版本探测器，失败原因尚未定位；不把一次单独通过当作根因证明。
前轮 helper 全套为 5186 / 0，各次检查数以对应日志为准。

GUI 全套接线修复前为 15485 / 9，其中本次检查入口直接在 `MenuBarController` 读取
`Bundle.main` 违反已有合同。失败后将身份/环境判断移到 AppDelegate，原断言未改，
`--view-wiring` 复跑 277 / 0。修复后完整复跑为 15471 checks / 27 failures，本次接线失败消失；
既有 17 项 `PanelSettingsHandbackSuite` 和 2 项 `SettingsNativeShellSuite` 的原生窗口/key owner
前置再次失败。下表记录全部 27 项，未制造资产或放宽断言。

| 未改动 suite | 失败数 | 本轮错误 |
| --- | --- | --- |
| `EventAnimationIntegrationSuite` | 1 | 缺少 `Pixel Motion Prototype.html` |
| `ReleaseLayoutSuite` | 1 | selector 的六个 pack 与工作树实际仅一个版本化 pack 不一致 |
| `SettingsPresentationTargetSuite` | 6 | Bailian 服务管理附属表单夹具断言失败 |
| `PanelSettingsHandbackSuite` | 17 | 原生前台/后台设置与 key owner 前置未满足 |
| `SettingsNativeShellSuite` | 2 | 未取得真实 key window |

已修复本次新增 C 依赖引起的两项编译探针失败。较早两次全套为 27 项失败，其中
`PanelSettingsHandbackSuite` 的 17 项及 `SettingsNativeShellSuite` 的 2 项在 Mac 解锁后的复验中通过，
该次完整结果为 15468 checks / 8 failures；末轮上述 19 项再现。两次原生环境不同，不能把前一次
通过替代最新结果，也未定位前置变化的根因。未在干净基线运行同一完整门禁，因此只确认失败
所在的既有 suite，**不宣称已证明是基线失败**。日志中 `SourceScannerSuite` 自造并撤回的 14 条
负向证据不计入失败。不能由 `cgWindowNotFound` 和原生前置不满足推导共同根因。

## 历史阶段的原生验收

前半轮三次 Computer Use 获取 Zed 返回 `-10005 / cgWindowNotFound`。用户随后确认窗口可见、Mac
已解锁，重建 Computer Use 连接后成功读取真实窗口。创建了隔离项目的新 terminal A/B，通过最新
检查包的 launcher 启动自有 fixture；两条 PTY 连接均认证成功。fixture 从真实进程触发隔离
`hook codex PermissionRequest`，显示了生产横幅；这不是实际 Codex 会话发出的回调。

真实点击 A 的横幅后，Zed 应用回退成功，窗口仍选择 B，反馈准确显示“已打开来源应用，未定位到
会话”。Debug 诊断为 `accessibility_not_granted`、`authenticatedPeers: 2`；没有产生
`exactReturnConfirmed`。独立检查包没有辅助功能权限，Computer Use 自身的权限不能转移给该进程。
首次几次连接或点击还因四秒显示期限失去窗口；后用有界合成事件和保留的 CUA binding 完成点击，
没有延长产品显示时间或导航预算。负向证据在忽略的 `managed-native-permission-negative.json`。
没有绕过 Computer Use 操纵窗口；用户随后明确授权仅该检查包的辅助功能权限，并完成系统认证。
同包 ad-hoc 重签后，旧权限登记不再匹配；本轮只操作该包登记，没有为普通 Claudio 授予权限。
最新包再次刷新登记时，系统显示认证提示，尚未读回认证完成。四键授权后的续测已恢复窗口连接，
系统设置仍显示“隐私与安全”的认证框；最新包真实点击也继续报告 `accessibility_not_granted`。

为避免四秒横幅在观察前消失，Debug 检查包可用 `CLAUDIO_ZED_NAVIGATION_INSPECTION=1` 自动挂载
现有生产主面板，并保留它供原生测试。AppDelegate 在 composition root 核对检查包的精确 bundle ID
及两个显式实验开关；面板 controller 只接收已批准的呈现请求。普通 Release 不含这条
检查路径。面板的来源按钮与横幅共用生产模型和 `SessionNavigationCoordinator`，不增加窗口或
来源状态，也不延长横幅阅读时间和原始三秒导航预算。以下精确正向结果来自这个面板入口；最新
版本的横幅直接点击正向尚未验证。

授权后先得到真实窗口选择失败：40 ms AX IPC 返回 `cannotComplete`。编译窗口读回回归先为
113 checks / 2 failures，修复后为 113 / 0。原生适配现在把不确定 Raise 结果交给具体窗口读回，
每次 AX 调用最多 250 ms 且受剩余预算约束，完成后再复验取消、窗口、前台及期限。真实测试中仍
出现过不可用和超时；安静窗口下的后续请求得到以下成功，不能据此声称每次点击均稳定。

| 对照 | 实际导航结果 | 目标 PTY 新回执 | 提醒读回 |
| --- | --- | --- | --- |
| 同项目、同 pane、同 cwd：B → A，请求 54 | `exactReturnConfirmed`，认证 peer 2 | A sequence 5 → 6，A 聚焦且 B 失焦 | 待接手计数 0，详情显示来源已清除 |
| 同项目、同 pane、同 cwd：A → B，请求 34 | `exactReturnConfirmed`，认证 peer 2 | B sequence 319 → 320，B 聚焦且 A 失焦 | 待接手计数 0，详情显示来源已清除 |

请求期间没有人工选择目标 tab。上述两项来自窗口 IPC 修复版本，早于最新显式四键配置版本；最新
检查包仍须复测，不混用包身份。脱敏结果留在忽略目录的 `managed-native-tab-positive-A.json` 与
`managed-native-tab-positive-B.json`。

分屏 C 的真实失败确认默认方向 chord 不可用：Terminal context 将 `cmd-k` 绑定到
`terminal::Clear`，随后 `cmd-right` 发给 terminal 的 `ctrl-e`。手工对照也清屏且没有选择右侧 C。
固定官方源码与实测一致。最新实现已删除这条 chord；没有显式四键文件时返回
`pane_bindings_unavailable`，不再尝试清屏前缀。键位合同新增九项检查，聚焦结果为 122 / 0。
用户随后明确回复“授权分屏四键配置”。安装前复核标准目录归当前用户、无 symlink，且
`keymap.json` 不存在；仅以 `O_EXCL` 创建与版本化配置字节相同的文件。没有合并其他键位，
也没有重建或重签检查包。37 个来源哈希与两个包内可执行文件哈希均匹配已有身份清单。

通过自有 terminal 重启 A/B/C/D，左右分屏原语得到真实读回：

| 动作 | 目标与对照的新回执 | 证据范围 |
| --- | --- | --- |
| C → B：`ctrl-alt-cmd-shift-f16` | B sequence 1 → 2 且聚焦；C 保持失焦 | 官方 Zed 已加载向左绑定 |
| B → C：`ctrl-alt-cmd-shift-f17` | C sequence 1 → 2 且聚焦；B sequence 2 → 3 且失焦 | 官方 Zed 已加载向右绑定 |

这两项通过 Computer Use 手工按键，不是协调器自动导航的正向验收。随后在 A 活动时触发 C 的
真实隔离 helper 事件，详情读回 `zed-managed-native-C`，点击最新检查包的生产来源按钮：诊断为
`accessibility_not_granted`、`authenticatedPeers: 4`，C 没有新的 focus-in。界面仍保留待接手提醒，
反馈“已打开来源应用，未定位到会话”。因此没有把配置存在或手工切换记作 `exactReturnConfirmed`。
证据为忽略目录中的 `managed-native-four-key-left.json`、`managed-native-four-key-right.json` 和
`managed-native-four-key-source-C-attempt.json`。

继续准备上下分屏时，Computer Use 报告用户已切换 Zed；fresh observation 确认当前为工作窗口，
后续点击被拦截，未向该窗口输入测试内容。上下两键、自动分屏、跨窗口、最新包 tab 复验及原生
目标退出负向仍未完成。四个自有 fixture 通过私有 request 文件正常退出，均记录 `exited`，对应
进程已退出。恢复配置前复验安装时记录的 inode/device/UID 与完整字节哈希，将自有文件移动到
忽略的证据目录，恢复原先不存在 `keymap.json` 的状态；没有删除或覆盖用户新增文件。

末轮完整代码、Debug/Release 构建、签名、体积、格式和本地化检查已完成。较早恢复原生连接时，按
应用路径和 bundle ID 获取 Zed 均返回 `-10005 / cgWindowNotFound`；系统设置也返回同样错误。
inventory 仍报告两个应用在运行，但无法获得可操作窗口。四键授权后的续测已获得 Zed 和系统
设置窗口，故上述连接失败是历史结果，不能继续作为当前阻塞。当前未完成的是最新检查包的系统
认证和不受其他操作干预的正向导航测试；没有由旧连接失败推导认证失败的共同根因。

续测开始前已读回旧 A/B/C/D 的退出标记和 shell 提示符。续测结束后的进程退出与 keymap 恢复
已读回；测试窗口关闭和新 shell 提示符未再次确认，未关闭工作窗口。本地日志和脱敏结果保留
在忽略目录。检查包本轮未重签，没有新增一次签名登记要求。

真实 Codex/Claude Code 的交互回调、VoiceOver、任意复杂布局、Intel、签名发布与正式接受均未
验证。新会话经过 launcher 的可行路径不为已有普通 terminal 补上定位身份。

实现依据：[ADR 0019](../adr/0019-open-verified-source-applications.md)、
[ADR 0023](../adr/0023-return-to-verified-local-sessions.md)。
