---
status: accepted
---

# 使用仅驻留内存的事件来源提示与辅助窗口

全事件历史与消除规则已由 [ADR 0013](0013-separate-transient-notices-from-attention.md)
部分替代；下述内存、非激活窗口及隐私边界继续有效。
事件接收资格与退出行为由 [ADR 0025](0025-automatically-maintain-explicit-host-intent.md)
替代本文旧的“GUI 未运行仍播放、写回执与计数”条款，见文末现行修订。

来源应用身份、App 级打开与胶囊入口由 [ADR 0019](0019-open-verified-source-applications.md)
修订；精确会话导航仍须独立验证。

Claudio 将宿主 hook 的最少来源字段投影为独立的不可变 `HostEventNotice`，通过 GUI
拥有的私有 Unix domain datagram endpoint 传递给当前运行的提示模型。来源提示只在本次
GUI 生命周期的内存中保留，最多 50 条、最长 30 分钟；它不进入
`HostHookReceipt`、receipt history、本地活动摘要、配置、日志或磁盘队列。

来源提示是对既有声音事件和宿主激活事实的短暂 presentation projection，而不是新的
宿主能力、回执证据或导航真相源。hook 发送是 best-effort 的一次非阻塞尝试：GUI 未运行、
endpoint 失效或队列已满时，既有播放、回执、活动计数和 CLI 成功退出合同保持不变。

自动到达使用 retained、非激活的 `NSPanel`，只显示在顶部，不激活 Claudio、不抢输入焦点。
用户点击来源、数量或菜单栏「近期提示」后，窗口才进入可键盘交互状态。应用关闭、锁屏、
睡眠、退出或用户关闭提示偏好时立即清除来源并使当前 receiver epoch 失效；胶囊的显式收起
只改变展示状态，近期记录仍可在本次运行内重看；恢复只接受新事件。

动态静默继续由 ADR 0009 的 GUI 观察者和带有效期快照负责。静默期间允许保留本次运行的
近期信息，但自动提示只收起且不在恢复时补播。`SettingsDestination` 与 ADR 0008 的
单一 retained 设置窗口仍是设置与菜单栏路由的 owner；事件来源提示不创建第二个设置窗口。

精确会话跳转不是默认能力。没有经过宿主 adapter 证据的来源只提供来源详情和复制有效
session ID；开发预览可以注入模拟成功/失败，不能作为生产导航证据。

## 事件接收资格修订（现行 · 2026-10-06）

[ADR 0025](0025-automatically-maintain-explicit-host-intent.md) 明确替代本文“GUI 未运行时既有播放、
回执和活动计数保持不变”的旧合同。新版 helper 在入口捕获共享来源意愿 revision 和独立 GUI 运行身份，
并在各发布边界复验；GUI 退出、崩溃、注册不可验证或来源关闭时，新事件安静返回且副作用为零。
通知偏好关闭或 receiver 不可用与 GUI 退出不同：已开启来源仍可处理合法声音、活动和回执，通知继续
best-effort。已启动声音自然结束，不补播暂停事件；运行身份不进入 installation/receipt。

`intent_revision` 可选解码，生产接收门禁拒绝旧消息或错误 revision。关闭来源只收起该来源横幅，
不执行全局隐私清空；已接受待接手提醒、冻结阅读及主动导航能力依原 TTL 保留。锁屏/睡眠的既有
全局隐私边界仍独立有效。
