# 官方 Zed 来源识别与应用回退验证（2026-10-09）

本文保留来源识别及早期研究阶段的证据。用户后续授权的 Debug 受管理新会话导航已实现，当前结果
以 [受管理导航实施与验证](zed-managed-navigation-2026-10-09.md) 为准；已取得生产协调器路径的真实
tab 双向精确返回，跨窗口与分屏验证继续进行。下文的未支持结论属于此前普通 terminal 阶段。

来源识别修复已实现：官方 Zed 的 `Zed → /usr/bin/login → shell → 宿主进程` 链可通过有限的系统 `login` 校验，并由 GUI 复验。普通 Release 与既有 Zed terminal 继续使用 `applicationFallback`；这一来源识别路径不产生 `exactReturnConfirmed`。

工作位于独立 Git 工作树，分支 `codex/zed-login-navigation`，基线 `7f0533605ff77380f973d3fe1986499ab4f43723`。未提交、推送、发布或改变 issue 状态；主工作树中的其他开发改动不属于本轮。

## 实现与回归边界

- helper 与 GUI 共用 `HostProcessAncestry.read` 和 `HostProcessReadEnvironment.live`，没有第二份来源状态。普通读取可接受时不增加内核、路径或签名查询。
- 普通读取不可接受后，仅内核可执行路径恰为 `/usr/bin/login` 的进程可以进入 `sysctl(KERN_PROC_PID)` 路径。有效 PID／启动身份、有效 UID 为 root、真实 UID 为当前用户、运行中 Apple `com.apple.login` 签名及查询前后的身份／父 PID／UID／路径一致性缺一不可。
- `systemLogin` 是本机类型，保留在完整祖先链并计入 16 层上限。未知进程、其他用户、断链和循环仍不能被跳过。类型、UID、路径和签名不进入消息，wire 身份字段仍只有 PID 和启动时间。
- TTY 的 `terminalProcess` 排除系统 `login`，复验启动身份后继续绑定存活 shell；Terminal／iTerm2 的既有导航身份与路由保留。
- Zed 沿用现有应用回退、文案、单次在途请求及原始三秒截止时间。应用打开、失败或超时均保留提醒和剩余阅读预算。消息 schema、产品数据路径、本地化和横幅外观未改。

新增 `SystemLoginAncestrySuite.swift` 与 `ZedSourceNavigationSuite.swift`，在各自 executable harness 注册。覆盖完整真实模式的注入重放，以及权限拒绝、错误 PID／启动身份／有效或真实 UID、非系统路径、签名失败、PID 复用、微秒变化、父链变化、路径变化和查询期间退出。GUI 测试通过生产模型、来源适配器与协调器重放同项目两个独立 terminal：只激活同一个 Zed 实例，不派发精确宿主导航、不移除提醒、不重置阅读预算；2.99 秒回调为应用回退，3.0 秒回调超时且不能迟到激活。

保留测试先失败的证据：初次祖先链回归为 36 checks / 3 failures；加入共享 TTY 回归而尚未排除 `login` 时为 37 checks / 1 failure。两处行为修复后新增和相关用例全部通过。日志分别为 `claudio-zed-login-red.log`、`claudio-zed-terminal-red.log`。

## 自动检查

环境：arm64，macOS 27.0.1（26A434），Apple Swift 6.4。默认 SDK 27 的 GUI 构建因本机缺少 `SwiftUIMacros.StateMacro` 插件失败；依照 `CONTRIBUTING.md` 使用已安装的 SDK 26.5 完成 GUI harness 和产品构建，没有改动源码或仓库构建配置来绕过问题。

GUI Swift 命令的前缀为：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift run --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  --package-path gui claudio-gui-tests
```

| 检查 | 结果 |
| --- | --- |
| `swift run --package-path helper claudio-tests` | PASS：5094 checks / 0 failures |
| `helper/.build/debug/claudio-tests --system-login-ancestry` | PASS：96 checks / 0 failures；包含原祖先链和导航证据套件 |
| `gui/.build/debug/claudio-gui-tests --zed-source-navigation` | PASS：68 checks / 0 failures；使用 SDK 26.5 的最终编译产物 |
| GUI harness `--event-attention` | PASS：1590 checks / 0 failures |
| 完整 GUI harness（SDK 26.5） | FAIL：15431 checks / 9 failures，见下表；新增 Zed 用例通过 |
| GUI Debug product build | PASS：`swift build -c debug --build-system native --sdk …/MacOSX26.5.sdk --package-path gui --product ClaudioGUI`，同时设置上述 `SDKROOT` |
| helper Debug product build | PASS：`swift build -c debug --package-path helper --product claudio` |
| 本地 Release bundle | PASS：`CLAUDIO_BUILD_SDK=…/MacOSX26.5.sdk bash scripts/dev-bundle.sh`；GUI／helper Release、LoginItem、ad-hoc 签名和体积门禁通过 |
| `bash scripts/check-release-size.sh dist/claudi0.app` | PASS：GUI 6,704,160 bytes；helper 3,160,576；LoginItem 54,208；资源 2,493,925；bundle 正规文件合计 12,412,869 |
| 定向 `swift format lint --strict` | PASS：四个改动的 core 文件和两个新增 suite |
| `jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings` | PASS；复用现有双语反馈键，没有新增文案 |
| `git diff --check` | PASS |

完整 GUI harness 的九项失败位于本轮未改动的检查或资源范围内，未为了使全套变绿而修补它们：

| 失败位置 | 数量与观察 |
| --- | --- |
| `EventAnimationIntegrationSuite.swift:266` | 1：缺少历史文件 `designs/pixel-motion/Pixel Motion Prototype.html` |
| `scripts/test-sound-pack-selector-state.js:20` | 1：选型板列出六个包 ID，隔离工作树中实际受 Git 管理的包只有 `minimal-chime`；未复制主工作树的忽略包或制造资源 |
| `PanelSettingsHandbackSuite.swift:186` | 1：菜单收起后 Settings 键盘焦点断言失败 |
| `SettingsPresentationTargetSuite.swift:676` | 6：`bailian-beijing` 的 permissions-checked／verified／unavailable／probing／replacing／save-failure 附属表单断言失败 |

没有运行未修改基线的完整对照 harness，因此上述分类不等于已经逐项证明基线失败。`SourceScannerSuite` 故意制造并撤回的两组七项故障不计入最终九项失败。

## 官方 Zed 与原生横幅检查

保留 `/Applications/Zed.app`，版本 1.23.2、bundle ID `dev.zed.Zed`，签名为 Zed Industries, Inc.（Team `MQ55VZLNZQ`）。`codesign --verify --deep --strict /Applications/Zed.app` 在检查后通过；未替换 Zed、安装扩展或新增权限。

用本轮生产源码构建并运行 `dist/zed-navigation-evidence/Claudio Zed Navigation Inspection.app`。这是独立 bundle ID 的 Debug 检查包，使用既有 `CLAUDIO_TEST_HOME`／`CLAUDIO_TEST_ROOT` 和宿主适配器隔离目录，不启用来源应用替代实现。GUI 来源读取、模型、协调器、原生横幅和墙钟均为生产实现；启动可执行路径与 12 个相关生产文件的 SHA-256 已复核。其目录隔离是 Debug 检查用途，不是产品数据路径迁移。

通过 Computer Use 在 Zed 中建立检查项目 A 的两个 terminal，以及检查项目 B 的 terminal，分别运行隔离 helper 的 `hook codex PermissionRequest`。载荷使用合成 session ID 和检查项目目录；这是实际 helper 进程、系统祖先链、GUI 接收及原生横幅，**不是实际 Codex 会话发出的回调**。

| 观察 | 结果与证据边界 |
| --- | --- |
| 三个实际 terminal 的进程读取 | 普通读取均不可用；内核查询均返回 root 有效 UID／当前用户真实 UID、有效启动身份、路径 `/usr/bin/login`、Apple login 签名；生产读取接受 `systemLogin`，并保留其 Zed 父进程 |
| 同项目 terminal A、B 的实际横幅 | 均显示检查项目 A 的待授权事件；各次点击 `event-notice.body.<UUID>` 后，AX 和截图读到“已打开来源应用，未定位到会话” |
| 检查项目 B 窗口的实际横幅 | 显示检查项目 B 的待授权事件；点击正文后同样读到准确的应用回退反馈 |
| 点击后的应用读回 | 三次成功点击后，`NSWorkspace.shared.frontmostApplication` 均为 `dev.zed.Zed`；不把这个读回记为 terminal／tab／分屏／窗口定位确认 |
| 剩余阅读进度 | 三次成功点击的截图均仍有横幅及部分剩余进度；精确的预算数值、不移除提醒和三秒截止时间由编译接缝回归验证 |
| 从其他应用切回 Zed | NOT VERIFIED：尝试切换到其他应用后，没有取得可靠的前台变化对照；不能由点击后 Zed 已在前台推断此前切换成功 |
| Computer Use 的窗口获取 | 横幅可见时 AX、点击和截图成功；无可见窗口的菜单栏应用初次连接及末次重复检查仍出现 `-10005: timeoutReached`，未把超时算成通过 |

本轮原生检查部分通过，**完整原生验收未完成**。真实 Codex 回调、从其他前台应用／其他 Space／最小化状态返回、键盘焦点顺序和 VoiceOver 未验证。Terminal／iTerm2 只验证了编译接缝兼容，没有新增真实宿主精确导航验收。Zed 的各 terminal 精确跳转仍明确未支持，取得官方版可用且能读回确认的接口后才另立实施计划。

检查结束后本轮 terminal 进程已退出；独立检查应用在复核其完整可执行路径后停止，已有 Zed 项目窗口保留。没有升级、重签名或退出官方 Zed。

## 证据留存与交付

本地检查包、`inspection-identity.json`、`native-smoke-results.json`、只读进程／前台应用 probe 和日志保存在本工作树被忽略的 `dist/zed-navigation-evidence/`。自动检查日志副本位于其 `logs/`，包含 helper 全套／聚焦、GUI 全套／聚焦／event-attention、Debug 构建、dev-bundle 和初次失败回归。原生 AX 与截图来自本轮 Computer Use 工具输出；未将宿主配置、回执、原始来源身份或检查包加入 Git。

本地 Release bundle 仅为当前 arm64 架构、ad-hoc 签名的检查产物。x86_64、macOS 12、Developer ID 签名／公证、发布与正式验收均未验证或未执行。实现和检查不构成发布授权。

## 首次后续精确导航与 Vibe Island 静态调查

用户追加要求解决具体 terminal / pane / tab / window 后，完成 [官方 Zed 与商业 Vibe Island 调查](../spike-zed-exact-navigation-2026-10-09.md)。在自建 Zed 测试窗口内运行两个独立 PTY 探针，实际取得两个 terminal 的 focus-in 和 command palette 引起的 focus-out；探针到期恢复 terminal mode。这验证焦点读回能力，没有完成按事件来源身份选择目标 terminal 的导航器，没有接管已有 CLI 输入。没有启动或修改商业 Vibe Island。

Vibe Island 1.0.51 的安装包静态证据指向数据库目录匹配与 project route，未验证同工作区多 terminal 的唯一定位。官方 Zed 数据库的 GPUI window ID、目录快照和 CLI Exit status 均不能直接替代目标 terminal 焦点确认，本轮没有新增该生产路由。

调查后再次运行 helper 聚焦 suite：96 checks / 0 failures；GUI 聚焦 suite 使用 `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`：68 checks / 0 failures，日志为 `logs/zed-source-navigation-vibe-followup.log`。默认 SDK 27 仍在 `SwiftUIMacros.StateMacro` 插件缺失处构建失败；SDK 26.5 复跑通过。本地化 JSON 与 `git diff --check` 再次通过。未重跑已记录的全套或重新封包，生产代码在此调查期间没有改动。

## 继续研究与真实对照测试

用户随后要求“接着研究，测试”。本次实际启动既有商业 Vibe Island 1.0.51，并点击当前任务的四次来源卡片；这与上一节未启动商业应用的早期调查分开。原生结果与固定源码依据记录在 [调查的后续实测章节](../spike-zed-exact-navigation-2026-10-09.md#本轮原生对照vibe-island-1051)。

- 商业应用从另一 workspace 或独立 Zed 窗口可以回到 Claudio project；同项目另一 pane 的放大与普通布局两次对照均未返回来源 pane。四次点击日志均为 `zedProject(path)` 的单步 project route。结果限定本机该版本、本次配置，不外推到所有版本或所有 terminal。
- 自建窗口中同目录的三个独立 PTY 探针完成 5 次身份匹配回执：双向 tab、双向 pane、返回已有原生窗口。2 个真实负向区间没有目标新回执；旧回执与错误 instance 的 2 个重放检查被拒绝。新回执延时 11–1702 ms 仅计算最后选择动作，不能当完整三秒导航预算达标。
- 并行测试与其他操作者改变焦点。一次 pane 选择取得新回执后在预算内再次失焦；未把一次 `focus-in` 或目标窗口截图记为最终精确成功。尚未实现自动导航器、真实 CLI 的 PTY 透传 bridge、启动身份防 PID 复用、Claudio 自身的 UI 控制权限及最终前台联合确认。
- 六个宿主配置/插件文件前后存在性、字节 SHA-256 与 mode 一致。Vibe Island 安装包摘要不变，测试后正常退出并复核进程结束；官方 Zed 的 `codesign --verify --deep --strict` 通过。三个自有 probe 均恢复 terminal mode 并退出，自建窗口已关闭，用户既有窗口保留。

本次新增的 probe 与结果分析均为忽略目录中的隔离研究工具，结果留在 `focus-return-prototype/native2-results.json` 与 `vibe-native-followup/jump-log-redacted.json`，不进入消息、配置、产品日志或 Git。没有新增生产导航代码、修改官方 Zed、增加权限、提交或发布。生产来源识别修复继续保留，精确 terminal/pane/tab/window 返回仍未接通；自动套件结果沿用上节已执行的记录，本次没有重复跑全套或封包。

## 2026-10-10：受管理新会话的实现结果

以上“精确返回未接通”限定原来源修复与研究阶段。用户随后授权实现，已接通 Debug launcher、
身份验证 PTY bridge 和有界 window/tab/pane 搜索；官方 Zed 的七项生产面板/协调器原生返回得到
目标新回执与最终焦点确认。普通 Release 和已有普通 terminal 仍是应用回退，不会因本实验
取得精确能力。当前聚焦检查 135 / 0，helper 完整 5188 / 0，GUI 完整 15484 / 27（未改动 suite
的资产/夹具/原生前置失败，尚未证明是基线失败）。最新包兼容分支原生复验与直接横幅正向因
Computer Use 失去窗口连接未完成；认证此前已完成。包身份、矩阵及清理结果见
[当前实施验证记录](zed-managed-navigation-2026-10-09.md#当前结果2026-10-10-续测)。
