# claudi0：macOS 原生设置界面研究

研究日期：2026-10-01。只采用 Apple 官方设计与 API 资料，并结合用户提供的 System Settings 截图；当时是独立探索，未修改生产 Swift 或领域合同。2026-10-02 八页设置方向已经固定，见 [DESIGN.md](../../DESIGN.md) 的现行八页章节和 [#215 迁移规格](../../plan/PLAN-MACOS-SETTINGS-MIGRATION.md)。本文保留研究来源、推导方法与原建议范围，不作为新的验收报告。菜单栏、面板和横幅继续沿其整合原型合同，#216 角色动画增量另按 [事件动画规格](../../plan/PLAN-EVENT-ANIMATION.md)。

## 设计方向

采用 System Settings 的「侧栏导航 → 分组表单 → 详情页／短任务 sheet」结构。浅色下使用浅灰侧栏、白色主区、浅灰功能组；深色下同步映射语义背景。组内用轻分隔线，组间靠留白，标签在前、值和操作在后。避免把声音、工作区、集成设计成另一种全页灰底的管理台。

这是一项基于用户截图和 claudi0 能力的设计选择，**不是 Apple 要求所有应用照搬 System Settings**。研究时的 Apple Settings HIG 以 toolbar panes 的传统应用设置窗口为典型；其「窗口按 pane 内容调整、最小化／最大化按钮变暗」建议也不同于 claudi0 已有可调整尺寸的 retained 设置窗口。采用这套外观不改变窗口生命周期或最小系统版本。[Settings HIG](https://developer.apple.com/design/human-interface-guidelines/settings)、[当前窗口合同](../../docs/adr/0008-use-one-retained-unified-settings-window.md)

## Apple 指南与研究阶段的应用建议

| 原则 | Apple 官方依据 | 用于 claudi0 |
| --- | --- | --- |
| 减少选择负担，提供好默认值 | 设置应尽量少、默认体验应合理；常规设置与任务内选项应放在对应上下文。[Settings](https://developer.apple.com/design/human-interface-guidelines/settings) | 保留现有八页能力；不新增账户、同步或系统全局设置。配置五事件时，当前声音包、音量和作用域始终可见。 |
| 用层级表达关系 | 阅读顺序、分组容器、留白和分隔线帮助理解；渐进披露降低初始复杂度。[Layout](https://developer.apple.com/design/human-interface-guidelines/layout) | 每个功能组一块轻底色；复杂说明、工作区规则、事件记录按需展开；操作与它影响的数据放在同一区域。 |
| 稳定导航与当前选择 | 分栏中持续标示选择可说明内容之间的关系；侧栏标签简洁，通常不超过两级。[Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)、[Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) | 固定八页顺序与现有 route identity；选中页保持高亮。声音事件编辑进入同窗口 detail，返回恢复工作区身份与原控件。 |
| 导航与内容具有不同材质角色 | Liquid Glass 属于 controls/navigation 层，内容区不应满铺玻璃；macOS material 按用途而非偶然颜色选择。[Materials](https://developer.apple.com/design/human-interface-guidelines/materials) | 侧栏呈现轻材质，主内容安静清晰；不把每个功能组变成漂浮玻璃卡。旧系统使用对应标准材质。 |
| 系统字体与语义颜色 | 系统字体提供熟悉层级；macOS 系统字体是 SF Pro。语义颜色自动适配 appearance、vibrancy 与 contrast，不能随意互换含义。[Typography](https://developer.apple.com/design/human-interface-guidelines/typography)、[Color](https://developer.apple.com/design/human-interface-guidelines/color) | HTML 使用 `-apple-system` / `system-ui`，不嵌入 Apple 字体。Swift 使用系统 text style、label／secondaryLabel／separator 与系统背景色，避免生产代码硬编码原型采样 RGB。 |
| 控件大小与语义一致 | macOS switch 比 checkbox 更突出；grouped form 单行可采用 mini switch，主设置采用 regular switch。[Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles) | 功能组总开关较突出，五事件自动开关紧凑一致；开关只表达自动行为，试听是独立动作。 |
| 操作名称与后果明确 | 按钮应明确表达动作；继续输入的 push button 可带省略号；primary、cancel、destructive 角色不同，破坏性动作不设为默认主动作。[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) | 「编辑…」「添加工作区…」「复制声音包…」打开对应任务；「试听」「重新检测」直接执行；删除保留明确确认与取消。 |
| Sheet 用于有结束点的短任务 | macOS sheet 对父窗口 modal；只显示一个，取消不保存，完成提交；复杂持续任务应考虑非 sheet 形态。[Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets) | 新建／重命名／删除确认可用 sheet；长期声音包与 AI 生成编辑留在 detail，不叠 sheet，不另建设置窗口。 |
| 标准组件承担窗口与焦点行为 | Apple 建议使用标准 window 与 controls，避免自行复制窗口 frame；焦点外观要符合平台，文本框用 focus ring，列表用高亮。[Windows](https://developer.apple.com/design/human-interface-guidelines/windows)、[Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection) | HTML 窗口框只为设计预览；生产保留 AppKit traffic lights、resizing、toolbar 和真实 key 状态。不能把网页画出来的红黄绿直接移植进 Swift。 |
| 可访问性是完整操作链 | 原生 AppKit 控件已有 accessibility 协议；应验证键盘、VoiceOver、Reduce Motion、contrast 与不用颜色表达状态。[Integrating accessibility](https://developer.apple.com/documentation/accessibility/integrating-accessibility-into-your-app)、[Testing system accessibility features](https://developer.apple.com/documentation/accessibility/testing-system-accessibility-features-in-your-app) | 试听、复制、移除、生成和取消有名称／结果；禁用旁保留原因；错误可见且可恢复；页面滚动到底仍可达操作。HTML 检查不替代 native VoiceOver 验收。 |

## 从截图推导的视觉参数（2026-10-01 研究建议）

以下是**当时的原型建议范围**，不是 Apple HIG 规定的固定数值，也不是截图已校准的物理测量。截图的显示缩放和 Retina 比率未知，实际移植应以系统组件实测为准。后来固定的 252／210 pt 侧栏、780 pt 阅读列、10 pt 圆角及准确颜色等项目参数以现行 `DESIGN.md`／#215 为准，不由下面的研究范围覆盖。

| 元素 | 原型建议 | 原生实施取向 |
| --- | --- | --- |
| 窗口 | 延用默认 `1240×820`、最小 `960×640` | 现有 `SettingsWindowGeometry` / `contentMinSize`，不缩字来适配最小窗口。 |
| 侧栏 | 约 `230–250px`；控件与边缘有 `12–16px` 留白 | 系统 sidebar row 与 icon；不引入侧栏第二份数据 owner。 |
| 导航项 | 紧凑单行，约 `32–36px` 行高；约 `20px` glyph 容器 | native sidebar text/icon size 优先，跟随平台与用户选择。 |
| 主区 | 白／深色语义背景；左右 `28–40px`；限制可读内容宽度 | 主内容独立滚动；保留页头与导航；语义背景自动更新。 |
| 分组 | 浅灰柔和底色；约 `10–12px` corner；组间 `20–28px` | `Form` / `Section` 或同语义 fallback；不以厚描边和阴影堆层次。 |
| 行 | 基本 `44–52px`；两行说明与错误自然增高；组内边距约 `12–16px` | 标签与 controls 基线对齐；长英文、长路径、较大文字可折行。 |
| 文本 | body 约 `13px`，secondary 约 `11–12px`，页名约 `17–20px` | 使用系统样式与现有固定紧凑密度，保留系统辅助功能缩放；不恢复已退役的应用文字大小偏好。macOS 本身不支持 iOS 式 Dynamic Type。 |
| 色彩 | 主体中性；默认蓝色 accent 只用于选择和明确主要操作 | 尊重系统 accent；「待处理」同时有状态文本／glyph，不能仅用颜色。 |
| 分隔 | 细、低对比，只切分同组行 | `Divider` / separator 语义色，Increase Contrast 加强可辨性。 |

「苹果味」来自层级、精度、状态和行为的一致性；从静态截图抄一个灰色值或圆角值并不能替代这些原则。窗口不活动、sidebar 焦点转移、sheet 打开、保存失败、空库和失效目标都应保持同样的秩序。

## 与现有 claudi0 实现对接

当前 `gui/Package.swift` 的最低系统版本为 macOS 12。本机 Apple SDK 的公开 `.swiftinterface` 声明 `NavigationSplitView` 与 `GroupedFormStyle` 均为 macOS 13+；不得因这版外观悄悄提高最低版本。[NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview)、[GroupedFormStyle](https://developer.apple.com/documentation/swiftui/groupedformstyle)、[现有 Package.swift](../../gui/Package.swift)

下表保留研究阶段提出的组件选项与 owner 边界，不表示生产必须采用某个组件。系统字体、语义色、材质和标准控件提供平台行为；设置的具体表面与几何按现行项目合同实施。生产接缝见 [实现映射](IMPLEMENTATION-MAP.md)，当前差异与未完成验证见 [对齐记录](../../docs/validation/sot-implementation-alignment-2026-10-02.md)，不从历史研究推定当前实际绘制或辅助功能已通过。

| 原型部位／行为 | 已有接缝 | 可用原生组件与约束 |
| --- | --- | --- |
| 唯一设置窗口 | `SettingsWindowController` / `RetainedSettingsWindow` | 保留 retained AppKit owner、非激活焦点和 handback；调整 hosting content，而非新增 SwiftUI `Settings` scene owner。 |
| 八页导航与详情 | `SettingsDestination` / `SettingsRoute` / `SettingsPresentationSession` | macOS 13+ 可采用 `NavigationSplitView`；macOS 12 用既有双栏或 `NSSplitView` + `.sidebar` List，消费同一个 typed route。 |
| 页面分组与行 | `SettingsRootView` / `SettingsVisualComponents` | macOS 13+ 用 `Form.formStyle(.grouped)`、`Section`；12 用同层级容器配标准 controls。SwiftUI Form 具有 platform-appropriate styling，不能假设各平台布局一样。[Form](https://developer.apple.com/documentation/swiftui/form) |
| 当前作用域、声音包、音量与五开关 | `PanelConfigController`、现有 scope resolver | `Picker`、`Slider`、`Toggle`；选择用户指定 identity，不因最近回调或无效身份而落到可写默认组。 |
| 声音包、提示音编辑 | `SoundPackLibrary` / `SoundPacksEditorOwner` | detail 编辑复用锁／CAS／草稿发布／共享使用者披露；内置包只读并提供复制后编辑；不恢复整包导入。 |
| 从工作区进入声音，返回原处 | `SettingsSoundReturnContext` | navigation detail + Back；保留原作用域／事件／focus，返回前重验目标，失效显示错误。 |
| AI 服务、候选与采用 | 现有 AI Cue profile／generation owner | detail 内标准 text field、button、progress 与 candidates；生成锁定描述、取消可恢复、采用显式，费用／凭据说明就近；原型点击不调用真实 provider。 |
| 连接状态 | 现有 integration snapshots／adapters | row value 显示真实状态；必要操作如修复、重新检测在同组；已配置、能力支持、当前代次回执分别表达。 |
| 临时编辑任务 | 现有 sheet／presentation action | `.sheet` 或 AppKit sheet；Escape／取消、Return／提交遵循角色；不嵌套或新增平行窗口。 |
| 事件记录与统计 | `EventNoticeModel`、共享 activity projection | 默认折叠记录；只投影内存提醒，不混入日志或活动数据。清理操作保留各自后果。 |

## 采用后的合同与验证边界

八页名称、顺序、工作区与声音的单列 grouped forms 已由 #215 固定：顶端选择目标；基础选项一组；五事件一组；辅助规则／AI 服务另组；具体提示音编辑进入同窗口 detail。宽窗口不为填满空间而新增第二套编辑入口。原生迁移和后续修复已有独立记录，但采用合同不表示所有实际交互已经验收。

页间身份与返回、内置包保护、共享修改披露、失败保旧值、AI 取消／采用、native 双语／双 appearance／最小窗口、焦点、真实键盘与 VoiceOver 的结果分别见 [八页原生迁移记录](../../docs/validation/macos-settings-native-2026-10-02.md)。该记录绑定迁移阶段候选；当前 #216 源码／原型差异和现场观察 `BLOCKED` 另见 [当前对齐记录](../../docs/validation/sot-implementation-alignment-2026-10-02.md)。原型只能验证其视觉与模拟交互，不能证明系统 material、真实音频、Provider、宿主连接、生产持久化或当前原生 UI 验收。
