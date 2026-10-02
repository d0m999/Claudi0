# 八页原生设置迁移：实施与验收记录

状态：本机自动门禁与最终 64 组合原生矩阵通过；完整原生验收仍有下列未验证项。

规格：[PLAN-MACOS-SETTINGS-MIGRATION.md](../../plan/PLAN-MACOS-SETTINGS-MIGRATION.md)，
[Issue #215](https://github.com/d0m999/Claudio/issues/215)。源码固定基线
`7ca63a4af0497b74b53e89225ccf4de30d900c12`。设置原型 SHA-256
`f49c338fde51a03fa4ada9b5f31f071a281e6708038dbac609f3c7931b93fe91`。
所有本机 Swift 验证统一使用 Swift 6.4、SDK 26.5、macOS 27.0.1、arm64。
候选源码 HEAD 为 `145e91d01fa764f21f1e6fa005be0053185df2b7`；工作期间共享仓库另有
许可证提交进入 HEAD，该提交不是本次代理创建，已保留。固定验收基线仍为上列 `7ca63a4`。

## 实施边界

八页、详情和 sheet 采用新的设置外壳、系统字体、中性表面、单列功能组与原生控件。
`SettingsRootView`、`SettingsPresentationSession`、retained 设置窗口及领域 owner 继续复用。
工作区／事件／音频文件／AI 服务／面板显示集／宿主能力详情仅增加 package/internal 呈现状态；
已有 raw route、稳定目标身份、锁／CAS、备份、配置字段和持久化合同没有另建模型。
四份官方产品原图原字节放在已有 GUI 资源 bundle；设置呈现 target 仍零资源。
删除禁用原因消费 owner 的真实引用事实；缺少删除 capability 本身不表示包正在使用。
真实旧快照回归已复现并修正该错误：未引用包显示无法安全复验，同时保留库失败与重试入口。
健康库和清单失败现在都能通过既有 library owner 主动刷新。事件／音频详情保留捕获的包身份；
原包消失时显示不可用原因，只有本次显式复制的精确结果允许转到副本。AI 事件详情持续显示
当前服务与凭据状态。集成详情新增来自唯一 receipt store 的脱敏历史，并补齐五事件的
支持、实现和当前激活事实；历史读取与清理结果均通过真实 store 回读。
声音视图使用每次渲染新建的不可变投影容器，减少 SwiftUI 视图值复制生成的代码；
该容器没有观察、缓存或写入能力，数据仍由原 owner 发布。
原生音频详情另发现并修正辅助功能值错误：已绑定文件的指派／删除控件原来仍播报未使用，
现在从同一 `usedByEvents` 投影播报实际事件，包括旧重复绑定。快捷键说明中的旧页名也改为
当前「默认组／工作区」。这两项修复没有新增公共 API 或本地化 key。

v17 的原生批量导入发现：磁盘保留有效文件、拒绝无效文件，但页面只显示进度而丢失终态。
新修复将真实逐项导入结果保留在既有 owner 的 activity 投影中，页面直接消费；播报确认不消耗
可见结果，仍受既有 32 条终态上限约束。结果显示目标、成功文件、逐项失败及绑定／取消结果，
并增加 10 个双语条目。没有新增写入路径、持久化合同或独立状态 owner。
空库原生检查另发现：正在使用但已删除的包会保留占位卡，详情原先把这个占位视为有效目标，
显示空音频清单。写入原本已禁用；本次修复只补齐目标可用性与原因／焦点映射，避免把缺失包
说成空包。真实刷新后的占位回归修复前两项失败，修复后 45 项通过。

共享工作树原有的窗口焦点修复、handback 测试、浏览器验证脚本、设计文件删除和未跟踪原型目录
均保留。没有提交、推送、修改已有 issue 状态或清理共享工作树。

## 自动门禁

| 项目 | 当前回执 | 边界 |
|---|---|---|
| helper executable harness | 4,254 项通过 | 核心自动行为 |
| GUI executable harness | 最终 12,941 项全部通过；v27 初次 1 项测试等待竞态已修正并完整复验 | v21 构造器护栏与 v26 root 内类型擦除护栏均已修正，未放宽护栏；旧横幅失败回执保留，未修改横幅代码 |
| 设置导航原生焦点 | v27：49 项通过 | 系统键盘导航开启时的真实 key window；菜单操作另有外部 CUA 验证 |
| 工作区删除原生焦点 | v27：20 项通过 | 系统键盘导航关闭；Escape、原目标、Space／Return、修饰键保护 |
| AI 描述原生焦点 | v27：32 项通过 | 系统键盘导航关闭；输入器移除、取消、保留描述、first responder、修饰键保护 |
| 64 组合挂载布局 | v27：1,174 项通过，128 份截图 | 同一最终生产源码的外部 CUA 64/64 通过，页首／页尾 128 组截图与 AX |
| 双语原生状态 gallery | v27：160 场景、1,104 项通过 | 190 份位图、160 份挂载记录；包含真实凭据 sheet、即时翻译、取消按钮位图和 AI 服务上下文 |
| Debug／设置 target | 最终源码构建通过 | SDK 一致，不代表实际交互验收 |
| Release／本地 bundle／体积／签名 | v27 arm64 Release 装包、严格签名验证和前／后签名体积门禁通过 | GUI 每架构 7,000,000 B 预算仍生效；资源预算依据原图调整为 3,100,000 B |
| 本地化、格式、diff | v27 的 70 个 Swift 文件严格格式、JS 语法、catalog JSON 和工作树 diff 检查通过；v16 另有 13 个脚本语法单元检查 | 新增 57 个双语条目，共 1,025 条；原有条目仅更新快捷键目的页说明，allKnown 与占位符一致 |
| 独立资源回归 | selector seam 与 15 项 sound-pack candidate 测试通过 | 不代表设置交互或实际音频播放 |
| 声音包刷新与删除原因 | 最终 114 项通过；刷新修复前 2 项失败 | 真实库刷新、清单失败恢复、组选包与配置字节保持 |
| 详情身份回归 | 最新 45 项通过；初次身份修复前 3 项失败，缺失占位补充回归前 2 项失败 | 原包移除、快照焦点变化、精确副本结果、应用失败、草稿发布／取消与 pending 深链 |
| 回执历史与集成合同 | 2,509 项通过 | Foundation 接缝：来源隔离、分代、读取失败、清理失败与重试；原生点击另验 |
| View wiring | 335 项通过 | 新 fixture 的第七个锁调用及全部调用的实际路径实参逐一校验；未放宽锁护栏 |
| 音频清单辅助功能值 | 99 项通过；修复前同一可编译接缝 4 项失败 | 双语未绑定、单事件和旧重复绑定；真实原生 AX 复验另列 |
| 导入终态反馈 | 171 项通过；初始同一接缝 2 项失败 | 真导入、部分拒绝、全拒绝、取消保留、播报后可见、双语及 32 条终态上限；原生复验通过 |
| 固定基线统一门禁 | 未完成 | 脚本要求干净且已提交候选；当前共享工作树不满足，未制造干净状态 |

v27 `dist/claudi0.app` 签名后：GUI `6,984,160 B`、helper `3,179,520 B`、LoginItem
`54,144 B`、非可执行资源 `2,303,072 B`、bundle 正规文件合计 `12,520,896 B`。
GUI 预算余量 `15,840 B`。v18–v25 加入导入终态后曾超预算，最后超出 `592 B`；
编译产物显示公共页头／滚动容器被六类内容分别特化。最终使用内部视觉组件
`SettingsDestinationPage` 承接共用页头和滚动容器，在该组件边界擦除内容类型；
`SettingsRootView` 继续使用具体路由视图类型，不改变页面、状态 owner 或路由身份。
剥离 payload 从 `6,986,656 B` 减至 `6,970,248 B`。v26 曾将擦除放在 root 内而触发架构护栏，
v27 已移至内部组件，并保留原护栏。
最终前后签名门禁均通过；全部旧超限回执保留，没有放宽 GUI 预算或设置覆盖值。
这些结果只覆盖本机工具链和 arm64；其他工具链／架构仍需实测。strip、临时链接器签名移除和
最终严格 ad-hoc 签名见 [release-size-budget.md](../performance/release-size-budget.md)。

## 原生证据

隔离 DEBUG bundle 在生产 owner 创建前校验 fixture 身份。配置、包、活动、日志、defaults 均使用
临时根；defaults 通过既有 UserDefaults 注入接缝写入临时 plist，并有重开读回／独立实例回归。
本地编辑、刷新、窗口、文件面板与音频播放使用真实 owner／本地适配器；Provider、凭据服务、
Focus／Calendar、登录项、宿主配置、来源应用和部分 About／clipboard 操作使用明确替身。
导入时长探针为 fixture 固定值。
真实 Provider 请求、Keychain／SenseAudio 生产凭据、系统权限授予及宿主回调不由该 fixture 证明。

`build-evidence.json` 绑定基线、HEAD、工作树各文件指纹、原型指纹、SDK、bundle 各文件哈希和
bundle 指纹。原生 driver 的 `results.json` 另外绑定 driver／OCR helper 指纹、每次临时数据根、
动作、最新 AX、实际窗口几何、绘制颜色、布局帧、截图及磁盘读回。找不到唯一控件、动作报错、
超时或结果缺失均记录失败；失败回执保留，成功复验不改写旧结果。

v16 已完成外部 CUA 的真实 Tab、Space、方向键、Return 作用域／声音包选择。磁盘读回确认：查看
声音包和切换管理作用域没有改写组选包。系统键盘导航已恢复原关闭状态，并保存系统设置 AX 读回。
v17 只修正音频文件辅助功能值和快捷键页名说明，受影响原生呈现单独复验；不得把旧回执改标为新构建。
编译挂载的 64 组合覆盖八页、两语种、两外观、两内容区尺寸；首／尾各一张，验证唯一主滚动区、
末尾可达、列宽、颜色和横向边界。双语 gallery 覆盖 19 个常规状态、31 个 AI 状态和
10 个集成场景 × 三来源；30 个实际凭据 sheet 另截图，并在打开时双向切语种检查位图。
这批 evidence 证明生产 root 对 fixture 事实的原生呈现，不等于全详情／sheet、C01–C48 点击、
真实键盘、VoiceOver 或人耳试听通过。

此前锁屏导致的 `cgWindowNotFound` 已在用户解锁后恢复。候选 handback 随后通过 103 项，
导航焦点通过 49 项。旧锁屏回执继续保留，不能作为当前焦点失败结论。
固定基线在解锁桌面运行 event-attention，893 项中同样有 3 项横幅阅读轨动画断言失败；
该基线和候选的失败位置及数值一致。设置迁移不修改横幅代码。

v16 外部 CUA 共 34 次记录，按唯一场景取最新结果为 29/29 通过：八组矩阵覆盖 64 页面组合，
另 21 个行为场景覆盖双语 AI、两种复制、工厂恢复、草稿发布／取消、真实键盘、三来源历史、
四类清理隔离、提醒操作／来源超时、组配置独立写入、显示集上限、快捷键取消、凭据删除取消和安全诊断反馈。
取消、清理和复制结果均读取真实临时配置／manifest／receipt／activity／log；外部操作替身边界不变。
5 次旧失败记录保留：一次 AX 滚动工具错误、草稿发布后脚本没有返回上级、全角逗号的选择器判断、
以及两次旧横幅退出态。对应复验通过；来源超时改由设置的提醒阅读区直接验证。
v17 另外完成受影响的声音／快捷键两页 × 两语言 × 两外观 × 两尺寸，共 16 组合；以及五个音频
行为场景：双语实际占用值、五事件清除、未绑定指派、删除保护、删除取消／确认、原生单文件导入。
批量导入另有一项失败回执，直接促成上述终态反馈修复；该失败不计为通过。
v11 的目录派生名称、选包与音量确认、零来源工作区创建及真实配置读回证据仍保留原构建身份。
生成取消流程曾被 OCR 将进度与“取消”合并识别而判失败；实际按钮完整可见，原生 AX 点击
返回编辑态且保留描述。driver 改为唯一 AX 控件操作并保留结果断言，旧失败记录未改写。

v18 新增批量导入 1 成功／2 失败、逐项拒绝原因、英文窄窗反馈和再次取消文件面板后的结果保留；
提醒冻结／显式刷新／过期、零音量、失效工作区、旧快照、损坏包和空库也有单独回执。
空库详情失败是真实呈现缺陷，已经用缺失占位回归修复；最终原生复验另列。
v22 再次完成 64/64 页面组合，14 个分批矩阵覆盖全部八页 × 双语 × 双外观 × 双尺寸；
保存页首／页尾 128 组截图与 AX。一次工具因前台应用变化拒绝，重新观察后复验通过。
v25 补齐五 profiles 服务详情双语、逐个选择／检查、采用前归属说明及实际 Finder 定位。
一次候选断言错误使用旧控件 ID 导致超时；改为实际 `event-settings.ai-cue.name` 后复验通过。
上述旧构建回执保留其真实身份，不改标为 v27。

v27 外部 CUA 共 42 次记录，37 个唯一场景的最新结果全部通过，其中 16 次分批矩阵与
21 个行为场景。4 次失败和额外的重复观察回执均保留；该计数不表示 C01–C48 全部完成。
最终生产源码对应的外部 CUA 再次完成 64/64 页面组合：16 次分批矩阵均通过，
页首／页尾 128 组截图与 AX，实际尺寸、颜色、侧栏与分组间距、阅读列和滚动末尾均有读回。
再次通过原生多文件导入的 1 成功／2 失败、磁盘字节一致、双语窄窗反馈、取消文件面板保留终态，
以及原包消失后的事件／音频详情不可用。包消失场景会重新序列化 fixture 配置，原始键顺序改变；
首次误用字节断言失败，改用完整 JSON 值比较后通过，所有组选包／音量／开关／来源值均不变。
这与普通导入保持配置原字节的断言分别记录，没有把 fixture 注入当成产品写入。

v27 首次完整 GUI 回归中，A→B→A 采用测试在 library actor 已空闲、MainActor 尚未消费
AsyncStream 的时间窗口检查新 permit，导致 1 项失败；同一测试单独连续运行 10 次均通过。
修复只让该测试等待 owner 的 ready 投影；旧目标拒绝、孤立文件保留、manifest 不变、恰好一次刷新
和新 permit 不同的断言全部保留。生产源码没有修改，最终完整回归 12,941 项全部通过。

v27 还独立完成通知横幅偏好与接收器状态分离、Focus／Calendar 策略逐项切换并读取临时 plist，
登录项操作结果与显式重新检测、三项快捷键真实键盘录制／重复校验／清除、统计刷新失败保留最近
成功数字、日志四状态与五条脱敏上限、复制／Finder 失败保持数据，以及三来源选择与断开确认。
统计场景分别验证清理后 partial 和未清理旧快照；日志实际使用 7 条有效记录加 1 行损坏内容，
原生页只显示 5 条分类且不包含原始原因。隔离文件在检查后恢复原字节与可读权限。
登录项、快捷键注册／持久化、Finder／clipboard 和宿主连接仍使用明确的替身，不据此宣称系统接入。
宿主确认后的回执事实没有改变，重新检测也没有制造激活；临时 toast 的首次延迟断言超时后，
改为操作返回时立即检查并复验通过。旧失败记录保留。

最终证据清单为本机 `claudio-native-settings-verification-final/manifest.json`，包含门禁日志和
原生回执／截图哈希。与 v27 fixture 的 286 个生产源码／资源／Package 文件逐项比较一致；
构建后的差异仅为本验收记录与测试等待修正，不能把构建时的整工作树指纹称为当前指纹。

VoiceOver 曾经获准开启，用户先前确认能听到朗读；本次再次尝试字幕和实际阅读时，VoiceOver
窗口查询 `timeoutReached`，随后阅读操作发生 runtime timeout。未取得可靠的字幕／朗读次序证据；
旁白已恢复关闭并保存系统设置 AX 读回，字幕面板原值保持不变。完整阅读顺序仍未验证。
v27 真实播放器重新执行五事件、Basso 和候选音频，离页候选数归零及描述清理得到读回确认。
用户明确确认听到了前面的连续事件短音，并表示环境较吵；Basso 与候选音频没有获得人耳确认。
播放器调用和本地音频读取的自动证据不能证明扬声器音量或主观可听性。用户随后要求独立完成测试，
不再追加听音问题，不调整系统音量或录制麦克风。键盘导航和 VoiceOver 均已恢复原关闭状态。

## C01–C48 生产映射与自动验证

下表的 suite 名称均位于 `gui/Tests/ClaudioGUICoreTests/`，指向可编译的真实 owner／呈现接缝。
存在 suite 不等于所有原生状态已验收；原生栏明确列出尚需执行的项目。

| ID | 生产呈现／唯一 owner | 自动接缝 | 原生验收状态 |
|---|---|---|---|
| C01 | EventSettingsWindowView／PanelConfigController | WorkspaceSoundPresentationSuite、PanelSoundScopeInteractionSuite | v16 真实点击／配置读回通过：默认组音量与事件开关、工作区选包独立；64 组合首／尾通过 |
| C02 | EventSettingsWindowView／EventSettingsPreviewSequence、player | SettingsRootInteractionSuite、SoundPacksEditorNativeEffectsSuite | v18 零音量及损坏包禁用试听点击通过；v27 五事件真实播放，人耳确认连续事件短音；系统音、音量和停止的完整听音未确认 |
| C03 | SettingsSoundsDestinationView／session、SettingsSoundReturnContext | SettingsPresentationTargetSuite、SettingsRootInteractionSuite | v16 定向复制并应用保持捕获工作区，返回原组及配置读回通过；失效目标自动接缝通过 |
| C04 | AddWorkspaceSoundRuleView／PanelConfigController、WorkspaceDirectoryResolver | WorkspaceSoundPresentationSuite、WorkspaceDeletionPresentationSuite | v11 目录选择、派生名称、普通目录范围、选包／音量确认及磁盘读回通过 |
| C05 | 工作区范围详情／PanelConfigController | WorkspaceDeletionPresentationSuite、WorkspaceDeletionFocusSuite | 删除取消焦点通过；v11 零来源创建、五事件全开写回通过 |
| C06 | scopeContent／配置与工作区 owner | EventSettingsWindowSelectionSuite、SettingsNativeMigrationSuite | v18 失效工作区拒写与显式回默认组通过；损坏配置／冲突恢复点击待补 |
| C07 | SoundPacksWindowView／SoundPackLibrary | SoundPacksRefreshSuite、SoundPackLibrarySuite | v18 旧快照保留、实际刷新重试、空库与损坏包通过；首次加载失败点击待补 |
| C08 | 作用域 picker／SoundPacksEditorOwner | SoundPacksEditorMutationSuite、SettingsNavigationFocusSuite | 原生键盘查看不应用已通过 |
| C09 | packActions／SoundPacksEditorOwner | WorkspaceSoundPresentationSuite、SoundPacksEditorMutationSuite | v16 普通复制取消／确认不改组选包；定向复制并应用保持工作区身份，真实磁盘读回通过 |
| C10 | 包信息／SoundPacksEditorOwner | UserSoundPackDeletionSuite、SoundPacksEditorMutationSuite、SoundPacksEditorInterfaceSuite | 未引用旧快照禁用原因回归通过；引用保护、完整性保护与隔离结果点击待补 |
| C11 | 包操作／editor 与 native effects | SoundPacksEditorOwnerSuite、SoundPacksEditorNativeEffectsSuite | v16 单包／库恢复确认通过；v25 包许可可见，实际 Finder 选中捕获包并显示 manifest／音频通过 |
| C12 | libraryActions／SoundPacksEditorOwner | SoundPacksEditorMutationSuite、SoundPacksEditorAsyncOperationSuite | v16 恢复工厂库保留用户包及组选包字节，取消与确认点击通过 |
| C13 | panelDisplaySet／SoundPacksEditorOwner | SoundPacksEditorMutationSuite、SoundPacksWindowStarredPacksSuite | v16 显示集四项上限、第五项禁用、取消已有星标后恢复容量及配置隔离通过；损坏旧项待补 |
| C14 | eventMappingRow／SoundPacksEditorOwner | PackSoundSourceSuite、SoundPacksEditorInterfaceSuite | v16 草稿系统音首次绑定发布；v17 五事件重复占用的双语 AX、逐项清除与直接指派通过；完整选择器异常态待补 |
| C15 | 事件映射／editor、native file panel | SoundPacksEditorMutationSuite、SoundPacksEditorNativeEffectsSuite | v17 原生单文件面板导入、文件字节及 task_start 绑定读回、四事件清除通过；v27 批量导入终态及磁盘结果复验通过；单事件绑定失败的全部原生态待补 |
| C16 | audioDetail／SoundPacksEditorOwner | SoundPacksEditorMutationSuite、SoundPacksEditorViewSuite | v17 未绑定文件直接指派、占用后禁止删除、取消删除保留字节、确认后真实删除通过 |
| C17 | inventoryContent／SoundPacksEditorOwner | SoundPacksEditorAsyncOperationSuite、SoundPacksEditorNativeEffectsSuite | v27 原生多选导入 1 成功／2 失败及磁盘一致、双语窄窗反馈、再次打开文件面板后取消保留已完成结果通过；进行中取消的原生点击待补 |
| C18 | 库／清单恢复行／library、editor | SoundPacksRefreshSuite、SoundPacksEditorMutationSuite | v27 缺失包事件／音频详情原因与不可写保护通过；清单读取、manifest 损坏、工厂恢复失败的全部原生恢复动作待补 |
| C19 | SettingsSoundsAICueView／SoundPacksEditorOwner | AICuePackScopedSuite、SoundPacksEditorOwnerSuite | v16 草稿取消、首次系统音绑定发布、离页临时草稿清理通过 |
| C20 | draftNameSheet／editor | AICueDomainSuite、AICuePackScopedSuite | v16 草稿名称 sheet 保存／取消及无效值状态通过 |
| C21 | service 详情／AICueProviderRegistry | AICueProviderContractsSuite、AICueCandidateSetSuite | v25 五 profiles 地区、语言、候选数量／语义、存储说明双语可见；逐个选择与凭据检查通过且未生成、组选包字节不变 |
| C22 | 凭据状态／AICueGenerationViewModel、credential manager | AICueCredentialSuite、AICueLocalCredentialSuite | 凭据状态、实际 sheet 和恒显服务上下文 gallery 通过；管理点击与生产凭据外部验证另列 |
| C23 | 凭据 sheet／credential manager | AICueCredentialSuite、AICueLocalCredentialSuite | v16 确认删除后 Escape 取消，关闭 sheet 保留 SavedVerified；保存／替换／删除失败 gallery 通过；生产凭据未操作 |
| C24 | AI composer／AICueGenerationViewModel | AICueDescriptionSuite、AICueGenerationViewModelSuite | v16 双语生成锁定描述、取消保留描述、重新生成及部分／失败恢复点击通过 |
| C25 | 候选分隔行／generation dispatcher、editor | AICueCandidateSetSuite、AICueAdoptionSuite | v16 双语共同采用名、指定候选采用及 manifest 读回通过；v27 候选播放器执行和离页清理通过，人耳候选试听未确认 |
| C26 | 包说明／editor 的 attribution projection | AICueAdoptionSuite、SoundPacksEditorMutationSuite | v16 复制确认说明已见；v25 候选采用前许可／作者声明影响及独立归属保留说明可见，生成期间 manifest 字节不变 |
| C27 | IntegrationsSettingsDestinationView／HostIntegrationsViewModel | IntegrationDestinationModelSuite、HostIntegrationManagerBridgeSuite | v27 三来源选择不改连接／声音配置，Codex 捕获目标确认与取消、Claude Code 确认后的替身结果和重新检测通过；真实连接／断开外部验证 |
| C28 | 集成状态与动作／host manager | IntegrationDestinationPresentationSuite、HostIntegrationPresentationSuite | 10 场景 × 三来源 × 双语状态挂载通过；恢复点击与能力详情待补 |
| C29 | 宿主能力详情／共享 host snapshot | IntegrationDestinationPresentationSuite、IntegrationDestinationModelSuite | v16 三来源各四条历史、当前／旧代次、五事件三事实及当前来源清理的真实 store 读回通过；不代表真实宿主激活 |
| C30 | Notifications／preferences、EventNoticeModel | SettingsPreferencesSuite、SettingsPresentationLifecycleSuite | v27 横幅偏好切换写回，接收器停用事实保持独立；通知 gallery 状态通过；真实接收器动作待补 |
| C31 | Notifications／DynamicQuietPolicyModel、platform actions | DynamicQuietPolicySuite、SettingsNativeMigrationSuite | v27 Focus／Calendar 策略独立切换与临时 plist 读回通过；权限／系统入口失败有自动接缝，完整原生授权动作未覆盖，真实权限未授予 |
| C32 | 动态静默投影／DynamicQuietPolicyModel | DynamicQuietPolicySuite | 原因／健康／问题状态待补 |
| C33 | 所有页面／ClaudioPreferences、ClaudioL10n | SettingsPreferencesSuite、本地化 suite、SettingsSoundsLayoutSuite | 64 组合双语挂载及 30 个凭据 sheet 切语种位图通过；全部详情／AX 翻译待补 |
| C34 | LoginItemSettingsSection／LoginItemSettingsModel | LoginItemManagementSuite、SettingsNativeMigrationSuite | 登录项 gallery 状态挂载通过；v27 启用结果与显式重新检测采用替身实际状态通过；全四状态恢复点击未覆盖，未改生产登录项 |
| C35 | General／ClaudioPreferences | SettingsPreferencesSuite | 损坏偏好提示及显式修复待补 |
| C36 | ShortcutSettingsView／GlobalShortcutsModel | GlobalShortcutsSuite、SettingsPresentationLifecycleSuite | v16 三动作 Escape／离页取消通过；v27 三动作真实按键录制与清除通过；注册／持久化为替身 |
| C37 | 快捷键状态／GlobalShortcutsModel | GlobalShortcutsSuite | 空值／正常／失败 gallery 挂载通过；v27 裸键和重复组合拒绝且旧值保留；注册／保存／回滚异常的原生点击未覆盖 |
| C38 | ActivityDiagnosticsView／ActivityDiagnosticsModel | ActivityOverviewSuite、ActivityDiagnosticsSuite | v27 三来源和五事件计数、今日／七日／子任务摘要可见，刷新后与真实隔离活动数据一致 |
| C39 | 活动摘要／ActivityDiagnosticsModel | ActivityOverviewSuite、ActivityDiagnosticsSuite | 六类活动 gallery 通过；v16 清理后计数归零且其它对象不变；v27 损坏文件后保留数字并显示旧快照，恢复文件后刷新回 partial 通过 |
| C40 | 日志区／ActivityDiagnosticLogStore | ActivityDiagnosticsSuite | v27 存在／缺失／损坏／不可读四状态、大小与路径、7 条中最多 5 条脱敏摘要通过；复制／Finder 失败可见且数据不变，成功打开／复制仍为外部项 |
| C41 | ActivityDiagnosticsView 阅读区／EventNoticeModel | EventNoticeModelSuite、EventNoticePresentationSuite | v18 设置阅读区冻结、显式刷新采用新版本、过期清除来源内容通过；旧版本动作拒绝由自动接缝验证 |
| C42 | 提醒动作／SessionNavigationCoordinator | SessionNavigationSuite、EventBannerActionSuite | v16 复制会话、来源打开、失败／3 秒超时及移除点击通过；来源应用为替身 |
| C43 | 各清理控件／各自 owner | ActivityDiagnosticsSuite、IntegrationDestinationModelSuite、EventNoticeModelSuite | v16 提醒、回执、日志、活动四清理均先取消再确认；各自真实数据读回且另外三类保持通过 |
| C44 | AboutSettingsView／AboutSettingsModel | AboutInformationSuite | 64 组合及 About gallery 挂载通过；未知值与资源动作待补 |
| C45 | About resources／AboutSettingsModel | AboutInformationSuite | 空资源／打开失败 gallery 挂载通过；资源打开点击待补 |
| C46 | 安全诊断预览／AboutSettingsModel | AboutInformationSuite | v16 可选择安全预览、无临时私有路径及复制反馈通过；复制同一内容的 Foundation 接缝通过，clipboard 为替身 |
| C47 | 全部原生控件／session、focus coordinator | SettingsNavigationFocusSuite、WorkspaceDeletionFocusSuite、SoundPacksWindowAccessibilitySuite | 导航／取消焦点已验证；VoiceOver 实际阅读与顺序未验证 |
| C48 | 离页／切目标／关闭／既有 lifecycle owners | SettingsPresentationLifecycleSuite、AICuePackScopedSuite、SoundPacksEditorNativeEffectsSuite | v16 生成取消、草稿取消／离页、快捷键离页取消通过；v27 候选离页清理及失效详情保护复验通过；迟到结果接缝通过，全部关闭／焦点组合待补 |

## 尚未完成的人工与外部验收

- C01–C48 表中仍标记待补的原生异常与恢复动作，以及未覆盖的详情／sheet 正常、进行中、失败和禁用状态。最终 64/64 页面矩阵已经完成。
- 实际 VoiceOver 阅读与顺序：本机工具超时，尚未取得可靠证据。
- 本地系统音、候选试听、音量及停止的人耳确认：五事件连续短音已获用户确认，其余没有确认。
- 真实宿主回调、Provider 请求、生产凭据服务、系统权限和登录项。
- 干净已提交候选的固定基线门禁、远端 CI、双架构、正式签名、公证及发行。

上列未完成项保持未验证，不由原型的 64/64、48/48、511 项浏览器断言或任何自动构建替代。
