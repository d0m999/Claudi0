# 横幅共享实测布局验证（2026-10-13）

规格：[统一横幅实测布局协作与原子提交 #219](https://github.com/d0m999/Claudi0/issues/219)。issue 的标题、完整规格正文及 `ready-for-agent` 标签已读回核对。

本次在 `main`、起始 HEAD `742ed2b6b357df0dd311161f112256462f1af650` 的干净工作区实施。没有新建 worktree、提交、推送、发行或关闭 issue。

## 实现边界

- `EventNoticeStackPresentation` 是生产窗口、画廊和原生 fixture 共用的测量／布局协作模块。模型继续唯一拥有展示 FIFO、版本、预算和动效；导航协调器和窗口的职责未转移。
- 测量 token 绑定 epoch、环境代次、宽度及捕获的内容，接受当前请求的首个有限正高度。回调只排队，普通订阅合并后读取已提交状态。输出先提交再通知，支持订阅回调中的隐私撤回与几何变更。
- `commitStackLayout` 一次复验候选和版本，统一发布容量、准入与位置。几何不可用只暂停阅读、隐藏窗口；有效期和导航期限照常推进。
- 队列入口逐个候选可见数量测量展开／收起两态；容量提示、8 pt 间距、有效退场占位和剩余队列空间共同受可用高度限制；列表取内容自然高度、220 pt 和剩余空间三者的最小值。测量副本分批挂载，合计最多八个。
- 旧同步 AppKit fixture 改为注入确定性调度器并驱动实际 SwiftUI 测量，避免占用 MainActor 时等待实时调度器。原生 stack fixture 不再自算容量、位置或窗口高度。

## 自动检查

本机为 arm64 macOS 27.0.1；本轮 GUI 使用已安装的 macOS 26.5 SDK。命令均从仓库根执行，使用 executable harness。

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  swift run --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  --package-path gui claudio-gui-tests --event-stack
```

同一命令分别使用 `--view-wiring`、`--event-stack-native`、`--event-attention`、`--event-reading-live`；完整 GUI harness 不传筛选参数。原生执行串行。

| 检查 | 结果 |
|---|---|
| `--event-stack` | 249 checks，0 failures |
| `--view-wiring` | 298 checks，0 failures |
| `--event-stack-native` | 190 checks，0 failures |
| `--event-attention` | 1,865 checks，0 failures |
| `--event-reading-live` | 96 checks，0 failures |
| 完整 GUI harness | 24,496 checks，0 failures |
| 完整 helper harness | 20,604 checks，609 failures；见下文 |
| GUI Debug 构建 | 通过（普通 Debug 构建） |
| 本地化 JSON、`git diff --check`、Swift 格式 | 已通过 |

确定性覆盖包含 0／1／3 卡、未测量 FIFO 前项、50 条上限、逐 k 队列预留、剩余列表高度、过期／重复／非法测量、同代次反馈乱序、宽度 A→B→A、新版原位更新、独立预算、回队、原子发布和订阅重入。几何隐藏经过十秒推进仍保留预算，30 分钟保留期限及原始三秒导航预算未延长。

原生挂载覆盖中英 × 明暗 × 440／268 pt、导航反馈增高、退场反馈快照、容量提示、实际队列滚动、逐条动作身份、隐藏副本的辅助功能隔离，短队列按自然高度收紧，以及按当前系统设置绘制的阅读轨。268 pt 的实际输出宽度有单独断言。

### helper 门禁失败

609 项全部来自 `AtomicWriteSuite.swift`。它递归扫描工作区内非隐藏目录，纳入了已有 `dist/` 下的历史候选、副本和构建依赖，因而源码树清单、SPM 包清单、写盘表面及调用点台账不匹配。失败日志中的逐文件诊断都指向这些 `dist/` 副本，另有集合／计数汇总失败。本次没有删除产物、放宽扫描器或把这项失败计为通过。

首次完整 GUI 检查为 24,471 checks／2 failures，均为旧 `ViewWiringSuite` 的变量名／隐藏入口字符串断言；已按当前跨模块接线更新。随后 `--view-wiring` 的 298 项通过，完整门禁曾以 24,483 checks／0 failures 通过；最终短队列修复后的结果记录在上表。

## 原生窗口控制器

通过现有 `scripts/build-native-ui-regression.sh` 构建隔离回归包，使用当前起始 HEAD 作为 `CLAUDIO_UI_REGRESSION_BASE_SHA`，显式选择 macOS 26.5 SDK。回归包为本地 ad-hoc 签名，不是发行产物。构建证据枚举使用 `lstat`，符号链接记录为链接，不读取其目标。

固定入口 `--event-stack-window-regression` 运行真正的 `EventNoticeWindowController`／`EventNoticePanel` 和 delegate，只替换屏幕输入与领域时钟。运行时通过 `DYLD_FRAMEWORK_PATH` 指向同一构建的 Sparkle 依赖；未修改已安装应用或真实来源应用。最终构建连续三次运行，以下 9 项检查每次均通过：

1. 完成初始实测并显示窗口。
2. 显式交互窗口能成为 key window。
3. 程序性隐藏使窗口不可见。
4. 隐藏期间暂停阅读。
5. 程序性 resign-key 不清空展示身份。
6. 隐藏宿主完成测量并恢复展示。
7. 恢复不取得 key window。
8. 恢复不重播入场。
9. 向另一真实 AppKit panel 交接 key window 后，原交互栈按既有规则关闭。

此前一次运行的初始等待及两个后续断言失败；同一旧构建复跑通过，加入超时状态诊断后的最终构建连续三次通过。根因未确认，保留为原生测试时序风险；原始失败日志未删除，未声称偶发失败已经消除。

这验证了真实窗口对象与委托接线，但不是人工外部点击或真实宿主导航。Computer Use 连接本轮超时，没有把其缺失算作成功。

## 人工与外部检查

| 项目 | 本轮证据 |
|---|---|
| 多屏、拔屏、刘海安全区 | 未人工验证；保留 placement 计算测试 |
| Spaces／全屏应用切换 | 未验证 |
| 键盘焦点 | 隔离原生 key window 交接已验证；人工 Tab 顺序及外部应用点击透传未验证 |
| VoiceOver | 实际 AX 树中的身份和隐藏隔离已检查；朗读未验证 |
| 系统字体／显示缩放 | 字体环境失效接缝已覆盖；真实系统设置切换未验证 |
| Reduce Motion | 原有模型动效与受控绘制测试保留；真实系统偏好切换未验证 |
| 真实宿主回调／来源导航／真实音频 | 未验证，不属于此次布局交付的自动证据 |
| Developer ID／公证／发行 | 未执行 |

本机详细日志与原生构建身份保存在忽略目录 `dist/event-stack-presentation-2026-10-13/`。这些记录不代表正式验收。
