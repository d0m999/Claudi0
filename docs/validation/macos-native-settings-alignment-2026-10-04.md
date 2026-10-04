# claudi0 原生设置对齐实施记录 · 2026-10-04

八页设置与详情已迁入同一个 AppKit 原生外壳；导航历史、恢复请求及 modal 导航禁用由既有 `SettingsPresentationSession` 唯一持有。保留原领域 owner、配置格式、声音包、事件语义色与窗口非激活合同。本记录区分实现、编译夹具、当前工具链与真实原生验收；**不能据此宣布完整原生验收或发布通过**。

## 基线与共享工作区

- 实施前固定 BASE：`f106df47b5931ab952107a2b1b3cf295fd1f9a06`。实施期间另一个工作流产生 HEAD `27c499a6048721944a1f7322cd3faccb2d29ad53`；实施验证阶段没有 commit、push、PR、发布或修改 issue 状态。后续本地提交复核另见文末。
- 初始源码包含 45 个 tracked 改动与 6 个 untracked 文件。源文件清单、原始字节副本与 diff 位于 `/tmp/claudio-native-settings-20261004/`。初始 882 个路径的 SHA-256 清单摘要为 `b95e50b62edf77e9dcc2d2a93796bf439a1637b717cdec2a902f09142f68d2fb`。
- 核对范围外的初始改动与 untracked 文件：字节未变。只对本轮 Swift allowlist 的改动行运行 checked-in `.swift-format`；原有共享改动没有被整体格式化、恢复或暂存。
- 原运行包路径：`/Users/d0m999/Desktop/Claudio/dist/claudi0.app`，进程 `86474`。其 `Contents/MacOS/claudi0-app` SHA-256 保持 `851d9614662fe79c86aac3828366fd7136325ac1d5d4372097442a736fc568f8`。本轮未替换或删除这个包。
- 首轮 [审计记录的实施前快照](/tmp/claudio-native-settings-20261004/baseline/docs/validation/macos-native-ui-audit-2026-10-04.md) 查看的是旧运行包。原审计文件为实施前已有的 untracked 文档，保留在共享工作区，未纳入本轮提交。实施前源码已包含通知返回修复，故旧包的单箭头不能认定为当前源码回归。此次通知详情改为复用全窗口历史与工具栏，专项验证覆盖该入口。
- 本机为 macOS `27.0.1`、arm64、CLT Swift `6.4`。默认 SDK 27 的 `SwiftUIMacros.StateMacro` 插件缺失在实施前后均可复现；SDK 26.5 的检查单独标为辅助证据。

## 已实现的合同

- **原生外壳**：唯一 retained、非激活 `RetainedSettingsWindow`，`.accessory` 与既有层级／handback 保留。`NSSplitViewController` 的 sidebar item 提供系统材质，`NSTableView.style = .sourceList` 提供单选列表；八页三组、20 pt 图标、字标与 252／210 pt 断点保持。删除固定侧栏 RGB 及自绘选中底。
- **工具栏**：真实 `.unified` `NSToolbar`，同一个 momentary `NSSegmentedControl` 管理 Back／Forward；页名紧邻导航并带 AX heading，隐藏重复可见窗口标题，保留本地化窗口身份。正文独立 58 pt 页头与各页自有返回解释被移除。
- **布局**：`.fullSizeContentView` 的右侧内容受系统 `contentLayoutGuide`／safe area 约束，无固定标题栏高度补偿。保持单层主滚动区、最大阅读宽度 780 pt（含左右内边距）、32／26 pt 内边距、20／12 pt 间距和 38／51 pt 最低行高。macOS 13+ 关闭 hosting controller 自动 sizing constraints，使长英文仍保持 960 pt 请求宽度；macOS 12 使用已有布局与 compression priority。
- **控件**：行尾 borderless `NSPopUpButton` 按内容收起、最多 280 pt；完整菜单与 AX 名称保留包名、状态及许可说明。普通开关 mini、标签在左；播放为独立原生按钮，详情入口为 plain 右箭头。分组标题／说明置于组外，必要包元数据与操作保留在组内。
- **动画**：五事件预览改为原生 `selectOne` 分段控件，选中态持续可见；只改变预览，不写偏好或播放声音。四项角色画廊保持生产素材，补 radio group／selected 语义、←／→选择和 Space／Return 操作，并区分焦点、悬停、选择。
- **位置与历史**：`SettingsLocation` 保存浏览 route、scope、UUID／捕获目录身份、查看包 ID；`SettingsNavigationHistory` 保存最多 64 个位置及焦点／阅读书签。它不保存旧配置、音量、映射、凭据、候选、草稿或写操作。
- **事务规则**：侧栏、详情与新显式深链统一进入会话；重复当前位置只重验与更新焦点，不追加或截断前进分支。Back／Forward 只移动游标；新浏览位置截断前进分支；刷新、pending 完成、删除／复制结果匹配当前操作和版本时更新当前条目。已知失效位置保留身份与导航并显示原因；无法解析的输入拒绝入历史。返回查看包不改变当前应用包，历史遍历不重放复制、应用或采用。
- **生命周期**：离页按原 owner 停止试听、结束 AI 会话、取消未发布草稿；已接受的磁盘事务由原 owner 结算。未开始的复制仍遵守原 freshness 拒绝规则；已完成磁盘写入但迟到的 publication 可以保留副本，却不能夺回新页面。接受删除后的成功只在匹配原历史版本时转换当前条目，关闭／离页不会吞掉真实写入结果。关闭清空历史与书签，既有最后顶层页偏好保留。
- **焦点与 modal**：同一版本化恢复请求由 shell 与内容消费；旧请求不能覆盖新导航。侧栏鼠标／方向键选择保留 table responder，程序回写不再次导航；重复点当前侧栏行也只提交一次事务。sheet／原生文件选择器禁用外层导航，取消不移动游标。语言、刷新与后台 publication 不调用 `makeKey()` 或激活应用。真实 key-window 与 VoiceOver 路径仍待验。

系统的非遮挡内容布局见 Apple [contentLayoutRect](https://developer.apple.com/documentation/appkit/nswindow/contentlayoutrect)；hosting controller 的 sizing API 见 [sizingOptions](https://developer.apple.com/documentation/swiftui/nshostingcontroller/sizingoptions)。这里的具体尺寸与间距来自用户计划，不是 Apple 对所有设置界面的强制数值。

## 原型与现行规格

[Native Settings Alignment Prototype.html](../../designs/macos-settings-native/Native%20Settings%20Alignment%20Prototype.html) 提供八页、代表详情、失效位置、跨页历史与阅读恢复演示，支持中英、浅深色和两尺寸；画廊使用生产 atlas。SHA-256：`06b63d9a7baffa243f607802345f295f0ae9f78558085bdce9241e063b8de63b`。

本轮以用户提供的已确定计划为呈现规格；同步 [DESIGN](../../DESIGN.md)、[ADR 0008](../adr/0008-use-one-retained-unified-settings-window.md)、[设置体验计划](../../plan/PLAN-SETTINGS-EXPERIENCE.md) 与 [迁移计划](../../plan/PLAN-MACOS-SETTINGS-MIGRATION.md)。旧原型保留为历史，不能覆盖 2026-10-04 修订。原型脚本 `node --check` 通过；前段浏览器走查确认过跨页 Back 流程，最终浏览器复核因连接超时未完成。没有独立人工原型签字或正式验收结论。

## 九项首轮差异闭环

| 审计差异 | 实现与自动证据 | 真实原生验收 |
|---|---|---|
| 预览缺少持续选中态 | 原生 `selectOne`；值、双语名称、禁用态及零声音／偏好副作用专项通过 | 待验 |
| 各页详情返回不同 | 单一会话历史与同一 toolbar；A→详情→B→Back／Forward、重复、分支、上限、迟到结果专项通过 | 待验 |
| 侧栏鼠标后方向键焦点 | 原生 source list；跳过组间空行、首末边界、一次选择一次事务及同一行重选专项通过 | 实际 key window 无法建立，待验 |
| 窗口标题与正文页头两层 | hidden window title + toolbar heading；64 个组合标题／几何检查通过 | 待验 |
| 下拉框宽且重 | borderless native popup，内容宽度及 ≤280 pt；长值／完整 AX 名称专项通过 | 实际菜单键盘／VoiceOver 待验 |
| 动画开关居中 | 左标签右 mini 开关；生产绑定与 disabled 操作专项通过 | 待验 |
| 详情箭头底不同 | 各设置详情统一 plain disclosure，播放保持独立 native action | 待验 |
| section 标题在卡内 | 共享 section／row；通知、活动、关于等迁移；双语状态夹具通过 | 阅读／Tab／VoiceOver 顺序待验 |
| 侧栏固定实色 | 原生 sidebar split item；无固定 RGB 或强制 active material | 活动／非活动、减少透明度待验 |

## 自动门禁

全部结果取完整检查汇总；没有把提前退出或仅 exit 0 算作 harness 通过。GUI 全量入口改为在 AppKit event loop 中完成 MainActor task 后输出汇总，避免原异步顶层入口提前结束。

| 检查 | 结果 | 日志（本机临时证据目录） |
|---|---|---|
| `swift run --package-path helper claudio-tests` | **4314 checks，0 failures** | `helper-tests.log` |
| 当前默认 SDK 的 GUI harness（独立 scratch） | **构建失败，未执行 harness**：缺少 `SwiftUIMacros.StateMacro` plugin | `default-final-harness.log` |
| 默认 SDK Debug `ClaudioGUI` | **构建失败**：同一宏插件问题，基线亦存在 | `default-final-build.log` |
| SDK 26.5 辅助 GUI harness 构建 | **通过** | `final-tests-build.log` |
| `--settings-native-alignment` | **252 checks，0 failures** | `alignment-final.log` |
| `--settings-lifecycle` | **228 checks，0 failures** | `lifecycle-final.log` |
| `--settings-native-regressions` | **335 checks，0 failures** | `native-regressions-final.log` |
| `--settings-sounds-layout`，64 组合 + 页尾 | **1404 checks，0 failures** | `settings-layout-final.log` |
| `--settings-native-states` | **1164 checks，0 failures** | `native-states-final.log` |
| SDK 26.5 辅助全量 GUI harness | **完整输出 17981 checks，20 failures**；未全绿，分类见下文 | `full-gui-final.log` |
| SDK 26.5 普通 Debug 产品构建（隔离源码） | **通过** | `candidate-production-debug-build.log` |
| SDK 26.5 Release full LTO／Osize、helper、LoginItem、组装 | **通过**，arm64；签名与体积门禁通过 | `candidate-release-build.log` |
| SDK 26.5 DEBUG native fixture bundle | **通过**，ad-hoc 验签通过 | `candidate-debug-build.log` |
| `jq empty .../Localizable.xcstrings`、`git diff --check` | **通过** | 最终工作区复核 |
| `bash scripts/verify-settings-experience.sh f106df47b5931ab952107a2b1b3cf295fd1f9a06` | **失败于 clean HEAD 前置条件，后续门禁未执行** | `verify-settings-experience-final.log` |

复现 SDK 26.5 辅助 harness：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift build --package-path gui \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  --product claudio-gui-tests

SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
gui/.build/debug/claudio-gui-tests --settings-native-alignment
```

SwiftPM 的实际输出为 `.build/out/Products/Debug`，`.build/debug` 指向该目录。记录使用最终新二进制，未将旧 `arm64-apple-macosx/debug` 目录的可执行文件纳入通过证据。

布局专项保留原像素容差。诊断确认本机 Aqua `underPageBackgroundColor` 的 alpha 为约 0.898：RGB 150 叠在系统页面底色上，实际像素为 159。因此断言比较系统颜色与 alpha 的合成值，而不是忽略 alpha 的 RGB。实际表面保留系统 alpha、不错误声明 opaque；调试帧记录改为按当前视图读取窗口坐标，避免工具栏／语言变化后旧坐标落在标题栏。临时诊断输出已移除。

实施前原始字节快照重建并通过全部 882 个路径的摘要复核，辅助构建成功；其 `--review-repairs` 完整输出 **692 checks，3 failures**，三项均为 `ReviewRepairSuite` 横幅反馈／失败原因／超时原因的额外高度。横幅视觉不在本轮迁移范围，这些现有失败未被修改或隐藏。

最终全量 GUI 汇总为 **17981 checks，20 failures**：上述已在实施前快照复现的横幅高度 3 项，以及 `PanelSettingsHandbackSuite` 的 17 项实际 key-window 检查。后者首先无法建立“前台／后台设置”和“非激活菜单持有 key”的前置状态，随后的焦点归还检查也不满足；这个 suite 使用原来的 standalone 窗口，不挂载新增 shell。它们保留为失败，尚不能宣称真实窗口交接通过。最终全量中，设置导航、清理、布局、原生外壳与控件没有失败。`SourceScannerSuite` 打印的 14 行预期反例在该 suite 中已撤回，不是这 20 项实际失败。

共享工作区与未授权 commit 不能满足 clean HEAD 前置条件；本轮没有清理用户工作、修改该 guard 或用辅助检查替代这条门禁。

## 截图与状态证据

所有下列图片是 **生产 shell／视图挂载固定 fixture 后，AppKit `cacheDisplay` 的截图**，不是 Computer Use 对正在运行产品的截图，也不证明真实输入或 VoiceOver。

- [实施前截图目录](/tmp/claudio-native-settings-20261004/before-captures)：64 个组合的页首／页尾，共 **128 张**。基于实施前当前源码快照，包含当时源码中的通知修复；与首轮审计的旧运行包不同。
- [实施后截图目录](/tmp/claudio-native-settings-20261004/after-captures)：同一矩阵，共 **128 张**。
- [原生外壳截图目录](/tmp/claudio-native-settings-20261004/shell-final-captures)：64 张；`.accessory` 进程、真实 split view／toolbar／source list。
- [双语状态与 sheet 目录](/tmp/claudio-native-settings-20261004/state-final-captures)：正常、加载、失败、禁用、失效、AI 与集成状态；160 个双语场景各有页面 PNG 和 mounted／layout identifier JSON，另有 30 张独立 sheet PNG。
- [截图摘要清单](/tmp/claudio-native-settings-20261004/layout-capture-evidence.json)、[专项完整结果](/tmp/claudio-native-settings-20261004/targeted-final-evidence.json)。

代表性对照：

| 组合 | 实施前源码夹具 | 实施后源码夹具 |
|---|---|---|
| 中文通用／默认／浅色 | [before](/tmp/claudio-native-settings-20261004/before-captures/general-1240-zh-Hans-light.png) | [after](/tmp/claudio-native-settings-20261004/after-captures/general-1240-zh-Hans-light.png) |
| 英文声音／最小／浅色 | [before](/tmp/claudio-native-settings-20261004/before-captures/sounds-960-en-light.png) | [after](/tmp/claudio-native-settings-20261004/after-captures/sounds-960-en-light.png) |
| 中文通知／最小／深色 | [before](/tmp/claudio-native-settings-20261004/before-captures/notifications-960-zh-Hans-dark.png) | [after](/tmp/claudio-native-settings-20261004/after-captures/notifications-960-zh-Hans-dark.png) |
| 英文工作区／默认／深色 | [before](/tmp/claudio-native-settings-20261004/before-captures/events-and-sounds-1240-en-dark.png) | [after](/tmp/claudio-native-settings-20261004/after-captures/events-and-sounds-1240-en-dark.png) |

## 当前候选包与指纹

`scripts/dev-bundle.sh` 会先删除目标 `dist` 的旧包，因此**只在独立源码副本中运行**。副本为当时工作区 898 个文件的字节快照；不包含构建目录或用户声音包。临时 PATH wrapper 只给 Swift build 添加显式 SDK 26.5，原组装／签名／体积脚本未改。检查结果是辅助工具链构建证据。

### 生产 Release 候选

- [隔离 claudi0.app](/tmp/claudio-native-settings-20261004/candidate-source/dist/claudi0.app)。未启动它，避免混淆既有同 bundle ID 的运行产品。
- [源码清单](/tmp/claudio-native-settings-20261004/candidate-source-evidence.json)；[包清单](/tmp/claudio-native-settings-20261004/candidate-release-evidence.json)。
- 源码摘要：`da57f96dd74c7a188a5582e0712da712fc09e4de4bb6e58a8102014cff6aa422`；建包后逐路径核对未偏离。此报告为随后新增的验收说明，不属于该构建快照。
- GUI 二进制 SHA-256：`27dcd49bfec55e2c1703075f90e5833f74fa99b81fe4b9c62253ff4228a948b5`。
- bundle 文件清单摘要：`751b1885040729057869edbc5c22d7d302c3a2698595ac77bc3449a244e3815d`。
- GUI `6,063,536 B / 7,000,000 B`；helper `3,219,296 B / 3,250,000 B`；LoginItem `54,144 B / 500,000 B`；非可执行资源 `2,414,570 B / 3,100,000 B`；整包正规文件 `11,751,546 B / 13,850,000 B`。arm64、ad-hoc 验签通过；Mach-O minimum OS 为 `12.0`。

### 原生 DEBUG 夹具候选

- 实际启动路径：`/private/var/folders/1m/2jsf455s4r7dx9t8l233n55c0000gp/T/claudio-native-ui-build.ux0R5s/Claudio UI Regression.app/Contents/MacOS/ClaudioGUI`，进程 `60207`。
- [build-evidence.json](/var/folders/1m/2jsf455s4r7dx9t8l233n55c0000gp/T/claudio-native-ui-build.ux0R5s/build-evidence.json) 同时记录 BASE、HEAD、源码清单、原型和全包指纹。
- 二进制 SHA-256：`057b7c63277dea3b7cdac5bba0d3b1278ad479f865c7802511b4e6efc3a013d3`；bundle 清单摘要：`71fd4e98e85bce516cab5158132ce1235c5703670d322e118d1f7afeef51f5ba`。
- 该夹具保留 `.accessory` 与非激活设置窗口；Provider／来源应用为 fixture 替身，不能证明真实服务或真实宿主回调。

## 尚未通过／验证的门禁

| 门禁 | 当前结论 |
|---|---|
| 默认 CLT／SDK 27 完整 GUI 构建及 harness | **失败／未执行**：宏插件缺失；SDK 26.5 不替代此门禁 |
| 固定 BASE 的 clean HEAD 集成脚本 | **失败于前置条件**：共享 dirty tree；后续检查未执行 |
| SDK 26.5 辅助全量 GUI harness | **未全绿**：17981 项中 20 项失败（基线横幅高度 3 项；实际 key-window／handback 17 项） |
| 本机 macOS 27 真实 64 组合及详情／sheet 走查 | **未验证**：新包启动路径已确认，但 Computer Use 返回 `-10005: cgWindowNotFound`；对系统设置参考的重新读取也曾失败。不得把 fixture PNG 宣称为实机走查 |
| 最终 HTML 浏览器复核 | **未完成**：Chrome 会话调用超时；随后 Computer Use inventory 读取也超时。脚本语法检查通过 |
| 实际 ↑↓／Tab／Shift-Tab／Space／Return／Escape、画廊 ←→ | **未验证**：compiled callback／selected 值通过，不等于真实 key-window 输入 |
| 外部应用前台打开设置、菜单交接、后台设置、sheet 归还、关闭重开 | 自动状态／owner 合同有覆盖；**真实窗口顺序与焦点未验证** |
| VoiceOver 列表、选中值、导航禁用态、heading、详情／sheet 顺序 | 属性检查有覆盖；**独立 VoiceOver 未验证** |
| 非蓝强调色、增强对比度、减少透明度、减少动态效果 | 两种 high-contrast appearance 的 fixture 像素检查通过；**真实系统偏好矩阵未验证** |
| macOS 12 | 最低目标编译／Mach-O 声明有证据；**真实 macOS 12 运行未验证** |
| Intel、Developer ID／notarization、真实声音与宿主回调、生产／正式接受 | **未验证**；本轮仅提供 arm64 本地 ad-hoc 候选 |

临时证据目录包含基线、完整日志、指纹和候选；实施验证阶段没有提交、推送、替换运行包或正式发布。

## 用户授权本地提交后的范围与复核

用户随后明确要求 `commit`。提交父版本为 `27c499a6048721944a1f7322cd3faccb2d29ad53`；使用实施前字节快照与 HEAD 三方拆分 66 个路径，保留范围外的宿主会话、横幅、live-clock、原通知 bridge 及原 `eventAnimationForward` 本地化改动。仅纳入被全窗口历史替代所必需的通知入口与焦点迁移；独立范围审计通过。真实工作区文件没有被拆分候选覆盖。

提交复核发现原 toolbar 名称仍为“返回上一级／前进到事件动画”，与跨页历史不符。新增 `settings.navigation.back`／`settings.navigation.forward` 的 `Back`／`Forward`、`返回`／`前进`，在 64 组合逐段断言图像 AX 名称与 tooltip。通知专项亦注册到完整 executable harness。

精确提交候选从 Git tree 导出到 [隔离源码目录](/tmp/claudio-native-settings-20261004/commit-source)，包含 HEAD 与本轮允许内容；没有共享工作区的其他待提交改动。使用 SDK 26.5 辅助工具链复核：

| 精确候选检查 | 结果 | 日志 |
|---|---|---|
| 普通 Debug `ClaudioGUI` | 通过；格式化后增量构建通过 | `commit-production-final-build.log` |
| GUI harness 编译 | 通过；最终增量构建确认注册与格式更新 | `commit-tests-formatted-build.log` |
| `--settings-native-alignment` | **380 checks，0 failures** | `commit-alignment.log` |
| `--settings-lifecycle` | **228 checks，0 failures** | `commit-lifecycle.log` |
| `--settings-native-regressions` | **335 checks，0 failures** | `commit-regressions.log` |
| 完整 GUI harness | **完整输出 all 17973 checks passed** | `commit-full.log` |
| 本地化 JSON、脚本语法、精确候选 diff whitespace | 通过 | 提交前复核 |

上述运行汇总在最后两处纯折行／缩进修正前完成；去空白后的字符序列完全相同，修正未改变逻辑、字符串或断言。格式化后重新编译生产产品与 harness，三份新增导航文件的 strict lint 通过。

[编译与二进制指纹](/tmp/claudio-native-settings-20261004/commit-build-evidence.json)、[专项与完整汇总](/tmp/claudio-native-settings-20261004/commit-tests-evidence.json) 保存于同一临时目录。完整 harness 结束后，日志采集器因系统诊断与文本交错产生的 UTF-8 字节而解码失败，采集器退出码为 1，未保存 GUI 子进程退出码；原始日志未修改，重新读取后确认完整的 17973 项通过汇总。此采集器错误不计为测试断言失败，也不以其退出码宣称 harness 通过。

此汇总与前文含其他共享改动的 17981 项／20 项失败属于不同源码集合；没有修改或清理那些共享改动，不能据此宣称原工作区的失败已修复。精确候选的原生属性／几何回归通过仍不等于真实键盘、VoiceOver 或独立人工验收。前文 Release／DEBUG 夹具包在通用导航名称修正与提交范围拆分前构建，其指纹不能代表本次 commit；此次提交复核没有重新组装或替换运行包。默认 SDK 27 宏插件限制与 macOS 12 实际运行待验状态保持原有证据边界。仅创建本地提交，不推送或正式发布。
