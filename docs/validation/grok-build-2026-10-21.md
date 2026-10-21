# Grok Build 首版实现与验证（2026-10-21）

本记录对应 [ADR 0035](../adr/0035-integrate-grok-build-native-attention-hooks.md) 和用户确认的首版计划。
实施基线为 `ad6ce3a51d3df31b55d24f520f6e6b6eeb312835`；下列验证采集自本轮未提交工作区，
后续本地提交不代表发布或 Grok binding 获得普通 Release 准入。
Grok 的 `AdditionalHostReleasePolicy.verifiedBindings` 集合为空：普通 Release 隐藏入口，
Debug／`CLAUDIO_ADDITIONAL_HOST_ACCEPTANCE` 只开放三条候选 binding。

## 实现合同

| 公共事件 | 原生绑定 | 当前实现 |
| --- | --- | --- |
| `task_start` | `UserPromptSubmit` | 尚未实现：人工输入与自动唤醒不能可靠区分 |
| `stop` | `Stop` | 尚未实现：仍可被 gate 阻止 |
| `stop_failure` | 主会话 `StopFailure` | 仅 API 错误；按 session＋prompt 去重 |
| `notification` | `Notification(permission_prompt)` | 用户授权等待；无请求 ID，沿用通知去抖与提醒版本 |
| `notification` | 精确 `PreToolUse(ask_user_question)` | 提问意图，按 session＋tool-use 去重，不创建待接手提醒 |
| `subagent_stop` | `SubagentStop` | 尚未实现：仍处于结束 gate |

配置只管理 `GROK_HOME/hooks/claudio.json`；无有效绝对 `GROK_HOME` 时使用 `~/.grok`。
三条 binding 超时均为 2 秒。完整已知模板才证明所有权；外来、空白、编辑、重复 binding、
符号链接或并发编辑均不能成为覆盖／删除授权。关闭先保存 OFF 并撤销接收资格，清理失败仍关闭。
Claude compatibility、第三方 hooks、未知配置及一次性备份保留。

Grok 兼容加载的 Claude Claudio 命令及旧 `play` 在副作用前静默拒收。
原生回调同时验证 runner 的保留 `GROK_*` 身份、事件、字段类型、重复键和别名一致性。
来源摘要读取当前已准入绑定的回执；各 binding 的激活仍独立，不能互相借证。

首版恒用默认组。下述目录观测没有完成两个目录及关联 worktree 的验收，不开放工作区资格。
授权、提问和中断复用既有横幅／待接手模型；导航复用可信终端证据，应用切换不移除提醒。

## 本机真实宿主观测

- 宿主：`grok 1.0.62 (1474f9cbdd91)`，arm64。
- 实际 executable SHA-256：`ec434e831afdcfce87780f2815fd732b1df8a4a8de96a491716ad75d13605a4e`，POSIX mode `0755`。
- 在临时 `GROK_HOME`／Claudio 根和固定测试项目中运行原生 Grok；请求只送到 loopback 的受控
  OpenAI-compatible endpoint，返回工具调用或固定 HTTP 401。模型回复是本地 fixture，未使用真实
  供应商凭据或远程模型服务。未改写用户宿主配置、Claude compatibility 或已安装 executable。
- 临时 GUI 运行注册使用测试进程的真实内核身份，未伪造进程存活；它不是真实 Claudio GUI。
  提示音音量为 0，`played` 只证明 `afplay` 成功启动，不能证明人工听感。

| 流程 | 真实 Grok 回调 | Claudio 结果／证据边界 |
| --- | --- | --- |
| 受控 API 401 | 主会话 `StopFailure(error=authentication_failed)`，含 `promptId` | 生成当前 `stop_failure` 回执 |
| 原生 TUI 授权等待 | `Notification(permission_prompt)`；无请求 ID | 生成当前 `Notification` 回执 |
| 原生 TUI 提问工具 | 精确 `PreToolUse(toolName=ask_user_question)`，含 `toolUseId`、无 `promptId` | 生成独立提问 binding 回执；TUI 自动采集到等待回答状态 |
| 提问实际展示 | 另发 `Notification(elicitation_dialog)` | 按确认范围忽略，不扩大为明确输入请求 |
| 取消授权等待 | `StopCancelled` | 不生成执行中断回执 |
| 自动允许、正常结束 | `PreToolUse(run_terminal_command)`、`Stop` | 不生成开始／结束／执行中断提醒 |
| 工具执行 `exit 1` 后正常回复 | 工具调用、`Stop` | 不生成执行中断回执 |
| 强制 ask＋always-approve | 仍发 `permission_prompt`，`permissionMode=bypassPermissions`，客户端立即自动批准 | 修正后拒收，未新增通知回执；自动夹具另验证零活动／声音／提示副作用 |

真实回调的 `cwd` 与各固定测试项目一致，runner 的 session／workspace 身份与 payload 一致。
这些是宿主 runner 的真实派发证据，不是直接向 `claudio hook` 注入 payload。
取消／关闭测试使用受控进程终止；未完成真实子会话、所有终端组合或长期运行验收。

### 真实接线修正

1. 强制 ask 可越过 Grok manager 的自动允许路径，而客户端仍会自动答复；因此只接收已知
   `default`／`auto`／`plan` 模式的授权通知，拒收 bypass、未知及缺失模式。
2. 原有来源摘要固定等 `task_start`。Grok 没有该实现，改为读取其当前已准入绑定的最新真实
   回执；授权回执仍不能激活提问 binding。CLI doctor 和 adapter 回归覆盖该边界。

## 自动检查

检查从仓库根目录运行。GUI 使用本机 Swift 6.4 与 macOS 26.5 SDK，显式选择
`--build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`；
GUI harness 同时设置相同的 `SDKROOT`。这些结果不替代人工听音与正式发布资格。

| 检查 | 结果 |
| --- | --- |
| helper 完整 executable harness | 最终在无本轮编译／GUI harness 并行负载时，6153 项通过 |
| GUI 完整 executable harness | 25243 项通过 |
| GUI 接入合同 `--question-integration-contract` | 最后一次 JSON 实现精简后，3133 项通过 |
| additional-host CLI | 344 项通过；Debug 夹具与本轮普通 Release 封包内 helper |
| 普通 Release 迁移 | 242 项通过 |
| `--acceptance` 迁移 | 286 项通过 |
| GUI Debug 产品构建 | 通过 |
| 普通 Release／显式验收封包 | 均通过构建、体积、输入边界、ad-hoc 签名及 Sparkle 检查 |
| 已安装工具隔离 | 5 个真实 executable 的 SHA-256 与 POSIX mode 在收尾保持一致 |
| Swift format | 38 个变更／新增 Swift 文件通过 strict 检查；后续 JSON 精简文件复验通过 |
| 本地化 JSON、OpenCode 嵌入、`git diff --check` | 通过 |

GUI 完整 harness 在 JSON 序列化等价精简前通过；精简后的受影响 adapter／CLI／迁移与
GUI 接入合同另外复验，不将其写成再次执行了完整 GUI 原生检查。

Grok 专项通过 258 项检查，覆盖原生输入、来源隔离、去重、默认组、生命周期、配置所有权与
事务。原生产品图标 fixture 通过 63 项检查，包含英文／简体中文、浅色／深色及实际 27×27
渲染几何；图标使用官方主页声明的原始 PNG，来源与哈希见资源目录 `PROVENANCE.md`。

初次普通 Release 封包的 GUI 为 7,015,816 B，触发既有 7,000,000 B 门禁。符号分析定位到
新增 Grok 配置 `Codable` 类型与相关序列化生成代码，随后改用现有 Foundation JSON 路径。
完整模板字节、未知／编辑内容冲突策略和原有预算均保留，冻结模板迁移与专项重新验证。

普通 Release 封包通过 arm64 构建、输入边界、无 GUI 产品导出符号、ad-hoc 签名及 Sparkle
嵌入检查，签名后 GUI 为 6,996,912 B、helper 为 2,806,224 B，均在原预算内；
普通 Release 无 additional-host acceptance plist 标记，CLI 确认只有既有五个可见来源。

使用相同 SDK 与 `--additional-host-acceptance` 构建的显式验收包也通过上述门禁，签名后
GUI 为 6,996,912 B、helper 为 2,806,208 B，非可执行资源为 2,431,944 B（预算 3,100,000 B）。
本轮只保留统一产物 `dist/claudi0.app`，其 plist 明确标记
`ClaudioAdditionalHostAcceptance=true`；未额外保存普通 Release 的源码或 app 副本。
两个包均为 arm64 本地 ad-hoc 构建，未启动本轮验收包，未据此开放任何 Grok 普通 Release
binding。

一次与 LTO／迁移编译并行的 helper 完整重跑出现来源增量 p95 49.44 ms 超过 30 ms 门禁；
该次为 6153 项中 1 项失败。性能门禁保留原阈值，最终检查与编译负载分开执行。
最终来源增量 p95 为 8.00 ms，带来源回调 p95 为 13.00 ms，6153 项全部通过。

本轮临时宿主根、探针、下载副本、截图、故障夹具、测试日志及新增 Python bytecode 已清理；
未保留额外源码或 app 备份。验证收尾时 Git HEAD 保持实施基线，未暂存、提交、推送或发布；
后续本地提交沿用下列证据边界，不追认未完成的人工或发布门禁。

## 未完成的人工／发布门禁

- Claudio 原生横幅、人工听音、真实来源导航、开关操作、键盘／VoiceOver、Reduce Motion 与多屏。
- 两目录及关联 worktree 的目录通道资格；真实主／子会话组合。
- Developer ID 签名、公证、Gatekeeper、真实登录项与正式发布验收。
- `verify-settings-experience.sh` 要求 clean HEAD，本次未提交的任务变更使其停在前置条件；
  未为通过此门禁而提交或清理无关工作。

## 安全回退与避免过度测试

源码由 Git 审阅范围回退；宿主配置通过受管 disconnect 或既有一次性 `.claudio.bak` 恢复。
源码回退不代表宿主配置已恢复。外部修改造成冲突时先保持 OFF，不强删、不覆盖。
本轮不保留临时源码／构建备份、完整 payload、模型正文或凭据；临时探针和可重建截图在收尾清理。
迭代只跑受影响专项，完整 harness、Debug／Release、迁移、体积及输入边界作为最终门禁。

依据固定上游版本的 [hooks 合同](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-pager/docs/user-guide/10-hooks.md)、
[payload schema](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-hooks/src/event.rs)
与 [runner 身份注入](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-hooks/src/runner/command.rs)。
