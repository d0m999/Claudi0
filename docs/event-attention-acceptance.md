# Event Banner：实现与验收台账

## 2026-09-28：行动优先

本节是当前实施与证据；下方 2026-09-12–13 的记录保留为历史。范围来自用户确认的
Event Banner 行动优先计划；领域决定见 [ADR 0019](adr/0019-open-verified-source-applications.md)，
展示合同见 [DESIGN.md](../DESIGN.md)。本节对应本地提交，未 push、发布或替换运行中的正式 app。
开始时 HEAD 为 `82b1ee7a54c413f073e2d9cae9e52f2c5b858177`，工作树已有并行改动；本轮逐文件保留，
尤其保留既有本地化条目及已暂存内容。

### 已实现

- 默认 440pt，待接手胶囊 75pt、瞬时胶囊 67pt。主行使用宿主与动词短语，副行只展示已知项目和年龄。
  会话 ID、绝对日期时间、相对长式进入详情。小屏限宽，列表和详情滚动。
- 可注入当前时间的共享年龄投影；英中可见文本与 AX 标签使用同一次采样，向下取整。
  未知 `review` 使用「需要你查看／去查看」；信息通知维持中性；旧版本显示「已更新，请刷新」，
  来源和时间在真正过期时擦除。
- 文字进入详情；chip 打开经系统复验的来源 App，未知来源退为「查看详情」。详情展示 App 名称、
  打开、复制完整有效会话 ID 和独立移除。胶囊无计数入口，列表继续从菜单栏打开。
  瞬时关闭按钮在悬停／键盘聚焦时显形，始终保留可访问性动作。
- `EventNoticeModel` 唯一拥有 4 秒阅读预算，悬停／聚焦／展开共同暂停；单调时钟采样只供绘制。
  每个待接手版本独立保留最多 30 分钟，隐私期限不被暂停或视觉刷新延长。
- chip 使用固定 panel 底色承接事件色 12% 浅染／15% 交互底，事件色描边与正文色；深色渐变末端仍满足边界对比度。2pt 阅读时间轨、180ms 入退场、
  260ms 展开收起；字形静态；Reduce Motion 使用静态轨与即时切换。
- helper 只在有效接收通道分支捕获最多 16 层同用户祖先的 PID 和内核启动时间，schema 1 新增可选字段，
  旧消息与 8KiB 上限保持兼容。GUI 复验父链／用户／启动时间，选最近可激活 App；解析后不保留原始列表。
  来源目标绑定提醒版本，仅存在于内存，随移除、过期或隐私清空释放。
- App 级动作独立于精确会话返回；复用单在途、版本／epoch／代次校验和 3 秒超时。
  原实例有效则请求激活；已退出时先复验原位置及 bundle 身份，再不激活地启动并校验回调。
  迟到回调和用户已切走的前台不会触发后续激活。打开成功收起提示、保留提醒，并清除原窗口焦点归还。
- 原生检查发现无边框 `NSPanel` 默认不能成为 key window，现用 `EventNoticePanel` 仅在显式交互时授予
  键盘资格；自动展示仍不激活。复制会话 ID 取消在途打开时会清理等待状态，按钮可再次使用。

### 自动化与构建

环境：macOS 27.0（26A428）、arm64、Apple Swift 6.4。默认 MacOSX27 SDK 的 SwiftUI 宏插件缺失，
最小 `@State` 示例亦无法 typecheck；本轮通过的 Swift 命令均使用已安装的 SDK：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run --package-path helper claudio-tests
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run --package-path gui claudio-gui-tests
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run --package-path gui claudio-gui-tests --event-attention
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build -c debug --package-path gui --product ClaudioGUI
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build -c release --package-path gui --product ClaudioGUI
```

本机证据目录 `E`：`/var/folders/1m/2jsf455s4r7dx9t8l233n55c0000gp/T/claudio-event-banner-v30yyjfv`。
它包含日志、实际挂载截图、初始工作树快照与独立构建源码，未纳入 Git。构建仍有 CLT 搜索路径及
API 弃用警告，不宣称零警告。

| 检查 | 最终结果 | 日志（相对 E） |
| --- | --- | --- |
| helper executable harness | 4,186 checks，通过 | `logs/helper-final.log` |
| GUI 完整 executable harness | 11,327 checks，1 项既有失败，exit 1 | `logs/gui-full-final.log` |
| GUI `--event-attention` | 879 checks，0 failures，exit 0 | `logs/attention-final.log` |
| GUI Debug／Release product | 均通过，exit 0 | `logs/gui-debug-build.log`、`logs/gui-release-build.log` |
| 当前源码独立开发 bundle、签名、体积门槛 | arm64 ad-hoc，通过，exit 0 | `logs/dev-bundle.log`、`logs/release-size.log`、`logs/dev-bundle-signature.log` |
| 本轮 30 个 Swift 文件 strict format | 通过，exit 0 | `logs/swift-format.log` |
| 字符串目录 JSON、英中占位符与注册、diff 空白 | 均通过 | `logs/localization-json.log`、GUI harness、`logs/git-diff-check.log` |

GUI 全量已定位的既有失败是 `ReleaseLayoutSuite.swift:1235`：「App 图标必须保留右上信号点」。
该测试与 `assets/branding/claudi0-app-icon.svg` 均与开始时 HEAD 字节一致；HEAD 的 SVG 已不含测试要求的
`<circle cx="755" cy="303" r="22"`。本轮未修改该图标或放宽该断言。日志中 SourceScannerSuite 的
自变异探针会有预期失败输出，以 harness 最后总计为结果。

专项覆盖：年龄边界、全事件／原因／提问意图双语；4 秒及交叠暂停、版本替代、冻结刷新、30 分钟到期、
隐私失效；祖先断链／循环／异用户／PID 复用／无 App、旧 wire；App 目标变化、激活／重开替身、失败、
重复点击、3 秒超时、取消、迟到回调、打开保留提醒；英中 × 浅深 × 0/1/5/7/50 项、长文本、末行滚动、
300×180pt 详情。实际挂载胶囊覆盖 440pt 与 268pt 宽，鼠标分别命中文字、chip、关闭。
五种事件色在两种主题的渐变端点及 12%／15% 填充上检查正文 ≥4.5:1、必要图形／按钮边界 ≥3:1；
chip 最低正文约 11.38:1、最低边界约 3.06:1。
复制取消在途打开和深色紫色 chip 边界两项先由回归测试复现，再修复通过，见 `logs/attention-copy-regression-red.log`。
这些证据不证明真实宿主回调、VoiceOver 朗读或系统键盘路由。

### 原生检查与未验证项

使用临时 `ClaudioBannerProbe.app`，链接本轮产品模块和带结果观测的 controller 副本；通知为合成输入，
来源目标使用本机 Finder 的真实进程身份。它不构成真实 helper 祖先或宿主回调证据，也不是最终 bundle
验收。探针已退出；未改写正式宿主配置、回执或当前安装。状态日志见 `logs/native-probe.log`、
`logs/native-probe-action.log`。

| 项目 | 状态与边界 |
| --- | --- |
| 自动展示非激活 | 已观察：前台 PID 不变、app 不 active、自动面板无 key 资格 |
| 显式详情键盘资格 | 已观察：详情面板成为 key window；App 名称、打开、复制、移除可由 AX 获取 |
| 失败反馈 | 已观察：系统拒绝激活时显示失败；启动身份失配显示无法确认来源应用 |
| 真实 App 成功前台切换与退出后重开 | **未验证**：当前自动化会话的有效实例激活请求返回失败；替身通过不能替代实测 |
| Tab／Shift-Tab／Enter／Space／Esc | **未验证**：CUA 按键会切回探针控制窗，无法证明横幅内完整键盘路径 |
| IME、VoiceOver 实际朗读 | **未验证** |
| 系统 Reduce Motion、多屏／Spaces | **未验证**；仅有自动化投影与位置约束证据 |
| 真实宿主回调／真实 helper 祖先贯通、音频 | **未验证** |
| Intel、最低系统、universal、Developer ID、notarization、发布及正式验收 | **未验证**；本地产物仅 arm64 ad-hoc |

### 最终本地产物

开发 bundle：`E/source/dist/claudi0.app`。独立快照包含当前工作树的全部受跟踪文件与本轮明确新增文件，
共 656 个；它保留已有受跟踪并行改动。逐文件 SHA-256 见 `E/validation-source-sha256.json`，
最终回核原工作区与快照字节一致；原工作区 `dist/` 未被覆盖。以下命令在 `E/source` 根目录执行：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash scripts/dev-bundle.sh
bash scripts/check-release-size.sh dist/claudi0.app
bash scripts/verify-dev-bundle-signature.sh dist/claudi0.app
```

签名完成后再次测量（区别于组装脚本中的签名前检查）：

| 项目 | 最终大小／门槛（B） |
| --- | --- |
| GUI arm64 | 6,853,744 / 7,000,000 |
| helper arm64 | 3,137,712 / 3,250,000 |
| LoginItem arm64 | 54,144 / 500,000 |
| 非可执行资源 | 747,707 / 1,500,000 |
| bundle 正规文件总计 | 10,793,307 / 12,250,000 |

产物用于本机检查；自动化与本地签名不等于原生验收或可分发发布。

## 历史：2026-09-12–13


基线：`a33d077`。最终源码范围：`d2059b8`、`497f6fc`、`ed884cf`、`4160baf`（review 修复）、`e41587d`、
`2987fea`、`3143048`（对账轮）、`f0d99f0`（review 修复轮）、`ebdbed6`（第三轮修复），以及当前
本地提交的 Standards 命名/谓词收敛与最终证据重建改动。
日期：2026-09-12–13。环境：macOS 26.6.2、arm64、Apple Swift 6.3.3。
范围来自用户提供的 T1–T8 规格；评审发现由用户在会话中提供、未在仓库内跟踪，其修复即 `4160baf`，
对账轮与 review 修复轮的分拆见 `plan/FIX-EVENT-NOTICE-REVIEW-20260913.md`。
上述既有实现提交已推送到 PR #177；本轮修复已本地提交，未 push、发布或替换运行中的 app。

**总规格尚未正式验收。** 自动化、实际挂载视图、真实宿主回调与分发证据分开记录。
本文不把 synthetic、协议解码、构建成功或 ad-hoc 签名当成生产激活或正式验收。

## 已落地的合同

| 任务 | 实现 |
| --- | --- |
| T1 | ADR 0013 部分替代 ADR 0012；新增待接手提醒、提醒版本术语；schema 1 增加可选 `reason`、`observed_uptime`、`main_session_is_known`，不改 hook command、回执、活动摘要和配置 |
| T2 | 有界 stdin framing 后只解码一次宿主对象，来源和原因独立降级；Codex PermissionRequest 固定授权，Claude Notification 按已识别白名单分类；损坏/超长 ID 不截断复制，旧消息主会话身份未知 |
| T3 | 唯一 `EventNoticeModel` 持有最新和冻结版本，不可变来源载荷按版本共享，归并身份随版本擦除；完整主会话按 epoch、Surface、installation、projectKey、sessionID 归并；不透明 ID 按 UTF-8 字节区分；普通事件无历史/轮播；TTL 擦除每个旧版本来源与时间 |
| T4 | 动作捕获提醒 ID、版本、epoch、installation、能力代次；单在途、独立 3 秒截止、可取消 adapter；取消后回调失效；仅 exactReturnConfirmed 可作为导航移除依据；复制按实际结果反馈 |
| T5 | 独立横幅、五行列表、详情、空态；列表视口 270pt、行最小 54pt，全部 50 项可滚动；未知信息只在详情解释；过期/旧版本禁用动作，显式刷新切换内容；英中和 AX 投影同源 |
| T6 | 零项手动入口；保留统一 Settings 路由和既有焦点归还；动态静默不补播、不打断主动阅读；锁屏、睡眠、会话失活组成原因集合；禁用/退出使 epoch 和动作失效 |
| T7 | ingress 仍由 runtime 唯一持有，移入 Foundation-only GUICore 供真实队列测试；容量 128，每批 32 条或 4ms 后归还未消费消息；一次快照发布；徽标从首次变化起约 100ms 截止，显式移除立即更新；receiver I/O 每次最多 32 条并重验停止状态；原生 source timer 取消即解除闭包，token 释放自动取消 |
| T8 | 本台账与各包回归、实际挂载和资源测量；下面的真实宿主及人工门槛仍待验收 |

生产精确返回和按后续提交自动移除均保持关闭。验证过的测试替身可以启用提交清除，但它不是生产能力证明。
Stop、查看、复制和收起不移除提醒；移除原因区分用户操作、精确返回确认、后续提交、过期、容量和隐私清空。
容量保护当前阅读横幅、详情和在途动作；冻结内容不会因后续更新而延长自身 TTL。
最多保留 50 个最新版本、50 个冻结版本和 1 个瞬时版本；去重与顺序元数据各最多 256 条、最长 30 分钟。
同会话建立有效观察水位后，旧 schema（无有效 `observed_uptime`）或乱序观察的同会话更新被静默拒绝，
直至该顺序元数据过期；`observed_uptime` 在 schema 中仍为可选，但可选不等于水位建立后可绕过排序。
聚焦占位只保留安全身份，来源及发生时间擦除；刷新后可移走占位。零项不代表宿主任务完成。

## 自动化及资源证据

除注明项外，以下执行均返回 exit 0：

| 检查 | 结果 | 本机日志 |
| --- | --- | --- |
| helper Debug executable harness | 3,259 checks，通过 | `/tmp/claudio-attention-validation-final-jig8mg/logs/helper-debug.log` |
| helper Release executable harness | 3,222 checks，通过 | `/tmp/claudio-attention-validation-final-jig8mg/logs/helper-release.log` |
| GUI 完整 executable harness | 9,153 checks，通过 | `/tmp/claudio-attention-validation-final-jig8mg/logs/gui-full.log` |
| 最后一次 GUI 专项 | 337 checks，通过 | `/tmp/claudio-attention-validation-final-jig8mg/logs/gui-attention.log` |
| GUI Debug product | 通过 | `/tmp/claudio-attention-validation-final-jig8mg/logs/gui-debug-build.log` |
| GUI Release product | 通过 | `/tmp/claudio-attention-validation-final-jig8mg/logs/gui-release-build.log` |
| GUI/helper/LoginItem Release、组装及签名 | 通过，见下方产物表 | `/tmp/claudio-attention-validation-final-jig8mg/logs/dev-bundle.log` |
| 修改范围 Swift 严格格式 | 本轮 7 个 Swift 文件通过 | `/tmp/claudio-attention-validation-final-jig8mg/logs/swift-format.log`（strict 通过时无输出） |
| 本地化 JSON、占位符及注册 | JSON 检查与 GUI harness 通过 | `/tmp/claudio-attention-validation-final-jig8mg/logs/localization-json.log`、GUI 日志 |
| selector state、sound-pack candidates | 通过；Python 11 tests | 同目录 `selector-state.log`、`sound-pack-candidates.log` |
| 工作区 diff 空白检查 | 通过 | 同目录 `git-diff-check.log`（通过时无输出） |

完整 GUI harness 通过后，最后以 337 项专项复核事件提醒修复；同会话 watermark 拒绝缺失、
epoch 前及未来观察，瞬时项精确返回确认不再误走提醒移除。最终 Debug/Release 产物均使用这些修复后的源码。
构建仍有仓库已有的弃用 API / 测试捕获等警告，未将其表述为零警告。
早先与编译并行的一次 GUI 全量执行出现 SoundPacksEditorMutationSuite 两项收敛超时；
未改动该无关实现，之后串行全量通过，不据此宣称长期运行稳定性已验收。

2026-09-13 follow-up（`4160baf` 的对账轮）：`isAttentionRevision` 改名 `isAttentionReminder`
并收敛待接手谓词（纯重构，行为不变）；失焦接线断言由语句形态改为行为内容与接线存在性，变异验证
通过（等价 `guard` 改写保持绿、删除 `window.delegate = self` 时新断言按预期变红）；ADR 0013 补记
watermark carve-out。上表格式检查行此前为「6 个文件通过」，系 `4160baf` 对修复子集的重跑口径、
曾静默收窄原 28 文件声明，本轮按累计范围重跑并更正。本轮证据：GUI 完整 harness 9,151 checks
（该轮为含 5 项失败的 run 实测计数；同源码完整通过口径为 9,153，计数差系失败 suite 提前退出、
不对应任何源码增减，reconciliation 见下「review 修复轮」段），5 项失败与对账改动无关，均为本机 sandbox 环境既有失败（嵌套
SwiftPM manifest 解析、release-size fixture 的 stat 调用、SwiftPM dump 读取）；HitTargetSuite
悬停检查在六次全量执行中失败一次（基线及其余各轮均通过），判为与改动无关的偶发。
`--event-attention` 专项 337 checks 全过；GUI Debug product 构建通过；格式检查按累计 28 个
Swift 文件重跑通过（见上表）。本机 sandbox 内 SwiftPM 需 `--disable-sandbox` 才能运行，否则
manifest 编译被 sandbox_apply 拒绝。

2026-09-13 review 修复轮（来源：`plan/FIX-EVENT-NOTICE-REVIEW-20260913.md`，已提交为 `f0d99f0`）：
修复对账轮 review 的 actionable findings。① resignKey 失焦断言折入极性腿（闭包体不得出现
`!isInteractive`），断言消息标注「存在性+极性断言，不证明分支内归属；等价 guard 改写不得假红；
De Morgan 等价改写（`if !isInteractive` 互换两分支体）会假红，属已知边界」——消息终稿补入
`isInteractive == false` 式取反披露，见下「第三轮 review 修复」段；
变异实测：极性取反（`if !isInteractive`）判红、删除 `window.delegate = self` 判红、等价 guard
改写判绿、else-first 分支交换判绿（后两者为已披露边界：文本绊线不证明哪个效果属于哪个分支，
也不接受取反的等价重写）。② 台账头部「最终源码范围」补入对账轮三个提交。③ 证据表 GUI 完整
harness 行按本轮重跑更正为 9,153 checks 全过：对账轮记录的 9,151（该计数沿用对账轮段落自身的
记录、当轮未留存日志路径）含 5 项本机 sandbox 既有失败，失败 suite 提前退出使计数偏少，与本轮
9,153 的差值不对应任何源码增减（本轮测试改动为零新增 expect）；`--disable-sandbox` 重跑全绿。
本轮证据：`/tmp/claudio-review-fixes-20260913/logs/`（gui-full-final、gui-attention、
gui-debug-build、swift-format、mutation-a-rerun、mutation-b-rerun 及首轮四条变异日志）。
helper 各行沿用上轮证据（本轮未触碰 helper 源码）。

2026-09-13 第三轮 review 修复（本会话第二轮 review 的 actionable findings，已提交）：
① 台账自洽——对账轮段 9,151 的「较上轮 +1」叙述与 review 修复轮段的「失败 suite 提前退出」
叙述矛盾，统一为后者（计数差 2 不对应任何源码增减）；台账头部「未提交」前提过期，「最终源码范围」
补入 `f0d99f0`。② `EventNoticeModel` 提取 `isVerifiedSubmissionStart`（`requiresOrderedObservation`
与后续提交清除两处共享的 taskStart × verified-surface 谓词，纯重构）。③ resignKey 断言消息补披露
`isInteractive == false` 式取反边界（文本绊线能力边界，不新增断言腿）。
本轮证据：GUI 完整 harness 9,153 checks 全过（计数与上轮一致，零新增 expect），日志
`/tmp/claudio-review-fixes-20260913/logs/gui-full-r3.log`；变更的 2 个 Swift 文件严格格式重跑通过
（`swift-format-r3.log`，无输出）；`jq empty` 与 `git diff --check` 通过。helper 各行沿用上轮证据
（本轮未触碰 helper 源码）。证据表各行维持有效（源码改动对检查计数中性）。

2026-09-13 Standards judgement 与最终证据收口（本轮本地提交）：`EventNoticeModelSnapshot.recent`
及 `openRecent` / `closeRecent` / `refreshRecent` / `selectRecent` 等模型 API 改用领域词
`attentionReminders`，避免把只含待接手提醒的集合命名成通用近期历史；既有本地化 key、AX identifier
和面板焦点标识保持不变。`EventNoticeView` 两处移除按钮条件统一消费 `EventNoticeKind.isAttention`，
不再重复编码 `!= .transient`。行为与测试计数不变；本节及上表证据均绑定下述新独立源码快照。

可重复执行：

```bash
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift run --package-path gui claudio-gui-tests --event-attention
swift build -c debug --package-path gui --product ClaudioGUI
swift build -c release --package-path gui --product ClaudioGUI
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
git diff --check
```

专项回归包括：

- 0/1/5/6/50/51 项，完整身份及不完整/parent/旧消息身份，跨项目/安装与 Unicode ID。
- 暂停交叠、完整冻结版本、旧内容独立 TTL、重复 UUID、乱序观察、无效观察拒绝、元数据淘汰及容量阅读保护。
- Stop 不清除，提交清除默认关闭，缺失/相等/倒序/异常/parent 观察不清除。
- 双击、失败、永不完成后超时、取消/隐私/能力代次/版本变化后完成；精确返回只移除待接手提醒，瞬时项保留成功结果。
- 源码接线断言（delegate 赋值 + resignKey 闭包含未取反的 isInteractive 判别与 close()、键盘暂停解除
  的行为内容；极性取反、删除接线变异实测判红，等价 guard 改写实测判绿）在文本层守住失焦收起接线；
  else-first 分支交换与 De Morgan 等价改写属已披露边界（前者判绿、后者假红），不证明分支内归属；
  `isInteractive == false` 式取反不含 `!` 词元、判绿，同为已披露边界（第三轮补录）。
  真实失焦触发、外部点击及透传仍按下方人工门槛验收。
- 复制成功、失败和陈旧版本拒绝，隐私清空不覆盖用户主动导出。
- 实际调度器中取消或释放 token 后，30 分钟定时闭包捕获对象立即释放；没有被旧 asyncAfter 截止时间挂住。
- 真正挂载 `EventNoticeView` 到 NSPanel：英中、浅深主题 0/1/5/7/50 项、末行滚动、300×180pt 详情、256 字符无断点 ID、滚动后的实际按钮点击与失败反馈；HostingView 固有尺寸不能反向撑高受控窗口。
- 真实 ingress 的 1000 条/10 秒 synthetic 压力；真实 pipe/socket 新旧 wire、半包 stdin、声音失败独立性及 receiver FD 启停。

本轮实测：

| 测量 | 结果与范围 |
| --- | --- |
| 来源启用相对禁用的 helper 增量 | Release 100 对真实 pipe/socket，配对增量 p95 **0.44ms**，门槛 ≤30ms；启用 p95 2.91ms、禁用 p95 2.84ms。配对差值分位数不等于两个分位数之差 |
| stub hook 返回 | Release 100 次 p95 2.72ms；不代表真实播放器和真实宿主 |
| 半包 stdin 不关闭 | 配置 20ms；故障墙钟 21.02ms，含 poll 取整和 OS 调度 |
| 生产 ingress → model | 最后专项 synthetic 1000 条/10.000 秒，p95 **4.069ms**，门槛 ≤100ms |
| 首次徽标 | 最后专项实测 **101.180ms**；100ms 截止另由手动时钟断言，不被持续到达重置 |
| 常驻状态与 timer | 50/50/1 版本、256/256 元数据、128 ingress、至多 3 个模型 timer；隐私清空后计数归零；取消/释放 token 的实际捕获对象释放回归通过 |
| receiver FD | 100 次创建、发送、停止，FD 0..<1024 探测为 **3 → 3 → 3**；持续发送期间停止不迟到交付 |

实际调度延迟另行测量，不把 OS 调度等同于主动延长截止。
原有门槛不变：Release 来源链增量 p95 ≤30ms，accepted envelope 到模型 p95 ≤100ms，原生首次展示目标 ≤250ms。
20ms 是 stdin 的配置读取预算；poll 毫秒取整和 OS 调度可能产生墙钟超出，单独记录而不改预算。

## 独立 Release 产物

使用与本轮最终生产源码字节一致的独立快照运行原 `scripts/dev-bundle.sh`（GUI `Release -Osize`、
helper/LoginItem Release）。未启动该 app，未写工作区的 `dist/`。体积预算和脚本未修改。

签名后再次执行原 `check-release-size.sh`，全部通过
（`/tmp/claudio-attention-validation-final-jig8mg/logs/release-size-signed.log`；签名复验见同目录
`dev-signature.log`）：

| 项目 | 实测 | 原门槛 |
| --- | ---: | ---: |
| GUI arm64 | 5,575,536 B | 5,600,000 B |
| helper arm64 | 2,862,896 B | 3,250,000 B |
| LoginItem arm64 | 72,192 B | 500,000 B |
| 非可执行资源 | 686,919 B | 1,500,000 B |
| bundle 正规文件合计 | 9,197,543 B | 10,850,000 B |

GUI 无导出符号；原 `verify-dev-bundle-signature.sh` 通过。签名前 strip 门槛也通过
（GUI 5,589,912 B）；签名过程会改变 Mach-O 与资源封装大小，因此以上表格采用签名后的复检值。
版本为 `0.0.0-dev`，不是发布版本。

本机证据目录：`/tmp/claudio-attention-validation-final-jig8mg`；源码快照清单为
`validation-source-sha256.json`，构建日志为同目录 `logs/dev-bundle.log`。
清单覆盖当前全部 555 个 tracked 文件，并已逐项与最终工作树重算一致；本轮修改的 7 个 Swift 文件
与本台账均包含在内。
这些临时产物未纳入 Git，可能随系统临时目录清理消失。

- GUI SHA-256：`69dd8c919cc3d5c226a42969ace1b38a12e49aca97dce430b420dc2045e2fa3f`
- helper SHA-256：`79327cf9bcfdb28328d67b44ebc9c806285b4988705a99cff5f7ad2af5915878`
- LoginItem SHA-256：`6f6ac8fc24465a650980b96ab6d93c22f3054817a5e1ab0790ec8202f032ac24`
- bundle 文件哈希清单聚合 SHA-256：`3a90713b6c45af4341db27d7ae8df5add49bdab2d79674872ccbbdc9e8d18a7e`

## 尚未验证的人工或外部门槛

| 门槛 | 状态与所需证据 |
| --- | --- |
| 当前已实现 binding 的真实宿主回调 | 未验证；须逐一记录宿主版本、installation、binding 和真实脱敏回执；不能用本文 synthetic 输入代替 |
| 实际旧 GUI / 新 helper、旧 helper / 新 GUI 二进制配对 | 未验证；当前已有 frozen 旧 schema decoder 与旧 wire→新 receiver 的真实 socket 验证 |
| IME、FKA、VoiceOver | 未验证；中文组字不提交/不丢键，FKA 开关下 Tab/Shift-Tab/Enter/Space/Esc，VoiceOver 动作与反馈逐项验收 |
| 原生窗口和焦点 | 部分：挂载布局/鼠标动作已自动验证；运行 app 的 Settings 互斥、外部点击、精确 handback、多屏/小屏/全屏 Space/刘海和辅助显示设置未人工验收 |
| 锁屏/睡眠/失活交叠 | 模型回归与接线编译已验证，真实系统交叠未验证；只恢复一个原因不得重启 receiver |
| 真实音频 | 未验证；自动化只验证视觉与声音结果独立，不能代替扬声器/真实宿主声音验收 |
| 原生首次显示 ≤250ms、长期 RSS | 未测；队列到模型延迟、集合/计时器上限、receiver FD 循环不能代替这两个门槛 |
| Intel、最低 macOS 12 | 未验证；当前只有 arm64/macOS 26.6.2 环境 |
| Developer ID、universal、notarization、分发与正式验收 | 未验证；独立临时目录的 ad-hoc bundle 不建立这些结论 |

独立的 `verify-settings-experience.sh` 要求 clean HEAD，本次保留未提交工作，未将该脚本记为通过。
Settings 路由和窗口所有权的既有回归随 GUI 全量 harness 执行；正式提交后的集成台账需另行收集。

## 协议及系统依据

Claude 原因名单与主/子会话字段来自官方 [Notification](https://code.claude.com/docs/en/hooks#notification)
及 [common input fields](https://code.claude.com/docs/en/hooks#common-input-fields)；Codex 子会话结构参考
[官方 hooks 源码](https://github.com/openai/codex/blob/main/codex-rs/hooks/src/events/common.rs)。这些是协议依据，不是当前激活证据。

Apple 将 [sessionDidResignActiveNotification](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification)
定义为用户会话切出。因此它与锁屏原因分开处理。当前本机 loginwindow 二进制包含
`com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`，接线使用相应分布式通知；这仅是本机静态核对，
不能替代真实锁屏测试，也不构成 Apple 对这两个通知名的公开兼容保证。
