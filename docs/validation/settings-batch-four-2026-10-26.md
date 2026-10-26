# 第四批：键盘、导航与原生验收

状态：实现与工作树检查完成，等待精确范围本地提交授权。真实 VoiceOver 和干净候选综合门禁尚未完成，不构成本批通过声明。

## 基线与隔离

- 基线：`6b5aaf20ed2013103fcd937785d12203bb1fcb6c`，开始时 `main` 工作树干净。
- 当前 Mac：macOS 27.0.1（26A434）、arm64、Swift 6.4；固定 SDK 为 `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`。
- 所有配置、声音包、生成结果及凭据为隔离 fixture；不请求真实 Provider。前台进程与 Computer Use 串行；普通键盘与 VoiceOver 分开。
- 系统键盘导航原值 `AppleKeyboardUIMode=0`，专项临时为 `2`。启动器持有独占锁，并在正常退出／异常退出时恢复原值；进程内检查 `NSApp.isFullKeyboardAccessEnabled`。
- 强调色、选中文字颜色、外观原先未设用户 override；系统界面选择为自动外观、多色强调色。增强对比度、降低透明度、降低动态效果均为 `0`。通过系统设置逐一切换紫色强调色、增强对比度、降低透明度、降低动态效果；每次在 `finally` 中恢复，最后通过 `defaults` 读回与原始记录完全一致。
- 候选尚未提交；以下工作树结果不得写成干净 HEAD 的结果。实现源文件指纹为 `152d43ab2ead0358e6a28fb2b5abeeae4e5fa189e148a196c180a6f26d929cad`，逐文件摘要见证据中的 `environment/candidate-sources.json`；精确候选提交 SHA 待本地提交授权后产生。
- 已清理本批全部临时 App、构建副本、fixture 数据、探针与重复截图，保留证据纳入下述 Git 范围。10 个已记录工具的 SHA-256 与 POSIX mode 均在清理后匹配，系统外观和键盘偏好已读回恢复。启动器快照始于本批开始；实际 CLT Swift／Git 与 ffmpeg 快照始于最终独立 fixture 前，不把该比较外推到更早诊断阶段。

## 键盘原始证据与修复

未改生产代码的基线键盘专项为 287 checks / 0 failures；没有在第一次运行复现上批记载的随机失败。诊断版同为 287 / 0。

探针现在只观察构造时的一次明确呈现请求；它不循环 `makeKey`，也不在每次导航后再次呈现窗口。就绪须同时满足实际 key window、挂载窗口、导航／挂载 stamp、无附属 sheet 及恢复请求已结算。超时报告 first responder 类型／身份、WindowServer 顺序、AX 焦点、key window、stamp、sheet 与恢复请求，并停止该用例后续派生断言。Tab 失败保留实际 responder 转换序列，确认操作保留操作记录。

有效 RED：290 checks / 3 failures，分别为键盘夹具误用 `.regular`，以及中英文关于入口的 AX 身份被 SwiftUI 父级覆盖。夹具改用生产 `.accessory` 非激活窗口合同；原生动作控件独立保留自己的 action identifier，兼容直接设置原生 identifier 的 radio。

中间一次 335 / 2 的有效就绪失败记录到：窗口 visible 且 canBecomeKey，挂载和请求 stamp 一致，但 `NSApp.keyWindow=nil`、`isKeyWindow=false`，恢复请求仍为 content。没有将其推断为已确定的生产根因。另一轮因两个启动器的系统偏好恢复交错导致 `fullKeyboard=false`，该轮作废；之后加串行锁。去除重复呈现请求后，完整专项连续三个新进程均为 **352 / 0**，然后才调整导航。

新增关于 sheet 的正反 Tab、Return、Esc、模态导航阻断、历史不增项及原入口归焦。清除活动／日志仍覆盖 Esc、取消、明确确认一次执行；遍历不写声音配置。

## 导航行

六条路径（管理声音包分别覆盖默认组与工作区）在中英文下通过真实窗口 Tab、Space、Return，断言单次导航、侧栏归属、捕获 scope／目录身份、Back／Forward、入口焦点、阅读位置与配置不变。修复前 **516 checks / 52 failures**；采用内部 `SettingsNavigationRow` 后 **648 / 0**。真实磁盘声音包详情补充覆盖后 **654 / 0**。

矩阵补充发现底部行获得 first responder 后仍在滚动区外；原生动作控件现在在获得焦点时请求将完整行滚动到可视区。独立长标签／禁用 fixture 检查完整 AX 名称、换行、整行命中、禁用不激活。早期完整矩阵 **899 / 0**；后续正确 SDK 下重采 48 张画面，独立 App 对照确认焦点环与完整可见行。新增逐入口原生 sheet 阻断包含在完整专项中。

新构建（Mach-O SDK 26.5）中，Computer Use 与完整键盘专项均复现内置声音包详情进入后 first responder 为窗口。完整专项 RED 为 **955 / 1**，隔离磁盘专项 RED 为 **8 / 1**。原始状态为 key window 正确、WindowServer 包含当前窗口、挂载 stamp 一致且恢复请求已结算；正文仅有 SwiftUI 的 key-view proxy。旧恢复代码筛选可见 `NSControl`，排除了这些代理。现有 shell 改为重算 AppKit key-view loop，再使用侧栏后的有效正文目标，不识别私有类名，也不增加焦点 owner。隔离专项 GREEN 为 **8 / 0**，独立 App 实际 Space 进入详情与工具栏 Back 的焦点恢复均通过。

## 主原型回归迁移

原始全量：79 tests，30 failures、26 errors（包含子用例计数）。没有跳过测试或放宽仍有效的行为断言。

| 旧断言／失败 | 当前替代覆盖与处理 |
|---|---|
| 八页侧栏、usage 顶层、about 独立页 | 五页侧栏；连接下钻活动与诊断及侧栏归属；通用附属关于、Tab 圈定、Esc 归焦、模态阻断 |
| 旧快捷键录制／取消两项 | 旧路由进入通用、无录制控件、按键不改旧值；关于表单的真实取消与焦点恢复 |
| 侧栏 events 默认详情导致标题夺焦 | 区分调用者明确下钻与内部默认 workspaces 投影，侧栏焦点合同保持 |
| 面板声音深链接聚焦静态事件行 | 聚焦可写包对应来源控件／内置包复制入口，保留重复请求与关闭后面板事件归焦 |
| gear 后直接操作旧单页声音配置 | 进入当前工作区详情后检查 pack／volume／event 与失败恢复；保留工作区选择 |
| 旧内联 AI 表单、候选 DOM、离页丢弃任务 | 深链与场景迁移至当前附属表单及既有 reducer；关闭只失效采用上下文，任务继续且结果进生成记录，不改绑定 |
| 库首页服务管理默认展开 | 先操作真实 disclosure，再进入同一管理／凭据表单，保留描述与失败旧值 |
| 宿主列表节数包含新诊断节 | 明确检查两种宿主分组和独立诊断入口 |
| 同名 nav:integrations 的返回焦点 | 书签区分侧栏与正文来源，恢复原正文入口；保留捕获声音作用域返回上下文 |

迁移后原有全量 **79 tests / 0 failures**；五页专项 **6 / 0**；Node **109 / 0，skipped 0**。新导航行用例包含双语 × Space／Enter × 六路径，首次找到四个返回焦点失败，修复后通过。最后修正不含事件上下文的返回说明尾部多余箭头后，最新全量 **80 / 0**（144.631 秒）；五页 **6 / 0** 与 Node **109 / 0，skipped 0** 再次通过。

## 原生视觉、反馈、动画与 AX

- 中英文 × 明暗 × 960×640／1240×820：改动入口、命中范围、焦点环与滚动可达性已检查；另以 350 pt 独立 fixture 验证人工加长标签及禁用入口。
- 成功、警告、错误：通过实际根页、关于表单、AI 部分候选表单及命名错误表单挂载检查。初次成功像素检查位于滚动区外，夹具先滚动到实际反馈；AI 部分候选缺少警告图标的 RED 已保留。完整 polish **368 / 0**；48 张反馈画面已审阅，成功／警告／错误图标与中性正文分离，根页和表单均可阅读。
- AI 前台 fixture 使用生产 `AICueTaskSurface`，保留真实动画事务，覆盖展开、保存、待处理、结果、失败、收起、快速反转与 Reduce Motion。初版默认按钮样式与生产 `.plain` 不同，状态注入也早于交互就绪；相关失败不能直接定为生产缺陷，试验性生产焦点改动已全部撤回。
- 解锁后原始键盘记录显示 `key=true`、AX Generate 已聚焦，但 WindowServer 的 `order` 仍仅含上一扇窗口。就绪条件增加当前窗口已出现在 WindowServer 后，真实 Tab／Space 启动与动作结果等待通过，生产动画代码不变，**992 checks / 0 failures**。原生设置探针同步采用这一就绪条件，不重新激活或抢焦点。
- 新增逐入口 sheet 阻断后，完整键盘专项三个新进程分别 **971 / 0、971 / 0、971 / 0**。这些进程仍使用下述旧链接 SDK 标记，最新候选综合门禁会以显式 SDK 构建再执行三次。
- SDK 26.5 下修复正文焦点后，首次完整复跑为 **943 / 2**：一个导航后就绪失败与一个 Tab 遍历失败，均记录到 `key=false`。该轮不计通过；随后开启窗口生命周期调用栈记录，三个新进程连续为 **957 / 0、957 / 0、957 / 0**。没有把前两个失焦记录归因于已经确定的产品根因；最终候选仍需重复门禁。
- 通用／关于 AX 修复后，关闭 `CLAUDIO_SETTINGS_KEY_LIFECYCLE` 和 `CLAUDIO_SETTINGS_KEY_TRACE`，最新完整键盘专项连续三个新进程为 **971 / 0、971 / 0、971 / 0**。覆盖五页正反 Tab、方向键、声音列表／空列表／实际磁盘详情、radio、全部六条前进入口、清除取消／确认及关于。此三轮为工作树普通运行模式的稳定性结果。
- 最新原生专项：polish **368 / 0**、五页 **903 / 0**、表单 **541 / 0**、AI 动画 **992 / 0**、音量／挂载生命周期 **314 / 0**、panel/settings handback **136 / 0**。
- 正确 SDK 下的 48 张导航和 48 张反馈矩阵画面均已审阅。AI 八组合共采集 968 帧；普通展开的 16 帧存在连续变化，Reduce Motion 同阶段 16 帧绘制相同。审阅每次转换的开始／中间／稳定帧与全部快速反转帧，外形、背景与内容在最终状态一致，未发现裁切或闪白。
- 桌面曾出现外部原生读取 `cgWindowNotFound`，应用清单没有可用窗口，前台进程不满足挂载／key 前置条件；当时停止测试并恢复偏好。用户确认解锁后继续，锁屏阶段结果不作为产品 RED／GREEN。
- Computer Use 单实例核对：真实 Space 进入内置包后聚焦「复制并编辑…」，工具栏 Back 恢复包行；新导航行 Space 到工作区首页，Back 恢复原行及完整可见焦点环。最小英文深色窗口下，系统紫色强调色改变控件与焦点环；增强对比度增加分组轮廓；降低透明度移除背景混合。系统 Reduce Motion 开启时，实际 AI 表单经 Ctrl+Tab 离开多行编辑器、Space 生成、固定 fixture 完成后到达结果，三个候选可滚动访问；运行进程读回相应系统值为 true。所有系统开关随后恢复。
- 冷启动 AX：新 fixture App（无同进程 AX 预热），由 Computer Use 外部客户端读取。中英文命名错误均暴露全文，装饰图标未形成独立元素；正反 Tab 保持在 sheet 内，键盘取消恢复入口。新导航行仅一个 AX button。
- 外部 AX 发现通用页及关于 sheet 的父级 identifier 覆盖子控件。公共 AX bridge 回归分别为 **66 / 4 → 66 / 0**、**76 / 6 → 76 / 0**。在对应三处容器声明 `.accessibilityElement(children: .contain)` 后，新的 App 进程通过外部中英文对照：语言、登录项、重新检测、关于、复制、资源和关闭保留独立标识，名称／角色／禁用状态正确；Tab／Shift+Tab 圈定在 sheet，Esc 恢复关于入口。表单展示的 macOS 15.6.1 等版本值为固定 fixture 数据，不是当前系统检测值。
- 真实 VoiceOver：**待验收，用户明确表示不参与听读**。不再安排用户听读；AX 树、字幕及上述自动结果均不替代此项，因此本批不得宣称全部完成。范围仍为五页、新入口、完整反馈、恢复动作、禁用状态、动态反馈、关于／清除确认及取消归焦。

## 工具链与配色诊断

完整 GUI 后台初次结果为 **15,383 checks / 4 failures**，均为亮色设置反馈图标的对比度断言。调查未改颜色或降低阈值：

- 仅用 `SDKROOT` 的默认 SwiftPM 构建，`vtool -show-build` 显示 harness 的 `minos=12.0, sdk=12.0`。
- 仅传 `--build-system native --sdk .../MacOSX26.5.sdk`、未同时设置 `SDKROOT` 的中间 fixture App 为 `minos=12.0, sdk=27.0`。同时设置 `SDKROOT` 与显式 SwiftPM 参数后，最终 fixture App 与 harness 均为 `minos=12.0, sdk=26.5`，已通过 `vtool -show-build` 读回。
- 最小颜色程序保持相同源码，原 SDK 标记下亮色 window/group 为 `1.0`／`0.96470588`（alpha=1）；只将任务内可执行文件的 SDK 标记改为 12.0 后，同样读取变为 window `0.92549020`、group `0.58823529`（alpha `0.89803922`）。这复现了 harness 的旧配色和早期截图，不涉及已安装工具的修改。
- 综合脚本现把既有 `CLAUDIO_BUILD_SDK` 显式传给每个 SwiftPM build/run。Debug／Release、bundle、体积和格式 gate 保留；键盘专项在最终干净候选上启动三个新进程。
- 正确构建的后台复跑 **15,383 / 0**，没有修改反馈配色或降低对比度阈值。最终视觉画面已采用正确 SDK 重采；早期旧 SDK 矩阵仅是诊断过程，不作为 App 配色验收，也不保留重复截图。
- 最新后台经外部 `--scratch-path` 启动时，11 个 CLI 自启动预检失败：`argv[0]` 为相对路径，`URL(fileURLWithPath:)` 保留相对 base，`Process` 未能启动实际存在的文件。夹具在自身启动接缝使用 `.absoluteURL`；同一 SwiftPM 命令的独立 routing 回归 **289 / 11 → 289 / 0**，没有改生产代码或跳过预检。
- 综合脚本的可选 SDK 参数采用兼容 macOS Bash 3.2 的空数组展开；已分别验证未指定 SDK 与显式 SDK 两种参数形式，并通过脚本语法与格式诊断脚本检查。

## 命令与最终门禁

前台命令要求预留桌面，串行执行；键盘专项要求系统键盘导航开启。原值须在正常结束和中断时恢复并读回。

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --package-path gui claudio-gui-tests --foreground --settings-navigation-native-focus
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --package-path gui claudio-gui-tests --foreground --settings-polish-native
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --package-path gui claudio-gui-tests --foreground --five-page-settings-native
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --package-path gui claudio-gui-tests --foreground --five-page-forms-native
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --package-path gui claudio-gui-tests --foreground --ai-cue-animation-native
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --package-path gui claudio-gui-tests --foreground --mounted-lifecycle-contracts
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --package-path gui claudio-gui-tests --foreground --panel-settings-handback
python3 scripts/test-panel-settings-prototype-browser.py
python3 scripts/test-five-page-settings-prototype.py
node scripts/test-panel-settings-prototype.js
```

最新工作树已通过 helper **6188 / 0**、GUI 后台 **15,391 / 0**、显式 SDK 26.5 的 Debug App 构建、双语 catalog JSON、脚本语法和 `git diff --check`。完整严格格式差分本次 baseline/current 均为 687 条已有诊断，新增为 0；单文件 lint 中原有 `SettingsFeedbackNativeSuite` 换行诊断在基线上逐字存在，不计作本批新增。前台及浏览器结果分别记录于上文，不能由后台总数代替。

原始失败、GREEN、视觉、外部 AX 与隔离记录保存在[本批证据目录](evidence/settings-batch-four-2026-10-26/README.md)，仅保留可复核的必要材料。获得精确范围本地提交授权后，在干净候选执行：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
CLAUDIO_BUILD_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
bash scripts/verify-settings-experience.sh 6b5aaf20ed2013103fcd937785d12203bb1fcb6c --foreground
```

保留 Release、开发 bundle、体积与格式门禁，不自动 push。macOS 12 真机、真实宿主与音频、正式签名／公证不计入本批通过声明。
