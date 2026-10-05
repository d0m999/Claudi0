# 集成自动化与原生设置实施规格

依据：用户确认的开发计划，ADR 0025。实施基线：`5a0be8821cc115428742bc605230249f052a47b1`。

## 呈现基线与原型

`designs/macos-settings-native/Native Settings Alignment Prototype.html` 在实施前已有未提交的用户改版。
本次在该文件上补充未安装、退出/崩溃、重启与关闭竞争场景，没有重新创作其布局。

- 实施前 SHA-256：`81eab0fc56429f1601767a867b39fb9c8396284fd2b0211c13409a250e53e593`
- 增补后 SHA-256：`e70e7764b347a6bcec6a8ade0d0769ae9dc8dd4a53182da21b941242e20fba91`

结构为应用列表 → 应用详情 → 诊断详情。列表仅显示产品图标、名称、自然状态、持久开关与详情入口；
详情列五类支持的提醒及能力限定，声音编辑指向默认组/工作区；诊断保留机制、配置路径、安装 UUID、
逐 binding 证据、重新检测/重新配置和回执历史。清除历史保留确认，且不清除当前激活。
Codex 授权场景仅为原型 fixture，生产不凭等待或缺少回执推断授权。

## 唯一事实与共享接口

正式自动维护来源仅 Claude Code、Codex、WorkBuddy；新来源遵守 ADR 0024。
`HostIntegrationIntentStore` 保持原有共享 `config.json` 为唯一意愿事实，结构如下：

```json
{"host_integrations":{"policy_version":1,"surfaces":{"codex":{"enabled":false,"revision":"8E08E8BD-D48E-4A26-BAC7-873804775AD7"}}}}
```

同值写入幂等，意愿变化生成 UUID。现有 ConfigFileTransaction 完成锁、CAS 和原子发布，第一次变更
保留 `config.json.host-integrations.bak`。声音配置、未知字段、未来来源及已知条目的未知字段保留。
损坏、版本不识别、非法布尔和非法 revision 拒写、拒收，不能被缺省迁移覆盖。

首次迁移及后续发现只补不存在的正式来源为开启；已保存关闭永不被升级、重启、重装或修复改回开启。
未安装来源继续列出并禁止开启，已保存开启允许关闭。CLI connect/disconnect 写同一意愿并执行一次维护；
repair 尊重关闭；status/doctor 只读。bootstrap 只准备共享 runtime。

`HostIntegrationManager` 提供 `setEnabled(surface:enabled:)`、`requestMaintenance(trigger:surface:)`、
`retryMaintenance(surface:)`、共享 `snapshotStream()`。快照分别表达意愿、发现、维护、运行资格、
安装及回执事实。GUI 保存成功才显示新开关；保存失败保持旧值。清理失败仍保持关闭并在诊断显示失败。

## 运行资格与发布边界

独立 `gui-run.json` 保存运行 UUID、PID、内核启动秒/微秒和用户身份；不是通知接收器存活的替代值。
验证拒绝损坏、进程死亡、zombie、PID 复用、其他用户和无法读取身份。不引入 daemon 或心跳。
正常退出按 UUID 撤销，不删除 hooks、意愿或历史；崩溃后由内核身份验证拒收。短音已启动则自然结束，
暂停期间事件不记录、不补播。运行 UUID 不进入 installation scope 或 receipt schema。

hook 在入口（CLI 读输入前）捕获来源 revision 与运行身份。统一短期许可使用 `host-authorization.lock`，
结果 allowed/stale/busy/unavailable；意愿最终发布、运行注册及撤销使用同一边界。

| 发布点 | 许可内工作 | 许可外工作 |
|---|---|---|
| 宿主配置及 installation marker | 最终 CAS rename、marker 发布/撤销 | 探测版本、bootstrap、备份、编码与 staging |
| 活动 | 有界提交或合法暂存 | 已接受暂存合并为历史 |
| 去重 | 有界消费 | payload 解析 |
| 回执 | 复验 token、安装身份、原子发布 | scope/version 探测 |
| 音频 | 复验 token、spawn | 声音解析、等待播放结束 |
| 通知 | 复验 token、datagram send | 导航证据采集、编码降级 |

旧安装不能覆盖新关闭，旧清理不能删除重新开启后的接入；各副作用分别复验，不能仅在 hook 入口检查。
被拒绝的事件不能进入活动暂存队列或写诊断日志。已经合法提交/暂存的事实可以保留为历史。

`HostEventNotice.intent_revision` 为 schema 1 的可选 UUID 字段，保持现有 hook 命令与 8 KiB 上限。
旧消息可解码，新版生产接收门禁拒绝缺失、非法、不匹配值；异步导航准备返回与最终 reducer 再次复验。
复制、去掉进程证据及传输降级保留 revision。关闭只收起该来源横幅，保留已接受提醒的 TTL、冻结阅读
身份和主动导航；不调用全局隐私清空。

## 维护与生命周期

应用启动依次准备同版本共享 helper/runtime、迁移意愿、注册运行资格、维护来源；准备失败不写宿主配置。
发现使用 HostExecutableLocator 的真实可执行文件与有界版本探测；WorkBuddy 校验应用 Bundle 身份与
可执行文件。配置目录本身不是安装证据，无配置目录的首次安装可以创建自有配置。

每来源独立任务并合并重复请求：250 ms 合并窗口，60 秒发现兜底；启动、唤醒、重新激活及相关文件变化
触发。可安全重试的 lockBusy 按 1、3、10 秒重试；耗尽后等事实变化或用户重试。永久失败保留原内容，
不会因没有回执反复重装。维护由 app lifetime 持有，离页和关闭设置窗口不影响它。

## 状态投影

| 事实 | 状态 |
|---|---|
| 未安装 | 未安装（已有开启可关闭） |
| 已保存 OFF | 已关闭；清理进度或失败另列 |
| 准备中/既有安装恢复中 | 正在准备/正在更新连接 |
| 配置就绪、尚无当前真实 binding 回执 | 接入已准备好 |
| 当前 installation/scope/binding 的真实回执 | 已收到事件 |
| 有证据的配置、权限、版本或共享 runtime 故障 | 原因及必要操作 |

## 验收矩阵与证据边界

| 范围 | 自动验证 | 人工/真实宿主验收 |
|---|---|---|
| 初次迁移与持久意愿 | 缺失项、OFF 幂等/跨迁移、损坏拒写、未来字段/声音/备份 | 各来源实际首次安装与升级 |
| 发现与维护 | 无配置目录发现、重复触发、无回执不重装、单来源隔离、重试 | 实际安装/卸载、版本升级、配置监听 |
| 竞争 | 最终发布前关闭、off→on 旧 token、各事件发布门禁 | 真实并发回调与关闭 |
| 运行资格 | 内核身份、退出、损坏/PID 复用、通知旧 revision | GUI 退出、强杀/崩溃、zombie、重启 |
| 证据 | 当前代次/binding、清除历史不改当前激活、8 KiB 降级 | 宿主真实回执与听音 |
| 原生呈现 | typed route/历史、逐来源保存、TTL/冻结阅读、双语 catalog | 明暗/双语/最小窗口、键盘、焦点、VoiceOver、sheet |
| 交付 | 两 executable harness、GUI Debug/Release、格式、本地化、同版本 bundle | 两 CPU、签名/公证、正式发布与接受 |

自动测试、原型语法/场景、原生操作与真实宿主验收分别记录。固定 baseline 设置 gate 要求 clean HEAD；
未经授权不得为了通过该门禁创建提交。当前执行结果与未验证项见
[验证记录](../docs/validation/integration-automation-2026-10-06.md)。
