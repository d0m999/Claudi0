# 多横幅与待展示队列验证（2026-10-06）

合同来源：[ADR 0013 现行修订](../adr/0013-separate-transient-notices-from-attention.md)、
[DESIGN.md 多横幅规格](../../DESIGN.md) 与本轮用户确认的实施计划。
本记录区分自动检查、原生挂载和人工／外部验收，不表达真实宿主激活、发布就绪或正式验收。

## 实施范围

- `EventNoticeModel.stackSnapshot` 唯一拥有最多三条可见横幅和 FIFO 待展示队列；展示与等待合计最多 50 条。
  提醒、冻结阅读及展示容量独立；短暂退场帧不占用新的展示名额，立即撤销动作资格。
- 每条保留稳定展示 ID、捕获动作版本、独立阅读采样及纯动效计划；下一提交合并新增入场批次。
  新版原位替换并重获四秒，旧动作取消；提醒容量淘汰后的已接受队列项仍能原位更新。
  排队、入场、整栈悬停／聚焦、队列展开与模态交互不消耗预算。
- 导航仍只有一个在途请求和原始三秒预算，反馈按完整动作保存；关闭其他横幅不取消请求。
  精确返回只移除捕获版本，应用回退与 `requestSent` 保留提示；版本、TTL 和隐私失效拒绝迟到回调。
- 一个 retained 透明 `NSPanel` 使用完整卡片实测高度选择 FIFO 前缀；缩屏保存预算，零卡时入口转入现有面板。
  卡片独立完成入场、让位与退场，窗口没有叠加淡入。纱只覆盖背景与装饰；正文、按钮、阅读轨保持正常对比度。
- 同步领域词汇、ADR、量化设计规格、主 HTML 原型、英中本地化注册和已有单横幅回归。
  本轮授权本地提交，未推送；不相关的原有及共享工作树修改单独保留。

## 环境与命令

本机为 arm64、macOS 27.0.1（26A434）、Apple Swift 6.4。
GUI 使用 CONTRIBUTING 允许的本地兼容 SDK 26.5；该选择不代替 CI 的完整 Xcode 验证。

```bash
swift run --package-path helper claudio-tests

SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  swift run --package-path gui --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk claudio-gui-tests

SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  swift build -c debug --package-path gui --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --product ClaudioGUI

node scripts/test-panel-settings-prototype.js
python3 scripts/test-panel-settings-prototype-browser.py
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
git diff --check
```

GUI executable harness 另有 `--event-stack`、`--event-stack-native` 和 `--event-reading-live` 聚焦入口；
使用上述相同 SDK 参数与 `SDKROOT`。所有原生 GUI harness 串行执行。

## 原实施工作树的自动检查结果

| 检查 | 结果 | 证据范围 |
|---|---|---|
| helper executable harness | 4999 项通过 | 现有 helper 合同和跨目录写盘台账；开发观察日志出口仍保留 |
| GUI executable harness | 23343 项／19 失败，未通过 | 全部 19 条与修改前基线一致；23324 项通过，无新增失败 |
| GUI Debug product build | 通过 | arm64、本地 SDK 26.5；未构建发布 bundle |
| 栈模型聚焦回归 | 120 项通过 | 注入时钟、FIFO、版本、容量、独立预算、暂停、反馈、TTL／隐私和迟到提交 |
| 原生栈聚焦回归 | 170 项通过 | 完整卡片测量、实际像素、挂载的按钮和无障碍树、队列滚动 |
| 原生真实时钟阅读轨 | 96 项通过 | AppKit 事件循环中的连续绘制和自然到期 |
| 主原型 Node | 121 项通过 | 原型状态与动作合同；没有真实宿主操作 |
| 主原型浏览器 | 55 项通过 | Chrome 离线临时上下文、真实 DOM 布局／动画／键盘事件 |
| 本地化 JSON / diff 空白检查 | 通过 | 英中键、相同计数占位符、注册及 JSON 语法 |

## 既有原生焦点失败的基线核对

完整 GUI 首轮为 23318 项、25 条失败；其中六条仍检查单横幅的旧接线断言已迁移，
独立 `--view-wiring` 的 277 项通过。其余 19 条是窗口没有取得 key 的原生焦点检查：
`PanelSettingsHandbackSuite` 17 条，`SettingsNativeShellSuite` 两条。

使用本轮修改前的 HEAD 与初始 dirty 文件副本构建独立临时 checkout；
只在其 harness 增加串行执行原有两组套件的入口，生产文件未改。
该基线为 480 项、19 条失败，失败的文件／行号及重复次数与完整 GUI 首轮、最终重跑完全相同。
最终完整 GUI 为 23343 项／19 失败（退出码 1），没有其他实际失败；本轮相关回归均通过。
因此不能将完整门禁登记为通过，也没有通过改弱断言处理这些失败。
原生 key 焦点、Tab 顺序及焦点归还仍需在可取得 key 的运行环境复验。

提醒容量淘汰后再收到队列项新版的边界，新增回归先复现三条失败（120 项／3 失败），
修复后同一入口 120 项／0 失败。主原型对应新增回归也先失败，修复后全部 121 项通过。
这一分支保留展示 ID 和 FIFO 位置，递增捕获版本、释放旧动作，不增加展示溢出计数。

本轮未改动的 13 个初始 dirty 文件与保存的 SHA-256 完全一致；
`DESIGN.md`、主 HTML 原型及浏览器回归文件为有意重叠路径，保留已有修改并追加本轮合同。
上表的浏览器结果针对实施完成时的共享工作树，包含期间到达的其他开发改动；
提交时继续区分该历史快照与精确提交快照，后续未提交修改不继承这份结果。

## 本地原始证据

这些日志保留在 Git 外，路径为本机临时证据；不代表发布或真实宿主验收。

| 证据 | 本地日志 |
|---|---|
| helper 全量 | [helper-latest.log](/tmp/claudio-banner-helper-latest.log) |
| GUI 最终全量 | [gui-full-complete.log](/tmp/claudio-banner-gui-full-complete.log) |
| 修改前焦点基线 | [baseline-focus.log](/tmp/claudio-banner-baseline-focus.log) |
| 栈模型 | [stack-final-complete.log](/tmp/claudio-banner-stack-final-complete.log) |
| 原生栈挂载 | [stack-native-latest.log](/tmp/claudio-banner-stack-native-latest.log) |
| 真实时钟阅读轨 | [reading-live-latest.log](/tmp/claudio-banner-reading-live-latest.log) |
| GUI Debug 构建 | [debug-build-complete.log](/tmp/claudio-banner-debug-build-complete.log) |
| 主原型 Node | [prototype-node-complete.log](/tmp/claudio-banner-prototype-node-complete.log) |
| 主原型浏览器 | [prototype-browser-complete.log](/tmp/claudio-banner-prototype-browser-complete.log) |

浏览器最终重跑为 55 项、103.381 秒、退出码 0。
原实施工作树已验证的主原型 SHA-256：`b927f169134335de9bf46eda7861f176b2156c041170b80e72995e15a1047cdf`。
Node 回归 SHA-256：`cd50ba92821fedbef630be78d4aaa0552e62bbb5b2fd58e98ed3faec768c6ed4`；
浏览器回归 SHA-256：`e837e3b82407c59cfbdefb3743f32735ba393f8fef4c7f68803bfde96d060f02`。

## 本地提交快照的追加检查

本地提交使用独立临时索引，仅包含本轮原生实现、合同、文案、回归和所需的横幅原型前置变更。
设置外观、写入重试、场景导航、helper 迁移等其他工作仍留在共享工作树；重叠文件按差异拆分，未替换本机文件。
从临时索引导出独立目录，验证它不依赖那些未提交的设置修复：

| 检查 | 提交快照结果 |
|---|---|
| 栈模型 executable harness | 120 项／0 失败 |
| GUI Debug product build | 通过，arm64／SDK 26.5 |
| 主原型 Node | 121 项／0 失败 |
| 主原型浏览器 | 49 项／0 失败，90.938 秒 |

提交快照的 browser 回归包括队列来源投影、通知关闭、容量及冻结阅读的相关前置覆盖，
排除其余未提交的设置修复及测试。拆分首轮曾遗漏队列来源投影关联行，49 项中四个语言／事件组合失败；
补齐同一提醒投影后，同一 49 项全部通过。
helper／GUI 全量及原生挂载、真实时钟的上表结果仍属于原实施工作树；提交快照没有重新运行这些完整门禁。

提交快照主原型 SHA-256：`19ab467fd9108d33ffaf357f2a412e4c43e6c5147079bc2a8afe96b34afa54e5`；
提交快照浏览器回归 SHA-256：`2d0f4d73247b251120aab7869236cec07b853342d9247bdd587cd6b0f61ec1c7`。

## 呈现与人工／外部检查状态

| 项目 | 本轮已验证 | 人工／外部状态 |
|---|---|---|
| 明暗主题、英中正文、窄宽卡片 | 原生挂载与像素；440／268 pt；三层正文和阅读轨颜色一致 | 人工外观复核未验证 |
| 较大字号 | 完整卡片自然测量已实现 | 系统较大字号人工检查未验证 |
| 队列滚动 | 实际 `NSScrollView`、220 pt 上限、受限高度与只读摘要 | 人工滚轮／触控板体验未验证 |
| 单条关闭、Escape | 模型、原生按钮动作／取消命令、浏览器键盘事件 | macOS 实际 Tab 顺序、键盘 Escape 与焦点归还人工检查未验证 |
| VoiceOver | 展示 ID 唯一、隐藏测量与退场撤销无障碍资格的自动检查 | VoiceOver 实际播报与操作未验证 |
| 多屏 | 复用原有定位和屏幕变化处理，纯布局高度回归 | 实际多屏、刘海、Spaces、全屏切换未验证 |
| Reduce Motion | 纯计划、阅读轨绘制和浏览器中途切换回归 | 系统设置中途切换人工检查未验证 |
| 来源 OFF、静默、隐私 | 模型、导航取消、退场／待展示清除与迟到回调回归 | 实际锁屏／睡眠／退出场景未验证 |
| 真实宿主与声音 | helper 合同和注入 adapter fixture | 本轮未验证真实回调、真实会话返回或听音 |
| 发布／正式验收 | Debug 构建 | Intel、通用 bundle、签名、公证、生产与正式验收均未验证 |

原生位图来自 harness 的 `NSHostingView.cacheDisplay`；它们是合成 fixture 证据，
不是 Computer Use 截图，也不是用户现场或真实宿主证据。
