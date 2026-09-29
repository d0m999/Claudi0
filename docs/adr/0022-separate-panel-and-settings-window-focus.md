---
status: accepted
---

# 菜单与统一设置独立取得键盘焦点并保持窗口顺序

菜单 Panel 和唯一 retained Settings 窗口都以 `.nonactivatingPanel` 初始化。
`MenuBarPanel` 持有菜单原生窗口、状态栏锚定及 Esc／点外／切换应用的关闭边界；
`SettingsWindowController` 继续持有 ADR 0008 定义的同一个设置窗口、typed route 和关闭 handback。
领域模型、设置内容及配置写入 owner 不变。

这个决定来自实际窗口顺序故障：原实现为 `NSPopover` 取得 key 时激活应用，连带 Settings；
状态栏转发点击前的退激活，以及关闭 popover 时 AppKit 自动选择 main/key window，
都能改变桌面顺序。关闭后重新激活、等窗口后退再恢复最终位置，仍会产生用户可见的闪动。
应用始终保持 `.accessory`，包括设置打开期间；不得为规避系统行为临时切换为带 Dock 图标的
`.regular`。这是独立窗口实现的硬约束。

菜单的展示和普通关闭都不激活应用。打开前只记录当前 Settings 或附属 sheet 的 key 身份；
显式关闭时只调用 `makeKey()` 归还该目标，点外或切换应用时保留用户的新选择。
后台 Settings 暂时退出自动 key 候选，关闭菜单后恢复普通键盘资格，防止隐藏窗口接走输入。
设置在正常使用期间保持 `.normal` 层级。主动打开设置或显式 AX Raise 经
`presentForUserRequest()` 使用 `orderFrontRegardless()` 和 `makeKey()` 将它显示到前面；
菜单关闭归还 key 时不执行该排序操作。
该 API 的非激活前置语义见
[Apple 文档](https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless%28%29)。

## 状态栏转发点击前的保护

macOS 27.0 真机记录表明，真正处于应用前台的 accessory Settings 在物理状态栏鼠标按下后，
会先收到 `willResignActive`，随后系统将上一个普通应用排到 Settings 前面，最后才转发状态项
action。单独换成非激活窗口或状态项 expanded-interface session 不能消除这个早期重排。
辅助功能 Raise 后 `NSWorkspace.frontmostApplication` 仍可能是另一应用，不能替代这条路径。

`SettingsWindowController` 在 `willResignActive` 同步检查三项当前事实：Settings 或其附属
sheet 仍拥有原生 key、主鼠标键确实按下、当前位置命中自己的状态按钮。只有三项同时成立才
启动 `StatusItemWindowOrderGuard`。保护把原本在前的 Settings 临时提高一个窗口层级，在
零时长 `NSAnimationContext` 中通过 `CATransaction.flush()` 立即提交，赶在系统重排前保持
原位置。后台 Settings 不满足 key 条件，不进入保护。

菜单原生窗口显示后，在同一个显示事务中恢复原层级与原本的前方位置，立即结束保护。
菜单的 key handback 使用这次保护保留的当前 key 身份；不维护一个猜测前台应用的历史缓存。
若状态项 action 未到达，最长 500ms 后只恢复原层级，不执行前置；设置关闭也会清理保护。
因此保护不成为永久置顶、应用激活或普通菜单关闭时的排序策略。

本机真实鼠标事件的对照与验收范围见
[窗口焦点检查记录](../validation/panel-settings-focus-2026-09-29.md)。

代价是需要自行持有菜单锚定与关闭监视器，不能继续依赖 NSPopover 的 transient 行为。
现行 312pt 宽、560pt 首选高度、现有 SwiftUI 内容、圆角和焦点顺序继续有效；
历史 T15 的 NSPopover 尖角不再属于当前窗口外壳。
真实 NSPanel 回归覆盖 key、窗口顺序、前台应用、取消与 sheet；VoiceOver 和输入法组字的
完整验收需分别记录，不能由窗口测试推定。
