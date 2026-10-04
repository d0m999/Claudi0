# OpenCode／Kimi Code 首版实现与自动验证（2026-10-04）

状态：实现已完成；真实宿主、原生提示交互和听音验收未完成。
用户本次确认“先完成实现与自动验证，保留真实验收未完成”。
`AdditionalHostReleasePolicy.verifiedBindings` 保持为空，普通 Release 不展示或启用新增
来源。Debug 与显式 `CLAUDIO_ADDITIONAL_HOST_ACCEPTANCE` 构建提供后续验收候选。

## 范围与可复核来源

- 原工作树的并行 GUI／会话导航修改保持原样。
- 实现在独立 worktree，分支 `codex/opencode-kimi-first`，
  基线 `f106df47b5931ab952107a2b1b3cf295fd1f9a06`。
- 本机只读版本检查：OpenCode `1.18.34`，Kimi Code `2.1.1`。
- OpenCode 合同核对固定于
  [aec0b9a6](https://github.com/anomalyco/opencode/tree/aec0b9a6d8898f68f923aaf08b7306d931fd9d76)，
  重点为 `packages/plugin/src/index.ts`、`packages/opencode/src/plugin/index.ts`、
  `packages/opencode/src/session/prompt.ts`、`session/processor.ts`、`session/session.ts`
  及会话／消息事件定义。
- Kimi Code 合同核对固定于
  [f67e6398](https://github.com/MoonshotAI/kimi-code/tree/f67e6398fb3210ad8ace970e2dfd5bcc984ed61f)，
  重点为 `packages/agent-core-v2/src/features/externalHooks/agent/agentExternalHooksService.ts`、
  `session/sessionExternalHooksService.ts` 与配置／payload 类型。
  官方入口文档：[OpenCode plugins](https://opencode.ai/docs/plugins/)、
  [Kimi Code](https://www.kimi.com/code/docs/)。源码与本机版本事实不替代真实回调证据。

Grok、旧 Python Kimi、OpenCode Desktop、自动答复／审批、精确会话导航未纳入本次。
两个来源沿用五个公共 `Event`，自动声音使用默认组；复用现有静音、事件开关和提醒生命周期。

## 已实现的候选事件

| 公共事件 | OpenCode 的 Claudio 桥接事件 | Kimi Code 原生事件 |
| --- | --- | --- |
| `task_start` | `UserTurnStarted`：已确认主会话、非合成用户输入且实际执行 | `TurnStarted`：限定 `origin_kind == user` |
| `stop` | `ResponseCompleted`：正常终态消息和对应 idle | 未实现，缺少主／子 agent 身份 |
| `stop_failure` | `ResponseFailed`：终态错误消息、对应会话错误与 idle；取消／可恢复错误不播放 | 未实现，缺少主／子 agent 身份 |
| `notification` | `PermissionRequested`、`QuestionAsked`：具有请求身份的授权／明确输入请求 | `PermissionRequest`；精确 `PreToolUse(AskUserQuestion)` 仅表示“即将提问” |
| `subagent_stop` | `SubagentCompleted`：已确认子会话成功终态和 idle | `SubagentStop`：仅成功，不声称能定位具体子任务 |

OpenCode 上游 `session.idle` 与以上桥接事件分开标识；单独的 idle、task 工具返回、历史
消息、插件初始化错误、缺少身份或终态证据均不能生成完成音。插件使用当前 `server`
接口，仅投影必要身份／状态字段，队列、会话、请求、子进程和保留时间均有上限，不等待音频。

GUI、CLI 和诊断消费同一适配器快照，配置、能力及当前安装回执分别呈现。OpenCode 有
6 个实现绑定、覆盖 5 类公共事件；Kimi Code 有 4 个实现绑定、覆盖 3 类公共事件，另外
2 个声明绑定保持未实现。真实证据按绑定取得，来源级 ready 不能借给未观察的绑定。

## 配置、隔离与隐私

- OpenCode 安装自有 `plugins/claudio.js`，优先 `OPENCODE_CONFIG_DIR`，否则使用有效
  XDG 配置根；现有 `opencode.json/jsonc` 不改写。有效配置根中显式重复注册、另一份
  Claudio 插件、被修改的自有文件和不安全文件类型均拒绝写入。
- Kimi Code 使用 `KIMI_CODE_HOME`，默认 `~/.kimi-code`。自有 `[[hooks]]` 块以原字节
  增删，绝对 helper 路径、`timeout = 2`；第三方 hooks、未知字段、注释、CRLF、旧
  `~/.kimi` 保留。保守 TOML 解析器无法证明的结构保持原样并报告错误，包括日期值和
  嵌套数组表；这不是完整 TOML 重序列化器。
- 复用操作锁、文件锁、一次备份、锚定文件操作和 CAS；并发编辑不覆盖。断开先撤销
  当前代次，即使自有配置被用户修改、不能删除，也不能保留有效旧回调。
- 版本、有效配置根摘要、Claudio／绑定版本进入激活作用域；修复更换安装代次，旧
  UUID、旧配置根与同 UUID 的过期作用域不能激活或发布当前回执。
- 校验事件、类型、身份、重复字段、大小和安装代次先于副作用。提问按请求身份去重；
  Kimi 子任务没有稳定身份，不以显示名误合并两个成功任务。
- 回执／活动／请求账本不保存正文、工具输入、回答、原始目录或原始会话身份。当前
  提醒可临时显示安全来源，沿用既有内存生命周期。hook 无条件退出 `0`、零 stdout/stderr。

配置检查限于所选有效配置根，未遍历项目目录的其他插件注册；运行时相同目录／安装代次
的重复插件有进程内保护。宿主热加载、项目配置合并和插件实际加载仍由真实验收确认。

## 自动证据

| 检查 | 本轮结果 | 证据边界 |
| --- | --- | --- |
| helper executable harness | **4,624 checks，0 failures** | 编译与隔离 fixture／回归合同 |
| OpenCode 插件状态 harness | **32 scenarios passed** | 公共 `server` 接口、合成上游事件；未连接真实宿主 |
| 新增来源 CLI 子进程合同 | **143 checks passed** | Debug／普通 Release 真实 helper 子进程、假宿主版本、隔离配置、静音音频 |
| 既有 hook CLI 合同 | **PASS** | 退出码、零输出、提问入口与 Debug-only root |
| 既有 legacy install CLI 合同 | **PASS** | 原安装入口、备份、权限及 Release 测试入口隔离 |
| GUI executable harness | **17,721 checks，17 failures** | 17 项失败与干净基线完全一致，均属于原生窗口焦点；没有新增失败 |
| 干净基线 GUI harness | **17,456 checks，17 failures** | 同一提交、同一 SDK，失败断言逐项相同 |
| 新增来源 GUI 专项 | **113 checks，0 failures** | 共享快照、能力、双语、活动覆盖与输出目录夹具 |
| GUI 来源／提问集成合同 | **2,784 checks，0 failures** | 最终开始／终态限定分别呈现；能力、配置与回执保持独立 |
| Release layout 专项 | **142 checks，0 failures** | 发布路径、插件所需构建参数与原有分发合同 |
| GUI Debug／Release build | **PASS** | 本机兼容 SDK；不代表两个 CPU 架构 |
| 本地 app 打包 | **PASS，arm64、ad-hoc** | 显式验收构建；体积与本地签名通过，不代表 Developer ID／公证／发布 |
| JS 嵌入一致性、catalog JSON、diff whitespace | **PASS** | 静态产物与本地化结构 |
| 统一 Settings 固定基线 gate | 未通过 clean HEAD 前置条件 | 验证时源码未提交，脚本在构建前退出；当时没有为检查而提交、暂存或清理工作 |

配置回归覆盖重复连接、修复、断开、并发修改、损坏 TOML、编辑过的插件、重复插件注册、
新旧 Kimi 共存、独立运行时 PATH、Vibe Island 原字节保留及各来源锁隔离。
事件回归覆盖正常响应、错误与 idle 顺序、取消、压缩恢复、synthetic／`noReply`、历史
消息、并发会话、后台子会话、未知父子身份、重复请求、队列／状态上限、过期安装及非法
payload；确认没有跨会话消费、误报或敏感正文留存。

源码复核另外覆盖会话 `summary` 的统计对象与消息 `summary` 的压缩标记；合法统计
对象不会丢弃会话身份，统计／diff 正文也不会进入队列或桥接 payload。
打包的 Release helper 改用 `-Osize` 后，真实 CLI 子进程的 143 项合同再次通过。
同机 strip 后的测量：基线 `-O` 为 3,203,976 B，候选 `-O` 为 3,402,664 B，候选
`-Osize` 为 2,956,384 B；原有 helper 3,250,000 B 门槛未改。最终签名产物另行测量。

本机 Swift `6.4` 的默认 macOS `27.0` SDK 缺少可用的 `SwiftUIMacros.StateMacro` 插件，
默认 GUI build 失败。使用已安装 macOS `26.5` SDK 与 native build system 运行本轮
GUI 检查，并设置同一 `SDKROOT` 供 harness 内部编译探针使用：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  swift run --package-path gui --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk claudio-gui-tests
```

干净基线的独立 `--event-attention` 检查在此设置下通过 **977 checks，0 failures**，
用于核对原有提醒展示；它不替代候选完整 harness 或人工布局／焦点／VoiceOver 验收。

全量 GUI 的 17 项原生 `PanelSettingsHandbackSuite` 焦点失败与基线一一对应。本轮没有
修改该窗口所有者。全量运行后拆分开始／终态的限定 token 和双语说明，再次通过 helper
全量、CLI 合同及 GUI 来源／提问专项；不把专项结果写成原生焦点或全量 GUI 全绿。
47 个变更 Swift 文件的严格格式诊断与固定基线比较：基线 3 项、候选 3 项，新增 0 项。

## 交付及仍未完成的验收

插件以 `integrations/opencode/claudio.js` 为唯一源，生成嵌入 Swift 模板；打包复制同一源
到 app `Resources/integrations/opencode/claudio.js`。以下命令生成后续验收候选，不会
自行启动 app 或连接宿主：

```bash
CLAUDIO_BUILD_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  bash scripts/dev-bundle.sh --additional-host-acceptance
```

产物位于实现 worktree 的 `dist/claudi0.app`，版本 `0.0.0-dev`，plist 显式标记
`ClaudioAdditionalHostAcceptance = true`。最终签名后 GUI 为 **5,870,784 B**、helper 为
**2,940,608 B**、LoginItem 为 **54,208 B**，均通过现有预算；非可执行资源为
**2,430,333 B**，正规文件总计 **11,295,933 B**。未调整任何体积预算。
插件资源与唯一源逐字节相同，helper 含相同嵌入模板；版本与 plist 一致，Release helper
不含 Debug home/root 覆写入口。`verify-dev-bundle-signature.sh` 通过，仅为本机 arm64
ad-hoc 签名证据；没有启动或安装该 app。

本次没有使用模型登录／额度，没有修改真实宿主配置或调用真实模型。真实主会话、授权、
提问、成功子任务、错误、取消、原生提示和人工听音逐项仍未验证；精确会话导航不在范围。
CI、Intel 架构、Developer ID 签名、公证、生产发布和正式验收均未完成。
实现与自动验证完成后，用户授权本地提交；未 push、创建 PR、合并或发布。
