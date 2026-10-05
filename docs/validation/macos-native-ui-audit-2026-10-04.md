# claudi0 设置原生对齐审计 · 2026-10-04

本轮使用 Computer Use 实际查看运行中的 `dist/claudi0.app`，逐页访问八个设置目的页，并进入集成详情和事件动画详情；直接对照本机 macOS 系统设置的通用、声效和通知页面。截图及对应无障碍树已在本轮对话中展示。本文是首轮差异清单，未修改生产代码或持久偏好。

观察环境：简体中文、浅色；应用显示 `0.0.0-dev`、arm64；系统显示 macOS `27.0.1`。源码参考 `main` 的 `f106df47b5931ab952107a2b1b3cf295fd1f9a06` 加当前共享工作区改动。运行 bundle 尚未包含上一轮通知返回修复，不能将该旧按钮算作当前源码回归。

“原生控件”与“采用系统设置的呈现样式”是不同判断。当前下拉框已经是系统菜单控件，仍有样式和布局可进一步对齐。系统设置是本次用户指定的比较基准；以下设计差异不自动等于违反 Apple HIG。

## 优先处理

### 1. 动画事件预览缺少持续可见的选中态

- 实机复现：通知 → 事件动画，先点“用户发起”，再点“响应结束”，然后点页标题移开指针。预览标题更新，无障碍值也从“未选择”变为“已选择”；五个按钮仍使用相同的白色外观，看不出当前选择。
- 结论：已复现的呈现问题，当前源码也存在对应原因。
- 源码：[EventAnimationSettingsView.swift](../../gui/Sources/ClaudioSettingsPresentation/EventAnimationSettingsView.swift) 的 `previewSection` 只通过 `.tint` 表示选中；[SettingsFocusableButton.swift](../../gui/Sources/ClaudioGUIComponents/SettingsFocusableButton.swift) 的 `updateNSView` 没有传递选中状态或 tint，底层是 momentary `NSButton`。
- 建议：选中值需要持久可见的背景、标记或原生选择控件；不能仅靠预览正文或瞬间按压反馈表达。Apple 的 [Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles) 指南要求状态有明显视觉区别。

### 2. 详情返回方式跨页不统一

- 实机复现：集成 → 五事件能力与回执，页头显示单个裸左箭头；系统设置的声效／通知页显示带分隔线的前后导航胶囊。
- 当前源码：通知已修复为原生前后分段控件；工作区、集成和声音详情仍是单个 `.plain` 左箭头。
- 结论：确认的跨页设计差异；通知旧 bundle 单独标为待更新验证。
- 源码：[IntegrationsSettingsDestinationView.swift](../../gui/Sources/ClaudioSettingsPresentation/IntegrationsSettingsDestinationView.swift):59、[EventSettingsWindowView.swift](../../gui/Sources/ClaudioSettingsPresentation/EventSettingsWindowView.swift):105、[SoundPacksWindowView.swift](../../gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift):295。
- 建议：后续统一详情导航位置、控件及禁用态。是否让其他详情也支持前进，需要明确导航合同，并继续由现有设置会话持有状态。

### 3. 鼠标点选后的侧栏键盘起点不同

- 实机复现：系统设置点“声效”后按 ↑，选中“通知”；claudi0 点“通用”后按 ↑，仍停在“通用”，当时无障碍焦点报告为窗口。
- 结论：当前运行 bundle 的实际交互差异；尚未证明所有侧栏方向键路径都失效。
- 当前源码已有 `.onMoveCommand`，不能据此写成“没有实现方向键”。需要复核鼠标选择后焦点如何进入该 handler，再分别测试 Tab 进入侧栏的路径。
- 源码：[SettingsRootView.swift](../../gui/Sources/ClaudioSettingsPresentation/SettingsRootView.swift):167、[SettingsRootInteraction.swift](../../gui/Sources/ClaudioSettingsPresentation/SettingsRootInteraction.swift):128。现行 DESIGN 要求普通导航请求页标题焦点，因此调整鼠标选择后的行为也涉及既有焦点合同。
- 建议：优先核对运行版与当前构建，确认鼠标选中后是否应保留侧栏导航焦点。

## 需要重新定稿的呈现差异

| 项目 | 实际观察与系统设置参照 | 源码／当前合同 | 建议 |
|---|---|---|---|
| 窗口标题与页头分成两层 | claudi0 顶部居中显示“claudi0 · 设置”，正文上方再有独立页名和横线；系统设置将导航和当前页名放在顶部同一区域 | `SettingsWindowController.swift:279`；`SettingsPageLayout.swift:11` 自绘至少 58 pt 页头。属于当前结构选择 | 后续考虑由原生 toolbar 承载导航与页名，减少额外一层头部；保持 retained window 与非激活焦点合同 |
| 下拉框视觉重量较大 | 通用语言、工作区和声音包使用宽白色边框框体；系统设置声效／通知的值在行尾紧凑显示，箭头为小圆形控件 | `NativeMenuControlStyle.swift:5` 已采用原生菜单；`SettingsControlRow.swift:35` 限制控件列最多 280 pt。现行 DESIGN 明确要求中性系统灰底 | 调整收起态样式和宽度，仍保留系统菜单、完整无障碍值和键盘行为 |
| 动画页开关居中 | “显示角色”“静态表情”的标签及开关集中在卡片中间；其他设置页以及系统设置声效页是标签在左、开关在右 | `EventAnimationSettingsView.swift:76`；`EventAnimationActionButton.swift:122` 使用独立 AppKit 开关桥接 | 将同类设置行的标签和控件对齐到共同两端；开关尺寸也应随行层级统一 |
| 进入详情的箭头样式不同 | 工作区五事件行的右箭头有白色按钮底；声音五事件行与通知动画入口是裸右箭头；系统设置普通详情行使用裸 disclosure 箭头 | `EventSettingsWindowView.swift:1061` 没有 `.plain`；`SoundPacksWindowView.swift:856` 明确使用 `.plain` | 统一同语义详情入口的箭头、按钮底和命中区域，并清楚区分播放动作 |
| 分组标题的层级不同 | 通知“事件横幅”“自动静默”“当前状态”放在灰色卡片内部；系统设置“声音效果”“输出与输入”“通知中心”放在对应卡片外 | `SettingsRootView.swift:507` 及 `settingsGroupTitle`。属于目前自绘功能组结构 | 对真正的 section 标题统一采用卡片外标题，保留卡内字段和必要子层级 |
| 侧栏材质为固定实色 | claudi0 侧栏是固定灰色；系统设置侧栏具有系统背景材质及与顶部搜索区域协调的效果 | `SettingsRootView.swift:69`、`SettingsAppearance.swift:37`；现行 DESIGN 明确采用实色 RGB 表面 | 若决定采用系统材质，先在原型中确认浅色／深色与活动／非活动表现，再修订固定色合同 |

工具栏建议参考 Apple [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)：导航及页名属于工具栏常见内容；macOS 工具栏位于窗口顶部框架区域。开关的层级与尺寸参考 [Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles)。具体外观调整是结合本机系统设置观察得出的建议，并非 Apple 要求所有应用逐像素复制系统设置。

## 覆盖与后续顺序

已查看：默认组／工作区、声音、集成、通知、通用、快捷键、活动与诊断、关于；集成能力详情、动画详情；侧栏鼠标选择后 ↑；动画预览两种事件的选择反馈。没有触发真实试听、修改系统设置、写入配置、修复集成、删除记录或操作凭据。

尚未覆盖：深色、最小／默认尺寸矩阵、完整 Tab／Shift-Tab／Space 顺序、VoiceOver、增强对比度、系统强调色变化及全部 sheet。这份首轮检查不能声明这些门禁已通过。窗口非激活、唯一 retained owner、无 Dock 图标属于既有产品合同，不列为外观缺陷。

建议顺序：先完成已授权通知返回修复的运行版复核；随后处理预览选中反馈、详情导航一致性和侧栏焦点路径。工具栏、下拉框、开关行、分组标题与材质作为下一轮原型定稿事项。
