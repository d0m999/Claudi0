# 第三批：设置错误反馈与语义色（2026-10-26）

基线：`66af148d342053b5e2fbd0f8e0d92fdbf8bff422`，`main`，开始时工作树干净。
本记录记录实施候选的提交前验证结果。本批已获精确范围本地提交授权；不包含 push、发布或 issue 状态变更。

**当前收口状态：本批实现、最终四个前台 selectors、后台、Debug 构建、格式及外部 AX 复验均已完成。现有浏览器全量仍有基线可复现的失败，见下文；clean HEAD 综合门禁将在本地提交后执行，结果另行补记。**

## 实现范围

- 设置成功／警告／错误分别使用 `NSColor.systemGreen`／`systemOrange`／`systemRed`，信息使用系统强调色，反馈正文使用 `secondaryLabelColor`。保留原分类与告警底色透明度。
- package 内部环境标记在设置内容最外层启用并传递到 sheet；`FailureRow` 公共初始化接口及默认面板颜色保留。
- 声音错误入口与 AI 局部失败使用共享错误行；活动、连接、关于、登录项、工作区、提醒与静音、AI 服务与凭据反馈沿用同一颜色合同。未新增播报通道或动作 owner。
- AI 展开卡片使用 `SettingsNativeSurface(.group)`，普通描边为系统分隔色，增强对比度为次级文字色 60%／1.5 pt。原尺寸、圆角、状态转换、焦点与 Reduce Motion 保留。
- 音量百分比只在既有 `usesSettingsAppearance` 分支换色；原 Slider、字号、宽度及提交／回滚路径保留。
- 同步主原型的设置提示与表单错误、`DESIGN.md` 现行说明。未修改面板、品牌、五事件、事件动画预览、导航入口、配置或领域 owner；未挂载的旧 AI composer 未清理。

## RED / GREEN 方法与边界

原生回归挂载生产组件，不新增字符串扫描式配色测试。错误根页与真实命名 sheet 覆盖中英文 × 明暗 × 960／1240；另覆盖长消息、增强对比度、AX 完整消息、取消和默认面板隔离。AI 卡片遍历 generating／saving／pending／results／failed／ready，音量沿用现有实际挂载生命周期回归。

颜色从被测 view 的 `effectiveAppearance` 解析，转为 sRGB，包含系统 alpha 与窗口／功能组底色合成；不以固定 RGB 作为原生颜色合同。

初版根页 fixture 在窗口首次刷新时清空了预置失败，不能作为颜色 RED。已改为挂载后通过真实 session 请求触发 adapter 拒绝，并先断言失败事实存在。恢复按钮按实际 AXButton 角色和本地化动作名定位：本机 SwiftUI 把其 ID 投影为页面 ID，该现象未由本轮修改。原型关闭保留隐藏 DOM，测试按可见性断言，未要求删除节点。

有效 RED 对照仅暂时使用 `66af148` 的三个组件（`FailureRow`、`AICueTaskSurface`、`SharedMasterVolumeSlider`），其余当前测试与页面接线不变；随后恢复实现。没有提交、保存源码备份或削弱断言。

表中保留初轮颜色对照与最终 AX 补充后的结果；后续 AX 名称检查及收口见下方。

| 入口 | 组件基线 RED | 实现 GREEN |
|---|---:|---:|
| `--foreground --settings-polish-native` | 270 checks / 22 failures | 270 checks / 0 failures（颜色阶段）；278 checks / 0 failures（最终 AX 补充后） |
| `--foreground --app-motion` | 132 checks / 20 failures | 132 checks / 0 failures |
| `--foreground --mounted-lifecycle-contracts` | 314 checks / 2 failures | 314 checks / 0 failures |

RED 分别命中根页／sheet／长消息颜色、AI 功能组底色和音量百分比。面板默认错误色、操作、取消与原有形变测量不因 RED 对照失败。

## 验证环境与结果

本机 macOS 27.0.1 / arm64 / Swift 6.4，按 `CONTRIBUTING.md` 使用 macOS 26.5 SDK 兼容通道：

```bash
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift run --package-path gui --build-system native --sdk "$SDKROOT" claudio-gui-tests --foreground --settings-polish-native
```

后续 selectors 使用同一次构建的 `gui/.build/arm64-apple-macosx/debug/claudio-gui-tests`，前台 harness 与 Computer Use 串行。

- GUI 后台 harness：15,363 executed checks，通过。
- GUI Debug product 构建：通过。
- 本地化 JSON、`git diff --check`：通过。
- 涉及的 Swift 文件 strict-format 相对基线：68 → 68，新增 0；没有顺带清理既有诊断。
- Node 主原型现有回归：109 / 109，通过。
- 新增浏览器反馈用例：2 tests，通过；覆盖两语言、明暗、错误全文、中性正文、装饰颜色、alert role、重试与关闭。
- `--foreground --five-page-settings-native`：903 checks / 0 failures。
- `--foreground --five-page-forms-native`：541 checks / 0 failures。
- `--foreground --settings-navigation-native-focus`：287 checks / 0 failures。临时把 `AppleKeyboardUIMode` 从 `0` 设为 `2`，批次后读回恢复为 `0`。
- 全量浏览器回归：79 tests，30 failures / 26 errors，未通过。当前 56 条失败／错误签名全部在 `66af148` 原型对照中出现，新增签名为 0，包含旧八页／快捷键／旧 AI 控件等范围外测试。基线为 35 failures / 28 errors，其中 5 项为本轮新用例的预期颜色 RED，另 2 项额外错误只在临时路径的基线对照出现，未据此宣称修复。
- 格式诊断脚本自身回归：通过。

## 原生与人工证据

使用当前源码构建专用 `CLAUDIO_UI_REGRESSION` DEBUG app，经 Computer Use 的实际点击、按键及原生窗口截图走查。所有数据／Provider／活动操作均为隔离 fixture，没有真实付费请求、凭据操作、宿主回调或试听。

- 中文深色、960×640：无效名称通过 Return 触发完整错误，装饰图标红色，正文中性；可拖选整个错误句子。聚焦输入框后 Esc 关闭表单。选择错误文字、点击标题后，单次 Esc 未关闭；临时使用 `66af148` 的 `SettingsSoundsLibraryView` 原始 `Text` 错误正文复验，相同操作同样不关闭，重新聚焦输入框后 Esc 正常。该早期观察不作为全焦点状态取消通过的证据；最终候选从已选择的错误文本直接按 Esc 已复验关闭，见下方。
- 实际系统偏好组合：粉色强调色、增强对比度开启、降低透明度开启。设置组与 AI 展开卡片底色一致、加强描边清晰；服务成功图标为系统绿色、正文中性，主要动作及焦点环跟随粉色。
- AI 多行输入的原生 `Control+Tab` 到达生成按钮，Space 启动隔离生成并自动聚焦取消按钮；再次 Space 取消，保留描述。Esc 关闭表单并返回原事件来源控件焦点。普通 Tab 在多行输入中插入制表符，未把它记为控件遍历。
- 活动页通过 fixture 的 `revealLog: { false }` 呈现失败：红色图标与中性正文分离，AX 保留完整消息。Shift+Tab 两次可到达恢复动作，Space 可执行；清除活动确认按 Esc 后恢复原清除按钮焦点，计数仍保留。
- 以上为代表窗口走查，完整语言／明暗／宽度矩阵由前述挂载回归覆盖，不宣称逐组合人工验收。

最小证据：

- [基线整段红色错误](evidence/settings-feedback-2026-10-26/name-error-baseline.png)
- [命名表单完整错误与文本选择](evidence/settings-feedback-2026-10-26/name-error-dark.png)
- [粉色／增强对比度／降低透明度下的根页中性错误](evidence/settings-feedback-2026-10-26/settings-high-contrast-pink.png)
- [AI 卡片、系统功能组与取消焦点](evidence/settings-feedback-2026-10-26/ai-high-contrast-pink.png)
- [挂载 RED／GREEN 运行节选](evidence/settings-feedback-2026-10-26/mounted-results.txt)
- [浏览器基线与候选失败签名对照](evidence/settings-feedback-2026-10-26/browser-results.json)

临时系统偏好已恢复并逐键读回：`AppleAccentColor` 与 `AppleAquaColorVariant` 均恢复为不存在；`AppleKeyboardUIMode`、`increaseContrast`、`reduceTransparency` 与 `reduceMotion` 均为原值 `0`。UI 已恢复多色、自动外观、对比度／降低透明度关闭，并返回系统设置原来的通用页。外观选择未修改。

安装工具隔离检查：`swift`、`swiftc`、`python3`、`node`、`ffprobe`、`ffmpeg` 的真实可执行文件 SHA-256 与 POSIX mode 在 setup 前与全部收尾后均一致；不把仅内容 hash 一致当作隔离通过。初轮临时 app、独立构建 scratch 与 fixture 已删除。追加对照产生的基线 app／fixture 和冗余日志也在收尾删除。最终专用 Debug app 已完成解锁后的复验，随后一并删除；未保留源码／构建备份。

## 最终 AX 收口状态

冷启动的 Computer Use 快照曾省略共享错误行；同进程的公共系统 AX 属性读取能取得完整名称。这两类证据不同，未据此判断 VoiceOver 实际朗读结果。最终 `FailureRow` 仅在设置环境下显式设置完整 `accessibilityLabel(message)` 和静态文本 trait，面板沿用原分支与语义。没有新增播报调用。

- 增加真实命名表单的系统 AX 属性断言：必须是 `AXStaticText`，且名称／值包含完整本地化错误。读取保持 `MainActor`，因为 self-process AX 调用会直接进入 AppKit。
- `2026-10-25T17:06:16Z` 后桌面曾锁定，Computer Use 对系统设置和测试 app 都返回 `cgWindowNotFound`。该阶段仅运行后台与构建，没有绕过锁屏或把锁屏期间的前台结果计为通过。
- 桌面恢复可用后，在最终专用 Debug app 上由外部 Computer Use 冷启动触发错误，确认 `settings.sounds.error` 为静态文本，完整消息可见。拖选仍可用，错误文字获得实际焦点后直接 Esc 关闭表单。该成功不等于已验证所有焦点状态的取消。
- **最终候选重跑**：`--settings-polish-native` **278 / 0**，`--five-page-settings-native` **903 / 0**，`--five-page-forms-native` **541 / 0**，`--settings-navigation-native-focus` **287 / 0**，均带 `--foreground`、串行执行。键盘导航再度恢复为原值 `0`。
- **最终候选收尾**：GUI 后台 **15,363 checks，通过**；GUI Debug product **构建通过**；本地化、格式及 diff 检查通过。体积／最终 clean HEAD 综合门禁仍按下文边界处理。
- [最终四个前台批次摘要](evidence/settings-feedback-2026-10-26/final-foreground-results.txt)
- [最终外部 AX 快照](evidence/settings-feedback-2026-10-26/name-error-final.ax.txt)；[最终后台／构建摘要](evidence/settings-feedback-2026-10-26/final-background-build.txt)。

## 未验证与后续门禁

VoiceOver 实际朗读、macOS 12 真机、真实宿主回调、真实 Provider 与音频、Apple Silicon 跨版本兼容、正式签名／公证、生产就绪及正式验收未验证。AX、fixture 挂载、浏览器与构建不能代替这些证据。

实施期尚未运行要求 clean HEAD 的最终综合门禁。现已获得本批精确范围本地提交授权，随后在干净候选上执行：

```bash
bash scripts/verify-settings-experience.sh 66af148 --foreground
```

体积、格式与其他门禁脚本保持原样；不以未提交候选的局部检查替代最终综合门禁。
