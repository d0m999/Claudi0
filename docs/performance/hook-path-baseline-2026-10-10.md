# Hook 第一阶段：可复跑基线与预算草案

> 2026-10-13 文档归档：下文保留当时的候选、授权与验证状态；其中“未提交／未推送”描述记录时点。
> 后续提交状态与暂停范围见 [2026-10-12 收束记录](hook-performance-roi-closeout-2026-10-12.md)。本次归档不重新验证历史结果或重启实验。

规格：[Issue #218](https://github.com/d0m999/Claudi0/issues/218)；决策：[ADR 0031](../adr/0031-measure-hooks-before-changing-execution-policy.md)。
第一阶段只实现测量、fixture 修复、回归和文档。版本缓存的后续局部实现见
[本地验证报告](hook-version-cache-local-2026-10-10.md)；async、回执剪枝优化和 Git 算法未改变。
**2026-10-10 局部预算已批准：** 用户采用本文 Core 分场景预算和版本超时拒绝路径 ≤2 秒测试上限，
只放行版本缓存本地实现与隔离验证。宿主策略、生产启用和第三阶段继续暂停；不动现有回执历史及
活动计数。这是对原统一开工闸门的明确范围调整，不代表第一阶段全部验收。
历史评估的 20/30 ms、预计节省值和单次播放耗时都不作 SLO。
原断言的完整 GUI 门禁已通过，但旧 16 项失败的触发原因仍未证明。用户配置 API 后，Claude
正常短会话已取得一个真实回调；听音未确认。Codex 正常会话与 Claude 交互预检仍失败。
用户暂时没有隔离账户或 VM，生产完整路径批量基线保留未验证；第一阶段尚不能按完整真实宿主证据验收。

## 复跑与证据边界

在仓库根运行：

```bash
python3 scripts/benchmark-hooks.py
bash scripts/test-hook-cli-contract.sh
python3 scripts/test-additional-host-cli-contract.py
```

基准脚本在隔离 scratch path 构建 `claudio-hook-benchmark` 和生产 `claudio`，均为 Release `-Osize`。
正式计时在构建完成后开始；fixture 准备、检查和驱动器 JSON 输出不在计时区间。默认每个场景/探测模式/
observer 状态每轮预热 10、测量 100，重复 3 轮。固定种子 `0xC1A0D10` 决定 A/B 初始顺序，
随后交替 AB/BA；版本对照顺序交替正向/反向。分位数采用 nearest-rank，不扣除空进程耗时。
每一行是驱动器实际发起的一次 `handleHostHook`，计时含该调用的全部同步处理。

| 证据层 | 真实执行 | 替身或限制 |
| --- | --- | --- |
| Core 隔离 | 授权、活进程身份、installation、版本进程、活动、配置/工作区/Git、锁、当前回执、归档/剪枝 | 播放器只计一次成功启动请求；提示 sender 内存返回成功。不是 CLI、GUI 接收或实际出声 |
| Debug CLI 合同 | 真正 CLI 子进程、stdin、零输出、当前授权、回执及历史，覆盖成功/静音/失败/去抖/拒绝 | 临时根、测试进程代替 GUI 生命周期、确定版本 shim、音量 0；不是宿主回调 |
| Release helper 重放 | 确切生产二进制、实际用户根、既有授权/配置/磁盘，启动到退出的墙钟跨度 | 驱动器发起，非真实宿主；锁忙阻止声音但仍写入历史/活动和发送提示。既有批量数据有副作用，后续批量仅限隔离账户或 VM |
| Release helper / 真实宿主 | 本轮生成的确切 Release helper 由真实宿主回调启动；报告二进制 SHA-256 | 独立记录样本、会话结果和外部反馈，不混入 Core 分位数 |
| 人耳 | 用户对指定真实事件的反馈 | 不测首帧、loopback 延迟或其他音频设备 |

Release 未新增测试根入口；Debug-only 边界继续由真实 CLI 契约检查。默认关闭的测量上下文不读时钟、不
分配记录。开启后只收集有限枚举，最多 1,024 条并显式计溢出，所有样本要求零溢出。生产 hook 无新输出、
普通日志或持久遥测。**默认关闭不等于已证明插桩完全无成本**；本轮 A/B 量化开启相对关闭的成本。

阶段跨度是 inclusive，可嵌套，不能相加当总时长。`playbackLock` 包括锁内授权/启动，`playerStart`
仅覆盖启动调用，`notice` 仅覆盖发送调用；总计时还包括提示构造和进程来源解析。Core 的输入已是内存
payload，`inputAuthorization` 在 Core 场景主要是授权捕获；CLI 输入读取存在插桩但生产没有开启入口。

## 场景与逐样本有效性

12 个场景为：空历史完整播放、满载稳态完整播放、静音、时间去抖、不可播放、来源关闭、GUI 退出、旧
installation、播放锁忙、普通目录工作区、Git 工作区及损坏 Git 身份。工作区场景必须实际返回对应结果；
已修正 fixture 中无效的空事件字典，不把误拒绝算加速。

每个样本核对 `HostHookHandlingOutcome`、播放器及 sender 的独立调用数、活动文件计数、当前回执身份/
结果/完整 epoch 时间值、新增归档数及保留数量。拒绝必须无新播放/活动/回执/归档/提示；不能只看返回 0。
Core 完整播放的预期为接收/启动/活动/回执/归档/提示各 1；静音、去抖、锁忙和不可播放保留接收与诊断副作用，
播放器为 0。空历史每次调用前在计时外重建为空；稳态始终从 20 条开始，写入后仍为 20 条。

正常、近零、延迟三组产生同一 `benchmark-version` 输出；正常/延迟使用真实 shell 子进程，延迟组加
300 ms sleep，近零组使用现有 `CommandRunning` 替身。真实组执行本机 Claude Code `--version`。
每次事件新建调用内 scope snapshot，无跨事件缓存。磁盘/页缓存为预热条件，不声称测到了冷设备。
版本 runner 在隔离驱动器内记录真实 `CommandRunResult`：允许事件恰好探测一次，来源关闭和 GUI 退出
不探测；开启 observer 的拒绝样本还必须匹配具体拒绝枚举。

另有忽略 TERM 的超时诊断（10 个配对、1 轮、1 次预热），验证 1 s deadline 后 KILL 回收与拒绝副作用；
它是小样本失败诊断，不与默认规模数据混合，也不能从最大观测值宣称绝对上界。

## 测量结果

本轮正式数据来自 `dist/hook-baseline-2026-10-10/frozen/`，完成标记 `complete: true`；构建前、构建后及
采样后编译输入身份一致。基线为 `feb142b3fb87668ffc039a18cb07dba61d42490f` 加本轮未提交改动。
环境为 MacBookPro17,1 / arm64 / macOS 27.0.1 / Apple Swift 6.4；Release `-Osize`。
基准二进制 SHA-256：`d62a8edc546acf6c25c80642a17b01fb7949a7a15dd052557661099ea8d56ded`。

主场景集 7,200 次，版本对照 2,400 次；另有 20 次超时诊断。预热不计入这些样本数。所有样本均通过
目标结果和副作用核对，三个采样进程 stderr 均 0 字节。以下主场景表使用 **observer 关闭** 的数据，
每行 n=300（每轮 100，三轮）；单位 ms，版本为正常 shell 探测，不是生产 helper 总耗时。

| 场景 | p50 | p90 | p95 | max |
| --- | ---: | ---: | ---: | ---: |
| 完整播放，空历史 | 11.329 | 12.930 | 13.647 | 20.856 |
| 完整播放，20 条稳态 | 12.454 | 17.593 | 22.879 | 107.902 |
| 静音 | 11.840 | 16.623 | 22.988 | 172.688 |
| 去抖 | 12.104 | 15.524 | 16.836 | 263.275 |
| 不可播放 | 12.032 | 14.152 | 15.675 | 66.676 |
| 来源关闭 | 0.038 | 0.074 | 0.115 | 0.931 |
| GUI 退出 | 0.043 | 0.089 | 0.144 | 0.998 |
| 旧 installation | 5.333 | 7.507 | 8.287 | 38.625 |
| 播放锁忙 | 11.856 | 16.357 | 20.026 | 125.205 |
| 普通目录规则 | 13.370 | 15.308 | 16.058 | 68.509 |
| Git 规则 | 26.802 | 30.295 | 32.933 | 69.271 |
| 损坏 Git | 23.547 | 26.077 | 28.382 | 88.031 |

三个资格拒绝场景（来源关闭、GUI 退出、旧 installation）在每个 observer 状态各拒绝 300/300，
播放、活动、当前回执、归档及提示均为 0。其余九场景均接收 300/300，活动/当前回执/归档/提示均为
300/300；其中完整播放两场景与两类有效工作区场景启动 300/300，静音/去抖/不可播放/锁忙/损坏 Git
均启动 0/300。锁忙还单独记录 300 个 `lockBusy`；来源关闭/GUI 退出不探测版本，其余正常场景各探测一次。
超时样本另计：两种 observer 状态各 10/10 返回真实 `timedOut`，拒绝且所有副作用为 0。

### 版本探测配对对照

这组仅测满载稳态，独立于主场景集，不合并同名 normal 分布。下表仍为 observer 关闭、各 n=300。

| 探测模式 | p50 | p90 | p95 | max |
| --- | ---: | ---: | ---: | ---: |
| instant | 7.876 | 10.062 | 11.490 | 29.316 |
| normal | 14.570 | 17.364 | 18.809 | 45.530 |
| delayed | 327.378 | 331.353 | 332.573 | 487.357 |
| real | 21.095 | 24.596 | 25.978 | 63.004 |

按相同 `(round, pair)` 的原始样本逐对作差，normal−instant 的差值 p50 为 **6.132 ms**，
delayed−normal 为 **312.911 ms**，real−instant 为 **13.179 ms**。300 ms sleep 还引入额外 sleep
进程和调度，不能把 312.911 全称为 sleep 精度或保证移除进程的收益。真实版本组解析 Claude Code
2.1.282，播放器和提示仍为替身；缓存尚未实现，身份验证/签名/缓存读取的新增成本尚未测量。

### 开启 observer 的差值与阶段分解

下表是同轮同场景的 `on−off` 配对差值，各 n=300，单位 ms。它同时包含 observer 成本和相邻调用的
I/O/调度波动；负值不表示 observer 加速，也不能据接近零的中位数宣称插桩免费。关闭插桩相对修改前
二进制的增量尚未单独隔离。完整逐场景差值在 summary JSON 中。

| 场景/组 | 差值 p50 | p90 | p95 | max |
| --- | ---: | ---: | ---: | ---: |
| 空历史 | +0.081 | +1.610 | +1.994 | +7.185 |
| 满载稳态 | +0.026 | +3.087 | +6.341 | +220.448 |
| Git 规则 | -0.312 | +2.784 | +3.617 | +57.086 |
| 真实版本探测组 | -0.036 | +11.334 | +17.965 | +48.652 |

观察器开启时的阶段 p50（ms，inclusive，不能求和）：

| 阶段 | 空历史 | 满载稳态 |
| --- | ---: | ---: |
| 授权捕获 | 0.103 | 0.082 |
| 版本解析 | 5.060 | 5.172 |
| 活动记录 | 1.328 | 1.369 |
| 工作区/声音解析 | 0.437 | 0.434 |
| 播放锁及锁内处理 | 1.291 | 1.351 |
| 播放器替身启动 | 0.002 | 0.002 |
| 当前回执发布 | 0.437 | 0.456 |
| 历史发布 | 0.467 | 0.375 |
| 历史剪枝 | 0.138 | 1.008 |
| 提示替身发送 | 0.000 | 0.001 |

满载剪枝约 1.008 ms，空历史约 0.138 ms，仅说明本机这一分支的量级。两次持久发布仍各自存在；
后续允许的 <=20 条快路径在新归档后变成 21 条的稳态场景不会跳过原排序，不能承诺去掉满载读取。

超时诊断（observer 关闭，n=10）p50 **1206.219 ms**、p90 **1208.032 ms**、
p95/max **1209.395 ms**。实际确认 TERM 被忽略后子进程最终回收；没有播放或发布。此最大值是
观测值，不是任意调度/磁盘条件下的保证。

早先 `measured/` 的 9,600 个样本因驱动脚本在测量期间变化而被自动拒绝（编译输入未变）；
没有 `complete: true`，不进入以上结果或预算。该诊断数据保留，避免把一次失败的基准运行隐藏掉。

原始样本、分组统计、开启开销、metadata 和构建日志保存在本机 Git 忽略目录
`dist/hook-baseline-2026-10-10/`。metadata 含基线 SHA、dirty、编译输入逐文件摘要、二进制摘要、
Swift/OS/架构/硬件型号、宿主版本、缓存与注入条件。原始 JSONL 不含私人路径、宿主配置、安装 UUID、
事件 payload 或声音内容。进程错误/构建日志只作为本地诊断，不上传 Issue。

## 生产 Release helper 的独立证据

`scripts/measure-release-hooks.py` 测启动到退出的实际 CLI 墙钟，不扣除空进程成本。既有三组完整重放
每场景预热 10、测量 100、三轮，锁忙与旧 installation 的顺序由固定种子决定；各行 n=300，单位 ms。
二进制与 `frozen/metadata.json` 的 helper 摘要完全一致，编译输入在收尾时再次核对未变。

| 宿主 / 路径 | p50 | p90 | p95 | max |
| --- | ---: | ---: | ---: | ---: |
| Claude Code / 锁忙 | 46.291 | 57.523 | 62.710 | 216.318 |
| Claude Code / 旧 installation | 33.626 | 42.697 | 48.590 | 120.420 |
| Codex / 锁忙 | 50.602 | 101.187 | 164.132 | 673.475 |
| Codex / 旧 installation | 37.184 | 77.802 | 102.493 | 335.299 |
| WorkBuddy / 锁忙 | 26.321 | 28.820 | 29.747 | 101.636 |
| WorkBuddy / 旧 installation | 18.335 | 20.280 | 21.498 | 207.540 |

三组共有 1,800 个测量事件：900 个锁忙样本逐项产生一个新 `debounced` 归档，900 个拒绝样本保持
回执字节不变，所有 helper 零输出、exit 0；预热另计。历史使用当前稳态，cwd 为临时普通目录，
没有测试真实播放、静音组、Git 规则或空历史的生产路径。旧驱动器未冻结自身及 GUI 可执行文件摘要；
不能事后补造这些身份。构建身份通过 helper 摘要关联，原始限制见 `release-replay-provenance-addendum.json`。

补充 Claude 完整批次 `release-replay-frozen-claude/` 冻结了驱动器和编译输入：锁忙 p95 71.589 ms、
最大单轮 p95 87.153 ms；旧 installation p95 73.129 ms、最大单轮 p95 128.869 ms。它与首组
独立报告，不合并分布。该次第一轮与 WorkBuddy 桌面会话重叠，不能将漂移归因为具体 I/O 或版本成本。
补充 Codex 批次在拒绝样本期间发现回执变化，43 个已完成样本之后中止，没有完成标记，不进入预算。
随后 GUI 运行标记消失，具体外部触发未确定；未用提前拒绝继续计成功样本。

**重放安全修正：**锁忙仅防止声音，接受分支仍向实际用户根写回执/历史、增加活动并尝试发送横幅。
这些批次和预热确实产生了此类副作用，会推动既有历史剪枝，不能称为“无副作用基准”。已停止批量
实时重放，不在共享活动数据中猜测回滚。共享工作区的 `8934524` 将实时重放默认关闭，要求完整
`--allow-live-state-replay`，并说明仅在明确授权的隔离账户或 VM 使用；默认/`python -O`/缩写拒绝测试
全部通过。后续自动批量基线采用 Core 临时根；生产 Release 需要隔离账户或 VM，不能新增测试根入口。
真实宿主的小样本手工检查也会产生实际事件，须与批量隔离测试区分。

当前驱动器另核对注册 PID 的实际可执行文件，要求 `claudi0-app` 或 `ClaudioGUI`，保存摘要；
测试 harness 不能充当“真实 GUI”。恢复现有检查包后，新的超时诊断和 WorkBuddy engine 回调均通过
这项核验。未重封包或替换 GUI/helper，检查包不构成签名发布证据。

新增 `scripts/measure-release-hook-timeout.py` 在真实授权下注入私有 PATH 版本 shim，忽略 TERM、
sleep 3 s；逐项确认 shim 真被执行、helper 返回后子进程已不存在、回执字节不变以及零输出。
预热 1 次，测量 20 次，包含进程启动及清理：p50 **1229.882 ms**、p90 **1232.640 ms**、
p95 **1234.121 ms**、max **1235.236 ms**，20/20 零输出且无回执变化、探测子进程已回收。
收尾核对发现旧脚本误查 `~/.claudio/activity`，实际活动目录是
`~/.claudio/integrations/activity`。因此撤回旧批次“活动字节不变”的直接证据结论；
源码显示版本失败先于活动提交，但源码不能补成该批次的实际活动快照。
原始样本及元数据中的旧字段保持原样，解释以本纠正为准。脚本已修正目录并增加真实 summary/pending
变更检测回归，修正后的独立补测另列，不能将旧样本重新标记为通过新检查。
元数据与原始样本保存在 `release-timeout-live-gui/`。这是生产 CLI 的失败诊断，不是宿主超时实验，
也不是任意环境的墙钟硬上界。

修正后的独立补测 `followup/version-timeout-corrected/` 使用同一 helper 摘要，预热 1、测量 3 次：
p50 **1223.842 ms**，p90/p95/max **1232.909 ms**。三次均确认实际
`integrations/activity` 的 summary/pending 与回执字节不变、探测子进程已回收、helper 零输出。
它支持修正后脚本的检查，不能追溯替代旧批次的活动快照，也不补足完整播放的生产基线。

复跑该无接收副作用的诊断（先确认真实 GUI 正在运行）：

```bash
python3 scripts/benchmark-hooks.py --output dist/hook-baseline-rerun
python3 scripts/measure-release-hook-timeout.py \
  --helper helper/.build/hook-benchmark/release/claudio \
  --build-metadata dist/hook-baseline-rerun/metadata.json \
  --output dist/hook-timeout-rerun
```

每次复跑须使用对应新构建的 metadata；源码改变后旧 `frozen/metadata.json` 会被身份检查拒绝，
不能跳过检查继续沿用。此拒绝诊断不授权接收分支的实时批量重放。

## 真实宿主与人工证据

提供显式调用的 `scripts/measure-real-hook.py`，只在真实 GUI 和对应来源已开启时运行；使用会话级临时
hook 设置，不改自有/第三方安装配置、不绕过信任，不保存原始 stdin 或模型输出。一次回调的独立发起数来自
wrapper；驱动器另记录预期发起 1 个事件。回调进入后先原子保存开始记录，再执行 helper，超时或
取消不抹掉已知发起数，重复回调逐项计数。helper 耗时从其子进程启动前测到退出，零输出单独核对。新增历史归档只是辅助证据：若并发回调
混入，不能据此宣称唯一关联或推导总体送达率。该工具支持 Claude Code 与 WorkBuddy bundled engine
的短非交互检查，可按发起数保存多个结果；默认 1 次，批量另需明确 opt-in 并使用隔离账户或 VM；
测量工具禁止 `python -O` 禁用逐样本核验。callback 入口到计时终点
仍排除宿主派发、shell 启动及最终记录发布，因此只是宿主阻塞的下界；不把整段模型会话算成 hook 阻塞。

本机 Claude Code `2.1.282` 的两次 `UserPromptSubmit` 回调使用同一确切 Release `-Osize` helper，
SHA-256 为 `51353f1458b52d1c48dd9418f5e1a38922f8bd7084e808fe4cffa5ec01e13c5c`。

| 独立试次 | helper 进程耗时 | 发起/新增归档 | helper 输出与退出 | 用户听音 | 运行条件 |
| --- | ---: | --- | --- | --- | --- |
| 首次 | 774.57 ms | 1 / 1，`played` | stdout/stderr 0 字节，exit 0 | 未确认；未提前提醒 | GUI harness 同时运行 |
| 提前提醒后重跑 | 48.79 ms | 1 / 1，`played` | stdout/stderr 0 字节，exit 0 | 用户明确确认听到任务开始提示音 | 首轮 Core 探测对照同时运行 |

两次宿主会话均 exit 1，未触及驱动器 45 s 期限。因此这里只确认真实宿主回调、helper 完成、新归档及
第二次人工听音，**不确认短会话正常完成或总体送达率**。n=2 不计算分位数，也不将 48.79 ms 作为预算。
当时驱动器的会话总跨度还包含退出后的版本元数据探测，已在原始记录标注；脚本现已将会话终点移到进程
退出后立即取时。既有两个 helper 独立计时区间不受此修正影响；没有把会话总跨度当宿主阻塞量。

在不设置任何 hook 的单独诊断中，Claude 仍 exit 1 且结构化结果 `is_error=true`，说明宿主会话失败
可以在 Claudio 回调之外复现。后续诊断的 `terminal_reason=api_error`、`duration_api_ms=0`；原始
输出中已明确观察到 OAuth 会话过期且刷新失败；`subtype=success` 不能覆盖 `is_error=true`。
脱敏原因保存在 `claude-host-error-cause.json`，不保存凭据或完整输出。此为先前 OAuth 条件下的
历史诊断；用户随后配置 API，最新正常短会话见下文。没有执行新的 OAuth 登录或修改凭据。

Codex `0.162.1` 的无 hook 预检分别使用隔离配置和现有用户配置，45/60 s 期限内未完成正常模型会话；
后一组出现 `reconnect` 错误，未发起工具。驱动器只终止自己创建的进程组；没有绕过信任或改写私有
trust 数据。当前证据只能说明无 hook 也能复现连接/重试失败，根因未确认，不能写成 Codex 鉴权失败。
Codex 的正常真实回调、交互及短会话基线仍未取得；重放不能替代这些证据。
本次补测再次以现有配置、`--disable hooks`、只读 sandbox、无工具请求运行：40 s 内仅取得
`thread.started`/`turn.started`，未取得 `turn.completed`，由驱动器终止自身进程组。
`followup/codex-api-preflight.json` 不含原始模型或错误输出；本次没有鉴权失败的直接证据，
不能据超时认定根因。它没有调用 Claudio，也没有补成正常回调基线。

### API 配置后的 Claude 正常短会话

驱动器此前用 `--setting-sources ''` 隔离 hook 配置，同时丢掉用户设置中的 API 环境。
现在仅在内存复用 `ANTHROPIC_*` 及必要的 API timeout/effort 环境字段，未将凭据复制到 fixture、
报告或普通日志。独立无 hook 的 `--bare -p` 预检 exit 0、正常完成且回复 `OK`；不涉及 Claudio 状态。

提前 10 秒提醒后，只发起一次正常 `UserPromptSubmit` 会话。本次冻结的 Release helper 摘要仍为
`51353f1458b52d1c48dd9418f5e1a38922f8bd7084e808fe4cffa5ec01e13c5c`。

| 指标 | 结果 |
| --- | --- |
| 驱动器发起 / 原生回调 / 完成 | **1 / 1 / 1** |
| helper 墙钟 | **709.614 ms**，stdout/stderr 0 字节，exit 0 |
| callback 已测区间 | **710.871 ms**；排除宿主派发、shell 启动和最终记录发布 |
| 正常模型会话 | exit 0、`terminal_reason=completed`，总跨度 **4.330 s**；不是 hook 阻塞 |
| 新历史归档 / 活动 | `played` **1**；Claude 当日 task-start **669→670**，pending 0 |
| 人工反馈 | **“没有听到或无法确认”**；本次音频未确认 |
| 状态证据 | 前后私有快照稳定，configuration 与 installation 摘要未变 |

原始脱敏记录为 `followup/claude-normal-short.json`；n=1 不计算 p95、不解释启动波动原因，
也不将 709.614 ms 或历史的 48.79 ms 当成正常路径预算。`played` 表示播放器启动请求成功，
不代表已出声或用户听到。过去错误会话中用户明确听到一次的反馈仍保留，不外推到本次事件。
前后快照只包含此次事件附近的有限回执/活动，保存为私有目录和 0600 文件；它们产生在批量污染
之后，不能恢复污染之前的历史或证明当时的计数。未清理、回滚或按批量事件数减去活动。

真实交互预检使用 stdin/stdout 均为 TTY 的 PTY 和私有 `CLAUDE_CONFIG_DIR`，尚未发出用户请求即
因启动检查访问 Anthropic 服务返回 HTTP 403 而 exit 1；Claudio 回调数为 0。
`followup/claude-interactive-preflight.json` 只保存有限分类，不保存终端/模型内容。
该失败发生在 hook 之前，不能归因于 Claudio 或宣称用户配置的 API 不可用；正常 API `-p` 路径已单独通过。
没有绕过启动检查、修改私有 trust 或将非交互成功当成交互验收。

WorkBuddy `5.7.7` 分开记录两条路径：

| 路径 | 观察 | 限制 |
| --- | --- | --- |
| bundled lite-wb engine / 短非交互 | 实际 `UserPromptSubmit` 回调执行确切 Release helper，**53.039 ms**；callback 已测区间 54.137 ms；1 个发起、1 个完成、新增 1 个锁忙 `debounced` 归档，helper 零输出 exit 0 | engine 随后报告 `authentication-required`，虽然 exit 0，仍不是正常模型会话；n=1 不算分位数。桌面登录不能推导为 engine 登录 |
| 已登录桌面 / 交互 | 提前提醒后发起 1 个不使用工具的请求，UI 显示 `OK`、已完成 19 s；观察窗口新增 `UserPromptSubmit` / `Stop` 各 1 个 `played` 归档 | 使用既有 helper `18e3ab4bf1d6cd65d9fb0633704374dcbc0ba359bd18b5e868e3d40042fecd8a`，不是本轮 Release 二进制；未插桩回调分母及进程/宿主阻塞跨度。19 s 是会话 UI 时间；用户反馈“没有听到或无法确认”，实际音频未验证 |

本机 lite-wb bundle 摘要为 `11707578579941ac5434c0d72180a4ef6d8dc988432d8eae62c1f9c6ed3f50de`。
静态 `executeCommandHook` 将 `timeout` 秒乘 1000 传入 `hookExecutor.execute` 并 await。
会话级动态探针设置 1 s timeout、回调 sleep 3 s：发起 1 次、未完成、宿主结束后回调已不存在，
输出含 timeout 信号；入口到宿主退出 2648.389 ms 还含后续鉴权处理，不能据此声称 hook 恰在 1 s
释放宿主。这里确认该 engine 的显式 timeout 被执行，不覆盖所有桌面事件或取消边界。
官方 [CodeBuddy CLI hooks](https://www.codebuddy.ai/docs/cli/hooks) 与
[IDE hooks](https://www.codebuddy.ai/docs/ide/Features/hooks) 的通用 60 s 默认值仅为协议参考，
不能直接替代 WorkBuddy 当前桌面各事件的实测。

本次忽略 TERM 的一次性 hook 暴露了更严格的反向条件。bundled lite-wb 的 6 s/1 s timeout 探针
均未在 15 s 驱动器期限内取得释放点；1 s 组记录 hook 约在宿主启动后 0.924 s 进入，终止会话时
已运行 **14.084 s** 且 PID 仍存活。会话被驱动器终止后 hook 才确认消失，不能记为宿主 timeout
成功回收；没有调用 Claudio，也没有拿 host exit 0 当作通过。

对当前 bundle 的源码核对发现：timer 先 `child.kill("SIGTERM")`，1 s 后仅在
`!child.killed` 时发送 KILL，并等 `exit` 后才 resolve。
[Node `subprocess.killed` 文档](https://nodejs.org/api/child_process.html#subprocesskilled) 明确该字段
描述信号是否发送成功，不表示进程已退出。独立 Node 子进程对照复现了 TERM 发送成功、
`killed=true`、子进程仍在运行且该 KILL 分支不执行；测试最终只强杀自己的 fixture 并回收。
静态错误与动态反例一致，因此当前 **bundled engine 的 timeout 不能保证忽略 TERM 时的完整上限**。
源码摘要仍为 `11707578579941ac5434c0d72180a4ef6d8dc988432d8eae62c1f9c6ed3f50de`；
有限记录在 `followup/workbuddy-engine-native-timeout-1s-tracked.json` 和
`node-killed-diagnostic.json`。6 s 旧探针缺少 hook 年龄字段，只保留其失败边界，不补造时间。
未确认当前桌面是否使用同一 executor；Claudio 正常 helper 的 TERM 响应也不是本次假 hook 的行为。
不能只写一个 timeout 就宣称解决此限制；不在第一阶段修改上游 bundle 或新增 helper 看门狗。

交互与正常短会话的跨宿主阻塞、多次送达分母、并发/取消/乱序尚未齐全。以上缺口是后续预算冻结
及执行策略验收的前置条件，保持未验证；不通过修改登录、信任或私有设置消除证据缺口。
Kimi/OpenCode 只运行既有策略回归，不由这些 fixture 推导新的真实宿主结论。

### Claude 同步 timeout 的真实协议诊断

新增 `scripts/measure-host-hook-timeout.py`：会话级临时 `UserPromptSubmit` hook 忽略 TERM 并等待
20 s；使用本机 Claude CLI 与 loopback 假 API，仅发送 fixture key，不调用 Claudio、不播放、
不写安装 hook 设置或回执/活动。首次模型 API 请求说明宿主已越过 hook；该跨度还包含后续准备，
不能等同精确的宿主派发到释放。驱动器每 5 ms 检查已记录子 PID 是否消失，粒度及调度会影响观测。
得到释放证据后驱动器终止自己的会话，因此 host exit 143 是诊断结束，不是正常模型会话。

| 配置 timeout | hook 进入→子进程确认消失 | hook 进入→首个模型请求 | 子进程 / 驱动器 |
| --- | ---: | ---: | --- |
| 6 s，首次有效释放记录 | **7.448 s** | **7.486 s** | 请求到达及宿主退出时均已消失；未由驱动器杀 hook |
| 6 s，独立重复 | **7.446 s** | **7.482 s** | 同上 |
| 1 s，对照 | **2.446 s** | **2.471 s** | 同上 |

数据保存在 `followup/claude-native-timeout-6s-release-boundary.json`、
`claude-native-timeout-6s-repeat.json` 和 `claude-native-timeout-1s.json`。
本机 2.1.282 的这些样本反驳原 **0.7 s 清理 / 6.7 s 总跨度**提案：进程消失的观测余量约 **1.45 s**。
不以样本最大值声称宿主的硬保证，也不将此结果推广到其他事件、交互、async 或其他宿主。
第一阶段未将 timeout 写入 adapter。官方仍明确普通 async 不执行配置 timeout，见
[Claude Code hooks](https://code.claude.com/docs/en/hooks#configure-an-async-hook)。

两次启动失败记录保留：缺少 `--` 时 variadic `--tools` 吞掉 prompt，未触发 hook，不能计入
timeout 证据；另一次已记录释放点，但驱动器继续等待假 API 的错误会话直到 30 s，再自行终止。
该不完整会话不作正常基线；修正后的驱动器明确在取得释放证据后结束，保留原失败记录。

## Git 迟缓失败的组件诊断

独立 `--git-timeout-diagnostic` 复用现有 `CommandRunning` 与目录 resolver 注入，按原流程先探测
版本，再调用工作区 profile resolver。真实 runner 分别执行 0.5 s 和 2 s 超时、TERM/KILL 回收；
逐项验证原 Git 参数、两次调用、子进程消失以及 `invalidRule`，不回退到默认组或普通目录。
不改变共同仓库身份算法，也没有增加生产每阶段测试 API。

测量中版本 fixture 真实等待 0.9 s 且正常输出。新建脚本首次执行曾因约 **393 ms** 的正文进入延迟
超过 1 s 探测期限；同一文件随后正文进入约 16–38 ms，直接 runner 对照已复现此差别，延迟的 OS
内部原因未确定。首轮组合及两个 smoke 失败均保留，未计入预算。fixture 现在先做一次计时外的
2 s 准备探测；**被测版本探测仍为 1 s**，不能将这组暖文件条件当作冷 helper 或真实宿主布局。

`followup/git-timeout-prewarmed/` 有 10 对 observer A/B、1 次预热、1 轮，20 个有效样本：

| observer | n | p50 (ms) | p90 (ms) | p95 / max (ms) |
| --- | ---: | ---: | ---: | ---: |
| 关闭 | 10 | 3831.036 | 3834.475 | **3840.032** |
| 开启 | 10 | 3829.731 | 3835.222 | **3839.789** |

所有样本完成两次超时回收和工作区失败关闭。这是 **版本解析＋工作区解析的组件跨度**，不包含
完整授权、活动、回执或 CLI 启动；不是 `handleHostHook` 完整失败路径，不能据 3.84 s 宣称
完整 helper 的 5.5 s 上限已验证。编译输入、测量二进制和脚本文件身份单独保存；后来门禁将
fixture 初始化改为原子发布，原样本仍对应其明确记录的旧 benchmark，不改标为新构建结果。

复跑组件诊断：

```bash
python3 scripts/benchmark-hooks.py --git-timeout-only --output dist/hook-git-timeout-rerun
python3 scripts/measure-host-hook-timeout.py --timeout 6 --output dist/hook-claude-timeout-rerun.json
```

第二条仅验证 Claude 的一次性协议 fixture，不是 Git、Claudio helper 或正常会话测量。

## 待用户确认的预算

**Core 表和版本超时拒绝 ≤2 秒已获局部批准，其余仍为候选。** 本机三轮存在明显尾延迟漂移，不建议直接冻结统一毫秒 SLO
或任意固定百分比。先提请确认“使用场景自己的参考包络，并在每项优化时重测同条件对照”的办法。

Core 候选上限取本次 observer 关闭时三个单轮 p95 的最大值，向上保留两位小数；允许波动为该值
减去合并 p95，反映已观察到的轮次波动，不是统计置信上界。只适用于这里的 normal 探测隔离场景。

| 场景 | 合并 p95 (ms) | 候选 p95 上限 (ms) | 观测波动余量 (ms) |
| --- | ---: | ---: | ---: |
| 完整播放，空历史 | 13.647 | 15.50 | 1.853 |
| 完整播放，20 条稳态 | 22.879 | 27.29 | 4.411 |
| 静音 | 22.988 | 30.12 | 7.132 |
| 去抖 | 16.836 | 21.42 | 4.584 |
| 不可播放 | 15.675 | 18.52 | 2.845 |
| 来源关闭 | 0.115 | 0.13 | 0.015 |
| GUI 退出 | 0.144 | 0.22 | 0.076 |
| 旧 installation | 8.287 | 8.41 | 0.123 |
| 播放锁忙 | 20.026 | 39.04 | 19.014 |
| 普通目录规则 | 16.058 | 18.62 | 2.562 |
| Git 规则 | 32.933 | 35.01 | 2.077 |
| 损坏 Git | 28.382 | 31.10 | 2.718 |

候选比较规则：新旧实现用相同 fixture 与真实结果逐项配对，报告 p50/p95、逐轮结果和差值；
新实现不得超出已确认的场景包络，所宣称收益必须在同条件配对数据中出现。若同轮旧实现也超出包络，
先判断环境变化并复跑，不能靠放宽预算完成验收。缓存 miss/未知布局/拒绝路径不应因命中收益被平均掉。
回执优化分别报告空目录与满载稳态；收益有限仍保留正确性结果，不扩展范围。

以下生产候选明确分开“已测参考包络”和“容量设计提案”。它们不承诺优化节省，也不把未测路径
按已测锁忙路径处理。Release 的 p95 候选取上述完整批次中最大单轮 p95，向上取 5 ms 整数；
Claude 包含两个独立完整批次的较大值。由于早期身份记录不全且有实时状态副作用，候选只能供讨论，
正式冻结前须在隔离环境复跑；不能把较小的 Core 数字套到 CLI。

| Release helper 路径 | 候选 p95 上限 | 依据 / 适用边界 |
| --- | ---: | --- |
| Claude Code 锁忙 | **90 ms** | 最大单轮 87.153 ms；普通临时 cwd、当前稳态历史，未包含实际播放器启动 |
| Claude Code 旧 installation | **130 ms** | 最大单轮 128.869 ms；零副作用拒绝；不能据旧批次 48.590 ms 的合并 p95 隐去波动 |
| Codex 锁忙 | **235 ms** | 最大单轮 234.188 ms；该轮尾延迟明显，原因未定位，不许只选后两轮 |
| Codex 旧 installation | **210 ms** | 最大单轮 207.178 ms；保留拒绝与真实授权复验 |
| WorkBuddy 锁忙 | **35 ms** | 最大单轮 30.486 ms；版本来自 app bundle，不能与 Claude/Codex 的 CLI 探测成本混算 |
| WorkBuddy 旧 installation | **30 ms** | 最大单轮 25.329 ms；该数值由本轮样本取整产生，不采用初稿的统一 30 ms 目标 |

候选容差就是各表上限相对参考分布的轮次余量；不另加统一百分比。比较时同轮旧实现也须满足
包络，否则先核对环境并重跑。未覆盖的完整播放、生产 Git 和静音等路径仍须补自己的包络，不能
将这六行升格为完整 helper 的统一 SLO。缓存命中、miss、未知布局及拒绝分别报告。

| 生产指标 | 具体候选 / 当前缺口 | 冻结条件 |
| --- | --- | --- |
| 版本超时拒绝的 helper 测试上限 | **max ≤2.0 s**；旧生产诊断 max 1.235 s，修正活动检查后的 n=3 max 1.233 s；名义等待/清理 1.7 s，另预留 0.3 s 启动/I/O | 同条件每个样本都计清理、验证子进程已回收且无副作用。它是测试预算，不是任意调度下的硬保证 |
| 适用 Git 规则的迟缓失败路径 | **max ≤5.5 s，完整路径待验证**；名义容量 4.9 s 加 0.6 s 启动/I/O。暖版本＋Git 双超时组件观测 max 3.840 s | 组件已验证调用次数、回收与失败关闭；仍须完整编排/生产失败路径证据，不能用组件或损坏 `.git` 的快速失败替代 |
| Claude `UserPromptSubmit` / 短非交互的有效 timeout | **6 s 候选**；该版本一次性 hook 的 6 s/1 s 对照已执行超时，未写 Claudio 配置 | 仍须确认 helper 容量与目标事件/模式；不能将这一事件的协议 fixture 外推到其他事件或交互 |
| Claude 上述 timeout 后的回收及继续执行余量 | 修订为 **≤2.0 s 候选**；从 hook 进入到子进程消失及首个模型请求的测试总包络 **≤8.0 s 候选**。旧 **0.7/6.7 s 已被实测反驳，撤回** | 6 s 两次观测进程消失约 7.45 s、首请求约 7.48 s，故提出 2 s 余量；这是本机该 fixture 的讨论值，尚非宿主派发到释放或全部场景 SLO |
| Codex / WorkBuddy 及其他 Claude 事件的 timeout / 清理 | **未冻结**；WorkBuddy bundled executor 在忽略 TERM 反例中没有形成完整上限；原 6 s 只能作待测试输入，不能采用全宿主统一 8 s | Codex/其他 Claude 模式缺证据；WorkBuddy 还需解决或明确宿主限制及正常 helper 的取消合同。当前自有事件没有 Codex `SessionEnd`/`Interrupt`，也不能外推其较低上限 |
| 正常宿主阻塞 p95 | 暂无可冻结的绝对毫秒值；要求同条件逐事件/模式配对不退化，补齐基线后单独冻结 | 真实宿主派发到释放边界、正常退出及独立发起分母齐全；不得用 helper 墙钟、callback 下界或模型总时间替代 |

6/8/5.5 s 是修订后的局部容量提案，尚未取得其全部路径实测；第一阶段没有把这些数字写入 adapter。
如果实测不支持，继续留在预算点修订，不能进入实现后再靠缩短探测或放宽事件合同凑数。
**完整预算包仍缺正常真实宿主、生产完整路径及跨宿主/事件/模式释放与回收证据。**
2026-10-10 用户明确调整统一开工条件，批准 Core 表及版本失败 ≤2 秒，仅允许缓存本地实现与隔离
验证；该局部批准不冻结其他候选，也不开放宿主策略、生产启用或第三阶段。
需要确认的内容应一起记录：适用机器/场景、上述包络是否采纳、生产 helper 与宿主阻塞指标、各宿主
timeout、允许波动、真实宿主模式及外部证据。局部缓存开发授权不等于跨过生产启用和真实宿主验收闸门。

正确性预算建议：相同注入场景的结果分布、接收/副作用计数及拒绝原因完全一致；零 stdout/stderr；任何
新增丢弃、授权绕过、历史变化或失败掩盖均不接受。波动先比较同轮配对差值和三轮离散性，不能以不同证据层
的 p50 相减取得“收益”。真实模式要求发起分母中每个预期允许事件都可核对接收与相应结果；不因
锁忙/去抖快速退出而降低漏事件标准。未达到完整真实宿主证据时，不冻结宿主阻塞/timeout，不启用 async。

版本探测的 1 s timeout 不包含启动和清理；超时分支另等待 TERM 200 ms、KILL 500 ms，名义等待上限
为 1.7 s，另加启动/调度/I/O。版本失败即拒绝，不会再执行 Git，不能把两个失败分支简单相加。Git 的
0.5 s / 2 s 重试各有同样清理段，仅确认超时才重试，其名义等待总量为 3.9 s；如果之前版本成功但已接近
1 s，相关等待容量为 4.9 s，仍需另计进程启动、调度及其他 I/O。该计算是单次版本与单次 Git
解析的容量检查，不是完整 helper 的墙钟硬上界。不能直接把 1 s 写成失败 SLO，也不能据平均热路径擅自
选择 2 s 宿主 timeout。第一阶段不新增总期限看门狗。

## 检查与未完成闸门

| 检查 | 本轮结果与边界 |
| --- | --- |
| `swift run --package-path helper claudio-tests` | 补测后 **5,233 checks / 0 failures**；新 fixture 首次触发三项原子写台账失败，已改原子初始化、按路径登记一次调用点后完整重跑。包含 observer、共同仓库身份和 submodule 回归；未弱化原断言 |
| `bash scripts/test-hook-cli-contract.sh` | PASS；完整 fixture 后验证 played/静音/去抖/不可播放/失败/拒绝与零输出；Release 无测试根覆盖入口 |
| `python3 scripts/test-additional-host-cli-contract.py --debug-bin helper/.build/debug/claudio --release-bin helper/.build/release/claudio` | **159 checks passed**；包括 Kimi/OpenCode 的现有执行策略合同 |
| `python3 scripts/test-additional-host-migration.py` | **140 checks / 0 failures**；未运行 `--acceptance` 特别构建 |
| `python3 scripts/embed-opencode-plugin.py --check`、`node scripts/test-opencode-plugin.mjs` | 内嵌一致性通过，**37 场景通过**；不是 OpenCode 真实会话 |
| Release `-Osize` benchmark/helper | 构建通过；正式采样 **9,620 个测量事件全部有效**；原始文件与 metadata 的源码/二进制摘要齐全 |
| 默认 SDK 的 GUI harness 构建 | SDK 27 缺少 SwiftUI macro 插件，构建失败；不能记为通过 |
| 使用 SDK 26.5 的 GUI Debug build | 原构建及此次补测 **通过**；`--build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` |
| 使用 SDK 26.5 且设置 `SDKROOT` 的完整 GUI harness | **24,104 checks / 0 failures**，`gui-tests-controlled-full.log`；所有原断言保留。初次 24,088/18 的失败记录亦保留 |
| 两项嵌套编译探针 | 加一致的 `SDKROOT` 后独立正反探针及完整 harness 均符合预期；外层 `--sdk` 不会自动为嵌套 compiler 统一环境 |
| 原生详情的 16 项失败 | 全部落在同一 guard：30 ms RunLoop/layout 后未能同时取得滚动区、document 与包含完整 session ID 的原生 `NSTextField`，随后跳过对应滚动与集合断言。旧失败日志未分项记录，不能断言究竟哪项缺失。最小 seam、async yield、modal/stress 前缀、真实 AppKit 事件循环、原 attention 链及完整重跑均通过。触发原因未证明，不称为已修复；展示源码与该 suite 字节均未改 |
| GUI 聚焦入口 | 新增 `--event-notice-presentation` 与 `--event-notice-presentation-live`，均 **97 checks / 0 failures**；后者使用真正 AppKit 事件循环。未延长 30 ms、重试或弱化断言 |
| 生产版本超时诊断 | 旧批次 **20/20** 的活动不变未验证；修正后独立 **3/3** 确认回执和实际活动不变、子进程消失、零输出，max 1232.909 ms。非真实宿主 timeout |
| 实时重放默认保护 | `python3 scripts/test-release-replay-safety.py` **14 tests / 0 failures**；包含安全默认、真实目录 summary/pending 检测和仅内存复用 API 环境；全部使用隔离 fixture，不访问真实用户状态 |
| Git 超时组件 | **20/20** 有效；两次回收、失败关闭、版本正常成功。最大 3.840 s；不宣称完整 hook/CLI 预算通过 |
| Claude 正常短会话 | **1/1** 发起及完成、一个 `played`，helper 零输出；用户听音未确认。没有正常路径 p95 |
| Claude timeout 协议 fixture | 6 s 两次、1 s 一次，三次子进程均在首模型请求前消失；回收观测余量约 1.45 s，撤回旧 0.7 s 提案；假 API / 假 hook 不替代正常会话 |
| WorkBuddy timeout 反例 | 1 s timeout 下，忽略 TERM 的 hook 到驱动器结束时仍活着（年龄 14.084 s）；静态 `killed` 误用与独立 Node 对照一致，完整上限未成立。未修改宿主；不是桌面 executor 验收 |
| 真实宿主记录器的超时分母 | 隔离 mock 验证在 helper 超时前已记回调发起、超时后保留发起数；不是额外真实宿主或音频证据 |
| Python 语法、shell 语法、本地化 JSON、Swift 格式、`git diff --check` | 最终检查通过 |
| 原子 fixture 修正后的 Release benchmark | 新构建通过；12 场景各一对的 **24** 个 Core smoke 及 **2** 个 Git 组件 smoke 均有效、stderr 0 字节；仅验证新构建，不混入正式分位数 |

GUI 的可复跑兼容环境命令（已通过完整门禁，旧 16 项失败的触发条件仍未确认）：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  swift run --package-path gui --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk claudio-gui-tests
```

完整 GUI 运行时有负向扫描 fixture 故意打印失败条目再撤销计数，以最终 24,104/0 为准；不能仅凭
日志中的 `✗` 字符计数宣布门禁失败。旧原生断言的间歇性问题仍须保留诊断，不由重跑绿灯反推根因。

未完成的验收证据包括 Claude 足量正常样本与交互边界、Codex 正常短会话及交互、相同新 helper 的
WorkBuddy 桌面及正常 engine 会话、足量隔离生产 helper 各场景样本、完整 Git 失败路径与跨宿主
timeout/回收、并发取消/乱序送达、
旧 GUI 失败的可靠复现、首帧出声及双架构/签名/公证。未封包、未替换 GUI/helper 二进制、未执行
Release 分发或正式验收；为后续小样本诊断启动了现有本地检查包，并验证其真实可执行文件身份。

本轮开工前已有的唯一未跟踪评估草稿已备份；当前新增/修改均用于第一阶段。原稿历史测量仍保留出处。
基准产物、私人运行数据及构建日志只在忽略目录；脚本没有直接改写安装配置与宿主信任数据。
用户明确暂时没有隔离环境，本次没有继续生产接收路径批量重放、建立新账户或 VM。
批量实时重放的回执/活动副作用见上文，不能将“未改配置”描述成“未改用户状态”。
共享工作区在本次收尾期间另有重放安全修复提交 `8934524`；已保留该修复及其测试，本任务未执行
commit/push。正式编译基线仍由 `feb142b`、逐文件摘要与二进制摘要确定，不把新 HEAD 当作旧构建身份。

第一阶段代码与自动基准交付不代表整个规格完成，也不构成软件发布或正式验收。预算及缺失的真实宿主证据
需要独立确认；任何后续实现都须重新核对工作区并单项保留前后对照。没有 commit、push 或软件发布。

后续用户仅放行版本缓存的本地实现与隔离验证；其复审、真实签名完整 Core 数据和未执行试用方案见
[版本缓存复审报告](hook-version-cache-review-and-native-baseline-2026-10-10.md)。
新增冷路径数值仍为待确认提案，不自动修改本文件已批准的 Core 包络或 ≤2 秒版本超时拒绝上限，
不开放宿主策略、生产启用或回执热路径优化。
