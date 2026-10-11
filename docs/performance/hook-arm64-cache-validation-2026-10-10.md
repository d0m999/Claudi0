# arm64-only 分发与版本缓存隔离复验

2026-10-10。用户明确选择只支持 Apple Silicon，见 [ADR 0032](../adr/0032-support-apple-silicon-only.md)。
本轮继续版本缓存的本地优化和隔离验证；生产缓存、宿主执行策略、回执热路径第三阶段及生产冷预算
仍未放行。没有安装或启动候选 app，没有接受真实生产 hook，也没有改写现有回执历史、活动计数或宿主配置。
本轮没有 commit、push、发布或触发远端 CI。

## 支持范围与发布合同

- 正式 Release、本地 bundle 和公开预览的 GUI/helper/LoginItem 均只构建 arm64。
  实际 Mach-O 门禁拒绝 x86_64-only、universal、空/未知架构及三个组件架构不一致。
- 原 GUI 7,000,000 B、helper 3,250,000 B、LoginItem 500,000 B、普通资源 3,100,000 B
  预算保持不变；不能借用原 Intel 切片的预算。macOS 12 floor、GUI exports、签名及公证要求不变。
- Sparkle 上游 framework 保留原 universal 字节和独立 3,500,000 B 预算，不裁剪厂商依赖。
  预览 manifest 必须精确声明 `['arm64']`；生成后检查已签名 appcast 的候选项必须有唯一的
  `hardwareRequirements=arm64`，不在签名后修改 XML。旧 feed 项保持原样。
- Cask 与 Release workflow 生成的 Cask 同步增加 `depends_on arch: :arm64`，写法参照
  [Homebrew Cask Cookbook](https://docs.brew.sh/Cask-Cookbook#stanza-depends_on)。
- 核对 [GitHub runner 文档](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)：
  当前 `macos-15` 标准 runner 为 arm64，现有 Release/preview runner 标签适用，无需改成 Intel 标签。
- README、贡献指南、分发/安装指引、当前验收矩阵和本地 pre-RC 合同已同步。
  历史 Intel/universal 失败与测量数据保留，并标明已被当前支持范围决定取代；不改写成通过。

本地 arm64-only 构建不再需要 Intel 机器、Rosetta 或新的 Xcode 安装。当前隔离 Core 验证使用临时根，
也不要求新账户/VM。生产 Release helper 的批量接受事件测量仍须独立保护用户状态，当前没有执行。

2026-10-10 后续冻结复验见 [Git 长尾定位与缓存候选去留](hook-git-tail-and-cache-decision-2026-10-10.md)。
新快照 GUI 全量为 24,131 / 0；定向 Core 配对仍未通过原预算，不能覆盖本报告的历史失败或冷路径限制。

## 精确产物与门禁

工作区 HEAD 为 `52a5a5f9975edb93cc93d0a817e025f6b725f03c`，含先前 hook 实现及并行 GUI 改动。
本轮先保存修改前源树，再在仓库外冻结源码构建，避免其他线程的编辑混入候选。
`dist/arm64-hook-cache-2026-10-10/` 保存源文件摘要、构建日志、前后 benchmark、原始样本和检查结果；
`candidate-source.json` 标识实际构建源树，不将脏工作区的 HEAD 当作全部源码身份。
检查 DMG/manifest 另保存在任务目录的 `candidate/`；冻结产物源码与 benchmark 源码分别保存在
`candidate-source.zip`、`benchmark-source.zip`，不依赖临时工作区长期保留。

本机为 Apple Silicon，macOS 27.0.1、Swift 6.4 / Command Line Tools；装包显式选用已安装的
MacOSX26.5 SDK 与 native build system。GUI/helper 保持 Release full LTO + `-Osize`；LoginItem
保留原 Release 参数。`build-preview.py --inspection` 已生成 `0.0.1` 本地 DMG，实际挂载后再次核对
架构、体积、版本、动态依赖和 ad-hoc 签名；三个可执行文件的 Mach-O `minos` 均为 12.0。

| 最终签名后的产物 | 实测字节 | 原上限 |
| --- | ---: | ---: |
| GUI | 6,925,552 | 7,000,000 |
| helper | 2,747,056 | 3,250,000 |
| LoginItem | 54,208 | 500,000 |
| 普通资源 | 2,502,910 | 3,100,000 |
| Sparkle | 2,705,105 | 3,500,000 |

GUI 剩余 74,448 B，不提高预算；后续 GUI 改动须重新装包检查。DMG 为 8,336,198 B，
SHA-256 `f8abd8f4952cd7b9a2ee25cb30411cd8b313597b85ec0cb24a54206e8a449345`。
manifest channel 为 `local-inspection`，公开发布验证器会拒绝它。此包没有安装、启动或正式签名/公证，
不证明 macOS 12 实机兼容、系统放行、真实升级、听音或真实宿主回调。

首次打包在动态链接校验器处失败：`otool -L` 的首行包含被检查文件自身的绝对路径，原逻辑将其
误认成构建目录依赖。修复后仅解析真实依赖行，并继续拒绝构建路径、私有绝对依赖及空/不可解析输出。
三组正负例先失败后通过；完整检查包重跑通过，原失败日志保留。

## 缓存改动的范围与兼容性

本次唯一 Core 实现改动是 `HostVersionResolver.digest` 的等价编码优化：SHA-256 的每个 byte
直接映射为两个小写十六进制字符，省去 32 次 `String(format:)` 调用。schema、版本值、调用路径、
身份依赖、TTL、失效规则、非阻塞锁和签名资格均保持不变。`kSecCSCheckAllArchitectures` 与
`kSecCSStrictValidate` 保留；Claudio 改为 arm64-only 不会缩减宿主签名校验强度。
默认 resolver 仍为 `cacheDirectory: nil`，没有启用生产缓存。

独立组件诊断核对 258 组输入输出完全一致；每次摘要计算及编码 p50 从 26.704 µs 到 0.750 µs。
该微基准运行期间有 GUI harness，不能作为完整 hook 的收益或预算证据。
另外用修改前后两个独立 executable harness 做双向读写：Claude Code 和 Codex 各两种顺序，
四组全部通过；首次各调用一次注入的探测和签名端点，后续命中均零探测、零签名，缓存 bytes 与 mtime 不变。

## 配对测量

前后 benchmark 均为 Release full LTO + `-Osize`，使用同一个 `handleHostHook` 编排入口。
Core 默认每组预热 10、测量 100、三轮；内部固定种子交替 probe/observer，外层按轮和场景交替
前后两个冻结二进制。原始样本、p50/p90/p95/max、结果计数和源码/二进制摘要均保留；没有扣除
空进程基线。所有接收、播放启动、当前回执、归档、提示及活动计数在前后对应分组完全一致。
这些是临时根的 Core 调用，不是生产 CLI 进程边界、真实宿主阻塞或真实出声测量。

首批在 `not-ready` 的优化后 fixture 冷填充处失败，尚未产生该组计时样本；整个未完成批次保存在
`paired-core-first-excluded/`，不纳入统计。两构建各复验 10 次均通过，原始原因仍未确定，不能归因于
并发负载或编码改动。随后仅给 benchmark 的准备失败补充有限结果分类，保留原断言与立即失败行为，
没有重试、输出版本内容/路径或更改生产探测。原优化二进制与诊断增强后的二进制均保留。

第二批完成 **32,480** 个有效样本，涵盖 12 场景的 bypass/hit、满载 miss/force/unknown 和两类超时。
本轮自己的构建/GUI 已停止后才开始，但环境监控随后观察到其他编译和 GUI harness，记录在
`paired-core-environment.json`。共 13 个前后/分支分组的最差单轮 p95 超过原预算，分布于
full-empty、muted、not-ready、workspace-plain、workspace-git、git-damaged 六个场景；
此批次不能标为预算全绿，也不以外部负载为由删除失败。以下单位 ms，observer 关闭，每格 n=300：

| Core 场景 | 前命中最差轮 p95 | 后命中最差轮 p95 | 原上限 |
| --- | ---: | ---: | ---: |
| full-empty | 10.386 | 10.117 | 15.50 |
| full-steady | 14.506 | 14.854 | 27.29 |
| muted | 17.258 | 11.384 | 30.12 |
| debounced | 10.254 | 11.280 | 21.42 |
| not-ready | 10.583 | 16.862 | 18.52 |
| authorization-off | 0.067 | 0.064 | 0.13 |
| gui-exited | 0.082 | 0.077 | 0.22 |
| stale-installation | 1.584 | 1.413 | 8.41 |
| lock-busy | 10.730 | 17.527 | 39.04 |
| workspace-plain | 20.747 | 20.353 | 18.62 |
| workspace-git | 59.647 | 56.824 | 35.01 |
| git-damaged | 26.609 | 25.306 | 31.10 |

命中组的 workspace-plain / workspace-git 前后都超界；其余超界来自 bypass。
满载 miss/force/unknown 的前后分组均未超出原 27.29 ms 上限。
超时诊断共 80 行；关闭 observer 的优化后最长为 **1,224.086 ms**，包含忽略 SIGTERM 后的清理，
低于已批准的 2,000 ms 测试上限；各样本确认子进程清理、拒绝事件且零业务副作用。

observer 单列：满载 hit 的开启减关闭配对差值，每构建 n=300，前 p50/p95 为 **0.087/2.042 ms**，
后为 **−0.016/2.629 ms**。差值包含 I/O 与调度噪声；负中位数不能解释成 observer 提速，
这批结果不足以精确量化其纯开销。原始开/关样本与配对差值均保留，预算只比较关闭组。

### 定向复测

六个超界场景完成一次独立三轮配对复测，共 **14,400** 行，每格 n=300。处理计数仍完全一致。
监控未观察到 GUI harness/编译并发，但仍有以下 7 个分组超界，单位 ms；不能据此认定并发编译
是此前超界的唯一原因。原批次、复测分别保留，不合并统计或继续重复直到出现绿灯。

| 构建 / 场景 / 分支 | 最差单轮 p95 | 原上限 |
| --- | ---: | ---: |
| after / git-damaged / cache-bypass | 37.389 | 31.10 |
| after / git-damaged / cache-hit | 46.356 | 31.10 |
| after / workspace-git / cache-bypass | 35.205 | 35.01 |
| before / full-empty / cache-bypass | 18.909 | 15.50 |
| before / not-ready / cache-bypass | 19.502 | 18.52 |
| before / workspace-git / cache-bypass | 35.886 | 35.01 |
| before / workspace-git / cache-hit | 37.548 | 35.01 |

所以 **Core 性能预算验收未通过**。版本超时拒绝上限通过不代表所有场景通过，体积门禁通过也不能
替代性能门禁。本地编码优化保持待评审候选，不能据此启用生产缓存。

阶段数据提供了有限定位：优化后 `git-damaged/cache-hit` 的一个 observer 开启样本总耗时
68.534 ms，其中 workspaceAndSound 为 51.252 ms、versionResolution 为 2.373 ms，探测与签名
调用均为 0。另一个 63.844 ms 样本分别为 37.214/13.443 ms；波动不只出现在签名或版本子进程。
这些数据只解释相应 observer 开启样本，不能替 observer 关闭组的 120.503 ms 极值证明根因。
未修改 Git 身份解析、预筛、工作区规则或回执路径来凑数；下一步应先定位这类阶段波动。


### 真实签名参与的完整隔离 hook

Claude Code `2.1.282`、Codex `0.162.1` 的真实二进制和路径/元数据身份在前后核对一致。
本批每个宿主/模式/observer/构建预热 2、测量 10、重复三轮，共 **1,440** 行；下表关闭 observer，
每格 n=30，单位 ms。这是明确减小样本量的诊断复验，不替代默认 100×3 的生产预算验收。
监控未观察到 GUI harness/编译并发，但不代表机器其他负载完全受控。

| 宿主 / 路径 | 前 p50 | 前 p95 | 后 p50 | 后 p95 | 后 max |
| --- | ---: | ---: | ---: | ---: | ---: |
| claude-code / bypass | 17.533 | 31.858 | 17.338 | 34.716 | 39.463 |
| claude-code / hit | 6.549 | 12.646 | 6.603 | 7.571 | 13.473 |
| claude-code / cold | 602.827 | 693.220 | 606.850 | 659.610 | 777.205 |
| claude-code / expired | 601.455 | 715.024 | 608.721 | 744.088 | 825.499 |
| claude-code / force | 600.886 | 686.826 | 604.993 | 800.746 | 883.363 |
| claude-code / failed | 0.610 | 2.048 | 0.575 | 0.836 | 1.130 |
| codex / bypass | 18.910 | 24.129 | 18.518 | 20.790 | 22.294 |
| codex / hit | 7.167 | 7.954 | 6.726 | 8.225 | 8.721 |
| codex / cold | 168.910 | 181.280 | 167.743 | 178.647 | 183.079 |
| codex / expired | 168.911 | 179.537 | 167.190 | 184.280 | 194.535 |
| codex / force | 167.899 | 172.378 | 166.809 | 195.921 | 225.026 |
| codex / failed | 0.730 | 1.012 | 0.651 | 0.966 | 1.001 |


cold 指版本观察未命中，不控制 OS 文件缓存或 Security 内部状态。failed 使用受控探测失败，
验证拒绝及不复用旧值；它不是实际厂商 CLI 故障率测量。真实成功填充还在计时外验证下一解析器
可零探测/零签名命中，防止把未发布缓存的成功探测当作填充成功。

结论：摘要编码组件成本下降，但完整 hook 的中位数和尾部没有一致改善，**未证明稳定的端到端收益**。
Claude 命中 p50 基本不变，Codex p50 降约 0.44 ms 而 p95 略升；不能将微基准倍数应用于完整路径。
真实签名仍支配 cold/expired/force。缓存冷填充比原同步探测明显更贵；本次较短的 Codex 冷样本
也不能抹去前次 3.10 s 长尾。生产冷预算保持未冻结，生产缓存保持关闭。

复跑当前实现（会构建 benchmark；只用临时业务状态，真实签名组只读宿主身份并执行 `--version`）：

```bash
python3 scripts/benchmark-hooks.py --cache-comparison --output dist/hook-cache-new-core
python3 scripts/benchmark-native-hook-cache.py --host all --scenario full-steady \
  --samples 10 --warmup 2 --rounds 3 --output dist/hook-cache-new-native
```

本轮跨二进制配对顺序及原始前后产物另保存在任务目录的 `paired-cache.py`、`paired-cache-followup.py`
与 metadata 中。新运行使用新的输出目录；不能覆盖旧样本或把不同构建/测量边界合并成一个分布。

## 验证与仍未验证的边界

| 检查 | 本轮结果 |
| --- | --- |
| helper 全量 executable harness | 5,377 checks，0 failures |
| GUI 冻结源码全量 executable harness | 24,130 checks，1 failure；不得标为全量通过，原因见下文 |
| GUI 发布布局与 local pre-RC 专项 | 191 checks，0 failures |
| GUI Debug 构建 | 通过；本地工作区证据，源树见日志 |
| Debug CLI hook 契约 | 通过；临时 fixture、逐分支断言及零输出，非生产重放 |
| adapter 迁移普通/验收矩阵 | 140 / 132 checks，各 0 failures |
| Sparkle 版本/EdDSA/官方 appcast 两 DMG 回归 | 通过；临时测试密钥、真实 arm64 fixture DMG、签名及旧项保留 |
| preview provenance / 发布字节检查 | 通过；10 个发布回归及架构/feed 负例 |
| Sparkle 依赖路径解析回归 | 3 tests 通过；保留红灯记录 |
| benchmark driver 回归 | 11 + 6 tests 通过 |
| Cask Ruby、Python/shell 语法、JSON/本地化 | 通过 |
| actionlint / diff 检查 | 三份 workflow 通过；`git diff --check` 通过 |

首次工作区 GUI 全量为 24,113 / 1：旧 local pre-RC 文档断言还要求“Intel 真机”，已按 ADR 0032
改为 arm64-only。随后的工作区编译遇到另一个线程正在修改 GUI 源文件，因此切换到冻结源树。
冻结全量唯一失败来自并行开发的 `IntegrationAgentSectionSuite.swift:21`：旧断言同时要求桌面组
在前和扁平结果保持原全局顺序。检查时工作区中该断言已由并行改动修正为分组顺序；本轮没有修改它。
`ReleaseLayoutSuite` 和 `LocalPreRCSuite` 在冻结构建上独立 191 / 0，不能用专项结果覆盖全量失败。
完整全绿 GUI 验收仍须绑定后续稳定源树，当前候选没有被宣称为正式验收通过。

远端 CI、Developer ID/公证、macOS 12 实机、旧 Intel 安装的实际升级
排除、真实宿主/听音及生产 helper 批量基线均没有由本轮本地证据替代。
现有正式 workflow 仍固定 Xcode 16.4，GUI CI/preview 固定 26.3；这项既有工具链差异没有由本轮
CLT 构建验证，须在授权后的 CI 另外核对，不能把本机成功推定为远端正式构建成功。

此前全量 helper 扫描误把 `dist` 下旧冻结工作区纳入生产源码：原 21 项失败日志保留。
本轮将该任务自己的冻结工作区完整移到仓库外，核对 1,151 个非构建文件摘要不变，记录在
`dist/hook-release-readiness-2026-10-10/workspace-relocation.json`。随后 helper 全量通过；
没有删除历史证据，也没有移动用户回执、声音包或活动数据。
