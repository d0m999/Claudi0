# claudi0 hook 链路：调研核对与优化候选

> 2026-10-13 文档归档：下文保留当时的候选、授权与验证状态；其中“未提交／未推送”描述记录时点。
> 后续提交状态与暂停范围见 [2026-10-12 收束记录](hook-performance-roi-closeout-2026-10-12.md)。本次归档不重新验证历史结果或重启实验。

初稿日期：2026-10-09；核对日期：2026-10-10。
代码基线：`feb142b3fb87668ffc039a18cb07dba61d42490f`。
范围：宿主回调 → `claudi0 hook` → 播声、回执、活动与提示，以及宿主 hook 协议。

本文保留历史研究与只读核对记录；实现边界以 [Issue #218](https://github.com/d0m999/Claudi0/issues/218) 为准。
2026-10-10 随后开始第一阶段测量建设，见 [可复跑基线报告](hook-path-baseline-2026-10-10.md)。
未实施 async、跨调用版本缓存、回执热路径或 Git 算法优化；预算尚待用户确认。初稿数字不升级为当前 SLO。

## 1. 核对后的结论

- 版本探测、回执归档／剪枝和 Git 工作区解析是源码可见的同步工作，值得分别测量。
  现有证据不能把它们按耗时可靠排序，也不能承诺具体优化收益。
- 不应把所有宿主统一改为 `async: true` 加 `timeout: 5`。各宿主契约不同，尤其 Claude Code
  的普通异步 hook 不执行该 timeout；退出、取消、代次与当前激活均须单独验证。
- 保持现有事实 owner、安装代次和发布许可。性能改善不能让关闭来源、GUI 退出或旧回调重新
  获得播放／发布资格。新缓存、延迟归档或传输都只是候选方案。
- 暂不增加常驻 helper daemon。理由是现有域模型和缺少 Claudio 的端到端测量，不能用其他
  项目的 9 ms 数据宣布 Claudio 的 daemon 收益已经被证伪。

适用合同：[CONTEXT.md](../../CONTEXT.md)、[ADR 0005](../adr/0005-use-global-sound-defaults-with-sparse-surface-overrides.md)、
[ADR 0010](../adr/0010-use-local-activity-summary-for-recent-host-activity.md)、
[ADR 0012](../adr/0012-use-ephemeral-event-source-notices.md)、
[ADR 0024](../adr/0024-bridge-only-evidenced-additional-host-events.md)、
[ADR 0025](../adr/0025-automatically-maintain-explicit-host-intent.md)。
ADR 0012 的“GUI 退出后仍处理事件”旧条款已经由 ADR 0025 替代，不能据旧条款设计后台播放器。

## 2. 当前源码事实

| 检查对象 | 本轮只读核对结果 | 接缝／源码 |
| --- | --- | --- |
| 版本 scope | 生产环境的 `HookQuestionScopeSnapshot` 每次调用内惰性解析并缓存；Claude Code／Codex 的版本发现执行 `--version`，单次命令 timeout 为 1 s，超时后另有最多 200 ms TERM 等待和 500 ms KILL 回收等待，启动与调度/I/O 也不包含在传入 timeout 中。不是每次 scope 复验都再 spawn，也不是所有被拒绝事件都会走到这里。 | [HostHookRunner.swift](../../helper/Sources/ClaudioCore/HostHookRunner.swift)、[HostActivationScope.swift](../../helper/Sources/ClaudioCore/HostActivationScope.swift) |
| 新 hook 配置 | Codex 新条目生成 `type`／`command`；Claude Code 也设置这两个键，但会保留自有条目模板的其他字段，因此不能笼统断言所有已有条目都没有 async／timeout。Kimi 自有块显式写 `timeout = 2`。 | [CodexHooksTransform.swift](../../helper/Sources/ClaudioCore/CodexHooksTransform.swift)、[ClaudeCodeHooksTransform.swift](../../helper/Sources/ClaudioCore/ClaudeCodeHooksTransform.swift)、[AdditionalHostConfiguration.swift](../../helper/Sources/ClaudioCore/AdditionalHostConfiguration.swift) |
| 回执写入 | 成功发布当前回执后同步归档，归档发布成功后剪枝。发布包含私有临时文件、完整写入、`fsync` 与 rename。历史上限每来源 20 条；剪枝有界读取合法文件，按回执时间排序，并保留修改时间条件。 | [HostHookReceipt.swift](../../helper/Sources/ClaudioCore/HostHookReceipt.swift) |
| 工作区解析 | 存在适用规则和可信 cwd 时解析目录；Git 命令 timeout 0.5 s，仅确认超时才按 2 s 重试。匹配 Git common directory，普通目录按实际路径；损坏 Git 不能回退为普通目录。 | [WorkspaceSoundRules.swift](../../helper/Sources/ClaudioCore/WorkspaceSoundRules.swift) |
| OpenCode 覆盖 | 已处理 `permission.asked`、`permission.replied`、`question.asked`、`session.error`、`session.idle` 和 `session.status` 的 busy 分支，并结合会话／终态证据生成 Claudio 桥接事件。不能将原生事件和桥接事件名字不同当作缺失。 | [OpenCodePluginSource.swift](../../helper/Sources/ClaudioCore/OpenCodePluginSource.swift) |
| 音频子进程 | `SystemProcessSpawner` 断开 stdio 并启动子进程，不等待音频结束；这不等同于证明它能存活于所有宿主 teardown／进程组取消。进程内播放若随 helper 退出会被截断，若等待播放又会延长 hook。 | [Play.swift](../../helper/Sources/ClaudioCore/Play.swift) |
| 输出与性能保护 | 已有 CLI 脚本检查合法 hook 的零输出／成功退出；第一阶段复现发现主 fixture 缺少启用意愿/存活身份及匹配 scope，已修复并复跑；已有同进程 playback stub 路径 p95 ≤ 100 ms、真实 pipe/socket 来源增量 p95 ≤ 30 ms 检查。不能声称“没有任何回归保护”。它们也不等同于冷启动 CLI 或首帧出声 SLO。 | [test-hook-cli-contract.sh](../../scripts/test-hook-cli-contract.sh)、[test-additional-host-cli-contract.py](../../scripts/test-additional-host-cli-contract.py)、[HostHookRunnerSuite.swift](../../helper/Tests/ClaudioCoreTests/HostHookRunnerSuite.swift) |

源码事实不等于真实宿主回调、当前安装配置或本机声音验收。首次只读核对未运行这些脚本；后续第一阶段的执行结果独立记录于基线报告。

## 3. 宿主公开合同核对

### 3.1 Claude Code

截至本轮查询，command hook 默认 timeout 通常为 600 s；`UserPromptSubmit`、`PreModelSwitch`、
`PostModelSwitch` 为 30 s，`MessageDisplay` 为 10 s；`SessionEnd` 默认共享 1.5 s 预算，
显式 timeout 可提高该预算但最多 60 s。旧博客的 60 s 表述不能替代当前参考文档或已安装版本验证。

`async: true` 仅用于 command hook，不等待其完成且不执行普通 timeout；`asyncRewake` 仍执行
超时。非交互 `-p` 退出时会终止尚未完成的异步 hook。因而“async 加 timeout 5 s 即可保证有界”
的初稿建议撤回。来源：[Claude Code Hooks reference](https://code.claude.com/docs/en/hooks)，
Configuration / Run hooks in the background。

这只证明公开合同，未证明用户安装版本及每个 Claudio 目标事件的实际行为。调整配置前须记录
版本、验证目标事件、stdin、退出与取消，并保留第三方条目及未知字段。普通异步 hook 要限制寿命，
必须独立设计和验证；本草稿不授权新增 detach 进程。

### 3.2 Codex

公开文档的 `hooks.json` 使用顶层 `hooks` 对象，再按事件分组，不是初稿省略外层对象的结构。
多数 command hook 默认 600 s；`SessionEnd`／`Interrupt` 默认 1 s、最多 3 s。
异步 command hook 沿用超时规则，与 Claude Code 普通异步 hook 不同。
来源：[Codex Hooks](https://learn.chatgpt.com/docs/hooks)，Configuration / Run hooks in the background。

本轮访问初稿所列 GitHub `docs/hooks.md` 失败，改用官方文档核对。没有据此确认本机 Codex
版本或新增事件的真实支持；特别不能把其他宿主的事件名直接搬到 Codex。

### 3.3 Kimi Code、WorkBuddy 与 OpenCode

Kimi 的 `timeout = 2` 是 Claudio 配置生成器事实；WorkBuddy／Kimi 的当前上游 async 能力和
默认 timeout 未取得可靠版本化依据，初稿的“30 s／60 s”和“27 个事件”均撤出确定结论。
2026-10-10 对本机 WorkBuddy 5.7.7 bundled lite-wb 的补充检查确认显式 `timeout` 秒值会转换为
毫秒并执行；1 s / sleep 3 s 实验回调被取消且回收。此结果仅限该 engine，不覆盖所有桌面事件，
也未量到恰好 1 s 的宿主释放边界；详情与通用 CodeBuddy 官方文档的适用限制见基线报告。

OpenCode 官方插件文档列出原生事件；是否形成 Claudio 公共 `Event` 必须依据 ADR 0024 的
身份和终态合同。`todo.updated` 不能直接等同于“任务完成”，`session.status` 也不能直接
等同于响应结束。来源：[OpenCode Plugins](https://opencode.ai/docs/plugins/) 与本仓库适配器。

## 4. 音频与后台传输：证据能支持到哪里

[audiolat README](https://raw.githubusercontent.com/abd3lraouf-studios/audiolat/main/README.md)
展示作者设备的 AUHAL／AudioQueue 测量，并报告其一台机器 keep-open 收益为 9 ms。
内置扬声器示例 TOTAL 为 29.3／45.4 ms（差 16.1 ms），初稿误将 Queue 单个阶段的 45.3 ms
当作 TOTAL。两组 USB 示例差额为 18.5 和 16.5 ms。

这些是外部项目数据，不能外推 Claudio 各设备的收益。首回调、首帧提交、实际出声和 hook 返回
是不同指标；应先测本机 cold／warm／fresh 以及必要的 loopback，再决定是否做独立播放器原型。
未经测量，不承诺“换 AUHAL 必省 16–18.5 ms”，也不以 afplay 的整段墙钟时间代替启动延迟。
本轮没有安装或运行 audiolat。

[Apple TN2321](https://developer.apple.com/library/archive/technotes/tn2321/_index.html)
讨论 buffer 与功耗的取舍。实验不应为改善数字擅自改变设备全局 buffer 或其他应用的工作条件。

[Apple App Nap 指南](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)
列出前台、XPC 和 Apple event 可使 app 退出 App Nap，但没有提供对所有 Unix socket 接收行为
的穷尽证明。因此撤回“Unix datagram 一定叫不醒 GUI”及据此归因“后台收不到提示”的结论。
须先观测真实 App Nap 状态、接收与调度；不能从触发列表缺项直接推导消息必定丢失。

[Apple DTS：XPC and App-to-App Communication](https://developer.apple.com/forums/thread/715338)
讨论 XPC、Unix socket、CFMessagePort 与 rendezvous 的取舍。这不意味着 Claudio 必须立即
换 XPC 或增加 LaunchAgent，也不支持否定所有 Unix socket 鉴权。当前协议的私有目录、
安装／epoch／意愿验证与 peer 身份各自的安全边界须按具体消息类型审查。

## 5. 保留的优化候选及前置验证

以下仅排序研究步骤，不是实现承诺；初稿未经实测的毫秒收益估计已撤回。

| 候选 | 下一步证据 | 必须保留的合同 |
| --- | --- | --- |
| 分解同步工作与 CLI 开销 | 记录精确二进制 SHA／版本、样本数、是否有 GUI 授权、播放 stub 与测量边界；分别测版本探测、回执、工作区和派发成本。 | 不读取或留存 prompt／response，不改真实宿主配置，不把单机结果称为发布门禁。 |
| 跨调用版本探测优化 | 对比缓存命中／缺失／损坏、路径和 executable 变更、包装脚本及版本升级；现有调用内缓存已经存在。 | 不能仅靠 inode／mtime／size 或任意 TTL 承认旧 scope 有效；方案须与 ADR 0025 对齐，改变 current activation 契约时先修订 ADR。 |
| 宿主 async／timeout 配置 | 分宿主、版本、目标事件做迁移与真实取消实验；Claude Code 要单独验证异步寿命。 | 第三方 hooks、未知字段、installation ID、来源关闭、GUI 退出和最终发布许可。 |
| 降低归档／剪枝成本 | 分别量化目录枚举、解码和发布；测试旧历史文件、损坏输入、同时间戳、锁忙和并发。 | 不能只按新文件名排序而忽略现有回执时间语义；延迟归档不得覆盖当前回执或重复计活动。rename 的原子可见性不等同于持久性，不以此删除 fsync。 |
| 工作区解析 | 本轮仅补基线与回归，不实现目录预筛或 Git 缓存。 | Git 规则按 common directory 匹配；cwd 不在所选路径下仍可能命中同仓库 worktree。因此“无路径前缀就跳过 Git”不是安全通用方案。 |
| 音频层原型 | 本机设备与完整事件到出声 A/B；明确独立播放器和 helper 退出模型。 | 短音不得随 helper 退出截断；不阻塞宿主，不改变声音组和系统设备设置。 |
| 扩展事件与契约覆盖 | 先查现有适配器，按逐事件真实证据评估缺口；补测试前先列出现有覆盖。 | 不把 idle、todo 或工具返回当作响应／任务成功；新增绑定按 ADR 和代次规则处理。 |
| 独立 cold CLI／出声预算 | 在已有 100／30 ms 接缝门槛之外补充测量，再提议正式预算。 | 暂不写入未经批准的“冷 30／热 15 ms”门禁，也不按字面禁止现有必要版本／Git 子进程。 |
| 二进制及 doctor 研究 | 实际检查当前链接／采样，确认启动和 doctor 热点，再评估拆分收益。 | CryptoKit 等是否处于具体路径须逐调用确认；拆 hook executable 会影响命令 ownership、安装、签名与更新，不能称无架构风险。 |

当前域模型避免常驻 helper daemon，ADR 0025 又要求 GUI 退出后新事件无副作用。
本轮没有提议以守护进程推翻这两项合同；若后续测量和产品需求要求改变，先提出独立 ADR。

## 6. 初稿历史测量：保留数字，不作为当前基线

初稿记载在 2026-10-09、Apple Silicon、页缓存预热环境测量，使用 Python subprocess 串行派发。
所述二进制为当时安装版本，未记录可复验的 SHA、完整命令、样本数或原始样本文件。本轮没有
取得这些原始证据，以下统一标为“初稿转录、未复验”，不将其称为本轮实测。

| 初稿路径 | p50／单次 ms | p90 ms |
| --- | ---: | ---: |
| `/usr/bin/true` | 6.13 | 8.55 |
| `claudi0 --version` | 11.74 | 17.07 |
| hook 授权前置返回 | 28.31 | 34.05 |
| hook 去抖、不播放 | 55.59 | 73.20 |
| hook 首次播放（单次） | 190.27 | — |
| hook 空 stdin（单次） | 41.60 | — |
| `claude --version` | 11.0 | — |
| `codex --version` | 12.2 | — |
| `git rev-parse` | 13.09 | — |
| afplay Popen、不等待 | 6.49 | — |
| `claudi0 doctor` | 2106 | 2978 |

初稿 A/B 转录：正常版本命令 hook p50 44.98 ms；给版本 shim 加 300 ms sleep 后为 369.60 ms。
方向与同步版本探测源码一致，但未经复验，不能据此确认当前授权路径或预测移除探测的净收益。
`/usr/bin/true` 分位数也不能简单从另一分布的 p50／p90 相减得到精确净成本。

初稿的竞品、第三方进程启动基准、后台进程事故及 LaunchAgent 数字没有完整可定位证据链，
本轮未将这些材料用于排序或架构结论；不再转述费用、进程数或“所有锁都不阻塞”的绝对断言。
磁盘非阻塞锁不排除进程内 NSLock、版本命令等待及其他同步 I/O。

## 7. 首次只读核对的历史范围

该次已完成：当前源码与相关 CONTEXT／ADR 只读对照；Claude Code、Codex、OpenCode、audiolat
和 Apple 一手页面查询；恢复 10 个获授权的已修改文件；文档相对原草稿的只读复核和 whitespace 检查。
Standards 轴保持唯一 owner、现行 ADR 与证据边界；Spec 轴只处理用户授权的清理和草稿校正。

该次未运行：helper／GUI harness、类型检查、构建、真实宿主、人工听音、App Nap、性能 bench、
Release／封包或发布检查。上述边界只描述首次只读核对，不描述随后第一阶段实施。
未验证：用户安装版本、真实配置、WorkBuddy／Kimi 的当前上游 async 契约、旧测量原始样本、
各优化方案的实际收益及跨设备音频结果。本文仍保留为未跟踪草稿，未提交、推送或发布。


## 8. 第一阶段修正（2026-10-10）

新增独立 Release `-Osize` Core 基准和默认关闭的内存测量上下文；完整 fixture 通过真实进程身份、
启用意愿及 installation 校验，逐样本核对副作用。结果和预算草案见
[基线报告](hook-path-baseline-2026-10-10.md)，决策边界见
[ADR 0031](../adr/0031-measure-hooks-before-changing-execution-policy.md)。原稿的备份保留在本地
`dist/hook-baseline-2026-10-10/architecture-review.original.md`，本文件第 6 节仍保留历史数字和来源限制。

第一阶段没有复现首帧出声量化，不把播放替身或 `played` 回执当作人耳证据。同步清理期限不是
绝对墙钟上限；任何新的失败路径预算都须包含启动、TERM/KILL 回收及必要 I/O。
收尾时原断言完整 GUI 门禁为 24,104/0，但旧 16 项原生挂载失败的触发原因未确定；没有改断言
将其掩盖。先前 Claude 无 hook 的 OAuth 过期错误不再代表当前 API 状态：用户配置 API 后，
一个正常短会话已完成并取得真实回调，helper 709.614 ms、一个 `played`，听音未确认；n=1 不作 SLO。
交互启动预检与 Codex 无 hook 会话仍失败，均未补成正常宿主基线。
旧生产版本超时诊断误查活动目录，撤回该批次“活动不变”的直接证据；修正后独立三次均核对实际
summary/pending 与回执不变、回收及零输出，max 1.233 s；旧数字仍保留历史来源。
Git 超时组件最大 3.840 s，验证两次回收和失败关闭，不能替代完整 hook/CLI 失败路径。
Claude `UserPromptSubmit` 的一次性同步 hook timeout 诊断显示，6 s 配置后进程约在 7.45 s
消失，旧 0.7 s 清理 / 6.7 s 总跨度提案已撤回；修订的 2 s / 8 s 仅为本机该模式的候选。
以上均不能称为绝对上界。实时重放即使锁住播放器，
也会写真实历史/活动并发送提示，现已默认拦截，后续批量生产基线须在隔离账户或 VM 中取得。

WorkBuddy bundled lite-wb 的更严格反例另见基线报告：1 s timeout 的忽略 TERM hook 到驱动器
结束仍存活约 14 s。当前 executor 以 Node `child.killed` 决定是否升级 KILL，但该字段不代表已退出，
静态检查与独立子进程对照均支持此原因。因此“显式 timeout 会执行”不足以证明完整上限；
不外推为桌面全部事件结论，也不靠第一阶段修改上游或新增看门狗掩盖该限制。

版本缓存的本地实现、时钟修复、真实签名参与的完整 Core 隔离测量及恢复提案另见
[2026-10-10 复审报告](hook-version-cache-review-and-native-baseline-2026-10-10.md)。
该证据与本文件的历史进程/分支测量分开；不把组件首次填充或命中收益当生产冷路径预算。
