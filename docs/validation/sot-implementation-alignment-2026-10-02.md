# UI、实现与 SoT 对齐记录（2026-10-02）

状态：源码与原型核对完成；实时原生 UI 核对 `BLOCKED`，当前增量的构建、行为与原生验收未由本记录证明。首次核对发现一项源码偏离，收尾期间并行实现已修正源码；运行与原生确认待补。文档同步不改变产品合同，也不构成正式验收。

## 核对快照与范围

- 提交边界补充（2026-10-03）：本次 Git 交付仅包含现行 SoT 文档、规格、来源索引及三个精确忽略规则。标为“工作树待提交”的实现、原型、素材和固定证据另行交付；source.json 保留核对当时的完整工作树指纹，不表示这些依赖已包含在本次提交或可由该 Git 快照单独重现。
- HEAD：`0f8b5a04fec6f03e982649f91e0c87581d496740`，包含八页迁移 `c310ede` 及显式设置焦点／声音详情退出修复；事件动画和本次文档同步仍在工作树。
- 源码快照：`2026-10-02T15:34:20.910896+00:00`。432 个源码、原型、运行资源及参考数据文件的指纹见 [source.json](sot-implementation-alignment-2026-10-02-source.json)，清单 SHA-256 为 `aa09de0be41f784f5690da3e2014043e51cd208f139c268185edccc62e71647d`。
- 共享工作树在核对期间有并行修改。本记录绑定上述快照；未清理、提交或推送工作树，也没有把并行构建过程记为本次验证通过。
- 收尾复核：`2026-10-02T15:43:52.357746+00:00`，同一清单有 10 个并行源码文件变化；更新后的清单 SHA-256 为 `f1af3e96c1a41fc4461c534e6a3fbd8a76b502dbdef6feec8e94663cd7f583e4`。原始快照保留，变更指纹记于 source.json 的 `followup`。关键路由、保存、可见性及资源合同已重新读取，该时刻 EA-D01 仍成立；这次再核对也不代表构建或原生验收。
- 并行修正复核：`2026-10-02T15:48:18.179507+00:00`，资源 owner、通知总览、详情和回归 suite 又有四处源码变化，清单 SHA-256 为 `03ef74b48d7ea594c7333ba52b74c261f3dde4c817feef6f166c7521ee6ded89`，见 source.json 的 `parallel_fix_followup`。EA-D01 已统一有效样式投影，状态更新为“源码已修正，运行与原生验证待补”。原发现和两个较早快照保留。
- 最终只读回执补充：`2026-10-02T15:53:47.526306+00:00`，窗口 controller 的 DEBUG 几何回读新增 first responder／键盘访问／phase 字段；生产可见性接线未改变。清单 SHA-256 `f913e55e0582a845b489f618e6ad3c62706cd7a8b28f7ab65cde6a8a9650c276` 及单文件变更记于 source.json 的 `final_readback_followup`；没有把这些回读字段视作实际原生操作通过。
- “已落地”在下表仅表示生产源码具有对应接线。实际呈现、操作与验收分别记录；实现现状不自动取代已确认合同。

## 当前来源与合同

| 范围 | 合同来源 | 实现与证据边界 |
|---|---|---|
| 八页设置及详情／sheet | [DESIGN](../../DESIGN.md) 的 macOS 八页设置章节、[#215 规格](../../plan/PLAN-MACOS-SETTINGS-MIGRATION.md)、[设置原型](../../designs/macos-settings-native/claudi0%20macOS%20Settings%20Prototype.html)，HTML SHA-256 `f49c338fde51a03fa4ada9b5f31f071a281e6708038dbac609f3c7931b93fe91` | 生产 `SettingsRootView`／session／原有 owner；原生迁移证据是绑定当时版本的历史记录。 |
| 菜单栏、面板、横幅正文与阅读轨 | [整合原型](../../designs/panel-and-settings/Panel%20and%20Settings%20Prototype.html)、DESIGN 对应现行章节、ADR 0008／0013／0019／0022 | #216 只增加角色呈现，不改变来源动作、提醒语义、四秒阅读预算或窗口归属。 |
| 角色画面与播放规则 | [#216 规格](../../plan/PLAN-EVENT-ANIMATION.md)、Pixel Motion Prototype（工作树待提交：`designs/pixel-motion/Pixel Motion Prototype.html`），SHA-256 `d2b3cf0e8440785149a803e6927e72171bceb30892afdd218d31da2bd21529c4` | 图集、时序和静态帧从源原型导出，资源由 GUI executable 拥有并注入。 |
| 动画设置呈现 | 八页设置合同及 动画设置原型（工作树待提交：`designs/macos-settings-native/Animation Settings Prototype.html`） 的 A 并排布局 | B/C 比较器、浏览器内存演示及原型循环开关属于探索工具，未进入产品范围。 |
| 领域语义与事实 owner | [CONTEXT](../../CONTEXT.md) 及对应 ADR | 本次不新增领域模型或事实 owner。#215 原范围的“不新增字段／公共 API”不覆盖 #216 明确规定的后续动画偏好和子路由增量。 |

## 实现差异矩阵

| 分类 | 用户可观察合同 | 当前实现依据与结论 |
|---|---|---|
| 已落地（源码接线） | 八页、固定页头、单主滚动区、单列功能组、系统字体、中性表面、原生控件 | [SettingsRootView](../../gui/Sources/ClaudioSettingsPresentation/SettingsRootView.swift)、[SettingsAppearance](../../gui/Sources/ClaudioGUIComponents/SettingsAppearance.swift)、[SettingsPageLayout](../../gui/Sources/ClaudioGUIComponents/SettingsPageLayout.swift)、[SettingsDestinationPage](../../gui/Sources/ClaudioSettingsPresentation/SettingsDestinationPage.swift) 实现 #215 的呈现结构。当前窗口的实际绘制尚未在本次读取。 |
| 已落地（源码接线） | 唯一 retained 非激活窗口、显式展示恢复键盘资格、显式退出声音详情清理生成与草稿 | [RetainedSettingsWindow](../../gui/Sources/ClaudioGUIComponents/RetainedSettingsWindow.swift) 与 [SoundPacksWindowView](../../gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift) 复用现有归属和清理链；不新增窗口或状态 owner。 |
| 已落地（源码接线） | 通知 → 事件动画；四种样式、五类事件、重播、显示角色／静态开关、原版隐藏角色专用开关 | [SettingsNavigation](../../gui/Sources/ClaudioGUICore/SettingsNavigation.swift)、EventAnimationSettingsView（工作树待提交：`gui/Sources/ClaudioSettingsPresentation/EventAnimationSettingsView.swift`） 与生产 root 已连接真实 typed 子路由和偏好。 |
| 已落地（源码接线） | 默认原版、选择立即保存、关闭显示记住角色、损坏或未来配置保留原始字节 | EventAnimationPreferences（工作树待提交：`gui/Sources/ClaudioGUICore/EventAnimationPreferences.swift`） 与 [SettingsPreferences](../../gui/Sources/ClaudioGUICore/SettingsPreferences.swift) 使用唯一 `ClaudioPreferences` owner；明确用户修改才替换存储。 |
| 已落地（源码接线） | 返回入口焦点、离页／隐藏／关闭停止独立预览 | [SettingsPresentationSession](../../gui/Sources/ClaudioSettingsPresentation/SettingsPresentationSession.swift)、[SettingsWindowController](../../gui/Sources/ClaudioGUI/SettingsWindowController.swift)、EventAnimationPreviewSession（工作树待提交：`gui/Sources/ClaudioGUICore/EventAnimationPreviewSession.swift`） 已连接对应生命周期。当前真实 Tab 和焦点操作未验证。 |
| 已落地（源码接线） | 设置预览和真实横幅共用资源、播放器及内容；异常回退、原因与重试，保留选择 | [MenuBarController](../../gui/Sources/ClaudioGUI/MenuBarController.swift)、EventAnimationResources（工作树待提交：`gui/Sources/ClaudioGUIComponents/EventAnimationResources.swift`）、EventNoticeBannerContent（工作树待提交：`gui/Sources/ClaudioGUIComponents/EventNoticeBannerContent.swift`） 连接 GUI 资源、后台解码与缓存。通知总览已由并行实现统一到资源 owner 的有效样式投影；EA-D01 的原发现与当前验证状态见下节。 |
| 已落地（源码接线） | 动作沿用公共 Event／规范化原因与同一阅读预算；Reduce Motion 使用声明静态帧，装饰角色不重复朗读 | EventAnimationTimeline（工作树待提交：`gui/Sources/ClaudioGUICore/EventAnimationTimeline.swift`）、EventAnimationView（工作树待提交：`gui/Sources/ClaudioGUIComponents/EventAnimationView.swift`）、[EventNoticeView](../../gui/Sources/ClaudioGUIComponents/EventNoticeView.swift) 保留原事件、来源跳转、提醒保留期限和窗口合同。源码接线不证明实际 VoiceOver 或系统 Reduce Motion 操作。 |
| 检查已实现、当前运行未验证 | 时序边界、像素参考、偏好恢复、预览隔离、故障恢复及 32 组原生布局 | EventAnimationIntegrationSuite（工作树待提交：`gui/Tests/ClaudioGUICoreTests/EventAnimationIntegrationSuite.swift`） 和 原生操作 driver（工作树待提交：`scripts/event-animation-native-regression.mjs`） 已具备对应检查。本次未运行，不能从脚本或注册推断通过。 |
| 未完成／需后续证据 | 当前工作树的原生操作、布局可读性及适用工程门禁 | 实时原生工具两次 inventory 读取超时，随后直接探测 claudi0.app 也超时；当前 #216 的构建、harness、32 组原生矩阵、键盘、故障恢复与 bundle 门禁没有在本轮取得回执。#215 历史记录中仍欠的详情／异常、VoiceOver 和真实系统／宿主／Provider 项继续按原边界保留。 |

## 偏离记录与修正状态

### EA-D01：通知总览未反映资源失败后的原版回退

状态：原始快照的源码偏离确认；并行实现于收尾期间已修正源码并增加回归，运行与原生故障／恢复验证待补。本轮文档同步没有修改实现，也没有放宽 SoT。

[#216 规格](../../plan/PLAN-EVENT-ANIMATION.md) 要求通知总览显示有效样式，资源异常回退原版并保留选择。首次核对时 [SettingsRootView](../../gui/Sources/ClaudioSettingsPresentation/SettingsRootView.swift) 的 `notificationsSettings` 直接显示 `preferences.eventAnimation.effectiveStyle.localizationKey`，没有消费资源失败事实；详情页（工作树待提交：`gui/Sources/ClaudioSettingsPresentation/EventAnimationSettingsView.swift`） 的 `status` 已通过 `resources.failure(...)` 投影失败后的 `.original`。

原始静态反例：选择机械小鸭且显示开启，资源校验失败时，横幅与详情回退原版，通知总览仍显示机械小鸭。

收尾源码已增加 `EventAnimationResources.effectiveStyle(for:dark:)`；通知总览和详情均消费该唯一资源 owner 的投影，未加载或失败时显示原版，记住的偏好仍独立保存。回归 suite 已新增校验失败回退与恢复后重新显示角色的断言。这里只确认代码变化；后续仍需执行对应回归，并补绑定当前构建的原生故障／恢复操作证据。

## 历史验证与当前验收

| 证据 | 当前解释 |
|---|---|
| 2026-10-01 HTML 验证快照（工作树待提交：`designs/macos-settings-native/VERIFICATION.json`） 及六份 JSON／七张截图 | 原 HTML 与全部证据指纹仍匹配。保留原日期、基线、通过数值和交付状态；其中“待批准／未交付”描述当时阶段。不能改写成当前原生或 #216 通过。 |
| [八页原生迁移记录](macos-settings-native-2026-10-02.md) | v27 的 64 组合、行为与工程结果由其自身源码／候选／fixture 边界解释；表中未完成项继续保留。当前增量不能沿用旧候选通过。 |
| 本次源码与资源盘点 | 生产接线、合同来源及文件依赖可核对；不证明当前源码构建通过、实际布局、声音、原生键盘、VoiceOver、真实系统操作或发布。 |
| 实时原生 UI 核对 | `BLOCKED`：`mcp__cua_repl` 的 `cua.getState()` 连续两次约 30 秒超时并重置 kernel；随后直接 `cua.getApp(...)` 探测本地 `dist/claudi0.app`，仍返回 `timeoutReached`（server error `-10005`）。三次尝试均未取得窗口、AX 或截图。没有把超时当作产品缺陷或已验证。 |

原生工具可用后，应对绑定当前构建的通知总览、动画子页、四样式、五事件、返回焦点、关闭／隐藏、资源失败与恢复，以及双语／明暗／两尺寸逐项补证据。未运行的适用门禁保持 `NOT VERIFIED`；真实音频、系统权限、宿主回调、Provider 和发行证据继续单独记录。

## 资源与归档决策

- 当前源原型、运行图集／时序、两份 provenance、1,083 条播放参考及 480 条像素参考来源一致。数值是参考数据规模与静态盘点结果，不是本次运行 harness 的通过数。
- 并行工作已刷新原先不一致的三张 root 预览；17 张 root 预览现在登记于 `samples/provenance.json` 的 `previewFiles`，且 export_runtime.py（工作树待提交：`designs/pixel-motion/export_runtime.py`） 的 `check_only` 逐个校验。它们已成为新 checkout 的检查输入，应保留；此前建议的 `*-preview` 通配忽略不再适用。
- `samples/E/`、`G/`、`H/` 的图集、时序、APNG 和 contact sheet 属于规范样本；运行包仅使用 `gui/.../Resources/EventAnimations/`，导出检查仍依赖样本，不能忽略整个目录。
- ZIP 是可重建分发输出；两个比较 GIF 没有当前源码、原型或检查引用。仅对这三个明确路径添加 `.gitignore`，保留文件本身。
- 历史方向稿和已被替代的横幅稿登记于 [归档索引](../../designs/ARCHIVE.md)，保留 Git 历史及原路径，不搬移并行工作的文件。

## 本轮检查

以下为本轮实际检查；历史记录的通过不算本轮执行。

- 已执行：源码／原型合同与资源引用核对，含并行变更后的关键源码再读取；原生工具两次 inventory 读取及一次直接 app 探测（均 `BLOCKED`）。
- 文档检查：9 份 Markdown 的 251 个本地链接逐个检查；修正两处源码链接后全部存在。11 个本轮文档／忽略规则文件无尾空白；完整工作树 `git diff --check` 通过。
- 来源与历史证据：source.json 原始清单及 followup 重算一致；14 份原始验证 JSON／截图文件与本轮开始时逐字节 SHA-256 相同，原型及被记录证据的 SHA 校验一致。
- 忽略规则：`git check-ignore --no-index --stdin` 精确命中三个本机输出；83 个必需路径仍可进入 Git，包括 17 个 `previewFiles` 输入、正式资源、规范样本、参考 JSON、检查脚本和历史证据。
- 只读 Standards／Spec 双轴复核：修正上述来源链接后，本轮文档／忽略规则没有新增 actionable finding；EA-D01 的原始发现保留，当前并行源码修正及回归新增已复读，运行与原生验证仍待补。
- 未执行：helper／GUI harness、类型检查、Debug／Release 构建、资源重新导出、浏览器回归、bundle、完整设置门禁、原生矩阵与真实外部操作。本轮仅改文档与忽略规则，共享工作树另有并行实现／构建。

## 提交准备复核（2026-10-03）

- 提交范围为 11 份现行文档与忽略规则，包含 DESIGN 已确认的 #216 合同及完整事件动画规格；原生实现、原型、素材、固定证据和既有删除均排除。
- 27 个未提交目标的 44 处 Markdown 链接改为明确的“工作树待提交”路径引用，保留来源角色、日期和指纹。此前 251 个链接的结果属于完整工作树核对；当前 208 个本地活链接均可在拟提交 Git 快照中解析，不将待提交路径当作已交付依赖。
- source.json 的四个历史清单指纹重算一致；11 份文件无尾空白，完整工作树 `git diff --check` 通过。115 个范围外文件的存在状态及内容指纹与提交准备开始时一致。
- 本次仅验证文档交付边界、链接、指纹和 whitespace，未增加构建、harness 或原生验收结论。
