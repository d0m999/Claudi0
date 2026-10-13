# HostVersionResolver：本地实现与隔离验证

> 2026-10-13 文档归档：下文保留当时的候选、授权与验证状态；其中“未提交／未推送”描述记录时点。
> 后续提交状态与暂停范围见 [2026-10-12 收束记录](hook-performance-roi-closeout-2026-10-12.md)。本次归档不重新验证历史结果或重启实验。

2026-10-10 用户明确批准：采用[基线报告](hook-path-baseline-2026-10-10.md)的 Core 分场景预算、
版本超时拒绝路径 ≤2 秒测试上限，仅放行版本缓存本地实现与隔离验证。宿主策略、生产启用和第三阶段
继续暂停，不动现有回执历史和活动计数。本报告不替代真实宿主、人工听音、生产完整路径或正式验收。

后续复审与真实签名完整 Core 测量见[独立报告](hook-version-cache-review-and-native-baseline-2026-10-10.md)。
本文件保留上轮构建和测量来源；后续结果不与本文件的签名 fixture/版本组件样本混合。

## 实现边界

`HostVersionResolver` 是 Claude/Codex 版本观察的唯一缓存 owner，提供 `reuseValidated` 和
`forceProbe`。`HostActivationScope` 继续结合版本输出、Claudio 版本与 binding 构建完整 scope。
默认 `cacheDirectory == nil`；现有 CLI、接入维护及诊断没有传入缓存目录，保持真实同步探测。
本地显式注入 resolver 的 hook 工厂才可复用缓存，仍保留每次调用内的 scope snapshot 和所有实时授权复验。
没有新增生产配置项、测试根覆盖、宿主 async/timeout 或部署动作。

缓存只接纳下列布局：

- Claude 原生 `~/.local/share/claude/versions/<稳定三段版本>`，真实输出须与目录版本一致。
- Codex standalone `bin/codex` 及 layout 1 的 `codex-package.json`，要求已识别的 macOS target、
  `variant`、`entrypoint`、资源目录字段，真实输出须与元数据版本一致。

Claude 安装位置参考[官方安装排障文档](https://code.claude.com/docs/en/troubleshoot-install)；
Codex 布局参考[上游打包代码](https://github.com/openai/codex/blob/main/scripts/codex_package/layout.py)。
本机签名身份只读核对为 Claude `com.anthropic.claude-code` / `Q6L2SF6YDW`、Codex `codex` /
`2DC432GLL2`。代码通过 Security API 验证 Apple 信任锚、identifier、Team ID 及完整签名；没有每事件
`codesign` 子进程。签名检查仅在成功探测后、冷填充或强制刷新时执行，失败探测不承担签名成本。

每次命中重新定位原始调用路径，比较实际目标、路径链 inode/权限、文件大小、纳秒 mtime/ctime、
Codex 元数据身份和内容摘要。保留原始调用路径执行 `--version`，不改变 shim 的 `argv[0]`。
探测或签名验证期间依赖变化则拒绝结果；发布前再次核对。未知布局、npm、wrapper、shim、未知版本
格式或不合资格签名继续真实探测，不获得缓存资格。探测失败不使用旧值；缓存发布失败不废弃成功探测。

每宿主一个不超过 16 KiB 的私有文件，最多四条观察；内容只有版本文本、身份摘要和两个时间戳，
没有完整 scope、回执、事件内容或私人路径。目录 `0700`，文件 `0600`；拒绝不合规权限、symlink、
非普通文件和硬链接。复用 `AnchoredFileIO` 的描述符固定、fsync、原子发布和非阻塞写锁。
命中时不刷新时间或写文件；有效期不超过 600 秒，以 wall clock 与 uptime 双重检查，回退、重启或
两者间超过 5 秒的偏移视为未命中。不做负缓存。已持有事件发布许可时拒绝进入 resolver。

## 验证与预算

原始样本、构建身份、编译日志及修改前源码快照保存在忽略目录
`dist/hook-version-cache-2026-10-10/`。所有 hook 编排测试只使用临时状态目录和模拟播放器/提示端点。
真实二进制诊断只运行 `--version`，缓存仍在临时目录，不调用 hook 或重放真实事件。

初次完整 harness 的四项失败包括新源码 raw string 不受写入扫描器支持、基准 symlink 写入口未登记及
PTY resize 两项关联断言。修复前两项时改用普通字符串并登记精确写入口，未放宽扫描器；PTY 未改动，
后续完整运行通过。新增 PATH 测试初次错误混用了注入时间与系统时间，修正同条件 fixture 后通过。
原始失败日志保留，不用覆盖失败证据的方式报告通过。

## 测量结果

正式 Core 对照默认每场景/分支/observer 每轮预热 10、测量 100，三轮，固定种子交替；
共 **16,240 个有效样本**：12 场景 × bypass/hit × observer 开关共 14,400；
满载稳态 miss/force/unknown 各 600；已识别布局及未知布局的版本超时各 20。
所有行逐项验证预期处理分支和副作用计数；全部 stderr 为空。

配对组来自同一当前二进制，`cache-bypass` 是重构后的原同步探测分支；另保留修改前二进制及
7,220 个基线样本，不将这两类数据混为一个分布。Core 的签名端点明确为合格 fixture，真实系统
签名成本在下一张组件表单列。没有扣减空进程基线，没有把 observer 跨度相加。

以下 observer 关闭，命中组每场景 n=300；单位 ms。命中组每个场景三轮均低于已批准上限。

| 场景 | 不使用缓存 p95 | 命中 p95 | 命中最差单轮 p95 | 批准上限 |
| --- | ---: | ---: | ---: | ---: |
| 完整播放，空历史 | 11.091 | 6.192 | 6.630 | 15.50 |
| 完整播放，20 条稳态 | 10.532 | 6.245 | 6.284 | 27.29 |
| 静音 | 16.875 | 8.662 | 12.973 | 30.12 |
| 去抖 | 15.995 | 7.659 | 8.397 | 21.42 |
| 不可播放 | 11.954 | 7.152 | 7.152 | 18.52 |
| 来源关闭 | 0.066 | 0.065 | 0.095 | 0.13 |
| GUI 退出 | 0.045 | 0.051 | 0.055 | 0.22 |
| 旧 installation | 6.627 | 1.153 | 1.366 | 8.41 |
| 播放锁忙 | 10.869 | 5.811 | 5.917 | 39.04 |
| 普通目录规则 | 12.656 | 8.354 | 10.506 | 18.62 |
| Git 规则 | 28.269 | 22.501 | 23.149 | 35.01 |
| 损坏 Git | 25.984 | 20.633 | 21.503 | 31.10 |

完整对照中，bypass 静音第三轮 p95 为 37.973 ms、旧 installation 第一轮为 8.700 ms，超出
30.12/8.41 ms。相关 observer 样本同时出现较长版本跨度，静音还包含其他跨度变慢；系统级触发
原因未定位，不能归因于某个具体后台程序。按已批准规则保留原结果，两个场景各补 1,200 个
同条件配对样本：bypass 最差轮分别为 **10.303/4.805 ms**，hit 为 **5.756/0.998 ms**，均通过。
原超界记录没有删除或并入复跑分布。其他对照场景三轮均通过。

修改前单独基线还有空历史、Git 与损坏 Git 的尾部漂移，同样保留。首次新对照与额外宿主 CLI
构建重叠，主动停止，`after/metadata.json` 明确标为 incomplete/excluded；正式结果来自
`after-alone/`，其间没有并行运行其他本轮构建或 harness。

| 满载稳态其他分支（签名 fixture） | 合并 p95 | 最差单轮 p95 | 批准上限 |
| --- | ---: | ---: | ---: |
| 缓存缺失 | 12.565 | 12.661 | 27.29 |
| 强制刷新 | 12.726 | 13.121 | 27.29 |
| 未知布局回退 | 16.013 | 25.857 | 27.29 |

两组超时拒绝均没有接收、播放、回执、活动或提示；真实版本子进程确认回收。已识别布局的
max 为 **1,224.440 ms**，未知布局为 **1,345.092 ms**，均低于已批准 **2,000 ms** 上限。
这包含实际子进程启动和清理，仍是本机隔离编排测试，不是生产 Release helper 或宿主阻塞硬保证。

### 本机已安装二进制的版本组件

Claude Code **2.1.282**、Codex **0.162.1**；使用真实 Security API，所有缓存写入临时目录。
每宿主首次填充 n=1，裸探测、命中、强制刷新各 n=10，三个分支按固定种子交替正反顺序。
这些是版本组件的诊断样本，不能代替完整 helper 的 100×3 样本或真实宿主阻塞测量。

| 宿主 | 裸探测 p50 | 命中 p50 | 命中 p95 | 首次填充（n=1） | 强制刷新 p50 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Claude Code | 10.923 | 0.597 | 0.879 | 147.056 | 127.108 |
| Codex | 10.816 | 0.837 | 1.048 | 152.933 | 152.347 |

两宿主各 10 次命中均为 **0 次探测、0 次签名检查**。首次填充和强制刷新明显慢于裸探测，
额外工作包含完整签名验证、身份复验和原子缓存写入；不能把强制刷新组冒充原实现来夸大命中收益。
这项冷路径成本尚没有完整生产 hook 预算，仍是生产启用前需要评审的限制。

初次 native 诊断只有 cold/hit/force 三组，42 行原始证据保留；上述表格只使用后续加入
probe-only 对照后的 62 行，两个版本的构建摘要分别记录。

## 最终验证

- Helper executable harness：**5,361 checks，0 failures**，包含跨独立进程缓存复用、并发填充、
  失效回退、真实 shim argv[0]、Security API 拒绝错误厂商，以及缓存命中后的实时授权拒绝。
- Debug CLI 契约通过：零 stdout/stderr、正确分支结果；正式 Release 不含测试根覆盖入口。
- Additional host CLI：**159 checks passed**，包括已有 adapter 接入与修复合同。
- Release `-Osize` benchmark/helper 构建通过；GUI Debug 构建通过（固定 SDK 26.5）。
- Swift 格式检查、Python 语法、localization JSON 和 `git diff --check` 通过。
- 本轮没有重跑 GUI 原生 harness；旧 16 项 GUI 失败触发原因仍未证明。没有重测真实宿主会话
  或人耳听音，没有隔离账户下的生产完整路径批量验收，没有安装或替换运行中的 helper/app。

## 复跑

```bash
swift run --package-path helper claudio-tests --host-version-cache
python3 scripts/benchmark-hooks.py --cache-comparison --skip-probe-comparison --output dist/hook-cache-rerun
helper/.build/hook-benchmark/release/claudio-hook-benchmark --native-version-cache-diagnostic --samples 10
```

`complete` 只表示样本采集及身份核验完成；预算结果须分别读取 summary 的 `budget_checks` 和
`within_budget`。两个定向复跑的命令及独立元数据保存在忽略目录 `run-followups.py` / `followup/`。
正式报告不持久保存原始事件或宿主配置，原始计时行仅含脱敏阶段与有限结果。

宿主执行策略、生产启用、回执优化、Git 算法以及 AUHAL/daemon/拆二进制均未推进。现有回执历史
与活动计数没有回滚、清理或批量重放。未 commit、push、发布或进行正式验收。
