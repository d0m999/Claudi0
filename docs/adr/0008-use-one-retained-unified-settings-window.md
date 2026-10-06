---
status: accepted
---

# 使用一个 retained 统一设置窗口承载全部设置目的页

claudi0 使用一个由 AppKit controller 持有并在 app 生命周期内复用的统一设置窗口，以固定侧栏和类型化路由承载「通用、集成、事件与提示音、通知、显示、声音、用量、快捷键、关于」九个设置目的页。现有集成、事件与声音包的领域模型和写入链继续各自拥有事实，但对应视图迁入同一窗口；迁移完成后不再保留三个彼此竞争焦点和刷新时机的平行管理窗口。菜单栏入口和目的页间动作只提交设置路由，由统一窗口负责展示、选择、焦点与关闭后的 app handback。

选择这一形态是因为批准原型的核心合同就是同一设置空间内的稳定导航，而继续以多个 retained 窗口模拟侧栏会复制窗口生命周期、路由和刷新状态。代价是现有 view 必须从各自的 window controller 解耦，声音包的深编辑器也要成为「声音」目的页内的唯一编辑面；不得为迁移方便再创建一套轻量设置模型或第二条写入路径。

## 修订：2026-09-28

窗口焦点采用 [ADR 0022](0022-separate-panel-and-settings-window-focus.md) 的非激活窗口机制。
这一变更保留本 ADR 的唯一 retained owner、统一设置内容与类型化路由。

统一设置窗口与类型化路由的决定继续有效。顶层目的页改为「默认组／工作区、声音、集成、通知、通用、快捷键、活动与诊断、关于」八页；上方原九页清单中的「显示」已被本修订取代。固定紧凑布局不需要独立目的页，Orbit Zero 的装饰点也不再作为可调偏好。历史 `display` 路由值在启动时投影到「通用」，不报配置损坏且不主动改写保存值；历史 `Claudio.MenuBarStatusDot` 值保留但不再读取或影响图标。

## 整合原型修订（现行 · 2026-10-01）

本次呈现基线为 `designs/panel-and-settings/Panel and Settings Prototype.html`，完整合同见 [原生迁移规格](../../plan/PLAN-NATIVE-PROTOTYPE-MIGRATION.md)。它覆盖历史提示音组称呼、内层列表布局与横幅详情合同；包级事务和安全边界继续有效。容器统一称「声音包」，单个声音称「提示音」。八页顺序为默认组／工作区、声音、集成、通知、通用、快捷键、活动与诊断、关于，raw values 不变。

横幅正文静态，无展开或详情。未确认来源提供「在面板查看」；跳转失败就地呈现原因/重试，剩余 4 秒预算不重置。仅横幅自身悬停/聚焦暂停；面板与诊断共享独立冻结阅读集合，首个消费者冻结，显式刷新，末个关闭释放。来源激活仍保留提醒且不产生 exactReturnConfirmed。

## macOS 设置呈现修订（历史 · 2026-10-02）

当时八页设置及详情／sheet 的呈现引用为 `designs/macos-settings-native/claudi0 macOS Settings Prototype.html`，SHA-256 `f49c338fde51a03fa4ada9b5f31f071a281e6708038dbac609f3c7931b93fe91`，合同见 [八页设置迁移规格](../../plan/PLAN-MACOS-SETTINGS-MIGRATION.md)。它覆盖 #214 及 #213 中冲突的设置皮肤、独立事件卡与双栏／固定操作栏；此项视觉引用已由 2026-10-06 的主原型 SoT 修订取代。领域事务、稳定身份、唯一 retained window、非激活焦点及写入 owner 合同保留。该修订不代表完整原生验收通过。

## 原生会话导航修订（2026-10-04）

上述“正文静态”及 App 激活即收起的历史规则由 [ADR 0023](0023-return-to-verified-local-sessions.md) 替代。现有外观与唯一窗口 owner 保留；正文、主按钮、面板和活动诊断共用导航入口，仅精确返回消除对应提醒版本。自动检查与真实宿主验收分别记录。

## 系统原生设置外壳与浏览历史修订（2026-10-04）

设置继续由唯一非激活 retained window 承载，改用原生 split sidebar、source-list 和 unified toolbar；右侧复用现有 SwiftUI 目的页。八页及详情共享一个由 `SettingsPresentationSession` 持有的窗口期历史，最多 64 个位置，关闭清空。选择这一形态是为了统一跨页前后导航、系统侧栏键盘行为和工具栏 safe area，同时保持 macOS 12 及现有 `.accessory` handback。

位置只记录稳定浏览身份、捕获目录和阅读书签，不捕获配置或写能力。返回查看包不等于应用该包；失效身份进入不可用页而不是可写默认组。刷新和匹配当前导航版本的操作结果更新当前位置；历史遍历不重放复制、采用或写入。sheet 阻止外层导航，旧恢复请求与迟到结果不能覆盖新位置。它取代仅通知局部前进记录，避免目的页各自维护第二个路由或焦点 owner。完整呈现合同见 DESIGN 的“系统原生外壳与窗口期历史”。

## 统一主原型作为画面 SoT（现行 · 2026-10-06）

菜单栏面板、事件横幅和八页设置共用 [`Panel and Settings Prototype.html`](../../designs/panel-and-settings/Panel%20and%20Settings%20Prototype.html) 作为唯一画面参考。设置外观以当前 SwiftUI 页面和 AppKit 原生 split sidebar、source-list 与 unified toolbar 为准；独立的 `Native Settings Alignment Prototype.html` 与旧设置原型只作迁移记录和历史参考。

该决定只规定视觉参考顺序。原型中的 HTML 状态和动作不等于生产行为；路由、状态、写入、窗口 owner、焦点、无障碍、持久化和宿主能力继续由本 ADR、相关 ADR 与 Swift/AppKit 实现决定。一个 retained 设置窗口及窗口期导航历史合同不变；此项不表示已完成原生视觉验收。
