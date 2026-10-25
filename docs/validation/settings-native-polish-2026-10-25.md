# 设置原生对齐：第一批四项（2026-10-25）

实现起点：`8d081fc33e4d220795789e510822225797104e86`。实施验证时 HEAD 为
`c20e5fc48eb1208e0614ba892de04564b58dff4b`；并行提交只修改另外三个测试文件，与本轮无重叠。
下列为本轮四项改动与回归 suite 的提交前验证记录。

## 范围

- 自动检查更新使用 mini `NSSwitch`，保留适配器回写与不可用状态门控。
- 仅删除声音包列表正文重复的页名；工具栏、包详情与生成记录标题保留。
- 宿主详情的“诊断详情…”使用既有 `EventAnimationActionButton` 和 chevron，保留宿主目标及浏览历史。
- 活动与诊断的两个清除按钮移除图标，保留 destructive role、确认弹窗、禁用状态及进度反馈。

未调整拖放浮标、工作区来源勾选、视觉待定项、token、字体层级或配置与状态 owner；无新增 UI 文案。

## 自动验证

本机为 Swift 6.4 / arm64，按 `CONTRIBUTING.md` 使用兼容的 macOS 26.5 SDK。
以下两个 harness 及 Debug 构建均使用
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`，并向 SwiftPM 传入
`--build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`。

- `swift run --package-path helper claudio-tests`：6,187 checks，通过。
- `swift run --package-path gui claudio-gui-tests`：25,450 checks，通过。
- `swift run --package-path gui claudio-gui-tests --settings-polish-native`：148 checks，0 failures。
- `swift build -c debug --package-path gui --product ClaudioGUI`：通过。
- `jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings`：通过。
- `git diff --check`：通过。
- 改动 Swift 文件相对基线的格式诊断增量为 0；`ActivityDiagnosticsView.swift` 原有 69 条诊断未扩展修复。

25,450 项全量结果先于并行提交。收尾在 `c20e5fc` 上重跑本轮原生 suite，仍为 148 checks / 0 failures；
另外补跑 `--panel-settings-handback`（134 checks / 0 failures）及 `runSoundPacksRefreshSuites()`
（临时独立入口，273 checks / 0 failures），覆盖该并行提交的三个测试文件，随后删除临时入口。
没有把先前的全量计数冒充为新 HEAD 的全量结果。

新增 suite 已登记到完整 GUI harness，覆盖中英文、明暗、960/1240 两种宽度：
更新控件的原生类型、尺寸、辅助功能标题、单次回写与投影状态；声音列表去重及详情/记录标题保留；
诊断行的焦点资格、Space/Return 单次导航与返回；两个清除动作的进度、禁用和完成状态。
进行中的清除控件由 SwiftUI 暴露为 `AXBusyIndicator`，测试按实际角色检查。

修改前的原生挂载确认了默认 checkbox、列表重复标题与普通诊断按钮；初版探针中的进度定位错误
在修改生产代码之外单独修正，未把该测试错误当成产品回归。

## 实际窗口走查

通过临时测试 App 挂载 `SettingsPresentationFixtures.generalLogin` 与生产设置外壳，使用
computer-use 的真实点击/按键和窗口截图检查。该临时入口与 App 在走查后删除。
更新回写为 fixture 内存投影，清除动作使用既有模拟操作；没有操作真实宿主、更新服务或用户日志。

- 中文浅色 1240×820、英文深色 960×640：目视五页、活动与诊断及关于 sheet；四项改动均可见，文字未截断。
- 更新开关点击从 off 变 on，Tab 可到关于入口；Return 打开关于，Esc 关闭并恢复关于入口焦点。
- 侧栏 Down 按五页顺序切换，并跨过分组间距。
- Codex 详情 Tab 到诊断行，焦点环包住整行；Return 与 Space 均进入 Codex 诊断，返回恢复原行焦点。
- 两个清除动作均先显示相应确认；取消按钮关闭弹窗，模拟确认后分别出现正确的成功反馈。
- 事件动画暴露原生 radio 组，Right 从“原版图标”移到“机械小鸭”；角色资源在该 fixture 中未注入。

未把以下观察记为通过：声音页从侧栏 Tab 后，辅助功能树未报告正文焦点；一次活动清除弹窗
按 Esc 未关闭（点击取消正常）。尚未完成这两项的基线对照与完整五页 Tab 顺序验证，不能归因于
本轮改动。清除确认实现未修改；这些观察应在后续原生键盘验收中复查。

## 验收边界

原生探针使用隔离 fixture 和真实呈现组件，不代表真实宿主、Provider、音频或更新服务验收。
VoiceOver 实际朗读尚未验证。SDK 兼容通道不替代 CI Xcode、架构、签名或发布验证。

提交前尚未执行最终 `bash scripts/verify-settings-experience.sh 8d081fc33e4d220795789e510822225797104e86`：
脚本要求 clean HEAD；按 `DESIGN.md` 现行章节，须待精确范围本地提交获授权后运行。
本轮不包含 push、发布或修改 issue 状态。
