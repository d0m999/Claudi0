# Vibe Island 对 OpenCode、Kimi Code、Grok Build 的集成调研

调研日期：2026-10-04。本文延续 [Claudio 三宿主 hook 调研](spike-additional-host-hooks-2026-10-04.md)，结合公开一手资料、本机 Vibe Island 1.0.51 安装包和已存在的托管文件。官网声明、可读插件、二进制字符串和真实运行是不同证据等级；本次没有运行宿主或取得真实回调。

## 公开资料能确认什么

官方主页将这三个宿主列入自动配置范围，但宿主专页承诺的能力不同，不能把统一宣传中的审批、答题能力平移到每个工具。[产品主页](https://vibeisland.app/)

官方仓库明确定位为问题反馈与讨论社区。当前可见文件没有应用或插件实现；此次在官方账号、官网和相关 issue 中未找到可直接审阅的官方插件源码仓库。以下机制由官方说明支持，不能称为已复核实现算法。[官方社区仓库](https://github.com/vibeislandapp/vibe-island)、[官方账号公开仓库](https://api.github.com/users/vibeislandapp/repos?per_page=100)

| 宿主 | 厂商公开的接入机制 | 能力边界 |
| --- | --- | --- |
| OpenCode | HTTP SSE 事件流监控；REST API 执行审批与问题答复；自动发现端口并重连 | 明确公开双向交互，而非只有结束通知。[官方专页](https://vibeisland.app/opencode/) |
| Kimi Code | 首次运行自动配置；实时会话、工具状态及完成通知 | 专页没有披露配置路径、hook 事件表、Wire/SSE 使用情况或双向审批协议。[官方专页](https://vibeisland.app/kimi/) |
| Grok Build | 自动增加自有集成，保留既有配置；独立会话身份和完成预览 | 权限、问题及计划决定只提示并跳回 Grok；最终决定留在 Grok 原生界面。[官方专页](https://vibeisland.app/grok-build/) |

## OpenCode：事件观察、请求回复、会话归组

**公开接入方式。** SSE 用于消息、工具和会话状态变化；REST 用于权限批准／拒绝及回答问题。官网还说明自动重连和多层端口发现，但没有列出完整探测顺序、认证处理、请求去重键或回调优先级。[官方专页](https://vibeisland.app/opencode/)

**子任务完成抑制有维护者解释。** 在 issue #30 中，维护者确认 v1.0.34 将 OpenCode subagent 识别为父会话下的子会话，其 Final Answer 不再触发主 agent 完成提醒，父 agent 下发的任务也不应显示成顶层用户输入。这证明产品以父子身份控制提醒，而不是仅看某条消息是否结束；具体判断代码未公开。[维护者答复](https://github.com/vibeislandapp/vibe-island/issues/30#issuecomment-4803327485)

**跨来源重复身份只得到有限确认。** 维护者称 v1.0.43 统一了跨来源的子会话及重复会话身份处理，可能覆盖 #155 报告，但该报告未被官方复现。不能把 issue 已关闭写成“已证明所有重复接入都修好”。[维护者结案说明](https://github.com/vibeislandapp/vibe-island/issues/155#issuecomment-5103173880)

同一 issue 正文声称 OpenCode 通过 Claude Code 基础设施触发 Claude hooks；维护者明确指出 OpenCode 是独立 agent，并质疑来源标注及该根因。本文不采用报告者提出的原因，也不采用按 `tty + cwd` 合并会话的建议作为官方算法。[维护者澄清](https://github.com/vibeislandapp/vibe-island/issues/155#issuecomment-4836747605)

**插件与版本要分别处理。** 官方更新记录确认 v1.0.49 增加 OpenCode 1／2 共存，并修正用 V1 API 生成 V2 插件导致加载失败的问题；v1.0.51 继续补全 OpenCode 2 回答、问题及 viewer 跳转。这是官方存在托管插件和版本分支的证据，尚不足以确定生成器细节。[官方更新记录](https://vibeisland.app/changelog/)

## Kimi Code：公开行为较清楚，底层合同仍需本机证据

**产品承诺。** 官网描述 processing、工具执行、等待输入和 idle 等状态，展示简写工具名，并在完成时发送通知／可选声音；首次运行自动配置且通信在本机进行。这些描述没有给出把原生事件映射到完成、失败或子任务的规则。[官方专页](https://vibeisland.app/kimi/)

**名称不能代替版本识别。** 官方更新记录在 v1.0.27 和 v1.0.39 都出现 Kimi Code 支持说明，主页又同时列出 Kimi 与 Kimi Code；公开文字不足以证明它们分别对应上轮调研的旧 Python CLI 与新 TypeScript CLI，更不能据此认定安装路径。[官方更新记录](https://vibeisland.app/changelog/)、[产品主页](https://vibeisland.app/)

公开社区 #51 是要求官方支持 Kimi hooks 的历史请求，只有提问者回复“已加入”；没有维护者解释事件映射或生成配置。因此它只提供历史线索，不作为当前实现合同。[Kimi hooks 请求](https://github.com/vibeislandapp/vibe-island/issues/51)

**仍未公开确认。** 新旧 CLI 探测规则、配置写入方式、主／子 agent 身份、错误与取消分类、重复 Stop 抑制、问题请求 ID 及 answered/canceled 清理，均不能由该专页证明。[Kimi 专页](https://vibeisland.app/kimi/)、[官方文档目录](https://vibeisland.app/docs/)

## Grok Build：观察提醒与执行决定分开

**权限和问题处理。** 官网明确描述：观察权限、问题和计划决定，提示对应会话，并跳回原生界面。它没有承诺替 Grok 批准或回答；用户在 Grok 中完成决定。[官方专页](https://vibeisland.app/grok-build/)

**身份及安装边界。** 官网声称各会话保留自己的项目与 session identity，增加自有托管集成并保留其余 Grok 设置。这支持按宿主与会话归属呈现的产品合同；配置文件位置、安装标记和实际合并算法仍未公开。[官方专页](https://vibeisland.app/grok-build/)

**兼容范围。** v1.0.41 宣布 Grok Build 的状态、问题及完成提醒；v1.0.49 允许注册额外 Grok 配置目录。公开说明未解释如何处理 Grok 对 Claude hooks 的兼容加载，也未给出避免来源误标及重复执行的算法。[官方更新记录](https://vibeisland.app/changelog/)

## 本机证据：托管文件与 1.0.51 安装包

本节只读检查应用元数据、静态字符串、Vibe 自有插件和配置中的 Vibe hook 条目，没有读取会话内容、日志或凭证。配置已存在不代表由当前版本生成、当前宿主已加载或真实回调有效。

| 证据 | 范围与固定指纹 |
| --- | --- |
| B1 应用 | `/Applications/Vibe Island.app/Contents/MacOS/vibe-island`；Info.plist 版本／build 均为 `1.0.51`，bundle ID 为 `app.vibeisland.macos`；SHA-256 `6e791136c591bde9a2c15b39c6efea73ca5450e8aa6f86060abd53a5ad1441f0` |
| B2 桥接程序 | 同一 bundle 的 `Contents/Helpers/vibe-island-bridge`；SHA-256 `b22d9400901817198fb525b3da44e5417f8ba53aa20a3da7cc430778358aca01` |
| P1 已安装 OpenCode 插件 | `~/.config/opencode/plugins/vibe-island.js`，含 Vibe 托管标记，27,575 字节；SHA-256 `bbb306a42cb16bb15a05e592e539d305143ae0b46238000c938ac49fcb3e0325` |
| C1／C2 Kimi 配置 | `~/.kimi/config.toml`、`~/.kimi-code/config.toml`；只解析并摘录 command 属于 Vibe 的 hook 事件、来源及 timeout，未复制完整配置 |
| W1 启动包装脚本 | `~/.vibe-island/bin/vibe-island-bridge`，666 字节；SHA-256 `1f91af442d991c2e7100ccf6f67a182f23f7cbb1c3d0e61bc08395936d311719`；依次定位应用内 B2 并 `exec`，找不到则退出 0 |

### OpenCode：当前插件传原始事件，原生层负责后续解释

P1 的 `envelope`、`dispatchEvent` 和导出入口可直接阅读。它接收插件事件，携带 source、session、cwd、终端身份和原始事件，经本机 Unix socket 传给 Vibe；缺失会话资料时以 REST 查询补充，包括父会话资料。它保留 `session.idle`／`session.error` 的原生类型，没有在该插件中直接转换为 `Stop`。这些是静态代码事实，原生层最终如何决定完成仍需另外验证。

P1 的 `startGlobalEventBridge` 还提供 `/global/event` SSE 分支：当前 `auto` 配置在 desktop、存在服务器认证或使用非默认端口时启动，失败后延迟重连。它并非对所有 CLI 实例始终再开一条 SSE；B1 另可见 `OpenCodeV1Source`、`OpenCodeV2Source`、HTTP client 和 interaction adapter 类型，支持原生观察通道的结构判断，不能由类型名推断各分支优先级。

两个可借鉴的独立合同：

- **事件去重**：P1 优先采用 event ID，缺失时组合事件／会话／消息／part／状态。这个 fallback 没有显式轮次字段，不能据此宣布跨轮同类事件一定不会误去重。
- **待答请求生命周期**：P1 的 `awaitLedger` 按会话与请求身份跟踪占用及结算状态；原界面的 replied／rejected 事件释放等待；岛内回答经 REST 交付后记录结果，防止回声撤销已接收的答复。Claudio 即使只做提醒，也可采用请求身份和 resolved／canceled 清理。

B1 还包含另一套直接把 idle／error 转成 Stop／StopFailure、用短时间窗抑制重复的插件模板。**该模板不等于 P1 当前已安装文件**；不能拿包内旧片段证明当前路径的终态算法，更不能把时间窗去重直接作为 Claudio 的成功／失败判定。

### Kimi：新旧配置分开安装，共用桥接程序

本机 C1／C2 的 Vibe 条目如下；两组都调用 W1，用显式 source 区分宿主。

| 配置 | command 来源参数 | 已写入事件 |
| --- | --- | --- |
| `~/.kimi/config.toml` | `--source kimi` | SessionStart、SessionEnd、UserPromptSubmit、PreToolUse、PostToolUse、Stop、Notification，共 7 项；Notification timeout 为 600 秒，其余 30 秒 |
| `~/.kimi-code/config.toml` | `--source kimicode` | SessionStart、SessionEnd、UserPromptSubmit、PermissionRequest、PermissionResult、PreToolUse、PostToolUse、PostToolUseFailure、Stop、StopFailure、Interrupt、SubagentStart、SubagentStop、Notification，共 14 项；均为 30 秒 |

这补足了公开页面没有给出的实际路径与来源区分。B1 可见独立 Kimi／Kimi Code 托管块标记、`KimiCodeCLIIntegration`、`kimiWire`／`kimiCodeWire`；B2 可见 Wire 文件路径及助手文本提取相关字符串。它们提示桥接中还有内容补全分支，**不足以证明 Kimi 存在持续 Wire 观察器或所有状态由 Wire 驱动**。

C2 没有配置 `TurnStarted`。Claudio 应继续按自身“用户发起”语义评估 `TurnStarted` + `^user$`，不能因为 Vibe 使用 `UserPromptSubmit` 就放弃 origin／turn 身份。上轮查到的主／子 Stop 身份不足、Stop 可继续执行、明确待答时点等问题，也不能由这 14 条安装记录证明已经解决。[Kimi 原生事件定义](https://github.com/MoonshotAI/kimi-code/blob/f67e6398fb3210ad8ace970e2dfd5bcc984ed61f/docs/en/customization/hooks.md)

### Grok：独立安装器、事件翻译及权限观察线索

B1 包含 `GrokHookInstaller`、`.grok/hooks/vibe-island.json`、`GrokEventTranslator`、`GrokSessionReader` 和 recap monitor 类型；B2 包含 `GrokPermissionMonitor`，以及 malformed payload 丢弃、permission requested／resolved 对账和延迟转发相关字符串。结合官方观察与跳转说明，可判断其设计超出通用 Stop hook；**不能从这些字符串还原完整事件绑定、调用关系或去重算法**。

本机默认 `~/.grok/hooks/vibe-island.json` 不存在，本次未扫描额外配置目录，故没有 Grok 当前安装／加载证据。Grok 自动唤醒被误当用户发起、Claude 兼容 hook 引起来源混淆、终态重复等风险是否已处理，仍未核实。[官方能力边界](https://vibeisland.app/grok-build/)、[上一轮的原生源码调查](spike-additional-host-hooks-2026-10-04.md)

## 对 Claudio 的可借鉴结论

以下是结合公开与本机证据形成的工程判断，不是 Vibe Island 代码原样复用方案。

上轮把 OpenCode 主要列为薄插件接入，范围需要补充：**插件与官方 SSE／REST 应作为组合候选研究**。只做声音的第一阶段可以保留薄插件，但应传必要原生身份和状态，交给 Claudio adapter 解释；无需先实现岛内审批或采集完整助手回答。独立 SSE 观察器会新增连接、重连和身份协调责任，不能顺手混进现有 hook receipt。

| 可以借鉴的做法 | Claudio 仍需自己落实的合同 |
| --- | --- |
| OpenCode 用明确请求与会话状态支持交互，而不只靠一个完成信号。[机制](https://vibeisland.app/opencode/) | 声音适配只取必要事件字段；若增加独立观察通道，应保留其来源与代次，不冒充 hook 当前激活。[本地术语](../CONTEXT.md) |
| OpenCode 把子会话归入父会话，并抑制子任务冒充主任务完成。[维护者说明](https://github.com/vibeislandapp/vibe-island/issues/30#issuecomment-4803327485) | 在 adapter 边界记录稳定父子身份、每轮终态和请求身份；身份不完整时不能按目录／窗口猜合并。[本地术语](../CONTEXT.md) |
| Grok 只提示与跳转，保留原生决定界面。[官方边界](https://vibeisland.app/grok-build/) | 提问意图、明确待答、普通通知分别映射；不因产品写“支持 Grok”就标记全部五事件已实现。[上轮调查](spike-additional-host-hooks-2026-10-04.md) |
| OpenCode 插件按版本兼容，Grok 支持独立配置目录。[更新记录](https://vibeisland.app/changelog/) | 安装探测必须识别实际二进制／配置 scope，并保留第三方配置；配置存在不等于当前回调已激活。[本地术语](../CONTEXT.md) |
| 本机 P1 按请求身份处理重复／已答事件，C1／C2 用独立 source 区分两代 Kimi。 | adapter 内持有必要的会话、轮次、父子关系和待答请求状态；输出沿用五个 Claudio Event，旧请求及旧代次不能重新提醒。 |

## 证据缺口与完成边界

- 公共资料没有提供三宿主完整的原生事件到产品事件映射，也没有给出错误、取消、重新开始、旧请求失效的全部条件。[官方文档目录](https://vibeisland.app/docs/)
- 厂商修复声明与维护者解释能说明设计意图和已处理的问题，但不能替代当前版本真实宿主、重连、重复信号及听音验证。[官方更新记录](https://vibeisland.app/changelog/)
- 本节没有引用 Open Island 或同名开源替代品来证明商业 Vibe Island 的内部实现；公开源码未找到与“应用包内可能有可读脚本”是两个不同事实。[官方社区定位](https://github.com/vibeislandapp/vibe-island)
- 本次仅新增调研文档；没有改 Claudio 产品代码、用户配置或安装状态，没有提交、启动 Vibe Island、运行真实 hook 或人工听音。静态检查与配置存在均不构成真实宿主验收。
