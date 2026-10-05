# 本地会话导航实施与验证（2026-10-04）

## 本轮原生接入（已实现，原生验收部分通过，真实宿主验收受阻）

本轮基线为 `main` / `f106df47b5931ab952107a2b1b3cf295fd1f9a06`。用户明确确认保留横幅外观并直接完成原生接入，无需再等 HTML。正文与待接手主按钮共用导航动作；普通横幅不新增主按钮；关闭、正文和主按钮是平级控件，阅读轨仍只展示。面板与诊断通过同一个 `EventNoticeReadingView` 调用唯一 `SessionNavigationCoordinator.navigateSource` 并消费同一反馈投影。

正文新增稳定无障碍标识、操作提示与焦点暂停接线。三类成功结果分别处理：只有精确返回收起捕获的横幅并移除对应待接手版本；应用回退和请求已发送继续剩余阅读预算。所有成功结果释放窗口的焦点归还责任；在途请求、失效版本和迟到回调受已有协调器约束。补强回退阶段的迟到宿主回调隔离，以及应用结果返回时的原始截止时间复验。父会话文案只来自已解析目标的明确父会话证据。

`CONTEXT.md`、`DESIGN.md` 和 ADR 0023 已同步，ADR 0023 状态为 accepted；ADR 0008/0019 追加替代关系。`plan/session-navigation-native.patch` 保留为历史并标明已替代，其中误传给阅读轨的交互参数未采用。两份未跟踪的宿主 hook 调研文档保持不变。本轮未 commit、push、发布或改变 issue 状态。

### 本轮自动验证

Swift 6.4，arm64，显式使用 `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`；以下 Swift 命令均从仓库根运行并使用 `--sdk` 指向该 SDK。bundle 脚本使用同一路径的 `SDKROOT`，构建描述中的 `-sdk` 已复核。

| 检查 | 结果与证据边界 |
| --- | --- |
| `swift run --package-path gui claudio-gui-tests --event-attention` | 最终独立运行 PASS：1111 checks，0 failures。覆盖普通/待接手正文与独立按钮实际挂载点击、英中明暗/窄宽布局、反馈与高度、父会话文案、重复派发、三类成功、失败重试、共享截止时间、版本/epoch/能力代次/关闭取消及迟到回调、阅读预算与暂停、原生阅读轨、IDE/tmux/焦点适配器 fixture |
| `swift run --package-path gui claudio-gui-tests --view-wiring` | PASS：338 checks，0 failures；生产 executable 装配接线的源码门禁，不代表实机键盘行为 |
| `swift run --package-path gui claudio-gui-tests --panel-settings-handback` | FAIL：130 checks，17 failures，均涉及原生 key focus。隔离导出的未修改基线 `f106df47` 使用同一 SDK 运行也为 130/17，失败断言逐条相同；不能把本项记为 PASS，也不能据此宣布实机焦点通过 |
| `npm test --prefix extensions/vscode` | PASS：10/10 |
| `node scripts/test-native-ui-regression.mjs` | PASS：16/16；只验证 CUA 驱动的模拟输入/布局断言，不代表执行了真实 Computer Use |
| GUI Debug product build | PASS；最终源码重新构建 |
| GUI Release product build | PASS；另由 dev-bundle 完成最终源码的 Release / full LTO / `-Osize` 构建 |
| `jq empty` / 已用双语导航键 / `allKnown` | PASS；复用现有应用回退、请求已发送与父会话键，无新增 UI 文案；en / zh-Hans 占位符匹配 |
| `git diff --check` | PASS；完整工作树 diff 已只读复核 |
| 完整 GUI/helper executable harness、其他 CPU 架构 | NOT RUN；本次未扩大为全套测试 |

保留一次压力门禁波动：最终 1111 项检查的首次运行有 1 项失败，accepted-envelope → model p95 为 364.662ms（门槛 100ms）；该轮与构建/应用启动阶段接近。未修改业务代码或放宽阈值，结束其他本轮构建与隔离原生进程后独立重跑为 1111/0，p95 7.519ms。尚未证明首轮波动根因，也不能由单次复跑排除间歇问题。此前版本的 1107 项运行已通过。

### 首次本地应用包与重启（Escape 复验修复前）

`SDKROOT=…/MacOSX26.5.sdk bash scripts/dev-bundle.sh` 成功生成 `dist/claudi0.app`。旧包先备份至 `dist/packages/20261004-114137-before-native-navigation/claudi0.app`。最终包为当前 arm64 架构、ad-hoc 签名；`verify-dev-bundle-signature.sh` 和 `check-release-size.sh` 独立复核通过。

- GUI：5,904,192 bytes；helper：3,219,296 bytes；LoginItem：54,144 bytes。
- 非可执行资源：2,414,198 bytes；bundle 正规文件合计：11,591,830 bytes（门槛 13,850,000 bytes）。
- GUI SHA-256：`c5a3aaf2f8d176e7969790dd57016945103eb50a970c4cf5dbd992bcc86ac110`。
- 旧进程退出后启动新包，确认是新的唯一进程且启动后持续存活；此项仅是进程重启检查，不是原生布局或焦点验收。

原生 harness 导出的英文待接手浅色横幅、中文普通深色横幅已目视核对：正文无额外装饰，普通横幅无主按钮，关闭独立，阅读轨保留。导出图片属于挂载 fixture，不冒充屏幕实机验收或真实事件回调。

### 首次原生与真实宿主阻塞（解锁前，保留历史）

Computer Use 能返回应用清单，但连接旧包和最终新包均返回 `-10005: timeoutReached`；隔离原生验证包已启动，其界面连接返回 `-10005: cgWindowNotFound`，隔离 readback 的 key window 为 `none`。隔离验证进程在检查后已停止。最终应用的新进程已保留运行。

Terminal 的 Computer Use 请求被工具直接拒绝：`Computer Use is not allowed to use the app 'com.apple.Terminal' for safety reasons.` 未改用脚本绕过该限制。因此本轮未完成真实 Terminal 精确 tab 返回，也未完成正文键盘聚焦、正常目标应用交接、第三方应用切走、VoiceOver 或其他宿主的屏幕操作验收。没有安装 VSIX、申请 Apple Events 权限或生成真实宿主 hook 回执。

当时待继续验证：正文/主按钮/关闭、普通横幅反馈与剩余时间、Tab/Space/Return/Escape、目标交接和第三方切走、至少一次真实 Terminal tab 返回，再按安装/授权条件验证 iTerm2、tmux、VS Code/Cursor 与 Codex 桌面。下方早期记录仅供追溯，不再表示当前原生接入或工具链状态。

### 解锁并打开设置后的 Computer Use 复验

用户解锁后，Finder 的界面树和截图恢复，但当前 Release 应用仍返回 `timeoutReached`；用户手动打开设置窗口后，当前 `dist/claudi0.app` 的界面树、截图及“活动与诊断”点击均成功。该页当时没有待接手记录，因此横幅、面板详情与诊断详情使用隔离 DEBUG 原生包验证。所有输入通过 `mcp__cua_repl`；未使用 AppleScript、系统事件脚本或其它 UI 输入渠道。

重新构建的首个隔离包为 `claudio-native-ui-build.GKrx9f`，构建清单确认与当时工作树逐文件一致。该包使用真实生产视图、控制器和协调器，来源应用为替代实现，时钟手动推进，不代表真实宿主精确返回或真实墙钟阅读时间。工具输出中的截图已目视核对，独立控件身份由 AX 树确认；本地读回快照保存在 `/tmp/claudio-navigation-cua-retest/`。

| 原生操作 | 本轮观察 |
| --- | --- |
| 待接手正文与主按钮 | 正文的 AX 点击及指针点击进入失败反馈；主按钮也能重试。同一记录应用回退后仍保留提醒，剩余预算为 3 秒，没有回到 4 秒。单次派发计数仍由编译回归证明，fixture 读回没有请求计数 |
| 普通横幅 | 正文和关闭可用，没有额外主按钮；失败、应用回退、三秒超时反馈均真实显示，反馈高度及阅读轨目视正常 |
| 在途禁用与关闭 | 正文及主按钮禁用，关闭可用；关闭后 `cancelled`，待接手提醒保留 |
| 面板与诊断 | `event-notice.reader.open-source` 可点击，失败和应用回退反馈一致；诊断三秒后显示超时并恢复按钮可用性，提醒保留 |
| 未确认来源 | 正文显示“在面板查看”，点击后直接打开对应记录详情；详情没有来源导航按钮 |
| 更新与过期 | 更新后旧详情仍冻结，导航、复制及移除禁用，要求显式刷新；刷新显示更新记录。推进 TTL 后来源详情被清除，提醒数为 0 |
| Escape | 初次真实按键未关闭，诊断证明 keyCode 53 到达横幅且 first responder 为 `EventNoticePanel`。补齐 AppKit `cancelOperation` 到既有 `close()` 的接线后复验通过：正文或主按钮启动的在途请求被取消，横幅收起，提醒保留；推进到原截止时间后仍为 `cancelled` |
| Tab / Shift+Tab / Space / Return | 未完成按钮聚焦与激活验收。按键到达横幅，但本机 `AppleKeyboardUIMode=0`，标准 Button 不进入 Tab 焦点；控制窗的普通 Button 同样没有 Tab 焦点。没有改动系统设置，也没有把 controller 的 `keyboardPaused=true` 当作正文获得焦点的证据 |
| 第三方切走与正常目标交接 | 未完成。Finder 选择、打开窗口及标题栏指针输入后，没有读回可确认的横幅失焦和取消。来源应用替代实现也不执行真实目标焦点交接；不能据此宣布通过或归因于生产导航 |

焦点诊断包为 `claudio-native-ui-build.jDhk4I`；最终修复包为 `claudio-native-ui-build.pC8lY1`，arm64 / SDK 26.5，bundle 清单 SHA-256 `2dbabf4d016348996ade4375e8b898110e46a76a16db761af688165a93479238`，40,960,587 bytes。最终包的源码清单与修复后的工作树一致（文档随后追加本段）；复验后全部隔离进程通过固定 fixture 退出动作停止。DEBUG 读回增加普通键事件和 first responder 诊断，不改变生产行为。

Escape 缺口的修复仅增加原生取消命令入口，沿用同仓库 `MenuBarPanel.cancelOperation` 的方式；它只在显式交互资格有效时调用原关闭入口，不增加自动抢焦点路径，也不增加导航状态所有者。新增三项原生边界断言及 executable 装配检查。macOS 标准按钮的 Tab 资格遵循系统键盘导航偏好，参见 [Apple FocusInteractions.activate](https://developer.apple.com/documentation/swiftui/focusinteractions/activate)；仍需在开启键盘导航的环境验证正文、主按钮、关闭的实际顺序及正文焦点暂停。

Terminal 的 Computer Use 请求在解锁后再次被同一工具规则拒绝：`Computer Use is not allowed to use the app 'com.apple.Terminal' for safety reasons.` 因而真实 Terminal 精确 tab 返回仍受阻。VS Code 1.140.0 与 Codex 26.930.31428 的标准安装元数据可读；VS Code 默认 CLI / 标准扩展目录没有找到 Claudio 导航扩展。iTerm2、Cursor 在 `/Applications` 与 `~/Applications` 标准位置未发现，未扫描自定义路径。未安装扩展、请求 Apple Events 权限或触发真实宿主导航。精确返回、Codex 的请求已发送、真实目标交接、VoiceOver、tmux 及其它真实宿主验收仍未通过。

Escape 修复后的定向重跑：`--event-attention` 为 **1115 checks / 0 failures**，压力 p95 7.976ms；`--view-wiring` 为 **338 / 0**；`--panel-settings-handback` 为 **130 / 0**。本次焦点检查未重现首次运行的 17 项失败，首次及未修改基线的失败证据继续保留，尚未通过受控对照证明差异根因。日志分别为 `/tmp/claudio-navigation-cua-event-attention.log`、`/tmp/claudio-navigation-cua-view-wiring.log`、`/tmp/claudio-navigation-cua-panel-settings-handback.log`。未重复扩大到完整 GUI/helper harness。

### 复验后的最终本地包与重启

最终源码 GUI Debug build 通过；SDK 26.5 的 `dev-bundle.sh` 完成最终源码 Release / full LTO / `-Osize` 构建。此前应用包备份在 `dist/packages/20261004-125309-before-native-escape-fix/claudi0.app`。新的 `dist/claudi0.app` 为 arm64 / ad-hoc 签名，独立签名和体积复核均通过：GUI 5,904,208 bytes、helper 3,219,296 bytes、LoginItem 54,144 bytes、非可执行资源 2,414,198 bytes，正规文件合计 11,591,846 bytes。

当前 GUI SHA-256 为 `851d9614662fe79c86aac3828366fd7136325ac1d5d4372097442a736fc568f8`；上方 `c5a3…` 属于首次修复前的历史包。启动最新包前旧 PID 12621 已不存在，未向其它进程发送退出信号；通过 Computer Use 启动新包后确认唯一新 PID 25533 对应当前完整 executable 路径且持续存活。启动后重新连接返回 `timeoutReached`，没有取得当前 Release 窗口的 UI 复验；生产启动和进程存活不代表原生布局或真实宿主验收通过。

证据：`/tmp/claudio-navigation-cua-debug.log`、`/tmp/claudio-navigation-cua-dev-bundle.log`、`/tmp/claudio-navigation-cua-signature.log`、`/tmp/claudio-navigation-cua-size.log`、`/tmp/claudio-navigation-cua-restart.json`。本地化 JSON 和 `git diff --check` 通过；完整工作树 diff 已只读复核。两份无关宿主 hook 调研文档 SHA-256 与本轮开始一致。未 commit、push 或发布。

### 阅读轨静止反馈的追加诊断

用户反馈横幅出现后进度没有变化，并随后确认横幅会自动收起。因此不能直接把用户所见归因于悬停暂停或手动 fixture。当前没有复现“按时收起但进度不动”的真实屏幕现象，尚未确认其根因，也未作生产绘制修复。

已复核 `EventNoticeReadingTrack.swift`、`EventNoticeReadingTime.swift` 和 `EventNoticeModel.swift` 相对本轮 HEAD 没有修改；轨道仍为 2pt、左 17pt / 右 13pt / 底 2pt 留白，使用原四秒阅读采样。系统 API 读回 Reduce Motion / Reduce Transparency 均为 false；这不是用户看到的窗口中 SwiftUI 环境值的直接证据。此前原生测试包使用手动时钟，`model.presentationUptime` 不会自行递增，所以它的进度会停留直到显式推进；该事实仅解释测试包的行为，不能证明用户反馈的来源。

新增独立 `--event-reading-live` 原生 harness：使用默认生产时钟和 `EventNoticeScheduler.live`，在 entering 的暂停采样阶段挂载生产 `EventNoticeView`，鼠标保持在窗口外，窗口不成为 key。在约 0.3 / 1.3 / 2.3 秒读取实际挂载的彩色像素长度，并在 visible 后 4.4 秒检查四秒阅读及淡出完成。覆盖普通 `Stop` 和待接手 `PermissionRequest` 的浅色、深色四种场景。窗口与独立事件色样统一为 sRGB，避免跨窗口显示 profile 导致判色误差；这些缓存绘制图片属于 harness 产物，不是 Computer Use 的屏幕截图或真实宿主验收。

`CLAUDIO_ATTENTION_SCREENSHOT_DIR=/tmp/claudio-reading-live-layout swift run --package-path gui --sdk …/MacOSX26.5.sdk claudio-gui-tests --event-reading-live` 最终 **PASS：92 checks / 0 failures**。

| 场景 | 三次实际彩色长度（pt） | 四秒预算及淡出后 |
| --- | --- | --- |
| 普通 / 浅色 | 376 → 274.5 → 173 | hidden，阅读采样清除 |
| 普通 / 深色 | 380.5 → 274.5 → 175.5 | hidden，阅读采样清除 |
| 待接手 / 浅色 | 378 → 273.5 → 173 | hidden，阅读采样清除 |
| 待接手 / 深色 | 369.5 → 267 → 161 | hidden，阅读采样清除 |

保留测试开发中的失败边界：首次将实时 suite 放入同步 layout 入口，真实 main-queue timer 未进入 visible，得到 1118 / 1；随后改为独立 AppKit 事件循环和异步等待。扩展四种颜色的首次测量为 92 / 32，图片本身已显示轨道缩短，诊断 RGB 读回证实独立 sRGB 色样与默认显示 profile 的窗口不一致；统一测试窗口颜色空间后使用原判色阈值通过，未改生产时钟或轨道。日志为 `/tmp/claudio-reading-live-event-attention.log`、`/tmp/claudio-reading-live-harness-final.log`、`/tmp/claudio-reading-live-color-probe.log` 和最终 `/tmp/claudio-reading-live-harness-final-srgb.log`。修正 macOS 12 测试 target 不支持 `Task.sleep(for:)` 后，使用既有兼容的 nanoseconds API。

同时为 DEBUG 原生包增加可选 `CLAUDIO_UI_REGRESSION_LIVE_CLOCK=1` 构建模式，直接使用生产 scheduler / uptime，自动展示时隐藏 fixture 的设置、面板及 controls，不主动聚焦横幅。默认手动模式保持原用途；清单和读回明确 clock mode，并补充阅读采样、暂停原因及横幅 window 状态。SDK 26.5 的实时包 `claudio-native-ui-build.pzTgH2` 构建和 ad-hoc 签名复核通过，bundle 清单 SHA-256 为 `ba31a79deefaa629175420e1dead7f54a00394a8d250634fa2567976c64b40d9`，40,963,773 bytes；它仅包含 DEBUG fixture，来源应用仍为替代实现。

Computer Use 在本次追加检查中返回新的 `Sky Computer Use native pipe startup failed`，应用清单也返回同一错误；重置工具连接后仍失败，实时原生包未能启动，未取得新的屏幕操作证据。默认显示 profile 的实际进度、键盘 / 焦点以及真实宿主验收继续受阻。未用其他 UI 输入渠道绕过工具。

本轮追加改动限于测试与 DEBUG 诊断，没有重打生产包；`dist/claudi0.app/Contents/MacOS/claudi0-app` 的 SHA-256 仍为 `851d9614662fe79c86aac3828366fd7136325ac1d5d4372097442a736fc568f8`。追加检查收尾时未发现 Claudio GUI 或隔离 fixture 进程；上节 PID 25533 是前次重启时的历史观察，不代表当前仍运行。没有本轮可确认的重新启动。

最终编译产物的 `--event-attention` 重跑 **1115 / 0**，`--view-wiring` 重跑 **338 / 0**；日志为 `/tmp/claudio-reading-live-event-attention-final.log` 与 `/tmp/claudio-reading-live-view-wiring.log`。native driver **16 / 16**、本地化 JSON、构建脚本语法和 `git diff --check` 通过。新增 diff 已只读复核，两份无关宿主 hook 文档 SHA-256 保持不变；`--panel-settings-handback`、扩展、生产 Debug / Release 构建沿用上节检查，本轮未重复扩大测试，未 commit、push 或发布。

## 早期实施记录（历史，原生待确认阶段）

源码基线：`main` / `7472120b54d5300015a1b0550951029f4b70d397`。本文记录本地提交前的实施与验证；未 push、发布扩展或发行应用。原先的原生参考资料、Onboarding 原型及 event-animation 验证文件未修改。

## 实施状态

公共合同、helper 有界采集/降级传输、唯一模型内存目标、统一导航入口、iTerm2/Terminal/tmux/IDE/Codex 适配器、私有 IDE socket、双语新增文案、Apple Events 构建配置和本地 VSIX 已实现。原始证据接收后释放；只有宿主读回确认才能消除捕获的提醒版本。固定 URL/动作不接受任意执行接口，回退和定位共享三秒预算；预期焦点交接在固定聚焦动作前显式标记。

用户计划第 4.1 节要求先确认 HTML 原型再改原生呈现。已发出确认请求，尚未收到答复。因此当前原生正文/主按钮/面板仍使用旧呈现和旧 App 入口；新适配器尚未成为原生按钮的正式导航能力。拟议呈现变更完整保存于 `plan/session-navigation-native.patch`，覆盖正文独立按钮、主操作统一入口、反馈、焦点交接、父会话标签、Panel 和 Diagnostics；已通过 `git apply --check` 及 Swift 语法解析，但未应用，也未取得完整类型检查或原生验收。

ADR 0023 为 proposed；DESIGN 的待确认段明确与现行“正文静态/App 打开即收起”合同的替代关系，未提前声明原生生效。此交付不是整个计划已完成。

## 自动验证

| 门禁 | 结果与边界 |
| --- | --- |
| `swift run --package-path helper claudio-tests` | PASS：4299/4299 |
| `bash scripts/test-session-navigation-core.sh` | PASS：196/196；编译真实 ClaudioGUICore 与不含 SwiftUI 的导航适配器，运行模型、原/新协调器、tmux 格式和真实私有 socket fixture；独立替代检查，不冒充完整 GUI harness |
| `node scripts/test-panel-settings-prototype.js` | PASS：106/106 |
| `python3 scripts/test-panel-settings-prototype-browser.py` | PASS：19/19；真实浏览器 HTML 检查，不代表原生呈现 |
| `npm test --prefix extensions/vscode` | PASS：10/10；固定动作、多窗口实例、取消、超时、失连、terminal 关闭、PID 歧义、主动切走 |
| `npm run package --prefix extensions/vscode` / VSIX ZIP 完整性 | PASS；`dist/claudio-session-navigation-1.0.0.vsix`，SHA-256 `476b6177446a2b1058381153dafbbbafee3536248f181cb28158c24602e8c660` |
| 完整 GUI executable harness | BLOCKED：Command Line Tools 缺少 `SwiftUIMacros.StateMacro` 插件，未执行测试 |
| GUI Debug / Release product build | BLOCKED：同一插件缺失；相关 `@State` 错误及不可变 self 诊断随之产生 |
| 新增导航适配器独立编译 / Runtime 独立类型检查 | PASS；后者使用单独生成的导航组件模块，不代表 GUI 产品构建 |
| `jq empty` / 新增 en 与 zh-Hans 键及 `allKnown` | PASS：新增三个无占位符键，匹配注册 |
| entitlement plist / bundle 脚本语法 / release 配置检查 | PASS：Apple Events entitlement 与用途说明均存在；本地 ad-hoc 签名仍保留既有无 entitlement 合同 |
| 本地 Claudio bundle、签名、体积 | NOT RUN：GUI 构建阻塞；未删除/覆盖旧 bundle 来重复失败，旧 artifact 不算本轮产物 |
| 原生待确认补丁 / `git diff --check` | PASS：可应用检查、语法解析、diff 空白检查；原生补丁尚未应用 |

提交前复核：导航核心 196/196、扩展 10/10、HTML 原型状态检查 106/106、本地化 JSON 与脚本语法检查均通过。helper 首次与导航构建并行重跑时出现 1/4299 项失败，输出截断未保留具体断言；随后单独完整重跑为 4299/4299 通过。没有为此修改业务代码，首轮失败原因尚未定位，不能据一次重跑排除间歇问题。暂存检查另发现补丁文件的空白上下文行被当作尾随空格；已规范为空行，`git apply --check` 仍通过，原生补丁保持未应用。

## 真实宿主验收

全部未验证。仅读取了版本/安装元数据，没有操作真实会话，没有安装 VSIX，没有请求 Apple Events 权限。

| 宿主 | 可读元数据 | 正确窗口/tab/pane/thread、键盘与 VoiceOver |
| --- | --- | --- |
| Terminal.app | 2.15 | NOT VERIFIED |
| iTerm2 | 标准 `/Applications/iTerm.app` 未发现；其他位置未查全 | NOT VERIFIED |
| tmux | 3.7c | NOT VERIFIED：server/client、detach/reattach、外层窗口 |
| VS Code | 1.140.0 | NOT VERIFIED：两个同工作区窗口、多个 terminal、真实扩展连接 |
| Cursor | 标准 `/Applications/Cursor.app` 未发现；其他位置未查全 | NOT VERIFIED |
| Codex desktop | 26.930.31428 / `com.openai.codex`，安装目录名为 ChatGPT.app | NOT VERIFIED；只允许 requestSent，不具备 thread 读回 |

最小化、其他 Space、全屏、目标关闭、权限拒绝、点击后立即切走、键盘焦点和 VoiceOver 仍待逐宿主人工验证。IDE 未连接不能可靠推断“未安装”（例如自定义 extension 目录/禁用/重载）；目前提供未连接、已验证连接、版本不支持状态及主动安装步骤，“未安装”专属状态尚未完成可靠检测。

## 本轮误操作与恢复（独立于 Claudio 交付）

读取 Codex 桌面元数据时，`plutil -extract … json` 未显式指定 `-o -`，误覆盖 `/Applications/ChatGPT.app/Contents/Info.plist`。已停止元数据探测并完成恢复：从官方同版本 `ChatGPT-darwin-arm64-26.930.31428.zip` 提取原文件；先验证 archive 的 `Contents/MacOS/ChatGPT` 和 `_CodeSignature/CodeResources` 与本机逐字节相同，再原子恢复 Info.plist。

恢复文件 SHA-256：`8b72fd3f7925f1c4dfc480bc20b769cb554a55eb56a9876848ac89fd2433bc90`（20810 bytes）。恢复后 `codesign --verify --deep --strict --verbose=2 /Applications/ChatGPT.app` exit 0，显示 `valid on disk` 和 `satisfies its Designated Requirement`。没有重签名、升级或替换主程序；本项验证的是误操作恢复，不是 Claudio bundle 签名。

## 历史下一步（已由本轮实施状态替代）

1. 用户确认整合 HTML 原型后，应用原生补丁并将 ADR/设计合同转为现行；补齐原生交互回归。
2. 在具备 SwiftUI macro 插件的完整工具链上执行 GUI harness、Debug/Release、本地 bundle 与签名/体积检查。
3. 用户主动安装 VSIX，按计划逐宿主进行真实跳转、焦点、拒绝权限和 VoiceOver 验收，再决定正式能力资格。
