# 事件动画接入与自动验证记录

状态：实现与自动验收完成，整体验收 **PASS**。资源一致性、适用工程门禁、32 组原生布局、点击、键盘、异常恢复、真正重启及真实横幅操作均已通过，相关截图已由 Codex 实际查看。本记录不设置人工验收关卡。

规格：[PLAN-EVENT-ANIMATION.md](../../plan/PLAN-EVENT-ANIMATION.md)，[Issue #216](https://github.com/d0m999/Claudi0/issues/216)。机器可读记录见 [event-animation-2026-10-03.json](event-animation-2026-10-03.json)。

## 实现范围

定稿 HTML 是角色画面、逐帧时长、静态帧和产品循环范围的唯一来源。导出流程直接执行 HTML 的 Canvas 与时序函数，先校验临时输出再更新资源；运行包只持有四份图集、三份时序及来源清单，共八个文件。机械小鸭采用明暗两套图集，幽灵和比特币采用已核对像素一致的共用图集。设置 HTML 原型读取同一导出数据。

原生设置使用保留的统一窗口及类型化「通知 → 事件动画」路由，四种样式并排，默认原版。偏好由 `ClaudioPreferences` 保存；关闭角色显示仍记住选择，静态模式与系统 Reduce Motion 使用动作声明的静态帧。损坏或未来配置只读回落，直到明确选择才替换原始字节。

设置预览与真实横幅复用资源、帧解析及横幅内容。预览有独立四秒会话，不创建真实提醒、声音或宿主操作；离页、关闭和不可见时停止调度。真实横幅使用已有阅读预算，暂停、重试及外观变化保持进度；普通消息保持中立静态，权限与输入请求使用待响应动作。资源失败回落原版，设置显示原因和显式重试。

GUI Release 的五条构建命令统一采用 SwiftPM full LTO，保留所有原有体积、资源、架构、导出和签名门禁。helper、LoginItem、Debug 及 harness 命令不采用 LTO。具体合同见 [release-size-budget.md](../performance/release-size-budget.md)。

## 候选与运行环境

共享仓库已有并行 C1 声音／集成改动。验证使用只含本功能的隔离、干净、已提交候选；没有提交主仓库、清理其他改动、推送、发行或关闭 Issue。

| 身份 | 值 |
|---|---|
| 固定实现基线 | `0f8b5a04fec6f03e982649f91e0c87581d496740` |
| 隔离 LTO 候选 | `3322be93c25160a6607769f9c90191a68f4a30fc` |
| 首轮原生布局候选 | `0d24c5417c73c7c4a802b2063fee066c1f72d341` |
| 定稿 HTML SHA-256 | `d2b3cf0e8440785149a803e6927e72171bceb30892afdd218d31da2bd21529c4` |
| Runtime 来源清单 SHA-256 | `2d5fbe91377f9e9163c3490042537b2a8dab14c6dc7f0523803870899879c6b7` |
| 原生 DEBUG bundle SHA-256 | `ea344017a98e6204969c87cec3c28e50318a80088b58cd5692305a29f358ac26` |
| 标准 Release bundle SHA-256 | `8f1b971d39d7b7ec4fb2fb5b6011cbc38c739b9bdc60d437c204959e4521c634` |
| 标准 Release GUI SHA-256 | `cc98f3d0210306d22cd69390aa93051ebe85833633d7207e7c3d4bbca76dfdcf` |
| LTO 候选原生源码指纹 | `4354fbeb3e2b39f259a067aaef81c84788a233b7d74291ed8ef724438693483e` |
| 本机环境 | macOS 27.0.1、arm64、Swift 6.4、SDK 26.5 |

SDK 27 的 SwiftUI macro 缺失也影响旧代码；本机验证明确使用已安装的 SDK 26.5，没有修改系统工具链。新原生 bundle 的 29 个文件与首轮原生矩阵 bundle 逐条相同。两候选差异仅为三个构建脚本／workflow、LTO 合同测试和原生驱动焦点前置步骤；生产呈现及运行资源字节一致。该对应关系记录在 `/tmp/claudio-event-animation-native-candidate-parity.json`。

最终原生操作使用候选外的测试驱动 `a6963da2`：保留新鲜 AX Raise 与快捷键前置步骤；必要时依据当前截图和窗口几何点击标题栏，随后仍核对真正 key 状态。生产源码及 bundle 未修改，工程候选内驱动 `7fee45eb` 与最终执行驱动分别登记，不替换源码指纹。最终驱动语法检查与实际原生操作通过。

## 已运行的验证

| 检查 | 结果 | 证据边界 |
|---|---|---|
| HTML 与运行资源 | PASS：480 参考帧、1083 时序边界、源码变化拒绝旧导出 | `/tmp/claudio-event-animation-resource-candidate.log`；八个运行文件与候选一致 |
| 原生动画专项 | PASS：3859 项 | 偏好、声明时序、暂停恢复、循环衔接、外观保持进度、静态、调度停止、失败重试及预览竞争 |
| 生产设置根视图挂载布局 | PASS：4115 项、32 张截图 | 四样式 × 中英 × 明暗 × 两种尺寸；挂载位图及滚动末尾可达 |
| Computer Use 原生布局 | PASS：32 组，另两张最小窗口底部补证 | 最新 AX、选择态、真实窗口几何、偏好读回 |
| Computer Use 最终操作 | PASS：五类必测流程、六条结果 | 点击与五事件预览、键盘、损坏恢复、退出／重启、横幅来源失败与重试；`results.json` 的第 13–18 项，索引从零开始 |
| 同字节新候选原生补证 | PASS | `3322` Debug bundle 再次实际退出／重启及偏好原始字节读回；异常原因、显式重试和关闭显示状态滚动到底部截图完整可见 |
| 真实动画横幅 | PASS：画面与操作 | 原生比特币横幅正面帧与来源操作中的边缘帧已实际查看；聚焦暂停时阅读预算 `4 → 4`；单次、循环、暂停恢复的确定性检查另由 3859 项专项覆盖 |
| Codex 截图检查 | PASS：原生 32 张、挂载 32 张及最终 19 张均实际查看 | 卡片并排、选中态、像素缩放、长标签、裁切／重叠；底部补证覆盖异常原因、重试和有效状态。额外白图明确记录为失焦后横幅关闭，不用来证明恢复 |
| 设置 HTML 原型 | PASS：Chromium 141 与 Chrome 154 各 129 项 | 同源数据、动态 Reduce Motion 与资源加载期间系统偏好变化；浏览器不证明原生交互 |
| 独立合同审查 | 无新增确认缺陷 | 只读代码审查，不替代测试、CUA 或 bundle 门禁 |
| 新 DEBUG bundle 构建及签名 | PASS | 当前架构临时 fixture，字节与矩阵 bundle 一致 |
| helper / GUI 全量 harness | PASS：4275 / 16886 项 | 第二次完整工程门禁，未跳过 suite |
| Settings target / GUI executable | PASS：各 Debug、Release | 四项构建，使用 SDK 26.5 |
| 本地化、diff、格式 | PASS | catalog JSON；候选两次 diff 检查；strict format 基线和 HEAD 均 849，无新增；共享树另独立 diff 检查通过 |
| 标准 bundle、签名及体积 | PASS | 实际 arm64 ad-hoc app；签名前后原预算、零产品导出、架构及资源检查均通过 |
| 统一工程门禁 | PASS，exit 0 | `/tmp/claudio-event-animation-scoped-lto-gate-rerun.log:3020`，绑定候选 `3322be93` |

原生与挂载截图分别位于 `/tmp/claudio-event-animation-final-native/` 和 `/tmp/claudio-event-animation-final-mounted-layout/`。对应运行日志、报告、截图清单及 SHA-256 由机器记录绑定。

最终视觉记录为 `/tmp/claudio-event-animation-native-final-visual.json`；新候选底部及重启补证位于 `/tmp/claudio-event-animation-supplemental-native/`。主操作、补充操作、截图、AX、驱动和工具诊断的校验值均登记在机器记录中。

## 失败记录与恢复边界

旧标准 `-Osize` 候选 GUI 在签名前为 `7,122,184 B`，超过 `7,000,000 B` 预算。预算没有调整；采用官方 SwiftPM full LTO 后，同一标准装包流程的签名前后门禁均通过。独立实验的签后 `5,619,104 B` 仅作为优化依据；本次实际 app 数值如下。

| 实际标准 app | 签名前 B | 签后 B | 原预算 B |
|---|---:|---:|---:|
| GUI | 5,607,880 | 5,619,136 | 7,000,000 |
| helper | 3,197,960 | 3,179,520 | 3,250,000 |
| LoginItem | 54,304 | 54,144 | 500,000 |
| 非可执行资源 | 2,397,597 | 2,412,585 | 3,100,000 |
| bundle 正规文件合计 | 11,257,741 | 11,265,385 | 13,850,000 |

实际打包的八份动画资源共 `97,062 B`，逐文件 SHA-256 与候选源资源一致。bundle 指纹使用按相对路径排序的文件与符号链接记录，算法、每文件校验值及链接目标记录在 `/tmp/claudio-event-animation-standard-bundle-manifest.json`。

新候选第一次统一门禁在 16887 项 GUI 检查中出现一项 `AICueRuntimeSuite.swift:712` 等待 Provider 悬挂超时。该测试仅以 2000 次 `Task.yield()` 为等待上限；同次运行随后 Provider 完成、迟到结果隔离及清理断言均通过。测试与生产路径相对基线未变。单次已编译接缝隔离为 112 项、零失败；随后一次无并行重构建的完整复验为 16886 项、零失败，并通过全部后续门禁。首轮多一项计数来自超时分支的额外 `expect(false)`，没有减少注册或断言。第一次失败日志保留。

挂载截图首轮遗漏输出目录，32 项保存失败；补建目录后同一源码重跑，4115 项、零失败，并实际检查全部截图。没有删除保存断言或改写失败回执。

原生驱动首轮点击／键盘流程在非激活设置窗口失去 key 后，焦点等待失败；仅添加 Raise 与快捷键的首次复验仍出现同类失败。随后增加依据当前截图与窗口几何点击标题栏的恢复步骤，继续保持原 key-focus 断言。最终完整点击和键盘流程均通过；修复前失败及其回执保持记录。此修复只涉及自动化驱动。

桌面锁定曾导致 `cgWindowNotFound`，用户解锁后原生矩阵已通过。本轮诊断确认旧工具运行时仍映射已删除的 Sparkle 安装路径，代码签名查找返回 `OSStatus 100002 / FileNotFound`；新运行时签名验证成功，直接 `cua.getApp` 已恢复。旧运行时失效是历史 native startup failure 的强候选原因；由于外层工具序列化丢弃内层错误 cause，不能把它写成所有历史失败的唯一已确证根因。

另已确认浏览器和动态工具 socket 因 `untrusted-process-ancestry` 拒绝当前 Zed CLI 进程链；`cua.getState` 会等待包含浏览器清单的 `Promise.allSettled`，因此其超时不等于原生管道仍不可用。恢复验证使用公开的原生 app 入口。没有修改工具安装、权限或进程，也没有绕过信任检查；没有执行 kill。诊断分别记录在 `/tmp/cua-service-log-diagnostic.json` 和 `/tmp/cua-transport-diagnostic.json`。

额外横幅观察中的 `timeoutReached` 已另行定位：当时 fixture 进程健康、原生 app 清单读取正常，但没有可见窗口；采样显示主线程正常等待事件。交互横幅失去 key 后按既有 `windowDidResignKey → close → model.dismiss` 生命周期关闭，空白截图对应关闭状态。该截图不用于宣称动画恢复，也不把无窗口观察误记为管道失败或必测项 BLOCKED；恢复和循环规则由确定性专项检查证明。

| 最终原生必测项 | 最终状态 |
|---|---|
| 点击、五事件、Replay、开关、返回焦点、离页及预览隔离 | PASS |
| Tab 顺序、四样式 Space、五事件、Replay、开关与 Back Space | PASS |
| 资源损坏原因、原版回落、选择保留及显式重试 | PASS，另有底部原因及重试截图 |
| 同一 bundle 真正退出／重启与偏好字节读回 | PASS，另在同字节 `3322` Debug bundle 再次通过 |
| 真实横幅来源失败／重试、预算保持、提醒寿命与关闭 handback | PASS，来源激活仍为 fixture 替身 |

包含并行 C1 改动的另一份全工作区快照曾在 16968 项 GUI 检查中失败 17 项；声音作用域等行为和 source-wiring 差异属于那份候选，不混入本功能隔离候选的通过结论。该完整日志也保留，不能宣称当前共享工作树全部通过。

VoiceOver 实际朗读、真实听感、真实宿主回调均为 **NOT VERIFIED**，不增加为本次动画接入的完成条件。远端 CI、x86_64、正式签名、公证和发行未执行。
