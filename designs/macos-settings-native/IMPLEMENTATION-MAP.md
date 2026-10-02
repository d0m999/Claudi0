# macOS 设置：实现映射与能力边界

2026-10-01 的历史源码盘点基线为 `7ca63a4af0497b74b53e89225ccf4de30d900c12`；当时只补齐独立原型、配套说明与浏览器回归。2026-10-02 已将八页原型固定为 #215 的设置呈现基线，原生迁移和后续修复分别交付。本文同步合同、实现接缝与证据边界，不把源码存在或历史通过项视为当前原生验收。

八页设置的唯一呈现基线为 [claudi0 macOS Settings Prototype.html](<claudi0 macOS Settings Prototype.html>)；[DESIGN.md](../../DESIGN.md) 的现行八页章节记录呈现合同，[#215 迁移规格](../../plan/PLAN-MACOS-SETTINGS-MIGRATION.md) 规定范围与验收。该基线覆盖 #214／#213 冲突的设置皮肤、独立事件卡、主辅栏与固定操作栏；[整合原型](<../panel-and-settings/Panel and Settings Prototype.html>) 继续拥有菜单栏、面板和横幅。领域、持久化和窗口焦点仍按 `CONTEXT.md`、ADR 与既有 owner。

[八页原生迁移记录](../../docs/validation/macos-settings-native-2026-10-02.md) 保存迁移阶段的生产映射、原生矩阵和未完成项；[当前对齐记录](../../docs/validation/sot-implementation-alignment-2026-10-02.md) 保存本次源码／原型差异及现场观察边界。#216 动画为后续授权增量，单列于下文，不改写 #215 的旧范围和历史证据。

## 1. 能力映射入口

[CAPABILITY-MATRIX.md](CAPABILITY-MATRIX.md) 保留 2026-10-01 的完整盘点：**C01–C48 共 48 项**均关联“原生入口／已有 owner 能力／原型呈现”，记录 HTML `data-action`、`data-control` 或稳定 ID、条件状态、预期结果与回归 ID。该表是 #215 能力索引；HTML 控件标识不新增生产接口或持久化合同，也不代替当前原生可达性与结果验证。

| 页面／合同 | 对照项 | 原生主要接缝 |
| --- | --- | --- |
| 默认组／工作区 | C01–C07 | `PanelConfigController`、`EventSettingsWindowSelection`、`WorkspaceDirectoryResolver`、`SettingsSoundReturnContext`、`SoundPackLibrary` |
| 声音包、提示音、音频与草稿 | C08–C20、C26 | `SoundPacksEditorOwner`、`SoundPackLibrary`、`PackFork`、`SoundPackAudioImportExecutor`、`AICuePackDraftTransaction` |
| AI 服务、凭据与候选 | C21–C26 | `AICueProviderRegistry`、`AICueCredentialManager`、`AICueComposer`、`AICuePackScoped` 及现有生成／采用链 |
| 集成 | C27–C29 | `HostIntegrationPresentationStore`、`IntegrationDestinationModel`、`HostCapabilityBinding`、既有 manager／adapter 与回执投影 |
| 通知 | C30–C32 | `ClaudioPreferences`、`EventNoticeHealthStore`、`DynamicQuietPolicyController` |
| 通用 | C33–C35 | `ClaudioPreferences`、共享 language store、`LoginItemSettingsModel` 与平台 adapter |
| 快捷键 | C36–C37 | `GlobalShortcutSettingsModel`、`GlobalShortcutRegistrar` 与既有 persistence adapter |
| 活动与诊断 | C38–C43 | `ActivityOverviewProjector`、`LocalActivitySummaryStore`、`ActivityDiagnosticsModel`、独立 log store、`EventNoticeModel`、`SessionNavigationCoordinator` |
| 关于 | C44–C46 | `AboutSettingsModel`、`AboutBundleFacts`、`AboutBundledResourceKind`、既有 resource／clipboard adapter |
| 焦点、目标与生命周期 | C47–C48 | retained settings owner、`SettingsPresentationSession` 与现有 editor/session lifecycle |

表格关联领域 owner 与原型操作；当前生产映射和实际验证范围另见对应原生记录。可达性、状态和结果是否正确须有绑定候选的证据，不能由表格或旧浏览器回归推断已通过。

## 2. 已固定的八页外壳映射

| 呈现合同 | 生产映射 | 保持的边界 |
| --- | --- | --- |
| 默认 1240×820、最小 960×640；侧栏 252/210、断点 1100 | retained AppKit 设置窗口及现有尺寸约束 | 单一 app-lifetime owner、非激活展示与关闭归还，不新增窗口。 |
| 系统字体；页名约 17、主标签 13、辅助 11–12 | 设置局部系统字体和文本样式 | 不继承 Rounded，不修改面板、横幅或全产品字体。 |
| 八页统一白色／深色主底、灰色侧栏、轻灰功能组 | 设置局部语义色与标准 AppKit／SwiftUI 控件 | HTML chrome／材质只是近似，原生 Increase Contrast／Reduce Transparency 另验。 |
| 单列最大 780，包含内边距；左右 32／窄窗 26 | 每页一个主 `ScrollView`，重排已有 editor supplement | 声音辅助内容进同列，不复制 owner、不形成第二主滚动区。 |
| section 28、group 16、圆角 10；行最小 48／多行 61 | 设置局部 group／row 与组内分隔线 | 长英文、错误与路径自然增高，最小窗口操作可达。 |
| 八页三组、组间 24 | 既有 typed `SettingsDestination` | 不添加搜索、通用 history、帮助或退役显示页；历史 `display` 兼容由现有代码拥有。 |
| 条件详情与工作区定向编辑后返回 | `SettingsPresentationSession`／`SettingsSoundReturnContext` | 返回只导航，不撤销配置，不恢复失效候选；返回前重验身份。 |
| 官方 Claude／Codex／WorkBuddy 图标 | 已记录静态原图与 Codex 深浅变体 | 保留原色／比例，不网络加载；来源和 SHA-256 见 README。 |

尺寸是项目已固定的呈现参数，不是 Apple 官方要求。继续保持 macOS 12 支持范围，较新材质／API 需兼容分支。外壳与页面迁移已有独立实现记录，完整验收仍按 #215 规格逐项记录。

## 3. 逐页合同

八页顺序保持：默认组／工作区、声音、集成、通知、通用、快捷键、活动与诊断、关于。生产 raw route 为 `events-and-sounds`、`sounds`、`integrations`、`notifications`、`general`、`shortcuts`、`usage`、`about`；HTML 首项为 `page=events`，不能据此改动生产 route。

### 默认组／工作区（C01–C07）

- 作用域、选包、独立音量、五事件试听／自动开关与定向编辑／返回共用现有配置与声音事实 owner。自动开关关闭不单独禁用手工试听；零音量、缺声、播放器／安全失败都有具体原因与恢复入口。
- 名称由目录派生。创建选择目录／包，解析 Git 或普通目录范围并明确确认音量，五事件初始全开；零来源合法并说明当前不适用。Claude Code／Codex 资格沿目录证据，WorkBuddy 当前不可选；无自定义名称或更换已有目录。
- 删除只删捕获规则，项目和声音包保留，取消无写入。迁移、损坏规则、写冲突、备份／读回与重试沿现有能力。失效目标不可写，显式选择默认组才进入可写目标。
- 库加载／刷新、最近成功快照、失败／重试与空库分开，刷新失败不伪装空库；不增加第二扫描／缓存 owner。

### 声音包与提示音（C08–C20、C26）

- 查看与“用于当前作用域”分开，管理作用域、当前使用与共享使用者可见。普通复制自动命名，只查看副本；复制并应用捕获明确目标，应用失败保留副本，不改其他组。复制与 AI 采用旁披露整包许可／作者声明变化，独立归属资料和未知元数据沿既有合同保留。
- 包许可、Finder、单包／整库工厂恢复、删除保护与在途禁用可达。恢复只重建工厂内容，保留用户包及组选包；用户包无工厂恢复。有效引用或引用不完整禁止删除，部分结果按实际隔离／保留状态显示。
- 面板显示集是 `SoundPacksWindowStarredPacks`／`soundPacksWindowStarControl` 已有能力补回设置原型，新增最多四项；损坏包或已有第五项可取消星标，不授权恢复生产面板声音包画廊。
- 五事件可选文件／系统音、试听、单事件导入与清除绑定；占用原因可见，写入再次校验，既有重复可修复。系统音只存名称，不进音频清单；内置包先复制再编辑，映射由 `SoundPacksEditorOwner` 独占。
- 未绑定音频可直接指派或删除，删除前重验占用，无独立试听。多文件添加的成功项保留，失败与取消不冒充回滚；导入成功但绑定失败报告文件已保留与旧映射未改。清单失败、manifest 定位／重试和工厂恢复失败分开呈现。
- 未发布草稿只由 AI 采用或系统音首绑定发布；此前无普通文件导入、复制、应用。草稿名可保存／取消，已安装包无改名。首绑定失败／取消不发布空包；成功查看用户包但不自动应用。

### AI 服务与生成（C21–C26）

| 固定 profile | 能力与候选身份 | 凭据政策 |
| --- | --- | --- |
| `elevenlabs-global` | 中／英文语音、混合、动物、音效；三个真实风格候选 | 只读 probe 后验证并保存／替换，Keychain。 |
| `minimax-global` | 中文语音；三个编号候选 | 只读 probe 后验证并保存／替换，Keychain。 |
| `qwen-singapore` | 中／英文语音；三个真实风格候选 | 保存不生成／不做模型验证，待显式生成验证；独立地区 Keychain slot。 |
| `qwen-beijing` | 中／英文语音；三个真实风格候选 | 同上，地区／slot 独立，无跨地区 fallback。 |
| `senseaudio-cn` | 中文语音、动物、音效；编号候选。语音完整三个，SFX 可按路线政策提供 1–2 个并明示 `N/3`；无 mixed | 只读 probe 后验证并保存／替换；ADR 0015 私有本地文件、未加密、非 Keychain。 |

能力与 candidate policy 由 `routes.keys`／路线拥有，不新增 Provider、任意 endpoint/model/voice。凭据分别显示检查、缺失、验证、延迟验证、拒绝、不可用与待替换；保存、替换、取消替换和确认删除保留逐 profile 政策及失败旧值。

描述是必填创作输入，名称／事件不发给服务。生成保留并锁定描述，支持取消、修改描述、重生成和试听；候选共享 `adoption-name`，名称不改变风格／编号身份。明确采用前不写包，在途禁冲突操作，失败保留旧绑定并如实呈现部分结果。

五事件顺序为用户发起、响应结束、执行中断、等待介入、子任务结束，沿 `Event.allCases`；稳定 ID `task_start`、`stop`、`stop_failure`、`notification`、`subagent_stop` 不变。

### 集成（C27–C29）

三来源选择与开关独立，选择不连接；连接／断开确认、修复、升级、检测、失败和在途禁用复用 manager／adapter。未连接、旧接入、等待当前回执、需处理、已激活分开；配置修复成功只到等待回执。

支持、实现、当前激活为三个事实。Codex 执行中断不支持；WorkBuddy 执行中断支持但未实现，当前实现覆盖 4/5。最新当前回执与脱敏历史分开，清除只作用当前来源。普通声音入口保留手动作用域，不随来源选择改组。

### 通知（C30–C32）

横幅偏好与接收器 ready／disabled／unavailable 及失败码分开，不固定“健康”。Focus／Calendar 的策略、授权与已有系统设置入口独立。七种当前静默原因、三种快照健康、观察／发布失败与过期可达，过期／不可确认不持续静音；不改包、音量、事件开关或手工试听。Calendar 只使用最小忙碌事实。

### 后续事件动画增量（#216，独立于 C01–C48）

八页顶层身份保持不变，新增「通知 → 事件动画」详情。原版、机械小鸭、像素幽灵和比特币采用 A 并排布局；角色画面、逐帧时长、循环和静态帧由 Pixel Motion Prototype（工作树待提交：`designs/pixel-motion/Pixel Motion Prototype.html`） 唯一拥有，指纹 `d2b3cf0e8440785149a803e6927e72171bceb30892afdd218d31da2bd21529c4`。布局与真实触发语义分别沿现行原生设置合同和领域模型，不以动画推断宿主任务状态。

| 增量 | 当前接缝与唯一职责 |
| --- | --- |
| 通知入口与详情 | `SettingsRootView`／typed `SettingsRoute`／`SettingsPresentationSession`，复用 retained 窗口；不新增第九个顶层目的页。 |
| 样式、角色显示与静态偏好 | `EventAnimationPreferences` 定义值，唯一 `ClaudioPreferences` 保存并发布 `Claudio.Notifications.EventAnimation`；异常保留原始值至显式选择。 |
| 四秒隔离预览 | `EventAnimationSettingsView` 消费会话的 `EventAnimationPreviewSession`，不写真实提示、不播放声音或操作宿主。 |
| 资源与逐帧解析 | GUI executable 的 `EventAnimationResourceComposition` 注入资源；`EventAnimationResources` 读取／解码，Foundation `EventAnimationTimeline` 负责确定性帧解析。设置 target 不拥有资源。 |
| 原生角色与横幅 | 设置预览及真实横幅消费共享 `EventAnimationView`／`EventNoticeBannerContent`。动画沿现有阅读预算和暂停边界，不新增计时事实 owner。 |

这些路由与字段由 [#216 规格](../../plan/PLAN-EVENT-ANIMATION.md) 后续授权，独立于 #215 原迁移不新增接口／配置合同的范围。其资源、交互和异常验证不能计入旧 48/48 浏览器用例。通知总览资源失败投影的 `EA-D01` 原发现、并行源码修正及待补验证，以及现场 `BLOCKED` 见 [当前对齐记录](../../docs/validation/sot-implementation-alignment-2026-10-02.md)，不改变失败回退原版与保留选择的规范。

### 通用与快捷键（C33–C37）

语言即时翻译全原型及 ARIA／sheet／错误，跟随系统显示解析语种，用户内容保持原值；损坏偏好沿现有恢复事实。登录项四态、等待批准与恢复可达，失败保原值，无窗口生命周期伪设置。

三快捷键覆盖录制、取消、清除、损坏值，以及校验／注册／持久化／回滚异常。按当前 key-code 规则拒绝裸键、仅 Shift／Option、保留键与 app 内重复，组合含 Command 或 Control。Escape／离页／关闭取消，失败报告实际注册结果；无新监控或权限。

### 活动与诊断（C38–C43）

三摘要、来源明细与五事件计数来自现有投影；六统计态为 ready／empty／unobserved／unavailable／stale／partial。刷新保最近成功数据，清理后可能 partial；近七日为今天及前六个本地日期，无七日日柱图／日志条数／工作区统计。

日志存在／缺失／损坏／不可读分开，显示大小、路径、最多五条脱敏失败及 Finder／复制。提醒首次阅读冻结、显式刷新、旧版拒绝、过期清空；有效会话才可复制，打开失败／超时保提醒。打开来源应用不声称精确会话或任务完成。日志、计数、回执和提醒各自清理，互不替代；阅读不改横幅预算。

### 关于（C44–C46）

版本、构建、架构、最低／当前 macOS 与未知值沿 bundle／system facts，不推测。开源许可、声音归属、隐私三个独立资源，缺失有原因、打开失败可见。安全诊断先显示在可选择区域，再复制同内容；版本／诊断复制失败就近反馈。仅包含显示的脱敏字段，无真实目录／凭据／宿主内容。

## 4. 焦点与生命周期（C47–C48）

详情返回只导航。定向编辑捕获规则／目录身份、包和事件，返回前重验；保存仍生效，失效不跳可写默认组。取消 sheet 恢复触发焦点，目标消失则聚焦可见原因。切目标、包／profile／事件、离页与关闭停止试听、清理候选／空草稿，迟到结果不得改新目标；录制取消与提醒消费者释放沿相同边界。

已移除设置搜索、通用前后历史、帮助、已安装包改名、复制自定义名、已有工作区改目录／自定义名、声音页整包试听和未绑定音频独立试听，不留待新增接口。

## 5. 历史八页演示与证据边界

声音包、目录、连接／回执、计数、提醒、权限、版本、凭据及生成结果均为固定内存演示，当前 96 场景可从窗外工具或 `window.prototypeReview.scenes` 查询。不接收真实 Key、不读写用户配置／声音包／Keychain／SenseAudio 文件、不访问宿主配置、不请求 Provider、不申请权限或注册真实快捷键。合成试听、文件／Finder／来源反馈不证明真实音频／磁盘／系统动作。

重复入口：`python3 scripts/test-macos-settings-prototype-browser.py`。回归按 C01–C48 核对固定八页 HTML 的可达控件与结果，覆盖八页 × 双语 × 双外观 × 双尺寸共 64 页级组合；详情／sheet 另检查正常、在途、失败和禁用。定位失败或结果缺失判失败。截图／详情在运行输出的 artifacts 目录，2026-10-01 的固定记录为 `VERIFICATION.json`，不覆盖独立动画原型或原生 #216 增量。

最终 HTML SHA-256：`f49c338fde51a03fa4ada9b5f31f071a281e6708038dbac609f3c7931b93fe91`；历史页级布局 **64/64**，96 场景布局；能力用例 **48/48**，511 项能力断言；详情入口组合 **376**、操作状态快照 **776**。独立复核共 1984 观察点。结果与截图绑定同一指纹，见 VERIFICATION.json（工作树待提交：`designs/macos-settings-native/VERIFICATION.json`） 和 [README 验证记录](README.md)。JSON 的待批准／无交付状态保留为当时快照。浏览器布局／键盘／ARIA 仅证明 HTML；该次运行未验证原生布局、真实焦点／键盘、VoiceOver、实际听感、真实权限／宿主／Provider、两架构、签名／公证或正式验收。后续原生证据与未完成项分别见八页原生迁移记录和当前对齐记录。

## 6. 源码与文档依据

- 壳与导航：[SettingsRootView.swift](../../gui/Sources/ClaudioSettingsPresentation/SettingsRootView.swift)、[SettingsNavigation.swift](../../gui/Sources/ClaudioGUICore/SettingsNavigation.swift)、[SettingsPresentationSession.swift](../../gui/Sources/ClaudioSettingsPresentation/SettingsPresentationSession.swift)、[SettingsPresentationDependencies.swift](../../gui/Sources/ClaudioSettingsPresentation/SettingsPresentationDependencies.swift)。
- 作用域与声音：[EventSettingsWindowView.swift](../../gui/Sources/ClaudioSettingsPresentation/EventSettingsWindowView.swift)、[SettingsSoundReturnContext.swift](../../gui/Sources/ClaudioSettingsPresentation/SettingsSoundReturnContext.swift)、[SoundPacksWindowView.swift](../../gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift)、[SettingsSoundsAICueView.swift](../../gui/Sources/ClaudioSettingsPresentation/SettingsSoundsAICueView.swift)、[AICueProviderRegistry.swift](../../gui/Sources/ClaudioGUICore/AICueProviderRegistry.swift)。
- 其他目的页：[IntegrationsSettingsDestinationView.swift](../../gui/Sources/ClaudioSettingsPresentation/IntegrationsSettingsDestinationView.swift)、[ActivityDiagnosticsView.swift](../../gui/Sources/ClaudioSettingsPresentation/ActivityDiagnosticsView.swift)、[ShortcutSettingsView.swift](../../gui/Sources/ClaudioSettingsPresentation/ShortcutSettingsView.swift)、[AboutSettingsView.swift](../../gui/Sources/ClaudioSettingsPresentation/AboutSettingsView.swift)。
- 动画增量：EventAnimationSettingsView.swift（工作树待提交：`gui/Sources/ClaudioSettingsPresentation/EventAnimationSettingsView.swift`）、EventAnimationPreferences.swift（工作树待提交：`gui/Sources/ClaudioGUICore/EventAnimationPreferences.swift`）、EventAnimationPreviewSession.swift（工作树待提交：`gui/Sources/ClaudioGUICore/EventAnimationPreviewSession.swift`）、EventAnimationTimeline.swift（工作树待提交：`gui/Sources/ClaudioGUICore/EventAnimationTimeline.swift`）、EventAnimationResourceComposition.swift（工作树待提交：`gui/Sources/ClaudioGUI/EventAnimationResourceComposition.swift`）、EventAnimationResources.swift（工作树待提交：`gui/Sources/ClaudioGUIComponents/EventAnimationResources.swift`）、EventAnimationView.swift（工作树待提交：`gui/Sources/ClaudioGUIComponents/EventAnimationView.swift`）、EventNoticeBannerContent.swift（工作树待提交：`gui/Sources/ClaudioGUIComponents/EventNoticeBannerContent.swift`）。
- 合同：[CONTEXT.md](../../CONTEXT.md)、[DESIGN.md](../../DESIGN.md)、[CONTRIBUTING.md](../../CONTRIBUTING.md)、[八页迁移规格](../../plan/PLAN-MACOS-SETTINGS-MIGRATION.md)、[事件动画规格](../../plan/PLAN-EVENT-ANIMATION.md)，以及 [统一设置计划](../../plan/PLAN-SETTINGS-EXPERIENCE.md)、[原生迁移规格](../../plan/PLAN-NATIVE-PROTOTYPE-MIGRATION.md) 与 ADR 0001–0009、0011、0014–0016、0021–0022 的现行覆盖关系。

统一设置计划 §5.6 的“支持导入声音包”为旧文字，不覆盖后来整合 SoT／原生迁移规格与当前范围；整包导入无入口。历史 Global／Surface、唯一全局音量、九页与 SenseAudio Keychain-only 描述被后续 ADR 覆盖。保留这些覆盖关系及现行领域模型，不因实现或文档同步扩大能力。
