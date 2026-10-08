# 原生 App Motion 实施与证据

用户于 2026-10-08 确认 AI 按钮→任务卡→结果托盘、全 App 已有试听控件的播放→停止胶囊、作用域同一外框覆盖式展开。附属表单、原生窗口、既有生成与文件安全 owner 保留；手动试听仲裁见 ADR 0028。

实施顺序：正式设计／整合原型 → 共享试听与形变组件 → 生产 AI 表单 → 作用域外框 → 两套 harness、Debug／Release、本地 bundle 与原生走查。

## 已实施的生产路径

- `PanelAppComposition.manualPreview` 持有唯一手动试听会话，生产注入 `NSSoundAudioPreviewPlayer`。请求、播放和序列资格由 `ManualAudioPreviewSession` 发布。请求先撤销旧音频和序列；重复启动同一请求被拒绝，准备与 completion 都按令牌重验。每次可见界面使用新的来源身份，迟到关闭不能停止之后的来源。调度结束后，最后一段真实音频仍保留整段停止资格。
- `MotionPreviewButton` 接入面板、默认组／工作区详情、声音页、附属表单及生成记录的已有控件。单条按钮预留 76 pt，图标使用等顶点数路径插值；文字使用独立淡入／淡出。连续试听沿用原调度顺序与间隔，每一步检查共享序列资格。设置失去 key 不停止试听；离页、显式隐藏及关闭停止。
- `SettingsSoundsLibraryView.aiComposer` 挂载稳定的 `AICueTaskSurface`，外框与真实内容测量分离；生成、保存、待处理及失败保留真实恢复操作，保存后显示实际数量和原生候选 List，底部仍显式选用。只读 `AICueTaskPresentation` 与 `hasCurrentGenerationContext` 区分后台旧任务；重开不会取得旧结果的采用资格。后台状态有明确说明，未引入第二任务或候选 owner。
- `PanelSoundScopePicker` 在 50 pt 槽位中呈现连续外框，沿用既有菜单测量、视口约束和内部滚动。选择通过既有校验立即提交，不等待 100 ms；收起即撤销菜单命中和 AX 资格，归还触发焦点。外框在整个收起阶段仍覆盖下方内容。窗口仍为 312 pt 宽、首选 560 pt 高的 retained `NSPanel`。
- `CONTEXT.md` 和 ADR 0028 记录领域决策，`DESIGN.md` 记录呈现合同。正式整合 HTML 使用同样三条形变链；设置 ShadowRoot 显式借用共享动效样式。原生预览使用真实 `PanelView` 与 retained Settings 生产挂载，服务与配置仍为隔离 fixture。

## 自动检查与证据边界

以下证据来自实施时包含其他并行 Provider 修改的共享工作区，分别记录，不能合并为正式验收或当作独立提交树的检查结果。

- 专项 executable harness：108 checks，0 failures。涵盖跨界面互斥、同目标停止、失败启动、同步／迟到 completion、迟到准备、同类别旧来源关闭、序列播放／间隔停止、调度结束后仍可停止、retained Settings 失去／取得 key 不停止、隐藏／关闭清理，以及 AI 当前／后台投影。作用域另覆盖同步提交、重复激活 gate、失效目标与既有布局／交互合同。实际挂载 suite 检查按钮→任务卡→完整托盘、快速完成与重置，并验证英中停止胶囊预留尺寸和具体服务失败文案。
- helper 完整 executable harness：5030 checks 通过。本轮未修改 helper 行为。
- 最终低负载 GUI 完整 harness：15185 checks，1 failure，仅为本轮开始前就缺失的 `designs/pixel-motion/Pixel Motion Prototype.html`。窗口焦点、真实横幅计时及压力检查均通过；压力 p95 为 4.725ms，低于 100ms 门槛。八页、两语言、两外观、两尺寸的原生布局矩阵已执行。
- 解锁后的先前运行为 15176 checks、5 failures（历史原型缺失及 4 项指针悬停导致的阅读轨暂停）；相关重跑为 1522 checks、1 failure（并行构建期间压力 p95 162.626ms 超限）。这些环境失败在最终完整复核中均未再出现；未改写无关断言或把失败当通过。
- 生产 source-wiring harness：277 checks，0 failures。
- GUI Debug 构建与本机 Release bundle 构建、ad-hoc 签名及大小门禁均通过。最终 bundle 为 arm64；GUI 6703776 B、helper 3155552 B、LoginItem 54208 B，正规文件合计 12407448 B，均在现有预算内。Release 构建由 `dev-bundle.sh` 的正式构建路径完成。SDK 使用 `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` 与 SwiftPM native build system，最低运行版本仍为 macOS 12。
- 正式 HTML Node harness：121 tests，85 pass，36 fail；失败为旧 Qwen profile 断言。用实施前共享工作区 HTML 快照运行相同脚本，失败名称与数量完全一致。浏览器实测已检查作用域覆盖展开、整段停止与当前事件行、AI 124×34 起点、任务卡及持续展开结果托盘；HTML 证据不代表原生布局或真实音频。
- 字符串目录 JSON、`git diff --check` 与新增组件／共享状态／专项 suite 的 swift-format 检查通过。新文字包含匹配英文／简体中文，并注册 `allKnown`。
- 固定基线 `verify-settings-experience.sh 87f22a8623061d43ceaa8184fc581b3927a7b658` 按现有合同拒绝共享脏工作区：`unified settings evidence must be collected from a clean HEAD`。没有暂存、重置或清理其他工作，也未绕过门禁。

## 原生走查状态与重播

Mac 解锁后，已用界面工具读取实际原生窗口与 AX 树：

- 中文深色 AI 表单观察到按钮起点、生成任务卡、3 条完整结果托盘和可滚动到达的底部恢复操作，父窗口和附属表单不随内容扩展。SenseAudio 隔离纯音效路线观察到 2/3 部分成功托盘；失败卡明确显示服务暂时不可用，之后可重新生成。保存后选择候选才启用显式“选用”，没有自动绑定。关闭重开不恢复旧候选采用资格。
- 真实 `NSSound` 启动后出现停止胶囊；同按钮再次点击立即恢复播放入口，真实自然 completion 后恢复；播放另一事件立即撤回旧事件的播放态。组事件名称、编辑和静音控件没有因播放挤动。已检查英文小窗口浅色及中文大窗口深色，最终英文浅色面板中 `Stop Preview` 完整可读。
- 作用域连续外框向下覆盖内容，保持 312×560 pt 面板。Space／Return 展开，Down 改变选项焦点，Return 立即选中工作区并更新音量，收起时 AX 菜单退出，焦点返回触发器；Escape 同样收起。
- 再次解锁后，通过系统设置确认“减弱动态效果”原值为关闭，临时开启并观察到实际系统开关为开启。相同生产挂载中检查了 AI 生成按钮、任务卡及保存后 3 条结果托盘；试听可展开为停止胶囊，再次点击收回；作用域通过 Space 展开、Up／Return 立即改选默认组并更新音量，Return／Escape 收起后菜单退出 AX 树、焦点归还触发器。终态文字和操作可用；截图及 AX 观察不证明逐帧时序。检查结束后确认系统开关已恢复为关闭。

原生走查发现并修复了托盘高度裁切与非激活面板的 Return／Space 激活缺失。高度问题由 mounted reproducer 先重现（102 checks 中 2 failures），修复后通过。隔离 fixture 同时适配仅支持一个结束 binding 的 Kimi Code，并使用 3 秒真实示例音频和真实时长探测，避免预览瞬间结束。独立预览身份避免多个同名旧构建混淆；Show panel 收起隔离设置窗口，生产窗口合同不变。

这些证据验证原生可见状态、AX 角色、部分键盘行为、实际播放器启动／completion 回调，以及系统 Reduce Motion 开启时三处控件的终态和操作；没有验证 VoiceOver 的真实朗读、主观听音、完整 Tab 顺序、逐帧动画时序或正式验收。外部 Provider 未调用，生成由隔离服务替代；底层保存／采用仍走现有生产 owner。

最终完整 harness 结束后，打开系统设置曾因再次锁屏而受阻，当时未改动系统开关。用户再次解锁后，已完成上述 Reduce Motion 走查并恢复原值。独立预览重新置前，停在保存成功、选中第一候选且显式“选用”启用的结果托盘；没有执行采用操作。

隔离预览可按以下命令重新构建，不覆盖已安装 App 或用户配置：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
CLAUDIO_UI_REGRESSION_MOTION=1 \
CLAUDIO_UI_REGRESSION_BASE_SHA=87f22a8623061d43ceaa8184fc581b3927a7b658 \
CLAUDIO_UI_REGRESSION_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
scripts/build-native-ui-regression.sh
```

脚本返回 `.app` 与 `build-evidence.json`，记录当前源文件／原型哈希、SDK、架构与 bundle 内容哈希。打开返回的 App 后，用 `Show panel` 检查作用域和试听；用 `Show settings` 进入声音包事件的 AI 生成表单，`AI complete`／`AI partial`／`AI failure` 与 `Finish generation` 控制隔离生成器。关闭重开后确认旧候选不进入当前目标，保存／采用仍走生产 owner。

本轮隔离产物为 `Claudio App Motion Preview.app` 与同目录的 `build-evidence.json`，所在临时目录由构建脚本返回。bundle 内容 SHA-256 为 `bd41b41f44384bbf363f66a27e5a7a7bbe4956ce527a2094dc76c78aa1590d16`；最终生产源文件与 manifest 逐条一致。本证据文档在构建后更新，不冒充构建时完整工作区指纹。该临时目录可由上述命令重建。

最终详细输出位于 `/tmp/claudio-motion-focused-delivery.log`、`/tmp/claudio-motion-helper-tests.log`、`/tmp/claudio-motion-gui-delivery.log`、`/tmp/claudio-motion-debug-delivery.log`、`/tmp/claudio-motion-bundle-delivery.log`、`/tmp/claudio-motion-native-delivery.log`、`/tmp/claudio-motion-wiring-delivery.log` 与 `/tmp/claudio-motion-prototype-final.log`。托盘重现记录为 `/tmp/claudio-motion-native-measure-red.log`；解锁后先前完整运行与相关复核为 `/tmp/claudio-motion-gui-unlocked-final.log` 和 `/tmp/claudio-motion-attention-delivery.log`。

真实本地 bundle 位于 `dist/claudi0.app`；它是当前架构的走查产物，未代表双架构签名、notarization、发布或正式验收。


## 独立提交范围复核（2026-10-09）

共享暂存区出现另一轮百炼提交准备后，本轮改用 `codex/app-motion` 的隔离工作树，从固定基线 `87f22a8623061d43ceaa8184fc581b3927a7b658` 拆出 49 个 App Motion 文件及片段。未包含 Provider、凭据、存储或百炼路线修改；共享工作区与其暂存内容保留。

独立候选的专项 executable harness 为 108 checks、0 failures，生产 source-wiring 为 277 checks、0 failures；正式 HTML Node harness 为 121 tests、121 pass、0 fail。GUI Debug 与 Release 构建通过。相对固定基线的格式核对发现 19 处新增换行／缩进诊断，已仅在相应回调及 fixture 行修正，修正前后去除空白的源码完全一致；复核无新增格式诊断。字符串 JSON 与 diff 检查通过。此前共享工作区的完整 harness 和原生走查证据仍按其原始范围记录。

独立候选输出为 `/tmp/claudio-motion-commit-focused.log`、`/tmp/claudio-motion-commit-wiring.log`、`/tmp/claudio-motion-commit-prototype.log`、`/tmp/claudio-motion-commit-debug.log`、`/tmp/claudio-motion-commit-release.log` 与 `/tmp/claudio-motion-commit-format-final.log`。


干净候选上实际运行了 `verify-settings-experience.sh 87f22a8623061d43ceaa8184fc581b3927a7b658`：suite 注册与 helper 全部 5028 checks 通过；GUI 完整 harness 为 15189 checks、2 failures，压力 p95 为 4.708ms，原生 64 组布局及窗口／横幅检查完成。两项失败分别为既存 Pixel Motion 原型缺失，以及旧声音包选型板要求五个被 Git 忽略的本地包、干净工作树仅有已入库 Factory Pack 导致的目录断言失败。后者的脚本、catalog 与 state seam 和固定基线逐字节一致，使用同一基线的最小独立快照已复现相同失败；未修改无关选型板断言或引入本地音频来绕过检查。

固定门禁因此返回 1，未进入后续构建／bundle 阶段；本轮独立候选的 Debug、Release 与格式检查使用上述单独记录，不冒充整套门禁通过。门禁输出为 `/tmp/claudio-motion-commit-settings-gate.log`；选型板重现为 `/tmp/claudio-motion-commit-selector.log` 与 `/tmp/claudio-motion-commit-selector-baseline.log`。本地提交不代表推送、发布或正式验收。
