# 跨宿主提问入口：P0 / P2 证据与缺口（2026-09-27）

状态：**Codex 开发观察 reader 已实现；隔离 CLI 已分别实测同步和异步提问工具的精确 `PreToolUse`，独立 App Server 的一次只读读取未接管原 CLI 问题。当前 Codex TUI 的异步问题可见，显式开启 Claudio 开发观察器后又经人工确认一次铃音和横幅；具体文案未看清。当前 TUI 受信任的临时提问与 `Bash` 对照 hook 均未收到本代理工具调用回调，原因尚未区分。P0 的明确输入请求及跨客户端门槛未通过，正式入口未选择。WorkBuddy 新提问入口缺少 Desktop 证据，未增加 matcher。**

本记录区分公开协议、本机安装、合成合同、真实会话增量读取和真实提问。它不把原型、文件中出现工具调用或尚未出现工具结果当作明确输入请求，也不据此声明任务暂停。正式行为范围见[研究稿](../cross-host-waiting-input-hooks-research-2026-09-27.md)与本次开发计划。

## 1. 本机版本与可复核来源

| 对象 | 2026-09-27 只读结果 | 能证明的范围 |
| --- | --- | --- |
| `codex --version` | `codex-cli 0.157.1` | 当前 CLI 命令版本；不证明提问 hook 覆盖 |
| `codex app-server --help` | 支持 stdio / Unix / WebSocket；可导出版本对应 schema | 可用命令合同；未连接已有会话 |
| WorkBuddy Desktop | `CFBundleShortVersionString=5.6.2`，`CFBundleVersion=5.6.2`；应用进程存在 | Desktop 版本与运行事实；不使用其内部 sandbox 版本代替 Desktop 版本 |
| Vibe Island | `CFBundleShortVersionString=1.0.51`，`CFBundleVersion=1.0.51` | 本机应用版本与下述二进制静态证据 |

入口探针没有建立正式 hook receipt；独立 App Server 进程只读新建隔离 CLI 和当前
根线程，没有恢复、代答或接管用户已有线程。后述当前客户端无声探针曾短暂修改
`~/.codex/hooks.json`，结束时已核对原始字节和权限并恢复；WorkBuddy 与 Vibe Island
配置未改写。

### App Server schema 摘要

在独立临时目录运行：

```bash
codex app-server generate-json-schema --experimental --out <temporary-schema-directory>
```

| 0.157.1 导出文件 | SHA-256 |
| --- | --- |
| `ClientRequest.json` | `0f8733c93b3609fa82337ae94f8a4971b93e3327b0b3e99dce2a86cf495d925b` |
| `ServerRequest.json` | `3d7bc481f84dc042984a74420e65c5a8d3c423f37a91b7d5df2365c903a12ac6` |
| `ToolRequestUserInputParams.json` | `fda15b62e7446105b59c8ed85c908abed2a47db70653e57c92c47a2f204fa77a` |
| `v2/ThreadReadParams.json` | `dfe040c6ac71d30795b8be3f3ff232e66f362a37f883b491e5d1ea367f470db4` |
| `v2/ThreadReadResponse.json` | `d685105cfc1430330376770fd05616814b30d2ecbc3e590780a90a66fdd36bc3` |
| `v2/ThreadResumeParams.json` | `cc5bb3b25f82073d24af5b6c09e4804ac307467f8400ba5f263fa86f9f0349e6` |
| `v2/ThreadStatusChangedNotification.json` | `26f3c60c1b73f7fa2d31c74429cdc36f8746c76c33e3d314b3fb61d3661f05f6` |

- `item/tool/requestUserInput` 是 server request；本机 schema 的必填参数包括 `isBlocking`、`itemId`、`questions`、`threadId`、`turnId`。协议字段存在不证明第三方只读 observer 能收到原客户端请求。
- 当前导出的 client methods 没有独立的 `observe`、`subscribe` 或 listener 方法；有 `thread/read`、`thread/resume`、`thread/unsubscribe`。`thread/resume` 的说明指出对运行中的线程会重新加入。没有通过 resume 实验影响用户会话来填补证据。
- 官方文档明确：`thread/read` 不订阅事件，也不把线程载入内存。因而单靠该方法不能建立新输入请求的实时来源。[官方 App Server 文档](https://learn.chatgpt.com/docs/app-server#read-a-stored-thread-without-resuming)
- `serverRequest/resolved` 也可能表示开始新轮次、轮次完成或中断时的清理，不能统一解释为用户已回答。[官方请求说明](https://learn.chatgpt.com/docs/app-server#toolrequestuserinput)
- 两份本机 response/notification schema 的 `ThreadActiveFlag` 枚举都含
  `waitingOnUserInput`。这是**已载入线程的状态字段合同**，自身没有请求身份；
  不能用字段存在推断独立观察者可收到当前客户端的状态或具体问题。

### 当前客户端的共享 App Server 只读入口复核

在当前根客户端会话中尝试通过 `codex app-server proxy` 建立独立连接，准备只发送
`initialize`、`thread/read(includeTurns: false)` 和 `thread/loaded/list`。代理在握手前
结束，未取得任何线程响应；随后 `codex app-server daemon version` 也报告本机控制
socket 不存在。本次没有发送 `thread/read` 或订阅请求，没有改变原客户端的请求归属。
这一结果只说明**当前运行环境的共享代理入口不可用**，不能证明 App Server 协议对
其他客户端也不可用，或推断提问事件是否存在。官方文档仍只把 `thread/read` 定义为
不订阅事件的存量读取；当前根会话的可靠明确输入请求继续保持未验证。

随后在另一独立 stdio App Server 进程中，仅初始化并对当前根线程执行一次
`thread/read(includeTurns: false)`：线程身份相符，但 runtime status 为
`notLoaded`，没有 `activeFlags`。这与隔离 CLI 的只读探针一致，说明该独立进程
没有当前客户端的实时运行状态；没有调用 `thread/resume`、代答或接管请求。

### 当前客户端精确 hook 的信任与执行探针

另在 0700 私有临时目录准备无声诊断处理器，只对当前会话的精确
`request_user_input` / `request_user_input_async` `PreToolUse` 记录脱敏身份；
合成输入验证处理器正常退出、无 stdout/stderr，并忽略其他会话。核对原始配置摘要后，
以单个锚定 matcher 临时写入用户 `~/.codex/hooks.json`。按 Codex 的 hook 信任合同，
通知用户在当前 TUI `/hooks` 核对并信任该新定义。测试窗口内没有取得信任状态回复，
因此**没有发起真实提问**；临时处理器记录数为 0，不能据此推断当前客户端是否支持
提问 `PreToolUse`。结束时按候选配置摘要 CAS 恢复原始字节及模式，最终 SHA-256 为
`5c4b19ca1ce6e929aa03557965b5dc4115ba835f72f9d695c1a2b55b647d952d`，
`PreToolUse` 槽位不存在；私有临时目录及配置副本已精确删除。

用户随后要求继续，故重新准备同样的精确无声探针，在当前用户配置中临时安装，
并直接发起一次当前根客户端的 `request_user_input_async` 受控问题；工具返回
`accepted: true`。处理器合成输入预检有 1 条记录，真实调用窗口却是 **0 条**。
本次没有在当前 TUI 完成新定义的 `/hooks` 信任审核，也没有证明运行中的客户端已
重新载入配置，因此零记录**不能判为工具缺少 `PreToolUse` 支持**。发问后立即按
候选字节和文件代次核对并恢复原始 hooks 字节与模式；最终 SHA-256 仍为
`5c4b19ca1ce6e929aa03557965b5dc4115ba835f72f9d695c1a2b55b647d952d`。
本机 `codex features list` 报告 `hooks` 为 `true`，只能排除 CLI 的当前功能开关
整体关闭，不能证明运行中的根会话已信任或载入这个新增定义。
本次没有 ClaudioGUI 进程、铃音或横幅预期；用户随后确认**在当前 Codex TUI
看到了测试问题**。因此同次测试有真实问题界面与 0 条临时回调两项独立事实；
后者只作为**未信任临时 hook 的执行结果**记录，正式入口仍未验证。

其后完成一次[受信任临时 hook 与 `Bash` 对照探针](codex-current-client-trusted-hook-probe-2026-09-27.md)：用户在当前 TUI 的 `/hooks` 确认精确提问组为 `Trusted`，两次异步问题在 TUI 可见并得到答复，但提问处理器仍为 **0 条**；独立 `^Bash$` 组也经用户确认为 `Trusted`，本代理的 `exec_command` 执行 `/usr/bin/true` 后对照处理器仍为 **0 条**。两脚本合成预检通过，测试前配置和脚本摘要一致，收尾时恢复原始配置并删除临时目录。这表明本代理工具调用路径在该运行会话中没有抵达两个临时处理器；尚不能区分运行时加载边界和工具桥接路径，也不能用提问零记录否定 Codex 的一般提问 hook 覆盖。

## 2. Codex 入口对照与验收状态

| 候选入口 | 已确认 | 本轮未确认 | 决定 |
| --- | --- | --- | --- |
| 同步 `request_user_input` 的 `PreToolUse` | 独立 CLI 0.157.1 的锚定 matcher 两次命中；Plan mode 原生 A/B 问题显示并回答，请求、会话及目录字段齐全 | 当前根客户端的同步 hook、Claudio 安装回执及听音未验证 | 不新增正式 binding |
| 异步 `request_user_input_async` 的 `PreToolUse` | 独立 CLI 0.157.1 的锚定 matcher 一次命中；根客户端受控调用返回 `accepted: true`，用户确认当前 TUI 显示测试问题 | 根客户端受信任精确 hook 的本代理调用仍为 0 回调；`Bash` 对照同为 0，无法归因于提问工具本身；没有可靠明确待答或当前回执 | 不新增正式 binding |
| App Server | 已核对官方文档及本机版本化 schema；独立进程的一次 `thread/read` 读取了待答的隔离 CLI 线程，原 CLI 仍完成回答 | 没有收到新请求事件；只读订阅及根客户端归属未验证 | 不接入用户已有线程 |
| 受限 rollout reader | 合成边界通过；根线程一次真实异步 `function_call` 被接受，具备请求身份；独立 CLI 的同步和异步调用身份可与 hook 关联 | 根客户端的同步 reader、可靠明确请求事件、取消/代答关联与问题到提示音延迟未验证 | 仅显式开发原型，输出调用意图 |

官方通用工具覆盖有特殊路径例外，不能据此推断两个提问工具必然产生 hook。[官方 Hooks 文档](https://learn.chatgpt.com/docs/hooks#tool-coverage)

### 隔离 CLI 的真实 `PreToolUse`

本轮新增[受控探针记录](codex-question-hook-probe-2026-09-27.md)：三个新建 CLI 会话使用
独立 `CODEX_HOME`、空目录、只读 sandbox 和临时脱敏 hook。精确 matcher 两次收到
`request_user_input`、一次收到 `request_user_input_async`；三个 `tool_use_id` 均与
各自隔离 rollout 的 `function_call.call_id` 关联，`session_id`、`turn_id`、`cwd`
均为非空字符串。Default mode 的同步工具在 hook 后返回不可用；Plan mode 的同步
问题真实显示并回答；Default mode 的异步工具返回 `accepted: true`。临时配置与会话
已删除，未安装 Claudio 播放或回执。此证据只覆盖该 CLI 表面，不能自动外推至此前
根线程的客户端实例，也没有产生可靠明确待答信号。

### App Server 的一次只读归属测试

[受控探针记录](codex-appserver-read-probe-2026-09-27.md)使用另一个新建隔离 CLI
会话：原 CLI 的同步 A/B 问题界面待答时，独立 App Server 仅初始化并调用一次
`thread/read(includeTurns: false)`。响应的 thread ID 对应，独立进程报告的 status
为 `notLoaded`；
没有输入请求通知。原 CLI 随后仍能由操作者回答并继续，证明**这一次读取**没有接管
原问题。它不证明能只读订阅新请求，也未在当前根客户端执行。官方接口将
`thread/read` 定义为不订阅、不载入内存的存量读取。
[官方 App Server 文档](https://learn.chatgpt.com/docs/app-server#read-a-stored-thread-without-resuming)

### 当前客户端的异步可见性复测

[受控记录](codex-current-client-async-visibility-probe-2026-09-27.md)在当前根客户端
两次调用 `request_user_input_async`，分别从精确会话文件的新 EOF 观察约 70 秒和
90 秒。两次都有精确 `function_call` 和同请求结果，工具均返回 `accepted: true`；
用户随后澄清 Codex TUI 看到了问题，之前“没看见”指 Claudio 没有反应。
至少第二轮的问题界面可见；第一轮未逐轮单独确认。记录类型中没有提问专属事件，
不能把 accepted 或 rollout 调用升级为 Claudio 可消费的明确待答。当前用户 hook
配置无 `PreToolUse` 槽位，两轮均未运行 Claudio 提问观察器或 hook；无声无提示
符合测试设置。此前草稿将反馈误判为 Codex 问题未显示，现已更正。

随后按用户就位流程显式运行隔离 DEBUG app。[受控验收记录](codex-development-notice-probe-2026-09-27.md)
显示真实异步调用进入开发观察，用户确认听到短铃、看到 Claudio 横幅；横幅具体
文案未看清。本次没有安装 Codex hook 或产生当前安装回执，也没有把 TUI 的人工
可见性当作可机器消费的可靠明确待答事件。

### 真实增量读取与定位失败

使用当前执行环境的 `CODEX_THREAD_ID` 定位一个明确的当天文件，从 EOF 开始；没有读取旧问题、旧答案或原始历史记录，也没有保存新原始记录。

1. 10 秒实际 reader 检查读取子线程新增的 **10,934 bytes**，执行 **49 次 poll**，无 reader failure，没有提问意图输出。poll 耗时 p50 **0.129 ms**、p95 **0.925 ms**、最大 **3.207 ms**。这些数值仅为该子线程的文件检查与解析耗时，不是提问识别、窗口出现或声音延迟。
2. 随后准备 30 秒 metadata-only 观察并由根线程发起一次确有用途的异步提问；根线程工具返回 `accepted: true`。观察读取 **15,908 bytes / 7 个 response_item**，没有匹配的提问调用。
3. 核对环境身份后发现：观察使用的 `CODEX_THREAD_ID` 属于执行子线程，根线程对应此环境的 `CODEX_SESSION_ID`。因此第 2 项是**选错被测线程**，零捕获不能证明 async 工具没有事件、没有身份或没有回调。没有回读历史或为了实验重复提问。

随后由根线程确认准确身份和显式文件，再开始一次 60 秒 EOF 观察。工具用于询问用户实际
听音、提示和焦点结果，用户在原客户端答复，未接管或代答。脱敏结果如下：

- 根线程 SHA256 前缀 `88478efa63a520c3`；请求身份 SHA256 前缀 `b6322b7710abb0fb`。
- 真实 shape 为 `response_item / function_call`，`name=request_user_input_async`，
  namespace 为缺失或 null（采样未进一步区分），`call_id` 通过身份合同。
- 记录时间 `2026-09-27T03:38:42.998Z`，探针观察时间 `03:38:43.011Z`，差约
  **13.094 ms**。这是写入时间到独立探针的延迟，不是 GUI 或声音延迟。
- 1115 次 poll、19,801 bytes、21 行，1 个候选和 1 个接受的调用意图，无失败；
  poll p50 **0.0723 ms**、p95 **0.1117 ms**、最大 **5.926 ms**。
- 用户前两次反馈声音与提示均未出现；第二次虽记录了模型接受和播放器启动，仍不能
  推断当时实际提醒成功。用户要求下次测试提前明确提醒。其回复准备好后，独立实例
  在 0.8 测试音量的一次真实异步问题中获得**人工听到铃音、看到提示**的反馈；
  当时没有输入。随后独立合成观察触发原生提示时，用户确认输入焦点保持。后者只
  验证提示窗口，不验证宿主问题界面的焦点行为。运行详情及后续验收顺序见
  [实现验收记录](cross-host-questions-2026-09-27.md)。

这确认了当前客户端一个真实异步调用的增量格式与有效请求身份，不确认同步工具，也不
把 function call 升级成可靠明确待答。不能从项目名、相近时间或子线程活动猜测根线程，
也不能以 `CODEX_THREAD_ID` 环境变量在所有进程中含义相同为前提。

| 真实场景 | 同步 | 异步 |
| --- | --- | --- |
| 原客户端发起工具 | 隔离 CLI Plan mode 显示问题并完成；根客户端同步未验证 | 根线程 API 多次 accepted；用户澄清当前 Codex TUI 的问题可见，至少确认第二轮；隔离 CLI 也得到 accepted |
| 精确 `PreToolUse` 与请求/会话/目录 | 隔离 CLI 真实命中并关联；根客户端及当前安装未验证 | 隔离 CLI 真实命中并关联；根客户端及当前安装未验证 |
| rollout 中新请求身份 | 隔离 CLI 的真实 `call_id` 与 hook 身份相符；根客户端同步未验证 | 根线程实际 `call_id` 通过合同，隔离 CLI 又与 hook 身份相符；未测真实重复回调 |
| 可靠明确输入请求，而非 function_call | 未验证 | 未验证；TUI 人工可见不等于可由 Claudio 读取的可靠请求事件 |
| 快速回答、取消、自动回答 | 未验证 | 未验证 |
| 原客户端保持原请求处理归属 | 隔离 CLI 的一次 App Server `thread/read` 后，原 CLI 仍完成回答；根客户端未验证 | 根线程只读文件观察中由原客户端接收用户回答；未做协议订阅、恢复或代答 |
| 问题至提示音延迟、人工听音 | 未验证 | 仅测得记录至探针延迟；根线程一次真实异步问题获人工听音和可见提示确认，未量到端到端延迟；隔离 hook 探针无播放 |

## 3. 开发原型的实现合同

代码：[观察值与选择性解析](../../gui/Sources/ClaudioGUICore/CodexQuestionObservation.swift)、[单文件 reader](../../gui/Sources/ClaudioGUICore/CodexRolloutObservationReader.swift)、[独立合同测试](../../gui/Tests/ClaudioGUICoreTests/CodexQuestionObservationSuite.swift)。

- `CodexQuestionObservation` 使用独立 `development_codex_rollout_v1` provenance 与 `runID`；身份只有 canonical UUID 会话、ASCII 请求 ID、精确工具枚举及时间。没有 installation ID、hook binding、目录、问题、选项或答案字段；也不提供 `Codable` 磁盘协议。
- 仅识别 `response_item / function_call` 的精确短名称 `request_user_input` 或 `request_user_input_async`，namespace 限 absent / null / `functions`。当前根线程一个真实异步样本命中此合同；同步仍只有合成证据。不猜测前缀、大小写或其他 namespace。
- 输出始终为 `callIntention`。`event_msg/request_user_input`、App Server 包、工具输出和未出现工具结果都不能绕过验证变成明确待答。GUI 通过独立进程内入口复用唯一提示模型，只做瞬时展示。
- Target 必须显式给出绝对文件路径和与 filename 后缀一致的 UUID；不枚举 sessions 目录，不读取历史 session metadata。打开时只读取 EOF 前一个换行边界 byte；启动时半条旧记录的后续部分丢弃。
- 使用只读、非阻塞、禁止跟随最终符号链接的文件描述符，并校验普通文件、当前用户所有权与读取权限。单次最多 64 KiB，单行最多 32 KiB，嵌套最多 24 层；未完成行最多保留 2 秒。
- 解析器只解码必要的 schema/identity 字符串。其他值逐字节检查语法并跳过，不构造问题/答案对象。重复键、非法 UTF-8、错误字段类型、畸形 JSON、超限与过期半行使整批失败并清空本代状态。
- 只接受启动后且不过度超前的 timestamp。同 run / session / request 去重；每次最多 32 个事件、每代最多 256 个请求身份。达到容量时终止该代，避免驱逐旧身份后重复发声。不同请求不使用 hook 的旧播放抑制状态。
- inode / device / 长度检查和最近新增 bytes 的内存摘要检查拒绝替换、可观察到的截断或改写；不在文件重置后从头回放。权限失效、格式失效与读取错误同样终止该代。关闭必须丢弃 reader；恢复创建新 run 和新 EOF 水位。
- 只有 Debug 构建且同时指定 `CLAUDIO_DEV_CODEX_QUESTION_OBSERVER=1`、`CLAUDIO_DEV_CODEX_ROLLOUT_PATH`、`CLAUDIO_DEV_CODEX_SESSION_ID` 才能从环境创建 Target。生产接入不由此自动开启。GUI 生命周期的关闭、退出、锁屏、睡眠需统一使本代观察及在途投递失效。
- 观察无可信目录，声音使用默认组的 `notification` 配置；不生成 hook receipt、不改变当前激活、不写活动计数。未建立跨源同一请求身份前，不为同一问题启用两个主声音入口。

### 自动化与手工证据

| 检查 | 结果 |
| --- | --- |
| 两个新 core 文件的 Swift 6 独立 typecheck | 通过 |
| 独立 reader 合同 suite | **81 checks，0 failures**；临时独立模块 runner，注册入口为 `runCodexQuestionObservationSuites()` |
| 合同覆盖 | EOF 历史、同步/异步精确名称、重复请求、半行与超时、代次恢复、过旧/未来时间、重复键/转义键、UTF-8、错误身份与类型、超限/积压/容量、截断/替换/同 inode 改写/权限/删除/链接/目录 |
| `swift-format` 按仓库配置格式化新增 Swift 文件 | 已运行 |
| 本文件对应的真实子线程增量 reader | 已运行；没有提问样本 |
| 根线程真实异步提问 | 一个实际样本通过 reader；用户在原客户端回答，仍只表示调用意图 |
| 声音、原生 UI、锁屏与睡眠恢复 | 真实异步问题有人工听音与可见提示；合成触发的原生窗口有人工非抢焦点证据；隐私恢复仍未验证 |

完整 helper / GUI harness、CLI 合同、GUI 构建和本次其他改动的门禁统一记录在主交付验收记录；本表只报告本 reader 的独立结果。

## 4. Vibe Island：hook 与会话观察分别取证

本机 `/Applications/Vibe Island.app/Contents/MacOS/vibe-island`，版本 **1.0.51**，SHA-256：

```text
1620bd88a97ede93867f1a79a00ff12e59eb66ae22e69933e399798af154debf
```

对该文件做只读字符串/符号检查，看到独立的 `CodexSessionWatcher`、`CodexRolloutFileEventMonitor`、`CodexSessionIndexStore`、`CodexThreadSummaryMonitor`、`requestUserInputPromptTracker`，以及 `vibe-island-codex-hook.py` 和 `item/tool/requestUserInput` 标识。它支持“应用包含 hook 与会话观察两组实现”的静态判断；没有运行其提醒流程，也没有获得其对应源码 commit，不能由符号推出具体请求判断或去重算法已验证。

公开 **Open Island** 对照另行固定到 `Octane0411/open-vibe-island` commit **`b50f87aa7d58af1478837d48909eb68baa37f9b9`**，提交日期 **2026-09-15**。它是可读的另一份实现，不冒充本机 Vibe Island 1.0.51 的对应源码：

- `CodexHookInstaller` 的默认安装只有 SessionStart、UserPromptSubmit、PermissionRequest、Stop，说明复制默认 hook 本身不等于复制提问观察能力。[固定源码](https://github.com/Octane0411/open-vibe-island/blob/b50f87aa7d58af1478837d48909eb68baa37f9b9/Sources/OpenIslandCore/CodexHookInstaller.swift#L80)
- `CodexSessionTracking.swift` 独立处理 rollout，包含 watcher、偏移和首次历史读取。提问判断把 snapshot 改为 `waitingForAnswer`，reducer 随后发出 `activityUpdated`；它没有发出 `questionAsked`，因此这条 rollout 路径的提问状态本身不进入通知声音白名单。[状态更新](https://github.com/Octane0411/open-vibe-island/blob/b50f87aa7d58af1478837d48909eb68baa37f9b9/Sources/OpenIslandCore/CodexSessionTracking.swift#L1182)、[事件映射](https://github.com/Octane0411/open-vibe-island/blob/b50f87aa7d58af1478837d48909eb68baa37f9b9/Sources/OpenIslandCore/CodexSessionTracking.swift#L835)、[通知白名单](https://github.com/Octane0411/open-vibe-island/blob/b50f87aa7d58af1478837d48909eb68baa37f9b9/Sources/OpenIslandApp/IslandSurface.swift#L23)
- 另一条 `CodexAppServerCoordinator` 路径把 `isWaitingOnUserInput` 映射为 `questionAsked`。这项源码映射自身没有提供 Claudio 要求的请求身份，也不证明可以只读订阅另一客户端的已有会话。[固定源码](https://github.com/Octane0411/open-vibe-island/blob/b50f87aa7d58af1478837d48909eb68baa37f9b9/Sources/OpenIslandApp/CodexAppServerCoordinator.swift#L140)
- Claudio 采纳来源适配、身份关联与重复抑制的设计方向；没有采用历史 bootstrap 或“弹卡时才响”的声音门槛，也没有把上述静态判断作为可靠明确输入请求证据。

因此 Vibe Island 的 hook 安装效果与会话观察效果必须分别验证，不能用其产品说明替代当前 Codex 客户端的实测。

## 5. WorkBuddy Desktop P2 缺口

本轮直接核对 Desktop 5.6.2 的 Info.plist 与运行进程，没有得到 Desktop 提问工具名、精确 `PreToolUse` 回调、稳定请求 ID 或提问界面证据。新提问 matcher 保持未实现；CodeBuddy CLI / SDK 的 AskUserQuestion 文档不代替这些事实。

后续只读查看 Desktop 时，当前窗口存在正在编辑的输入区。为保留用户并行工作，没有切换会话或发送测试提示，也没有修改 WorkBuddy hook 配置；因此这一轮仍没有新的真实 Desktop 回调证据。

既有 [`Notification` 验收记录](workbuddy-notification-2026-09-25.md)和[工作区目录记录](workspace-sound-rules-2026-09-24.md)只覆盖各自已列明的 subtype / 场景。`permission_prompt`、`idle_prompt` 或 Security Center 的界面不扩展成新的提问能力，也不成为本次新增提问类型的当前回执或听音证据。

下一轮须在同一个明确 Desktop 版本、临时可恢复探针和可控问题下，关联工具名、请求/会话、真实 UI、当前安装及人工听音；取得这些事实后才可选定版本化精确 matcher。
