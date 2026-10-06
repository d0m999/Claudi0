# OpenCode／Kimi Code 真实宿主验收（2026-10-06）

状态：三个绑定已通过逐绑定验收并写入正式启用集合；普通 Release app 已构建并运行，最终当前安装的三个绑定回执均为 `played`。

用户授权取得真实宿主、原生提示和听音证据，随后构建 app。证据按绑定记录；真实回执的
`played` 只证明播放进程已启动，不能代替人工听音或原生提示观察。

## 候选与隔离

- 源码基线：`b14703d6caab5bf064da8e2c30d89962c6967d3f`。
- 使用独立 detached worktree，保留主工作树同时进行的设计／动画修改。
- macOS `27.0.1`、arm64、Swift `6.4`；本机兼容 SDK 为 macOS `26.5`。
- OpenCode `1.18.34`；Kimi Code `2.1.1`。
- app 使用 `--additional-host-acceptance` 构建，plist 的
  `ClaudioAdditionalHostAcceptance` 为 `true`；属于本地 ad-hoc 验收候选。
- 独立候选 GUI SHA-256：
  `901f8e18c37151cdca4a8ed6918405232573a2fdc0ef88cfbc1b5d4c474007fc`。
- 独立候选 helper SHA-256：
  `7c82d52af225bf67d8a88a4dd55a0d68778aaadbbc0f63486d07429870449250`。
- 真实宿主仅在空白验收目录执行自拟测试任务。配置、helper、候选指纹、测试输出及回执
  保存在本机私有证据目录；真实配置、凭据、prompt／response、完整回执不进入 Git。

第一份位于共享 `dist/claudi0.app` 的候选被另一轮重建移除，GUI 随后退出；该期间的
Kimi 调用不计为接收验收。用户随后确认本轮独占 app 运行验收。独立候选的真实测试
前后检查 GUI 注册身份、可执行路径、存活状态及已安装 helper 与候选的一致性。

## 自动检查

| 检查 | 当前结果 | 边界 |
| --- | --- | --- |
| helper 全量 executable harness | 4,857 checks，0 failures | 自动合同；不证明真实宿主／听音 |
| OpenCode plugin harness | 37 scenarios passed | 合成上游事件 |
| 新增宿主 CLI 合同 | 161 checks passed | 最终普通 Release helper；隔离 fixture、假宿主版本、静音音频 |
| GUI Debug build | PASS | 本机 macOS 26.5 SDK |
| 验收候选与普通 app Release 构建、体积、ad-hoc 签名 | PASS | 本机 arm64，非 universal／公证产物 |
| JS 嵌入一致性、catalog JSON、diff whitespace | PASS | 静态结构 |
| GUI 新增来源专项 harness | 113 checks，0 failures | 自动合同 |
| GUI 全量 harness | 23,023 checks，0 failures | 当前主工作树、本机自动／原生探针；不代替人工验收 |

最终普通封包：GUI 6,083,984 B，helper 3,154,736 B，LoginItem 54,208 B；非可执行
资源 2,422,191 B，正规文件合计 11,715,119 B，均满足既有预算。

OpenCode 原 JSONC 与 Vibe Island 插件 SHA-256 与备份一致。Kimi 首次接入保留原配置
前缀；验收期间观察到非 Claudio 的 `default_model` 外部更新，最终保留当前值。忽略
该单字段和新增分隔空行后，其余非 Claudio 字节与原备份一致；最终 Kimi 再次 connect
逐字节幂等。接入仅管理 Claudio 自有插件／hooks 与来源启用意愿，原始配置备份保留。

## 逐绑定证据

| 来源／绑定 | 真实宿主／当前回执 | 原生提示 | 人工听音 | 正式启用 |
| --- | --- | --- | --- | --- |
| OpenCode `UserTurnStarted` | 真实 `run --dir` 用户任务；当前回执 `played` | 用户确认 | 用户确认 | 已写入集合 |
| OpenCode `ResponseCompleted` | 三次真实 `run --dir` 用户任务；当前回执 `played` | 用户确认 | 用户确认 | 已写入集合 |
| OpenCode `ResponseFailed` | 待验证 | 未验证 | 未验证 | 关闭 |
| OpenCode `PermissionRequested` | 待验证 | 未验证 | 未验证 | 关闭 |
| OpenCode `QuestionAsked` | 待验证 | 未验证 | 未验证 | 关闭 |
| OpenCode `SubagentCompleted` | 待验证 | 未验证 | 未验证 | 关闭 |
| Kimi Code `TurnStarted` | 三次真实 `-p` 用户任务成功；当前回执 `played` | 用户确认 | 用户确认 | 已写入集合 |
| Kimi Code `PermissionRequest` | 待验证 | 未验证 | 未验证 | 关闭 |
| Kimi Code `PreToolUse(AskUserQuestion)` | 待验证 | 未验证 | 未验证 | 关闭 |
| Kimi Code `SubagentStop` | 待验证 | 未验证 | 未验证 | 关闭 |

Kimi Code `Stop`／`StopFailure` 继续未实现，不以其他绑定的成功借用身份或终态证据。
精确会话导航、VoiceOver、完整键盘／焦点、Intel、Developer ID、公证、CI 和发布未验证。

## 原生观察与声音输出

Computer Use 的 Claudio 原生观察多次返回 `-10005: timeoutReached`；app 启动与真实
进程身份可以独立核实，但 AX／截图／原生交互尚未取得，不将工具调用当成通过证据。
后续原生提示和听音以用户逐组实际观察确认，未确认的绑定不进入正式集合。

首次独立 Kimi 回执产生后，用户回答“没有收到／没来得及观察”。读回通知偏好没有
显式关闭值，接收器 descriptor 有效；系统默认输出为 MacBook Pro 扬声器，静音为
`false`，主音量约 `0.551145`。这些读回不代替听音。随后倒计时与三次新用户任务
的观察重测，已由用户确认横幅和声音。

## 真实宿主暴露的修复

OpenCode 1.18.34 的实际模块加载器要求默认 `PluginModule` 导出。原模板只有具名
`id`／`server`，真实宿主报告 `Plugin export is not a function`，未初始化 Claudio。
先增加公开导出断言并观察失败，再加入 `export default { id, server }`；具名导出保持。

默认导出修复后，任务开始取得真实回执，用户确认“任务开始的横幅和声音都收到”。
完成仍无回执。私有只记录白名单身份／状态／时序的观察插件确认：宿主已发出终态
assistant 消息和对应 idle，约 16 ms 后调用 `dispose()`。原实现此时会杀掉正在启动的
helper。真实子进程回归先得到空结果并失败；修复后已接纳回调自然完成，宿主存活时
保留原有 1.5 s 子进程超时，新事件及未接纳队列仍在 dispose 后拒绝。

Kimi 倒计时后三次重测，用户确认“横幅和声音都收到，可以确认”；首次未及时观察的
结果没有计入人工通过。OpenCode 完成修复的新候选已取得开始／完成真实 `played` 回执；第一次用户未及时观察，
随后倒计时连续三次真实任务，用户确认“开始和完成的横幅、声音都收到”。

## 正式启用集合

- `opencode:UserTurnStarted:task_start:bridge_execution_evidence_only:v1`
- `opencode:ResponseCompleted:stop:bridge_terminal_evidence_only:v1`
- `kimi-code:TurnStarted:task_start:user_origin_only:v1`

其余七个已实现候选绑定没有取得三类证据，未进入集合；Kimi 的两个终态绑定继续未实现。
本次通过表示以上逐绑定本机验收，不表示所有事件、版本或 CPU 架构均已验收。

## 最终普通封包

补丁按九个明确路径同步到当前主工作树，目标文件与隔离基线逐字节核对，原源码另有
私有备份。保留本轮之外已提交的设计／动画改动；封包基于主工作树 `3bf3840fc0eaebf1ffc4453a10b47bd6357db935`
加本轮未提交补丁，未创建提交或推送。

- 稳定产物：`dist/opencode-kimi-verified-20261006/claudi0.app`。
- 普通构建：不传 `--additional-host-acceptance`，plist 无该验收开关。
- GUI SHA-256：`5f1385233d82363241089cb71d54ccf6879f2be2afd2ad4f5d60bf000d38cf1e`。
- helper SHA-256：`299999d667cd4acb7060bc5b048afd49b932a621a81a54c6655b8c4961e0f432`。
- 插件资源 SHA-256：`da22bceea841b3a420655f498fadbba04ba29d91a31bf16f02f7ad605cd89698`。
- 实际普通 Release helper 用不可变副本运行 CLI 合同，避免与封包缓存混用。

候选回执与真实输出保留在本机私有证据目录：`kimi-start-repeat-evidence.json`、
`loader-fixed-first-opencode-main-evidence.json`、`opencode-main-repeat-evidence.json`；
候选指纹见 `isolated-candidate.json`、`loader-fix-candidate.json`、
`dispose-fix-candidate.json`，最终指纹见 `ordinary-final-candidate.json`。
原生提示／听音通过依据为用户上述逐组确认，不以 AX 超时、静态偏好或 played 独立替代。

最终 app 的 GUI 注册身份、可执行路径和安装 helper 指纹一致；普通模式的实际
OpenCode `enabled_events` 恰为 `UserTurnStarted`／`ResponseCompleted`，Kimi 自有 TOML
块恰有一个 `TurnStarted` hook。证明记录为私有 `final-installation-proof.json`。

主工作树 GUI 全量已完整退出并通过（23,023 checks）；隔离旧基线的全量运行在发现
旧声音包选型板合同失败后停止，不能当成全量通过。相同选型板合同在当前主工作树
已单独通过，且包含于当前主工作树全量结果。最终 GUI Debug build 同样通过。

## 最终普通 app 的真实回调复核

- `ordinary-opencode-main-evidence.json`：真实任务 exit 0，`UserTurnStarted` 和
  `ResponseCompleted` 均为当前普通安装的 `played` 回执，GUI／helper 身份前后不变。
  原 `opencode/mimo-v2.6-flash-free` 请求在上游重试后达到 150 s 测试超时；该请求未计为
  成功完成。随后使用 CLI 实际列出的免费 `opencode/ling-3.1-flash-free`，经过上游重试
  后真实返回终态并取得完成回执。未构造合成回调填充验收。
- `ordinary-kimi-start-evidence.json`：真实任务 exit 0，`TurnStarted` 为当前普通安装
  的 `played` 回执，GUI／helper 身份前后不变。
- 最终 `integrations status --json`：两个来源均 enabled、configured、接收资格为 true，
  最新回执安装身份匹配当前安装且为 played；私有记录 `ordinary-final-status.json`。
- 曾观察到一次 Kimi 版本身份暂时无法读回；随后四次直接版本读取成功，约 0.33–0.72 s，
  最终真实回调和状态均通过。没有将暂时无法读回提升为支持或通过证据。

三个绑定的原生提示／人工听音依据仍为上文用户逐组确认；最终普通 app 的回调复核
单独记录，不据此增加任何尚未人工观察的绑定。当前产物是本机 arm64 ad-hoc app，
没有进行 universal、Developer ID、公证、CI 或发布。
