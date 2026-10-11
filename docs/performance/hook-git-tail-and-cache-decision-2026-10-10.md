# Git 长尾定位与版本缓存候选去留

2026-10-10。结论：GUI 自动化验证已补齐，当前冻结快照的 arm64 体积门禁通过；Core 性能预算仍未通过。
版本观察的热命中有收益，但不建议继续将当前“hook 内同步冷填充”候选推向生产。保留本地候选和证据，
后续如继续投入，应先评审冷填充的触发位置，再做独立实验；本轮没有实施该设计。

## 授权与快照

本轮只冻结源码、补齐 GUI 验证、定位 `git-damaged` / `workspace-git` 长尾并评估缓存候选。
Git 算法、共同仓库身份、签名检查强度、TTL、超时、性能与体积门禁均未改变。
生产冷预算未冻结；生产缓存、宿主执行策略和回执热路径第三阶段继续暂停。
本任务没有修改生产源码、安装或启动候选 app、调用真实宿主 hook，也没有改写现有回执历史、活动计数或宿主配置。
没有 commit、push、发布或触发远端 CI。

冻结时 HEAD：`c8d8edb95189cf7994e92be01cce5375edc11f5a`，工作区有既有未提交改动。
实际源树为 1,029 个文件，摘要 `57d4e9918f400beab458d04d14cb9cdfcf122654fe7d3023d5c687333f45fbfb`。
复制时核对源文件前后身份，结束时再次核对全部冻结文件一致，不能用 HEAD 单独代表脏源码。
期间其他任务推进了主工作区 HEAD，并修改了 `scripts/test-panel-settings-prototype-browser.py`；
这些后续变化没有混入冻结测试，本任务没有覆盖它们。详情见 `snapshot-final-verification.json`。

证据保存在忽略目录 `dist/hook-git-tail-diagnosis-2026-10-10/`，下文文件名均相对该目录。
`source.zip` 与 `source.json` 保存源文件和 symlink 元数据；临时工作区位于仓库外，避免源码扫描误纳入副本。
本机为 arm64、macOS 27.0.1、Apple Swift 6.4 / Command Line Tools。
构建显式选择已安装的 MacOSX26.5 SDK 和 native build system；二进制另保留实际 build-version 记录。

## GUI 与本地装包

| 检查 | 当前冻结快照结果 |
| --- | --- |
| Question integration 专项 | 3,007 checks，0 failures |
| GUI 全量 executable harness | 24,131 checks，0 failures |
| GUI Debug 构建 | 通过 |
| arm64 本地 ad-hoc bundle | 架构、体积、exports、动态依赖及签名检查通过；未安装或启动 |

上次报告中的 GUI 单项失败属于旧冻结快照。当前快照已包含并行 GUI 工作对分组顺序断言的修正，
本任务没有改该测试；本次全量绿灯绑定当前源树，不改写旧快照的失败记录。
首先尝试复用移动后的编译缓存，因 Clang PCM 保留原 module-cache 路径而失败，保留
`gui-copied-cache-failed.log`。随后使用新的 scratch 目录，只复用依赖下载，干净编译通过；
没有修改源断言或弱化检查。专项、全量和 Debug 日志分别为 `gui-focused.log`、`gui-full.log`、`gui-debug-build.log`。

装包使用当前快照的普通 dev-bundle 公开预览编译条件，GUI/helper 为 Release full LTO + `-Osize`。
任务专用 wrapper 仅调整 SwiftPM scratch 路径，差异保存在 `bundle-scratch-overlay.diff`；
仓库原脚本没有因此变更。当前最终 ad-hoc 签名后字节数如下：

| 产物 | 实测 B | 未变上限 B |
| --- | ---: | ---: |
| GUI | 6,925,552 | 7,000,000 |
| helper | 2,747,056 | 3,250,000 |
| LoginItem | 54,208 | 500,000 |
| 普通资源 | 2,502,910 | 3,100,000 |
| Sparkle | 2,705,105 | 3,500,000 |

三个 Claudio 可执行文件均为精确 arm64；上游 Sparkle universal 字节保持原样。
`bundle-binaries.json` 保存二进制摘要和 Mach-O 记录：三个组件 `minos=12.0`、`sdk=27.0`。
GUI 剩余 74,448 B。`bundle-size-check.log`、`bundle-build-result.json` 保留原门禁输出。
这是未安装、未启动的本地检查包，不是 Developer ID 签名、公证或 macOS 12 实机证据。

## 未插桩配对测量：预算仍失败

保留的当前 benchmark 与本快照全部 97 个 `helper/Sources` 文件集合和字节一致，复用已经构建的
Release full LTO / `-Osize` / arm64 二进制，核对摘要后测量，避免测量窗口内重新编译。
前后 Core 只差 SHA-256 小写十六进制编码；benchmark 准备阶段另差有限失败分类。
准备和结果断言均在计时外；成功样本的编排及计时边界相同。精确差异见 `paired-source-differences.diff`。

| 用途 | SHA-256 |
| --- | --- |
| 旧编码 benchmark | `4b8027a946900368da9b07aeb952f33e4668d30d2e564f586e737aead2fcd59c` |
| 当前 benchmark | `06891d65bd9eaf04ad65d4f45d48dff41ed8522a9f3b70f80722acf165d67f99` |
| 诊断插桩 benchmark | `ea24ca936879b2d84408e5dac83a397efadda29e19e01d4b0cb28d8f3a81fe22` |

每场景、版本、probe/observer 组合预热 10 次，测量 100 次，外层重复三轮；每格 n=300。
外层交替前后版本，内部使用固定种子 `0xC1A0D10` 交替 probe/observer；没有扣除空进程耗时。
均在临时环境调用 `handleHostHook`，播放器和提示为注入端点；它们不是生产 CLI 或真实出声测量。
每个样本核对接收、播放启动、回执、归档、提示、活动、探测/签名次数及预期分支，不能以提前拒绝冒充成功。

首批完成 7,200 行后在第三轮 `git-damaged/after` 的计时前冷填充 fixture 失败，探测结果为 `timed-out`。
失败任务没有计时样本；整个不完整批次保留在 `paired/`，排除于预算验收。驱动器当时只在正常结束
保存环境监控，异常丢失了之前的监控历史。失败后观察到其他 GUI/编译进程，但缺少当时连续记录，
不能认定它们造成该次超时或所有长尾。原 stderr、`paired-incomplete.json` 均保留。

修正任务驱动器，使每个任务结束及异常时保留监控，并在观察到构建/GUI 并发后完成当前任务再停止。
没有删除失败样本或增加探测重试。之后单独运行一次替代批次，不重复到绿灯。
`paired-quiet/` 完整 **9,600 行**，前后对应处理计数完全一致，二进制摘要未变。
每 0.5 秒的进程监控未观察到编译或 GUI harness 并发；这不代表机器其他负载、I/O 或调度完全受控。

以下为 observer 关闭组，单位 ms。验收沿用**最差单轮 p95**，不能用合并 p95 替代。

| 场景 / 分支 | 前 p50 | 后 p50 | 前最差轮 p95 | 后最差轮 p95 | 原上限 |
| --- | ---: | ---: | ---: | ---: | ---: |
| workspace-git / cache-bypass | 27.739 | 25.983 | 66.911 | 42.371 | 35.01 |
| workspace-git / cache-hit | 22.907 | 21.542 | 58.183 | 39.398 | 35.01 |
| git-damaged / cache-bypass | 23.794 | 25.062 | 50.335 | 49.214 | 31.10 |
| git-damaged / cache-hit | 19.429 | 20.293 | 27.872 | 35.623 | 31.10 |
| workspace-plain / cache-bypass | 12.438 | 12.295 | 17.632 | 24.208 | 18.62 |
| workspace-plain / cache-hit | 7.846 | 7.686 | 10.556 | 15.897 | 18.62 |
| full-steady / cache-bypass | 11.549 | 11.181 | 29.925 | 15.299 | 27.29 |
| full-steady / cache-hit | 6.822 | 6.574 | 10.881 | 13.648 | 27.29 |

16 个前后分组中 **9 个失败**，其中当前候选 5 个失败。完整 p50/p90/p95/max、分轮和计数在
`paired-quiet/summary.json`；失败列表在 `failures.json`。例如当前 healthy Git 命中合并 p95
27.326 ms，但最差轮 39.398 ms，仍不通过 35.01 ms 上限。
没有 Git 的 `full-steady` 当前 bypass/hit max 也达到 113.179 / 110.705 ms，
所以不能把所有全路径极值解释成 Git。摘要编码前后的整体收益不一致，不能将微基准改善当作端到端验收。

## 诊断插桩：定位到 Git 命令等待，未证明单一 OS 根因

另复制一份诊断源树，仅加入有限单调时钟跨度：工作区身份、路径规范化、`.git` 检查、Git 命令、
`Process.run()`、管道排空、退出回调等待。生产源树没有这些新增跨度。
差异及源码摘要为 `diagnostic-overlay.diff`、`diagnostic-source.json`；该二进制不是生产候选。
Git 命令参数、`--git-common-dir`、环境净化、0.5 秒首尝试、仅确认超时才 2 秒重试和失败关闭均保持原样。

两场景完成 **2,400 行**，计数均符合预期，未观察到编译/GUI 并发。
以下只分析开启 observer 的 1,200 行，每场景/分支 n=300，单位 ms；不能与上面的预算数据合并。
新增诊断跨度的纯开销未单独量化，它们仅用于定位。

| 场景 / 分支 | Git 命令 p50 / p95 | 排空到 EOF p50 / p95 | `Process.run()` p95 | 退出等待 p95 |
| --- | ---: | ---: | ---: | ---: |
| git-damaged / bypass | 13.173 / 24.045 | 12.753 / 23.100 | 0.727 | 0.102 |
| git-damaged / hit | 13.157 / 24.315 | 12.706 / 23.103 | 0.787 | 0.109 |
| workspace-git / bypass | 15.052 / 34.142 | 14.456 / 32.200 | 1.344 | 0.164 |
| workspace-git / hit | 15.071 / 30.843 | 14.584 / 30.373 | 0.985 | 0.159 |

每个已定位样本都只有一次 Git 命令，没有触发超时重试，不能把长尾归因于第二次 Git spawn。
常见波动集中在启动后排空 stdout 至 EOF 的等待区间，包含子进程运行、输出/退出和父子进程调度，
不等于复制 stdout bytes 的 CPU 成本，也不能据此判定 `poll` 算法有错。
通常路径规范化和 `.git` 检查很小；Git 命令之外的身份处理 p95 为 0.149–0.517 ms。
当前缓存命中版本解析 p50 为 0.809 / 0.850 ms，且零版本探测、零签名；Git 等待仍在。

按同一事件核对的反例和长尾如下，不能相加不同事件的阶段最大值：

- `git-damaged/bypass`，97.405 ms：Git 命令 82.610 ms，其中排空等待 82.086 ms。
- `git-damaged/bypass`，87.119 ms：版本解析 52.887 ms，Git 23.021 ms，说明非命中版本探测也会波动。
- `workspace-git/hit`，178.885 ms：版本解析 0.910 ms、Git 命令 126.172 ms（排空 124.361 ms），
  playbackLock 39.568 ms。该跨度包含原锁下的操作；不能把它误称为等锁 39.568 ms，原锁仍非阻塞。
- `workspace-git/bypass`，206.628 ms：Git 命令 122.226 ms，其中排空 54.921 ms、启动 6.628 ms、
  退出等待 0.056 ms；命令内未细分部分还有 60.621 ms。身份内命令外另有 45.316 ms，
  包含 `.git` 检查 15.040 ms。该极值没有完全定位到某一个底层调用。
- `workspace-git/bypass`，102.660 ms：工作区/声音解析中身份之外 20.706 ms，历史剪枝 12.272 ms。

结论的证据边界是：Git 子进程等待是这两个场景的主要常规成本及多条实测长尾来源；
极端样本还有命令准备/收尾、文件处理和锁内操作波动。当前数据没有区分内核 I/O、OS 安全检查、
CPU 调度、Git 进程内部或其他系统负载，不能给出单一底层 OS 根因。
也不能用插桩样本直接解释未插桩组的某一个极值。
`diagnostic-analysis.json` 保存逐组阶段分布及同一事件的慢样本；包含区间不跨层相加。

## 缓存是否值得继续

当前 Core 各场景 bypass 与 hit 的分组 p50 差为 4.44–4.77 ms，结果计数保持一致，说明热复用机制有价值。
它不是实际厂商 CLI 的节省值。本轮没有重新执行真实签名 cold 测量；
以下复用[上轮真实签名完整隔离 hook](hook-arm64-cache-validation-2026-10-10.md#真实签名参与的完整隔离-hook)
证据，每格 n=30，不是本轮的新样本或生产预算。

| 宿主 | bypass p50 ms | hit p50 ms | cold p50 ms | 热命中节省 ms | 冷路径额外成本 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Claude Code | 17.338 | 6.603 | 606.850 | 10.734 | 589.513 |
| Codex | 18.518 | 6.726 | 167.743 | 11.792 | 149.224 |

若只有一次 cold，之后在 10 分钟有效期内连续有效命中，用中位数做理想算术估计，
`N × bypass >= cold + (N-1) × hit`，Claude 至少 56 次、Codex 至少 14 次事件才抵消冷填充成本，
这里 N 含首次 cold。它没有纳入 miss、升级、极值或真实工作负载；没有实际事件密度证据，不能作为产品收益承诺。
上轮 Codex 较早的 3.10 秒冷长尾仍保留，不能用这组短样本抹去。

建议停止推进当前同步冷填充路径的生产化，也不继续围绕摘要编码做微优化。
如果继续缓存实验，下一步先形成并评审一个设计候选：在既有连接/修复/版本诊断生命周期完成严格签名检查
和缓存填充，hook 只复用逐次验证合格的命中；miss 继续原有有界真实探测，不在 hook 中承担签名填充。
这会调整当前冷填充策略，须先明确与 ADR 0031 的关系、刷新触发和资格失效，再独立隔离验证。
**本轮没有实现或授权启用这个新策略**，也没有增加后台进程、daemon、看门狗、放宽签名或延长 TTL。
Git 算法继续不动，当前 Core 门禁失败和生产冷预算未冻结必须保留为推进条件。

## 复跑、核验与未执行项

本轮脚本均保存在证据目录，使用新的目录后缀才能复跑，防止覆盖旧批次。
配对脚本使用保留的确切二进制；诊断脚本使用其专用插桩二进制，绝不能冒充发布 helper。

```bash
CLAUDIO_DIAG_BATCH_SUFFIX=-rerun python3 dist/hook-git-tail-diagnosis-2026-10-10/run-targeted.py paired
CLAUDIO_DIAG_BATCH_SUFFIX=-rerun python3 dist/hook-git-tail-diagnosis-2026-10-10/run-targeted.py diagnostic
```

诊断分析器默认读取已完成的 `diagnostic/` 批次；复跑后应显式调整输入并生成新的输出，不能覆盖本轮统计。
源树、诊断 overlay、构建命令、二进制摘要、样本和环境监控均已保留。
冻结源文件最终核对、三个 benchmark 摘要复核、本地化 JSON 和 `git diff --check` 通过。
本轮未改生产 helper，未重复执行 helper 全量、CLI 契约或 adapter 迁移；
其上次结果仍属于上次快照，不冒充本轮重跑结果。版本超时拒绝 ≤2 秒测试本轮没有重跑。
真实宿主回调、人工听音、确切生产 Release helper 批量测量、远端 CI、正式签名/公证、
macOS 12 实机和正式验收均未由本轮证据补齐。生产冷预算继续未冻结。

现有回执历史和活动计数没有被本轮测量使用或更改；所有接受事件均指向临时 fixture 根。
没有清理历史、不完整样本或原失败日志。工作区既有改动继续保留。
