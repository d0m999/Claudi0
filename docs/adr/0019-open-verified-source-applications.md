---
status: accepted
---

# 打开已确认的来源应用，独立于精确会话返回

采用 2026-09-28 用户确认的 Event Banner 行动优先计划。来源应用由 helper 的同用户进程祖先身份与 GUI 的操作系统复验共同确认；终端中的宿主可以指向承载它的终端。App 级打开只收起提示并保留提醒，不产生 `exactReturnConfirmed`。缺少可靠身份时提供详情和有效会话 ID 复制，避免由宿主名猜测应用或会话路径。

helper 仅在有效接收通道存在时捕获最多 16 层祖先的 PID 与操作系统启动时间。schema 1 的可选字段保持旧消息兼容和 8KiB 上限。GUI 复验同用户、启动时间与祖先关系，选择最近的可激活 `NSRunningApplication`，随后释放原始祖先列表。`EventNoticeModel` 唯一持有绑定提醒版本的 `SourceApplicationTarget`，随版本过期、移除、隐私清空释放；来源身份不进入回执、活动摘要、配置或日志。

打开时再次校验原实例；实例已退出时，只有此前确认的应用位置与 bundle 身份仍匹配才允许重新打开。动作沿用版本、epoch、能力代次、单在途和 3 秒超时保护。重开先以不激活方式完成，再在仍有效的回调中激活，避免迟到回调抢焦点；超时后系统可能完成启动，但不能再激活或更新反馈。成功切换清除原窗口的焦点归还动作；失败进入详情，只在仍持有交互资格时接管键盘。

所有胶囊共用 4 秒阅读预算，悬停、聚焦和展开共同暂停。快照携带单调时钟采样与剩余时间，视觉刷新只绘制进度；每个待接手版本独立保留最多 30 分钟。旧版本显示「已更新，请刷新」，真正过期才擦除来源与时间。

本决定修订 [ADR 0012](0012-use-ephemeral-event-source-notices.md) 的默认来源动作与胶囊入口，以及 [ADR 0013](0013-separate-transient-notices-from-attention.md) 的展示合同；两者的隐私、容量、冻结、声音独立与非激活窗口边界继续有效。原型中待接手使用 30 分钟进度、未知原因称为审查、瞬时无关闭按钮和声音触发字形脉冲的表述由本次计划覆盖。布局与文案见 [DESIGN.md](../../DESIGN.md)，证据见[验收台账](../event-attention-acceptance.md)。

结构参考：[Open Island 固定源码](https://github.com/Octane0411/open-vibe-island/blob/b50f87aa7d58af1478837d48909eb68baa37f9b9/Sources/OpenIslandApp/TerminalJumpService.swift#L351) 分开应用激活和会话定位；实际系统调用采用 Apple 的 [NSRunningApplication](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(options:)) 与 [NSWorkspace.openApplication](https://developer.apple.com/documentation/appkit/nsworkspace/openapplication(at:configuration:completionhandler:))。

## 整合原型修订（现行 · 2026-10-01）

本次呈现基线为 `designs/panel-and-settings/Panel and Settings Prototype.html`，完整合同见 [原生迁移规格](../../plan/PLAN-NATIVE-PROTOTYPE-MIGRATION.md)。它覆盖历史提示音组称呼、内层列表布局与横幅详情合同；包级事务和安全边界继续有效。容器统一称「声音包」，单个声音称「提示音」。八页顺序为默认组／工作区、声音、集成、通知、通用、快捷键、活动与诊断、关于，raw values 不变。

横幅正文静态，无展开或详情。未确认来源提供「在面板查看」；跳转失败就地呈现原因/重试，剩余 4 秒预算不重置。仅横幅自身悬停/聚焦暂停；面板与诊断共享独立冻结阅读集合，首个消费者冻结，显式刷新，末个关闭释放。来源激活仍保留提醒且不产生 exactReturnConfirmed。

## 原生会话导航修订（2026-10-04）

上述“正文静态”及 App 激活即收起的历史规则由 [ADR 0023](0023-return-to-verified-local-sessions.md) 替代。现有外观与唯一窗口 owner 保留；正文、主按钮、面板和活动诊断共用导航入口，仅精确返回消除对应提醒版本。自动检查与真实宿主验收分别记录。
