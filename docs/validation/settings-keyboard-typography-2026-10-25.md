# 设置键盘、字体与间距：第二批验证

基线：`main@78f189cc303296eb86fbfcee228710c900e41c46`，开始时工作树干净。实施验收时未 commit；未 push、发布或修改宿主配置。

环境：macOS 27.0.1、arm64、Apple Swift 6.4。按 `CONTRIBUTING.md` 选择本机 `MacOSX26.5.sdk`；这是本地兼容性证据，不替代 CI Xcode 或发布验收。

## 测试修正与产品修复

旧 `SettingsNavigationFocusSuite` 从 `.about` 启动，但该路由现在打开附属表单；它还期待退役的作用域下拉框和静态标题 Tab 停靠点。原始基线运行是 `10 checks, 5 failures`，这些失败不能当作产品缺陷。现改为五页真实控件，保留导航焦点、空列表、禁用控件、正反遍历及不写配置的合同。

探针与生产窗口一样启用 `autorecalculatesKeyViewLoop`。鼠标释放事件先入队，避免同步 `mouseDown` 的跟踪循环等待尚未发送的 `mouseUp`；Shift+Tab 使用 AppKit 的 back-tab 字符。关于表单也改由窗口派发真实 keyDown/keyUp，不再直接调用 `selectNextKeyView` 代替按键。

确认并修复的产品问题：

| 问题 | 基线行为 | 最小修复与回归 |
|---|---|---|
| 清除活动／清除日志取消 | Esc 不关闭旧确认；取消后的入口焦点不可靠 | 使用显式 `.cancelAction` 的原生确认；本地 FocusState 在关闭后恢复触发按钮。窗口按键、实际 key window、操作记录共同验证取消零次、明确确认一次 |
| 声音包详情返回 | Tab→Space 进入包详情，工具栏返回后焦点停在工具栏 | 包与草稿入口复用已有 `EventAnimationActionButton`，保留布局、名称、草稿状态与标识，让现有历史捕获原生焦点身份；Back 回到同一入口，不应用包 |
| key 生命周期被遮挡回调降级 | 实际 `NSApp.keyWindow` 仍为设置窗口，会话却是 `.hidden`，焦点债务未消费，Tab 可停在 `NSScroller` | 原窗口适配器通过可编译的 `SettingsWindowPhase.native` 投影保留可见窗口的原生 key 身份；像素遮挡只影响非 key 窗口。没有新增导航或状态 owner |

取消与生命周期修复前的原始失败摘录：

```text
✗ escape dismisses the native confirmation
✗ Back restores the pack entry's actual focus
✗ native key ownership must not be downgraded by an occlusion callback
Settings navigation native focus: 287 checks, 1 failures
```

最后一条来自抽取原逻辑后的生命周期回归；改为保留 native key 后，同一专项为 `287 checks, 0 failures`。动态连接→活动入口也通过 Tab/Space 到达，测试不再手动重算窗口循环。

隔离验收工具另修正两处启动阻碍：测试 App 打包时嵌入现有的 Sparkle framework；没有 completion binding 的可见候选宿主，以其已支持的 audible binding 生成合成回执。它们不是实际宿主回调或当前激活证据。

## 字体与间距范围

10 处设置专属 `.headline` 改为 `SettingsAppearance.font(.body).weight(.semibold)`；活动页 4 处 `.caption2` 改为设置 caption。保留 `monospacedDigit()`、25pt 数字、header trait、现有标识、共享 `EventNoticeReadingView`、表格列宽、大标题及拖放浮标。

只将声音页／事件动画页外层 20pt 改为 `sectionGap`，以及指定的 10 个纵向信息组 12pt 改为 `informationGap`。token 原值仍为 20／12；没有替换 `padding(12)`，没有修改颜色、Slider、警告牌、品牌块、角色瓷砖、横幅预览或动效几何。没有添加纯 token 的字符串扫描测试。

## 自动与挂载验证

GUI 命令均使用：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift run --package-path gui --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk claudio-gui-tests <参数>
```

| 参数／检查 | 最终结果 |
|---|---|
| `--foreground --settings-navigation-native-focus` | 287 checks，0 failures |
| `--foreground --settings-polish-native` | 156 checks，0 failures；包括公开预览标题的八组合挂载 |
| `--foreground --five-page-settings-native` | 903 checks，0 failures |
| `--foreground --five-page-forms-native` | 541 checks，0 failures |
| GUI `--background` | 15,195 checks，全部通过 |
| `swift build -c debug --package-path gui --product ClaudioGUI`，同 SDK | 通过 |
| `--foreground --sound-editor-ai-lifecycle` | 125 checks，0 failures；补充描述、来源表单、候选及生成记录挂载 |
| xcstrings `jq empty`、`git diff --check` | 通过 |
| 与基线比较 changed Swift 文件的 `swift format lint --strict` | 新增诊断 0；既有诊断不冒充本批回归 |

原生挂载覆盖中文／英文 × 浅色／深色 × 960／1240 宽度；检查工作区来源标题的换行、声音包列表、活动摘要与来源指标、通用公开预览标题，以及滚动可达的表单。截图仅用于本批检查，收尾删除可重建的批量截图与临时拼图。

## Computer Use 与剩余边界

最终隔离 App 的 bundle 清单 SHA-256 为 `b68da660618bd6764729143fa20a606c52fc01e0d12413f6543effdabce9541d`。打包时工作树 fingerprint 为 `2f431f6a526ee17594fc835f9fbc451b3a02cc9e8602b67aa3aa8a1f2b7e3169`；验收后逐一核对 287 个 `gui/Sources/` Swift 文件，均与该 App 的源码清单一致。验证记录本身在打包后收尾，不将此工作树描述为干净 HEAD。

实际 Computer Use 按键与前台 harness 串行执行。运行时 `NSApp.isFullKeyboardAccessEnabled == true`。

| 实际窗口组合 | 工作区 | 声音包 | 连接 | 提醒与静音 | 通用 |
|---|---|---|---|---|---|
| 中文、浅色、1240×820 | 正反遍历通过 | 正反遍历通过 | 正反遍历通过 | 正反遍历通过 | 正反遍历通过 |
| 英文、深色、960×640 | 正反遍历通过 | 正反遍历通过 | 正反遍历通过 | 正反遍历通过 | 正反遍历通过 |

每组均由实际侧栏焦点开始，派发 Tab／Shift+Tab，核对 AX 焦点、实际 responder 类型／身份、窗口 `.key` 状态及声音配置未变；侧栏 Down／Up 跳过分组间隔。一次窗口中断和一次长批次超时的未完结果排除，刷新窗口后逐页重跑完整通过。

两个清除操作分别通过 Esc、聚焦取消按钮后 Space、明确聚焦确认按钮后 Space。六条实际路径全部通过：取消保留磁盘活动／日志事实，焦点回到原按钮；确认只清除对应 fixture 数据。执行一次的计数合同另由窗口派发按键的操作 recorder 验证。

关于入口 Return、sheet 内八次 Tab／八次 Shift+Tab、Esc 与入口焦点环恢复通过。事件动画原生 radio 的 Right／Left、Space／Return 通过。只读包的禁用删除被跳过；包入口 Return→工具栏 Back 的 Space→同一包入口焦点恢复通过，没有播放试听。

导入确认中的包名、AI 描述、待处理和已保存标题已实际挂载检查。为覆盖存储待处理，只在本次隔离 root 的 `generation-history` 路径制造文件／目录冲突；本地合成生成器产生三个候选后进入待处理。恢复该私有目录并点重试后进入已保存，生成请求数仍为一次。未采用候选，未调用真实 Provider。

空列表由原生挂载回归覆盖。Computer Use 的磁盘空库场景仍保留配置当前引用的不可用包入口，故不把该占位项计作“无条目列表”证据；不为验收删除或改写该领域行为。

一次切换验收 App 的运行因辅助闭包仍指向旧实例而作废；它的混合读回不计入通过记录。最终读回必须与当前 bundle、进程及窗口对应。SwiftUI 外部 AX 在部分通用控件上暴露容器标识，因此同时核对焦点控件标签、原生 responder 类型及可见焦点环，不把容器 ID 当作目标控件证明。

VoiceOver 实际朗读、真实宿主、真实音频、Provider 网络请求、登录／Focus／Calendar 的真实系统授权、签名公证、发布与正式验收未验证。

`bash scripts/verify-settings-experience.sh 78f189cc303296eb86fbfcee228710c900e41c46 --foreground` 在实施验收时未运行：该门禁要求干净 HEAD。用户随后授权精确范围本地提交，提交后补跑；结果见下文。

## 收尾

系统 `AppleKeyboardUIMode` 初始为 `0`，验收期间为 `2`，结束后恢复 `0`。新的后台 AppKit 进程读取 `NSApplication.shared.isFullKeyboardAccessEnabled == false`，确认恢复为关闭。

停止隔离 App 后，按已核对的精确路径删除本批 7 个 App／额外构建目录、9 个 UI fixture root、6 个遗留 harness fixture root、本批截图／临时拼图／探针／日志和两份缺依赖的测试 App 崩溃报告。未清理主 checkout 的常规 `.build` 缓存、其他任务目录、用户声音包、运行时备份或宿主回执。没有保留源码副本、恢复包或独立 patch。

实施验收收尾对前置快照中的 6 个真实可执行文件（`swift`、`swiftc`、`python3`、`node`、`git`、`codesign` 的解析后路径）再次比较 SHA-256 与 POSIX mode，变化为零。清理没有遗留跳过项；`git diff --check` 与本地化 JSON 检查通过，彼时 HEAD 仍为上述基线。

## 本地提交后的综合门禁

用户授权 `commit` 后，18 个范围内文件提交为 `19fccf962cadfa5572d66972339ffd1385ffe8fe`（`fix(gui): refine settings keyboard focus and typography`）。在该干净 HEAD 上运行：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
CLAUDIO_BUILD_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
bash scripts/verify-settings-experience.sh \
  78f189cc303296eb86fbfcee228710c900e41c46 --foreground
```

门禁退出码为 `1`，未通过。格式诊断脚本自测及套件注册检查通过；Helper 为 `6,187 checks` 全部通过，GUI `--all` 为 `25,729 checks`、`3 failures`。三条实际失败均来自 `PanelSettingsHandbackSuite.swift` 的同一个原生窗口用例：

```text
✗ 夹具必须分别建立前台和后台设置  (PanelSettingsHandbackSuite.swift:55)
✗ 菜单关闭后普通窗口顺序必须保持不变  (PanelSettingsHandbackSuite.swift:76)
✗ 设置的键盘归还不能改变窗口顺序  (PanelSettingsHandbackSuite.swift:81)
✗ all: 3 of 25729 checks FAILED
```

该失败用例直接构造 `RetainedSettingsWindow`，没有挂载本批修改的 `SettingsWindowController`。该测试、`RetainedSettingsWindow`、`MenuBarPanel` 和 `PanelSettingsHandback` 均与基线相同。随后同 SDK 单独运行 `--foreground --panel-settings-handback` 为 `134 checks, 0 failures`，未复现。全量上下文中的夹具前提及窗口顺序异常尚未归因；独立通过不能替代失败的综合门禁，本批未扩修窗口排序。

脚本因 GUI 失败提前退出，其后管理的 Settings target 与 GUI Debug／Release 构建、打包、体积检查、diff 检查及严格格式基线比较均未执行。上文独立执行的构建与专项结果保留各自的证据范围。

补跑期间键盘导航从 `0` 临时改为 `2`，两次前台进程结束后均恢复 `0`；新的后台 AppKit 进程再次确认 `isFullKeyboardAccessEnabled == false`。清理本次门禁新增的 35 个合成 fixture 目录（28 个 composer、6 个依赖夹具、1 个 Helper 夹具）；其中仅对隔离 Helper 临时文件清除遗留的不可变标志后删除。临时日志、采样和快照在记录最小结果后删除。未触及既有 `dist/` App 或主 checkout 的常规 `.build` 缓存。6 个真实工具在全部清理后的 SHA-256 与 POSIX mode 仍无变化。未 push、发布或修改宿主配置。
