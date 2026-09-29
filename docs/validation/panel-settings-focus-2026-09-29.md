# 菜单与设置窗口独立焦点检查

## 当前结论

2026-09-29 22:48（Asia/Singapore），最终本地 Release 包完成 24 轮真实 CGEvent 操作，
所有已记录的菜单打开／收起区间均未发生桌面窗口重排。应用保持 `.accessory`，不显示 Dock
图标；没有为设置窗口临时切换应用类型。屏幕局部录制中也未观察到设置前后闪动。
这份记录替代此前只通过辅助功能触发的有限结论。

## 契约与修复

菜单 Panel 与唯一 retained Settings 分别拥有原生窗口及键盘焦点。菜单打开或普通关闭
不激活应用，不因 Settings 可见就前置它；原本在前的设置保持在前，后台设置保持后台。

ADR 0022 使用创建时声明 `.nonactivatingPanel` 的原生窗口，并增加状态项退激活前的短暂
顺序保护。`willResignActive` 时仅在 Settings／其 sheet 仍拥有 key、主鼠标键按下且命中
自己的状态按钮时进入保护。零时长显示事务立即提交临时层级，菜单显示后同一事务恢复
普通层级与原位置。回调丢失时最长 500ms 后仅解除临时层级，不抢回用户的新选择。
菜单关闭归还 key 不执行应用激活或窗口前置。生产源码不含临时诊断日志。

## 根因与失败对照

用户此前报告的后退发生在真实鼠标路径。macOS 27.0 先退激活前台 accessory app，
将此前普通应用排在设置前面，然后才转发状态项 action。因此等 `togglePanel` 回调后
恢复原位置已经太晚，能够恢复最终状态但仍产生闪动。

辅助功能 Raise 可让 Settings 出现在前面，但 `NSWorkspace.frontmostApplication` 仍是
Zed，不能作为“Claudio 真正处于应用前台”的替代起点。此前 AX 路径的绿色结果没有证明
物理鼠标路径正常；用户复核失败后不再采用这种方式建立前台测试条件。

| 对照 | 本机结果 |
| --- | --- |
| 仅非激活窗口／回调后恢复 | 仍有真实鼠标打开时的后退或闪动 |
| macOS 27 状态项 expanded-interface session | begin/end 回调工作，仍在 action 前后退 |
| 普通 Settings `NSWindow` | 2/2 前台图标开关失败 |
| 原生 `NSMenu` 或增加应用 main menu | 各 2/2 前台检查失败 |
| `.regular` 应用类型 | 可稳定顺序，但出现 Dock 图标；用户明确拒绝，未保留 |
| 临时提高层级但不立即提交显示事务 | 2/2 失败，事务仍晚于系统重排 |
| 退激活前保护并立即提交、菜单显示后解除 | 诊断包 13/13，清理后的最终包 24/24 |

失败记录包括 `/tmp/claudio-menu-f0c9.jsonl` 与
`/tmp/claudio-f0c9-physical-order.jsonl`；诊断对照结果在
`/tmp/claudio-{normal,nsmenu,mainmenu,guard,guard2}-*.results.json`。
这些是本机临时证据，不随代码提交。

## 最终包原生验证方法

环境：macOS 27.0、arm64、单屏；使用 MacOSX26.5 SDK 构建。
用户明确授权 CGEvent 操作 Claudio 与 Zed。

每轮先通过真实 Mission Control 鼠标选择建立起点：前台场景同时要求
`NSWorkspace.frontmostApplication` 为 Claudio 且 Settings 排在普通窗口最前；后台场景
再通过真实鼠标选择 Zed，确认 Zed 前台且排在设置之前。随后点击系统状态按钮，并要求
菜单原生窗口真实出现，再按对应方式关闭。

只读 `CGWindowListCopyWindowInfo` 记录所有窗口层级的顺序，按操作前原有窗口 ID 比较，
而非只比较 layer 0，否则会漏掉短暂层级保护。界面工具自己的临时叠层不计入桌面基线。
真实图标坐标由当前菜单栏辅助功能位置读取，操作事件始终由 CGEvent 发送。

| 初始状态 | 收起方式 | 最终包轮数 | 结果 |
| --- | --- | --- | --- |
| Settings 在前 | 点击同一菜单栏图标 | 3 | 顺序不变 |
| Settings 在前 | Esc | 6（其中 3 轮录屏） | 顺序不变 |
| Settings 在前 | 点击菜单外的设置空白处 | 3 | 顺序不变 |
| Zed 在前，Settings 在后 | 点击同一菜单栏图标 | 3 | 顺序不变 |
| Zed 在前，Settings 在后 | Esc | 6（其中 3 轮录屏） | 顺序不变 |
| Zed 在前，Settings 在后 | 点击菜单外的 Zed 空白处 | 3 | 顺序不变 |

基础 18 轮的操作区间共有 1,456 次顺序采样，均未变化；采样间隔中位数 19.9ms，
最大间隔 119.8ms。后续 6 轮同步录屏的窗口顺序检查也全部通过。增加运行类型采样后，
所有已记录样本的 activation policy 都是 1（`.accessory`）；包内 `LSUIElement=true`。
首组三轮图标检查未包含该字段，不能把后加入的字段说成覆盖先前所有瞬间。

原始结果与窗口日志：

- `/tmp/claudio-final-guard-{fg,bg}-{icon,esc,outside}.results.json`
- 对应的 `.windows.jsonl`
- `/tmp/claudio-final-guard-video-{fg,bg}.results.json` 及 `.windows.jsonl`

录屏只包含 Settings 与 Zed 重叠区域的一条窄屏幕切片（140×480pt），没有录音：

- `/tmp/claudio-final-guard-video-fg.mov`
- `/tmp/claudio-final-guard-video-bg.mov`
- 对应的 `.capture.json`、`.frame-analysis.json` 和 `.png` 联系表

前台片段在开关菜单期间持续显示设置侧栏；后台片段持续显示 Zed，没有短暂插入设置。
录制为可变帧率，静止内容不会逐帧重复编码；创建时间元数据只精确到秒，不能用这份录像
证明每一个显示刷新帧都已检查。原始事件时间与窗口顺序采样是操作区间的主要证据。

## 代码检查与构建身份

| 检查 | 结果 |
| --- | --- |
| `claudio-gui-tests --panel-settings-handback` | 84 checks，0 failures |
| helper `claudio-tests` | 4230 checks 全部通过 |
| GUI 完整 harness | 未通过；既存图标信号点断言失败；最后一次串行运行阻塞在系统 Vision OCR 初始化，采样后终止，不记为全量通过 |
| GUI Debug／Release 构建 | 通过，使用 MacOSX26.5 SDK |
| 修改的 Swift 文件严格格式检查 | 通过 |
| 本地化 JSON、`git diff --check` | 通过 |
| 本地 app 签名与构建身份 | ad-hoc 签名校验通过，app 与 Release 构建 UUID 一致 |

焦点夹具覆盖原生 key、Esc、AX Cancel、菜单子窗口、点外事件、Settings 附属 sheet、
一次性 handback，以及临时层级恢复、超时不抢回前台、关闭不重新显示和状态按钮坐标命中。
GUI 完整运行的系统 OCR 阻塞位于 `SettingsSoundsLayoutSuite.swift` 中
`VNRecognizeTextRequest` 初始化；该未完成结果不能由针对性检查替代。

最终包：`dist/claudi0.app`，arm64；验证时 PID 58765，实际可执行路径为
`dist/claudi0.app/Contents/MacOS/claudi0-app`。

- 构建 UUID：`CDDBA596-61FF-3B02-9075-F04CF9F48037`
- SHA-256：`5420992f857531599a4dcbec6d08c9e70345aab4ad0cc3a17e819356f94fa280`
- GUI 可执行文件：7,044,824 B，比默认 7,000,000 B 门槛多 44,824 B。
- 本地检查包显式使用 `CLAUDIO_GUI_BYTES_PER_ARCH=7100000`，仓库默认门槛未修改。
- 当前架构 ad-hoc 检查包；未制作 universal／Developer ID／公证发布包。

## 未覆盖的边界

上述结果限于本机记录的操作路径；不等于所有显示帧、所有 macOS 版本、VoiceOver、
中文输入法组字、全键盘访问、多屏或全屏 Space 的完整验收。点外检查使用当时已在前的
窗口空白处；没有据此声称点击另一应用时会吞掉用户的正常切换操作。
