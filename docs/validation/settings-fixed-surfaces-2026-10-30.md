# 设置固定表面与反馈图标对比度（2026-10-30）

基线：`2bf3efe`（最近一次 CI 失败）。本记录只证明设置内容底、功能组与反馈图标对比度的本轮修复；不宣称正式验收、真实宿主或 macOS 26 人工走查通过。

## 问题

`6b5aaf2` 把设置成功／警告／错误图标改为 DESIGN.md「UI 语义色」表值，并新增 12 条「图标 × 明暗 × 窗口／功能组 ≥3:1」断言，但表面仍取系统语义色。CI 的 macOS 26 runner 上：

| 表面 | 解析值 | success | warning | error |
| --- | --- | ---: | ---: | ---: |
| `windowBackgroundColor`（亮） | `#ECECEC` | **2.778** | 3.50 | 3.69 |
| `underPageBackgroundColor`（亮） | `#969696`，alpha 0.898 | **1.110** | **1.326** | **1.397** |
| 上者合成到窗口底（约 `#9F9F9F`） | — | **1.24** | **1.48** | **1.56** |

同一断言在本机 macOS 27 上通过，因为该系统把两个语义色解析为 `#FFFFFF` / `#F6F6F6`（success 对 group 3.04）。本机不红、CI 必红来自 OS 解析差异，而不是测试环境噪声；macOS 26 是受支持的用户环境（部署下限 macOS 12）。

## 决议

实现侧恢复固定设计表面，图标与 12 条 ≥3:1 断言保持不变：

- `settings-window`：亮 `#FFFFFF` / 暗 `#202022`
- `settings-group`：亮 `#F5F5F7` / 暗 `#2D2D30`

来源为主原型 `--page` / `--group`（`designs/panel-and-settings/Panel and Settings Prototype.html`）。侧栏 source-list、统一工具栏、文字、分隔线与强调色仍由系统语义色绘制。理由与完整表格见 `DESIGN.md`「设置固定表面（现行 · 2026-10-30）」。

## 修复后对比度

| 表面 | success | warning | error |
| --- | ---: | ---: | ---: |
| 亮 window `#FFFFFF` | 3.2818 | 3.9210 | 4.1324 |
| 亮 group `#F5F5F7` | 3.0140 | 3.6011 | 3.7952 |
| 暗 window `#202022` | 7.3267 | 7.9122 | 4.7744 |
| 暗 group `#2D2D30` | 6.1843 | 6.6786 | 4.0300 |

最薄一对为亮色 success 对 group **3.014:1**，只高出门槛 0.014。任何 group 亮色改动都必须重测三色。

## 改动

- `gui/Sources/ClaudioGUICore/ClaudioColorHex.swift`：四个 `settings*` token（单一 hex owner）。
- `gui/Sources/ClaudioGUIComponents/ClaudioTheme.swift`、`SettingsAppearance.swift`、`SettingsNativeSurface.swift`、`SettingsSectionSurface.swift`：按 `ColorScheme` / `effectiveAppearance` 解析固定表面；`cardSurface` 更名 `groupSurface`；AppKit 表面不透明。
- `gui/Sources/ClaudioSettingsPresentation/{SettingsSoundsLibraryView,AboutSettingsSheet,EventSettingsWindowView}.swift`：附属表单改为固定窗口底。
- `gui/Sources/ClaudioGUI/SettingsWindowController.swift`：回归 JSON 的 `semanticColors` 改报固定 token（key 与消费脚本不变）。
- 测试：`ContrastSuite`（固定 token 数学 + 映射/不透明断言）、`FeedbackPixelSupport`、`AICueTaskSurfaceSuite`、`SettingsFeedbackNativeSuite`、`MountedVolumeLifecycleSuite`、`SettingsSoundsLayoutSuite` 的 fixture 与期望底同步为固定表面。
- 文档：`DESIGN.md` 新增「设置固定表面」并修正 2026-10-04 原生语义节中涉及内容底／功能组的表述；`settings-feedback-colors-2026-10-26.md` 增加前向注记。

## 验证

- `swift build --package-path gui --target ClaudioGUICore`：Build complete（新增 token 与 Foundation 层可编译）。
- `swift run --package-path helper claudio-tests`：**6,409 checks 全部通过**（helper 未受影响）。
- CI 契约：`test-ci-cache-identity.py`（4 条 lane 指纹）、`test-ci-whitespace.py`、`test-ci-gui-harness.py`、`test-ci-swift-toolchain.py` 全部通过；`ci.yml` YAML 解析通过；`ReleaseLayoutSuite` 的 ci.yml 断言（缓存顺序、4 条同 key、3 恢复／1 保存、`needs`、7 条 `-Osize`／LTO）用等价脚本复算通过。
- 诊断消费者 `node scripts/test-native-ui-regression.mjs`：25/25 通过。
- `jq empty` 与 `git diff --check`：通过；改动行的 `swift format lint --strict` 无新增诊断（`ContrastSuite` 保留既有行宽诊断）。
- 对比度数值由独立 WCAG 脚本复算，与 `DESIGN.md` 表逐位一致；`NSColor(Color)` 探针确认四个固定表面在各 appearance 下解析为精确 sRGB 且 alpha = 1。
- **未运行**：GUI 后台／前台 harness、Debug/Release 构建与 bundle。本机只有 CommandLineTools，没有 Xcode 的 SwiftUI 宏插件（`SwiftUIMacros`），无法编译 SwiftUI target；`ContrastSuite` 与挂载像素套件只能由 macOS 26 CI 证明。

## CI 回执（2026-10-30，run 41041029200 / `952f643`）

- `gui` lane **通过**：后台批、对比度映射断言、焦点原生选择器与两个画廊在 macOS 26 上全绿；这证明固定表面修复解决了原来的 4 条对比度红灯。
- `helper` lane 通过。
- `gui-foreground`：挂载百分比标签在 1x 显示器上没有全遮盖像素，2 条断言失败；已改为沿 ink→底色混合路径计数的部分遮盖模式（`6d1c688`）。
- `gui-bundle`：签名后 GUI `7,005,552 B` 超过旧 `7,000,000 B` 预算；按用户决定重基线为 `7,100,000 B`，详见 `docs/performance/release-size-budget.md` 2026-10-30 节。
- 最终全绿回执：[CI run 41047114738](https://github.com/d0m999/Claudio/actions/runs/41047114738)（`fcae496`）。后台 **15,431**、前台 **13,740**、helper **6,409** checks 全部通过；`gui-bundle` 未签名 `6,973,664 B`、签名后 `7,005,552 B` / `7,100,000 B`，helper `2,881,376 B` / `3,250,000 B`。

## 未验证

- macOS 26 挂载像素套件已包含在 CI run 41047114738 的前台批并通过；本机没有复跑。真实 job 图的人工目视仍未覆盖。
- VoiceOver、真实宿主回调与音频、macOS 12 实机、签名／公证：本轮未覆盖。
- 统一工具栏与侧栏保持系统材质；macOS 26 上内容层与 chrome 之间可能存在轻微接缝，未做人工视觉验收。
