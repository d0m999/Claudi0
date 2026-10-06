# 事件阅读器 GUI 回归修复

日期：2026-10-06。修复基线：`14f0640`，以下结果来自本次工作树。

## 失败与根因

修复前，SDK 26.5 下串行 `--event-attention` 为 1,167 项、10 项失败。
原测试假设 SwiftUI Button 必须挂载为 `NSButton`，并按数组下标点击第三个按钮。
原生探针实际观察到四个 `KeyViewProxy`、零个 `NSButton`，进程内 AX 子树也不可用。
八个来源导航场景因此在按钮数量断言后直接跳过，两个普通详情场景也无法验证动作集合。

## 修复与回归范围

- 使用同一稳定身份设置动作的 accessibility identifier 和仅限 Debug 的几何标记。
  所有阅读器按钮都使用这一入口，详情文本的标记同时记录实际挂载的会话值。
- 标记只观察原生视图位置，不持有或调用 Button action。测试按窗口查找唯一目标，向真实
  `NSPanel` 发送 `leftMouseDown` / `leftMouseUp`，由 SwiftUI Button 执行原来的闭包。
- 保留四动作／两动作集合、取消次数、焦点交接、迟到确认和提醒保留断言，移除失败后的
  `continue`；增加普通详情复制与返回的实际点击和捕获身份检查。
- 修正 fixture：使用支持 `.nonactivatingPanel` 的 `NSPanel`，macOS 13+ 固定 hosting sizing。
- 加入双窗口回归，覆盖其他阅读器刷新时同名动作与会话文本的隔离。初版探针只按 identifier
  保存一个视图，完整事件专项暴露了覆盖问题；最终按视图身份记录，按所属窗口查询。
- 增加 `--event-reader` 快速入口。记录器、原生标记及其状态均受 `#if DEBUG` 保护，Release
  保留原有 accessibility identifier，不创建测试标记。

## 验证

GUI/AppKit harness 与同包构建串行执行，没有重叠。使用本机兼容 SDK 26.5：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  swift run --package-path gui --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk claudio-gui-tests --event-reader
# 同一命令分别运行 --event-attention 和不带 flag 的全量 harness。
```

| 检查 | 结果 |
|---|---|
| 阅读器专项 | 80 checks，0 failures |
| 事件提醒专项 | 1,215 checks，0 failures |
| GUI 全量 | 17,785 checks，0 failures |
| GUI Debug 构建 | 通过 |
| GUI Release 构建 | 通过 |
| Release 二进制探针符号检查 | 三个记录器／标记类型均为 0 个符号 |
| 新增／修改 Swift 严格格式 | 通过；main.swift 保留 148 项既有诊断，新增 0 |
| localization JSON / git diff --check | 通过 |

临时日志：`/tmp/claudio-reader-fix-focused-final-20261006.log`、
`/tmp/claudio-reader-fix-attention-verified-20261006.log`、
`/tmp/claudio-reader-fix-full-verified-20261006.log`、
`/tmp/claudio-reader-fix-debug-verified-20261006.log`、
`/tmp/claudio-reader-fix-release-verified-20261006.log`。

这是实际挂载与合成原生鼠标事件的 harness 证据，不代表物理鼠标、完整键盘路径、VoiceOver、
真实宿主回调或听音验收。本次验证未重跑 helper harness，未打包或替换正在运行的 app；未推送。
此前集成实现的失败结果继续保留在其历史验证记录中。
