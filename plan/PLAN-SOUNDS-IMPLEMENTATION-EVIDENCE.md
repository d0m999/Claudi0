# 声音设置原生重设计：实施与证据

实施基线：`08da1a1a6f94a8275d76eeafe924e3080e775568`。
需求：[Spec #217](https://github.com/d0m999/Claudi0/issues/217)、[设计记录](PLAN-SOUNDS-INTERACTION-REDESIGN.md)、[实施规格](PLAN-SOUNDS-NATIVE-IMPLEMENTATION.md)。基线以后的既有设计修改也是输入。

## 实施状态

P0–P6 的生产接线纳入本轮本地提交；P7 处于验证收口阶段。本表的“实现”不代表正式验收。未推送、未发布应用，旧 issue 未关闭。

- 新声音页面只消费应用唯一的包库、包编辑 owner、生成协调器和两个持久存储。列表、包详情、草稿及生成记录有类型化位置；五种来源使用附属表单。
- 全部有效生成先归档，关窗继续；保存失败保留待处理结果，采用复制独立文件；命名草稿在首次绑定成功时原子发布。
- `.claudiopack` 为目录包，格式、安全限制见[导入说明](../docs/sound-pack-import-format.md)。历史、草稿、失败恢复及升级边界见[持久化说明](../docs/sound-assets-storage.md)。
- 复制与当前／历史生成采用移除整包 `license`、`author`，保留未知字段和独立归属材料；规范原型同步修正。

## D1–D55 对照

每项均有生产实现归属和回归入口。测试结果以文末实际运行记录为准，不能从套件名称推断全部手工场景已通过。

| 决定 | 已实现行为 | 阶段 | 生产归属 | 自动验证入口 | 原生证据边界 |
|---|---|---|---|---|---|
| D1 | 声音页以声音包为中心，移除工作区设置 | P6 | SettingsSoundsLibraryView / SettingsPresentationSession | SoundEditorAILifecycleSuite、SettingsSoundsLayoutSuite、SettingsNavigationHistorySuite | 原生挂载／交互夹具；完整人工矩阵待验收 |
| D2 | 声音页不显示工作区信息 | P6 | SettingsSoundsLibraryView / SettingsPresentationSession | SoundEditorAILifecycleSuite、SettingsSoundsLayoutSuite、SettingsNavigationHistorySuite | 原生挂载／交互夹具；完整人工矩阵待验收 |
| D3 | 列表进入详情，保持 macOS 交互风格 | P6 | SettingsSoundsLibraryView / SettingsPresentationSession | SoundEditorAILifecycleSuite、SettingsSoundsLayoutSuite、SettingsNavigationHistorySuite | 原生挂载／交互夹具；完整人工矩阵待验收 |
| D4 | 新建声音包先命名 | P3 | SoundPackDraftStore / SoundPackDirectoryTransfer / AICuePackDraftTransaction | SoundsRedesignCompositionSuite、AICuePackScopedSuite、SoundEditorAILifecycleSuite | 真实磁盘重建；应用重启人工验收待完成 |
| D5 | 逐事件使用统一的声音设置入口 | P6 | SettingsSoundsLibraryView / SettingsPresentationSession | SoundEditorAILifecycleSuite、SettingsSoundsLayoutSuite、SettingsNavigationHistorySuite | 原生挂载／交互夹具；完整人工矩阵待验收 |
| D6 | AI 生成采用窗口附属表单，容纳候选与试听 | P6 | SettingsSoundsLibraryView / SettingsPresentationSession | SoundEditorAILifecycleSuite、SettingsSoundsLayoutSuite、SettingsNavigationHistorySuite | 原生挂载／交互夹具；完整人工矩阵待验收 |
| D7 | 全部有效生成音频自动进入本地生成记录 | P1 / P4 | GenerationHistoryStore / SoundPacksEditorOwner | GenerationHistorySuite、SoundsRedesignCompositionSuite | 记录页面已接线；真实听感／访达找回待验收 |
| D8 | 生成记录同时保存原始声音描述 | P1 / P4 | GenerationHistoryStore / SoundPacksEditorOwner | GenerationHistorySuite、SoundsRedesignCompositionSuite | 记录页面已接线；真实听感／访达找回待验收 |
| D9 | 生成记录按每次生成分组 | P1 / P4 | GenerationHistoryStore / SoundPacksEditorOwner | GenerationHistorySuite、SoundsRedesignCompositionSuite | 记录页面已接线；真实听感／访达找回待验收 |
| D10 | 生成记录一直保留，由用户手动删除 | P1 / P4 | GenerationHistoryStore / SoundPacksEditorOwner | GenerationHistorySuite、SoundsRedesignCompositionSuite | 记录页面已接线；真实听感／访达找回待验收 |
| D11 | 删除生成记录不影响声音包内的独立副本 | P1 / P4 | GenerationHistoryStore / SoundPacksEditorOwner | GenerationHistorySuite、SoundsRedesignCompositionSuite | 记录页面已接线；真实听感／访达找回待验收 |
| D12 | 仅从事件入口选用历史音频 | P1 / P4 | GenerationHistoryStore / SoundPacksEditorOwner | GenerationHistorySuite、SoundsRedesignCompositionSuite | 记录页面已接线；真实听感／访达找回待验收 |
| D13 | 生成记录支持删除单条音频或整组 | P1 / P4 | GenerationHistoryStore / SoundPacksEditorOwner | GenerationHistorySuite、SoundsRedesignCompositionSuite | 记录页面已接线；真实听感／访达找回待验收 |
| D14 | 删除生成记录时移到 macOS 废纸篓 | P1 / P4 | GenerationHistoryStore / SoundPacksEditorOwner | GenerationHistorySuite、SoundsRedesignCompositionSuite | 记录页面已接线；真实听感／访达找回待验收 |
| D15 | 删除最后一条音频时一并移除生成组 | P1 / P4 | GenerationHistoryStore / SoundPacksEditorOwner | GenerationHistorySuite、SoundsRedesignCompositionSuite | 记录页面已接线；真实听感／访达找回待验收 |
| D16 | 单条删除不二次确认，整组删除需确认数量 | P1 / P4 | GenerationHistoryStore / SoundPacksEditorOwner | GenerationHistorySuite、SoundsRedesignCompositionSuite | 记录页面已接线；真实听感／访达找回待验收 |
| D17 | 关闭生成表单后继续在后台完成本次生成 | P2 | AICueGenerationCoordinator / AICueGenerationViewModel / AICueTerminationGate | GenerationHistorySuite、AICueGenerationViewModelSuite、SoundEditorAILifecycleSuite | 后台关闭流程夹具；最终应用退出对话框待验收 |
| D18 | 后台生成完成后仅在应用内提示 | P2 | AICueGenerationCoordinator / AICueGenerationViewModel / AICueTerminationGate | GenerationHistorySuite、AICueGenerationViewModelSuite、SoundEditorAILifecycleSuite | 后台关闭流程夹具；最终应用退出对话框待验收 |
| D19 | 离开声音页或关闭设置窗口不打断后台生成 | P2 | AICueGenerationCoordinator / AICueGenerationViewModel / AICueTerminationGate | GenerationHistorySuite、AICueGenerationViewModelSuite、SoundEditorAILifecycleSuite | 后台关闭流程夹具；最终应用退出对话框待验收 |
| D20 | 有未完成生成时，主动退出应用前提示 | P2 | AICueGenerationCoordinator / AICueGenerationViewModel / AICueTerminationGate | GenerationHistorySuite、AICueGenerationViewModelSuite、SoundEditorAILifecycleSuite | 后台关闭流程夹具；最终应用退出对话框待验收 |
| D21 | 整个应用同一时间只生成一组音频 | P2 | AICueGenerationCoordinator / AICueGenerationViewModel / AICueTerminationGate | GenerationHistorySuite、AICueGenerationViewModelSuite、SoundEditorAILifecycleSuite | 后台关闭流程夹具；最终应用退出对话框待验收 |
| D22 | 后台进度与取消操作统一放在生成记录 | P6 | SettingsSoundsLibraryView / SettingsPresentationSession | SoundEditorAILifecycleSuite、SettingsSoundsLayoutSuite、SettingsNavigationHistorySuite | 原生挂载／交互夹具；完整人工矩阵待验收 |
| D23 | 切换 AI 服务仅影响下一次生成 | P2 | AICueGenerationCoordinator / AICueGenerationViewModel / AICueTerminationGate | GenerationHistorySuite、AICueGenerationViewModelSuite、SoundEditorAILifecycleSuite | 后台关闭流程夹具；最终应用退出对话框待验收 |
| D24 | 声音页与生成表单复用同一套 AI 服务设置 | P6 | SettingsSoundsLibraryView / SettingsPresentationSession | SoundEditorAILifecycleSuite、SettingsSoundsLayoutSuite、SettingsNavigationHistorySuite | 原生挂载／交互夹具；完整人工矩阵待验收 |
| D25 | 包内声音修改逐次确认后立即保存 | P4 | SoundEventSelection / SoundPackImportBindTransaction / SoundPacksEditorOwner | SoundsRedesignCompositionSuite、SoundPackImportBindTransactionSuite、SoundPacksEditorAsyncOperationSuite | 来源菜单及附属表单夹具；全流程人工矩阵待验收 |
| D26 | 已命名的空声音包持久保留为草稿 | P3 | SoundPackDraftStore / SoundPackDirectoryTransfer / AICuePackDraftTransaction | SoundsRedesignCompositionSuite、AICuePackScopedSuite、SoundEditorAILifecycleSuite | 真实磁盘重建；应用重启人工验收待完成 |
| D27 | 内置包先在包级复制并编辑 | P3 | SoundPackDraftStore / SoundPackDirectoryTransfer / AICuePackDraftTransaction | SoundsRedesignCompositionSuite、AICuePackScopedSuite、SoundEditorAILifecycleSuite | 真实磁盘重建；应用重启人工验收待完成 |
| D28 | 事件的试听与更换直接放在包详情行内 | P6 | SettingsSoundsLibraryView / SettingsPresentationSession | SoundEditorAILifecycleSuite、SettingsSoundsLayoutSuite、SettingsNavigationHistorySuite | 原生挂载／交互夹具；完整人工矩阵待验收 |
| D29 | 清除操作使用独立的事件行按钮 | P6 | SettingsSoundsLibraryView / SettingsPresentationSession | SoundEditorAILifecycleSuite、SettingsSoundsLayoutSuite、SettingsNavigationHistorySuite | 原生挂载／交互夹具；完整人工矩阵待验收 |
| D30 | 点击清除直接执行，不二次确认 | P4 | SoundEventSelection / SoundPackImportBindTransaction / SoundPacksEditorOwner | SoundsRedesignCompositionSuite、SoundPackImportBindTransactionSuite、SoundPacksEditorAsyncOperationSuite | 来源菜单及附属表单夹具；全流程人工矩阵待验收 |
| D31 | 包内音频通过选择表单试听后显式选用 | P4 | SoundEventSelection / SoundPackImportBindTransaction / SoundPacksEditorOwner | SoundsRedesignCompositionSuite、SoundPackImportBindTransactionSuite、SoundPacksEditorAsyncOperationSuite | 来源菜单及附属表单夹具；全流程人工矩阵待验收 |
| D32 | 点选音频不自动试听 | P5 | SoundPacksEditorNativeEffectsDispatcher / NSSoundAudioPreviewPlayer / PackGallery | SoundsRedesignCompositionSuite、SoundPacksEditorNativeEffectsSuite、PackGallerySuite | 注入播放器回调；真实音频／设备／废纸篓待验收 |
| D33 | 声音页试听跟随 Mac 系统输出音量 | P5 | SoundPacksEditorNativeEffectsDispatcher / NSSoundAudioPreviewPlayer / PackGallery | SoundsRedesignCompositionSuite、SoundPacksEditorNativeEffectsSuite、PackGallerySuite | 注入播放器回调；真实音频／设备／废纸篓待验收 |
| D34 | 导入本地音频后先预览，再显式选用 | P4 | SoundEventSelection / SoundPackImportBindTransaction / SoundPacksEditorOwner | SoundsRedesignCompositionSuite、SoundPackImportBindTransactionSuite、SoundPacksEditorAsyncOperationSuite | 来源菜单及附属表单夹具；全流程人工矩阵待验收 |
| D35 | 生成表单只显示最新一组结果 | P2 | AICueGenerationCoordinator / AICueGenerationViewModel / AICueTerminationGate | GenerationHistorySuite、AICueGenerationViewModelSuite、SoundEditorAILifecycleSuite | 后台关闭流程夹具；最终应用退出对话框待验收 |
| D36 | 生成记录保存并分层展示时间、服务与时长 | P1 / P4 | GenerationHistoryStore / SoundPacksEditorOwner | GenerationHistorySuite、SoundsRedesignCompositionSuite | 记录页面已接线；真实听感／访达找回待验收 |
| D37 | 生成记录中的单条音频支持重命名 | P1 / P4 | GenerationHistoryStore / SoundPacksEditorOwner | GenerationHistorySuite、SoundsRedesignCompositionSuite | 记录页面已接线；真实听感／访达找回待验收 |
| D38 | 生成记录删除后不提供应用内撤销 | P1 / P4 | GenerationHistoryStore / SoundPacksEditorOwner | GenerationHistorySuite、SoundsRedesignCompositionSuite | 记录页面已接线；真实听感／访达找回待验收 |
| D39 | 成功保存到生成记录后才允许选用 | P2 | AICueGenerationCoordinator / AICueGenerationViewModel / AICueTerminationGate | GenerationHistorySuite、AICueGenerationViewModelSuite、SoundEditorAILifecycleSuite | 后台关闭流程夹具；最终应用退出对话框待验收 |
| D40 | 有音频尚未保存成功时，退出前同样提醒 | P2 | AICueGenerationCoordinator / AICueGenerationViewModel / AICueTerminationGate | GenerationHistorySuite、AICueGenerationViewModelSuite、SoundEditorAILifecycleSuite | 后台关闭流程夹具；最终应用退出对话框待验收 |
| D41 | 保存失败后允许关闭表单，在生成记录顶部继续处理 | P2 | AICueGenerationCoordinator / AICueGenerationViewModel / AICueTerminationGate | GenerationHistorySuite、AICueGenerationViewModelSuite、SoundEditorAILifecycleSuite | 后台关闭流程夹具；最终应用退出对话框待验收 |
| D42 | 保存失败的结果处理完后才允许再次生成 | P2 | AICueGenerationCoordinator / AICueGenerationViewModel / AICueTerminationGate | GenerationHistorySuite、AICueGenerationViewModelSuite、SoundEditorAILifecycleSuite | 后台关闭流程夹具；最终应用退出对话框待验收 |
| D43 | 放弃未保存音频时，确认数量后移到废纸篓 | P2 | AICueGenerationCoordinator / AICueGenerationViewModel / AICueTerminationGate | GenerationHistorySuite、AICueGenerationViewModelSuite、SoundEditorAILifecycleSuite | 后台关闭流程夹具；最终应用退出对话框待验收 |
| D44 | 试听按钮在播放中切换为停止 | P5 | SoundPacksEditorNativeEffectsDispatcher / NSSoundAudioPreviewPlayer / PackGallery | SoundsRedesignCompositionSuite、SoundPacksEditorNativeEffectsSuite、PackGallerySuite | 注入播放器回调；真实音频／设备／废纸篓待验收 |
| D45 | 离开声音页或关闭试听表单时立即停止试听 | P5 | SoundPacksEditorNativeEffectsDispatcher / NSSoundAudioPreviewPlayer / PackGallery | SoundsRedesignCompositionSuite、SoundPacksEditorNativeEffectsSuite、PackGallerySuite | 注入播放器回调；真实音频／设备／废纸篓待验收 |
| D46 | 主动取消生成直接执行，不二次确认 | P2 | AICueGenerationCoordinator / AICueGenerationViewModel / AICueTerminationGate | GenerationHistorySuite、AICueGenerationViewModelSuite、SoundEditorAILifecycleSuite | 后台关闭流程夹具；最终应用退出对话框待验收 |
| D47 | 再次生成时立即收起上一组结果 | P2 | AICueGenerationCoordinator / AICueGenerationViewModel / AICueTerminationGate | GenerationHistorySuite、AICueGenerationViewModelSuite、SoundEditorAILifecycleSuite | 后台关闭流程夹具；最终应用退出对话框待验收 |
| D48 | 通过“管理包内音频…”打开附属管理表单 | P6 | SettingsSoundsLibraryView / SettingsPresentationSession | SoundEditorAILifecycleSuite、SettingsSoundsLayoutSuite、SettingsNavigationHistorySuite | 原生挂载／交互夹具；完整人工矩阵待验收 |
| D49 | 删除未使用的包内音频时，确认后移到废纸篓 | P5 | SoundPacksEditorNativeEffectsDispatcher / NSSoundAudioPreviewPlayer / PackGallery | SoundsRedesignCompositionSuite、SoundPacksEditorNativeEffectsSuite、PackGallerySuite | 注入播放器回调；真实音频／设备／废纸篓待验收 |
| D50 | 包内音频统一从目标事件选择，管理表单不提供分配入口 | P6 | SettingsSoundsLibraryView / SettingsPresentationSession | SoundEditorAILifecycleSuite、SettingsSoundsLayoutSuite、SettingsNavigationHistorySuite | 原生挂载／交互夹具；完整人工矩阵待验收 |
| D51 | 本地音频统一在设置事件时导入 | P4 | SoundEventSelection / SoundPackImportBindTransaction / SoundPacksEditorOwner | SoundsRedesignCompositionSuite、SoundPackImportBindTransactionSuite、SoundPacksEditorAsyncOperationSuite | 来源菜单及附属表单夹具；全流程人工矩阵待验收 |
| D52 | 用户包详情常驻通用编辑后果说明 | P6 | SettingsSoundsLibraryView / SettingsPresentationSession | SoundEditorAILifecycleSuite、SettingsSoundsLayoutSuite、SettingsNavigationHistorySuite | 原生挂载／交互夹具；完整人工矩阵待验收 |
| D53 | 已创建的用户声音包支持重命名 | P3 | SoundPackDraftStore / SoundPackDirectoryTransfer / AICuePackDraftTransaction | SoundsRedesignCompositionSuite、AICuePackScopedSuite、SoundEditorAILifecycleSuite | 真实磁盘重建；应用重启人工验收待完成 |
| D54 | 新的命名操作不允许声音包同名 | P3 | SoundPackDraftStore / SoundPackDirectoryTransfer / AICuePackDraftTransaction | SoundsRedesignCompositionSuite、AICuePackScopedSuite、SoundEditorAILifecycleSuite | 真实磁盘重建；应用重启人工验收待完成 |
| D55 | 整体交互按审阅原型定稿 | P6 | SettingsSoundsLibraryView / SettingsPresentationSession | SoundEditorAILifecycleSuite、SettingsSoundsLayoutSuite、SettingsNavigationHistorySuite | 原生挂载／交互夹具；完整人工矩阵待验收 |

## 额外工程合同

| 合同 | 实现／验证 |
|---|---|
| 整包导入与目录包类型 | SoundPackDirectoryTransfer；dev-bundle.sh / release.yml 的 UTI；目录包预览、ID 冲突和链接拒绝回归 |
| 名称与身份分离 | SoundPackNames、AICuePackName；字符边界、宽度／大小写、双 store 竞争、旧同名无改动回归 |
| 安全文件读写 | PrivateSoundAssetIO；无跟随目录 fd、有界普通文件读取、短写循环、私有 staging、原子发布、可恢复 Trash；helper 写盘出口审计 |
| 采用能力 | 当前候选使用有效 permit；历史使用新字节证明；本地使用已验证预览；全部执行完整来源 CAS |
| 模态与焦点 | 同一 retained Settings 窗口、表单导航门禁；来源触发事件焦点归还；AI 生成期间移除可编辑 NSTextView |
| 本地化与无障碍 | 76 个新声音文案键，en／zh-Hans 对齐且注册 allKnown；事件、来源、播放、记录和恢复动作稳定 AX ID |

## 验证记录

运行环境：Apple M1（arm64）、APFS、macOS 27.0.1、Swift 6.4。GUI 按 CONTRIBUTING 的本机兼容方式显式使用 MacOSX26.5.sdk；最低部署版本仍为 macOS 12。原始本地输出保存在 `work/sounds-native-implementation/`，不提交运行日志、截图或二进制。

| 检查 | 实际结果 | 证据与限制 |
|---|---|---|
| Helper executable harness | 5,022 项通过 | `helper-tests-final.log`；包括新增写盘出口审计 |
| 声音核心集成／记录／ViewModel | 154 项通过 | `focused-tests.log`；真实隔离磁盘，受控 Provider／时钟／播放／Trash 边界 |
| 全量 GUI harness | 15,050 项中 15,049 项通过，1 项基线失败 | `gui-tests-final.log`；基线缺失动画原型，见下文 |
| 原生声音表单与生命周期 | 108 项通过 | `native-lifecycle-final.log`；包含 16 张可选流程截图、三条及一／二条候选、关闭继续、凭据返回、AI 草稿首音发布 |
| 原生描述框键盘焦点 | 20 项通过 | `native-focus-final.log`；实际 NSTextView 输入、Space、Escape、取消后返回；不等于完整键盘／VoiceOver 验收 |
| 原生设置布局 | 1,487 项通过 | `native-layout.log`；八页 × 两种语言 × 两种外观 × 两种尺寸，附加紧凑菜单／高对比度检查；不是系统辅助功能完整人工矩阵 |
| Debug／Release ClaudioGUI | 通过（Debug 2.80 s，Release 20.34 s） | 显式兼容 SDK；不代表 macOS 12 实机或 Intel 验证 |
| 100 包 Release 性能 | 通过 | 首次 p95 407.200 ms ≤ 500 ms；已有快照 p95 0.264 ms ≤ 100 ms；增量 p95 59.915 ms；`performance.log` |
| Swift 格式 | 61 个改动／新增 Swift 文件，0 诊断 | `swift format lint --strict`；相对实施基线同一批文件原有 157 条诊断，新增 0；格式基线副本在仓库外 |
| 原型 Node／本地化／diff | 通过 | `test-panel-settings-prototype.js`、xcstrings `jq empty`、`git diff --check`；Node 不能替代浏览器视觉验收 |
| 本地包体积／签名／目录包类型 | arm64 ad-hoc 包通过 | GUI 6,567,776 B／7,000,000 B；helper 3,155,552 B／3,250,000 B；包内正规文件 12,264,765 B／13,850,000 B；`codesign --verify --deep --strict` 通过；`.claudiopack` 声明读回正确 |
| 干净候选统一设置门禁 | 未通过前提检查 | 脚本要求 clean HEAD；未清理、重置、暂存或代替用户提交共享工作树 |

全量 GUI 的已知基线阻塞是 `EventAnimationIntegrationSuite.swift:266` 读取不到 `designs/pixel-motion/Pixel Motion Prototype.html`。实施基线 `git ls-tree 08da1a1a6f94a8275d76eeafe924e3080e775568 -- <该路径>` 同样为空。未伪造缺失原型、跳过测试或放宽断言；因此全量门禁不记为全绿。

截图在 `native-layout/` 和 `native-sound-flow/` 中。已目视检查声音列表明暗画面、包详情、三条候选及部分成功表单；最小窗口的生成表单服务区改用紧凑布局，保留共同服务 owner、管理入口和许可说明。截图来自生产页面的隔离 AppKit 挂载夹具，数据和 Provider 均为 fixture，不能算最终应用或真实 Provider 接受。

## 本地验收产物

`dist/claudi0.app`，当前 arm64 架构、ad-hoc 签名，来源为上述实施基线加当前未提交工作树。GUI 二进制 SHA-256：`efa6a25afc0397f545d242c43ea0b77e62e4f8aaa46ac8815bc1f242a50f80f2`。原本的本地验收包已复制到仓库外保存，定位记录在本轮本地输出目录；没有替换已安装应用或启动真实用户数据环境。

`dev-bundle.sh`、`check-release-size.sh`、独立签名检查及 Info.plist 类型声明读回均通过。仅此包体积／签名／资源结构获得验证；实际启动、原生手工流程、Intel、正式签名及公证没有因此获得验证。

## 尚未完成的原生与外部验收

| 项目 | 当前证据 | 剩余边界 |
|---|---|---|
| 中文／英文、1240×820／960×640、明暗 | 原生布局夹具通过 | 最终应用长名称／长描述／错误文本的完整人工走查 |
| 增强对比度／降低透明度 | 既有原生样式夹具覆盖部分合同 | 系统设置切换与全部新表单人工矩阵未验证 |
| 键盘与无障碍 | 描述框真实焦点／输入与既有原生导航检查 | Tab／Shift-Tab、方向键、Return、输入法组字、VoiceOver 全流程未验证 |
| 生成与退出 | app-lifetime 集成、关闭／切服务／取消及终止判定回归 | 最终应用真实退出确认和重复退出原生对话框未验证 |
| 音频 | 受控播放器完成／失败／迟到回调及相对增益 1.0 | 真实听感、输出设备切换、系统音量变化、组音量为零的实机播放未验证 |
| Trash | 真实隔离文件 + 注入 Trash 成功／失败／恢复失败 | 系统废纸篓与访达找回的最终应用操作未验证 |
| 重启 | 重建 store 后草稿／记录磁盘事实一致 | 最终应用退出重启人工验证未完成；未保存结果不承诺恢复 |
| Provider | 固定路线政策、请求次数、取消隔离与候选链 fixture | 未发起付费真实请求；费用、返回、听感与构建身份待单独授权验证 |
| 发布 | 本轮仅本地提交，无推送、发布或旧 issue 关闭 | Intel、macOS 12 实机、Developer ID、notarization、CI 与正式接受未验证 |

P7 尚未达到规格中的全部完成标准。自动 fixture、原生挂载、真实系统行为、最终构建身份及正式接受分别记录；旧 SenseAudio 豁免不扩展到本轮。
