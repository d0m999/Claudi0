# 暂缓的版本缓存核心与实验驱动器依赖清单

2026-10-11。本轮只修复单宿主身份预检与兼容性脚本的优化模式绕过，补合成契约，随后只读复评。
版本缓存核心、实验驱动器接线仍暂缓；本清单不是提交授权或新的合入候选。
没有追加诊断、性能测量、真实宿主回调或生产写入。E2、宿主策略及第三阶段继续暂停。

核对起点为共享 `main` 的 `95b2874a696a3bbcf82155c100968ad471db2130` 加未提交改动。
它不是历史 E1 构建身份。原 E1 包、旧摘要、原始样本继续对应各自的固定源码。
本轮修复前副本、限定差异、契约日志、候选摘要及保留核验另存忽略目录
`dist/hook-cache-driver-fixes-2026-10-11/`，不覆盖旧包。

## 本轮精确改动边界

| 文件 | 本轮差异 |
| --- | --- |
| `scripts/benchmark-native-hook-cache.py` | `identity` 接收宿主选择；前后预检均传递 `args.host`，默认仍为 `all` |
| `helper/Sources/claudio-hook-benchmark/main.swift` | 身份预检 CLI 分支传递 `--host` |
| `helper/Sources/claudio-hook-benchmark/NativeHookCacheBenchmark.swift` | 移出原身份读取函数；完整 hook 实验编排不改 |
| `helper/Sources/claudio-hook-benchmark/NativeHostIdentity.swift` | 新文件，承接原身份读取；先验证选择，再仅定位、探测和读取所选宿主 |
| `helper/Tests/ClaudioCoreTests/AtomicWriteSuite.swift` | 只将只读 `FileHandle` 审计项移到新文件；不增加写入豁免 |
| `scripts/test-hook-cache-compatibility.py` | 模块入口拒绝 `-O/-OO` 的执行与导入，保留正常模式断言 |
| `scripts/test-native-host-identity-contract.py` | 新合成契约：编译实际身份 collector 和实际 CLI 分支，注入合成 Core；另验证 Python 前后预检传参 |
| `scripts/test-hook-cache-compatibility-contract.py` | 新合成契约：临时伪 harness 验证正常核验、错误拒绝及优化模式提前退出 |
| 本文 | 完整列明待拆分依赖与当前证据边界 |

身份预检默认输出结构、版本来源与摘要格式未改。非法选择在查找宿主前拒绝。
兼容性脚本只允许正常 Python 模式运行，防止断言被解释器静默删除。

## 待拆分的编译依赖：核心与基线

下列是当前脏源码中直接参与该路径的增量，不是可以整文件暂存的清单。
`HostActivationScope`、`HostHookRunner` 和 harness 入口混有基线与缓存接线，应按差异拆分后重新核对依赖。

| 文件 | 责任 / 依赖 |
| --- | --- |
| `helper/Sources/ClaudioCore/HostVersionResolver.swift` | 新增唯一版本观察 owner；探测、严格刷新、资格验证、失效及私有缓存发布 |
| `helper/Sources/ClaudioCore/HostActivationScope.swift` | Claude/Codex 版本委托 resolver，scope 仍由原规则生成；同时含版本阶段 observer 接线 |
| `helper/Sources/ClaudioCore/HostEventAuthorization.swift` | 向 resolver 提供内部发布许可状态，防止许可内探测或刷新 |
| `helper/Sources/ClaudioCore/HostHookRunner.swift` | 可选 resolver 注入、按事件复用 scope；另含授权、活动、结果及提示阶段测量 |
| `helper/Sources/ClaudioCore/HookMeasurementContext.swift` | 新增默认关闭的 TaskLocal 内存 observer；resolver、编排、播放器和回执的编译依赖 |
| `helper/Sources/ClaudioCore/HostHookReceipt.swift` | 仅当前回执、归档与剪枝阶段 observer；不含第三阶段优化 |
| `helper/Sources/ClaudioCore/Play.swift` | 工作区/声音、锁与播放器阶段 observer；不改变 Git 解析算法 |
| `helper/Sources/claudio/Subcommands.swift` | CLI 输入与授权阶段 observer；不是缓存生产启用入口 |

上述增量还复用已存在的模块内能力，以下文件不需为缓存另加补丁：

- `helper/Sources/ClaudioCore/HostIntegrationModels.swift`：`HostID`。
- `helper/Sources/ClaudioCore/VersionCompatibility.swift`：`CommandRunning` / `SystemCommandRunner` 与有界进程清理。
- `helper/Sources/ClaudioCore/AnchoredFileIO.swift`：带身份复验的文件读取与原子发布。
- `helper/Sources/ClaudioCore/FileLock.swift`：非阻塞锁。
- `helper/Sources/ClaudioCore/PrivateDirectory.swift`：私有目录创建。
- 系统 `Foundation`、`Darwin`、`CryptoKit`、`Security`；helper 已有 `ClaudioVersionC` / `ClaudioPTYC` 依赖保持原样。

这列的是改动闭包及直接接线，不将所有已存在的 Core 业务文件重新列为待合入补丁。

## 待拆分的 Swift 验证依赖

| 文件 | 责任 |
| --- | --- |
| `helper/Tests/ClaudioCoreTests/HostVersionResolverSuite.swift` | 新增缓存命中/失效、探测、接收资格及跨进程 child fixture |
| `helper/Tests/ClaudioCoreTests/HostVersionRefreshSuite.swift` | 新增显式严格刷新、并发发布/失效及取消检查 |
| `helper/Tests/ClaudioCoreTests/HookMeasurementSuite.swift` | 新增 observer 开关、有限结果和隔离合同 |
| `helper/Tests/ClaudioCoreTests/HostHookRunnerSuite.swift` | 既有完整编排套件补充实际分支计数与无效资格 fixture |
| `helper/Tests/ClaudioCoreTests/WorkspaceSoundRulesSuite.swift` | Git worktree、submodule、symlink 与损坏身份回归；算法不变 |
| `helper/Tests/ClaudioCoreTests/AtomicWriteSuite.swift` | 隔离 target 的写入/只读 API 审计台账；本轮迁移一个已有条目 |
| `helper/Tests/ClaudioCoreTests/main.swift` | 三个新 suite 注册、缓存专项和带 action 的 child 入口 |

`test-hook-cache-compatibility.py` 依赖这个 child 接口及两份明确的 harness 产物：
旧产物无 action 参数，新产物接受 `refresh` / `resolve`。
脚本按两宿主、两个产物顺序验证冷填充、后续零探测/零签名及缓存字节与 mtime 不变。
本轮合成伪 harness 只验证脚本能识别这些结果，不证明真实新旧 Core 的格式兼容。

## 实验 target 的完整文件闭包

`helper/Package.swift` 新增 `claudio-hook-benchmark` executable target，依赖 `ClaudioCore`。
SwiftPM 会编译该目录所有 Swift 文件；不能只拿历史 E1 的三份实验文件和 `main.swift` 当作完整 target。

| 文件 | 责任 |
| --- | --- |
| `helper/Sources/claudio-hook-benchmark/main.swift` | fixture、受控探测、计数与分支校验、共享类型、CLI 调度及 Core 对照 |
| `helper/Sources/claudio-hook-benchmark/NativeHostIdentity.swift` | 所选真实宿主的只读身份与摘要预检；本轮抽出 |
| `helper/Sources/claudio-hook-benchmark/NativeHookCacheBenchmark.swift` | 完整隔离 hook、真实版本探测、受控播放器/提示，复用 main fixture |
| `helper/Sources/claudio-hook-benchmark/NativeVersionRefreshBenchmark.swift` | 显式刷新及随后两个隔离 hook 的独立记录 |
| `helper/Sources/claudio-hook-benchmark/NativeVersionCacheDiagnostic.swift` | 历史版本路径分解实验入口 |
| `helper/Sources/claudio-hook-benchmark/NativeSignatureDiagnostic.swift` | 历史签名分解入口 |
| `helper/Sources/claudio-hook-benchmark/GitTimeoutDiagnostic.swift` | 历史 Git 与拒绝路径诊断入口 |

后三个文件当前仍是 target 的编译依赖。保留文件不授权重跑诊断；如果后续去除入口，需单独拆分评审。
`helper/Package.resolved` 和现有依赖版本无需本轮修改。

## Python 驱动、统计与 CLI fixture 的边界

| 文件 | 状态 / 责任 |
| --- | --- |
| `scripts/benchmark-native-hook-cache.py` | 未提交；导入下一行基线工具及独立 evidence；构建 target/helper，按所选宿主前后核对身份 |
| `scripts/benchmark-hooks.py` | 未提交直接依赖；源码/二进制摘要和基线驱动。源码身份涵盖 Package.swift、Package.resolved、helper/Sources 的 Swift/C/H 与自身 |
| `scripts/hook-cache-evidence.py` | 已本地提交的纯统计与样本核验模块；驱动器将其摘要纳入新源码身份 |
| `scripts/test-native-hook-cache-driver.py` | 已本地提交；直接测试纯 evidence，不导入实验驱动器 |
| `scripts/test-hook-cache-compatibility.py` | 未提交；两产物缓存格式契约，含本轮优化模式拒绝 |
| `scripts/test-native-host-identity-contract.py` | 本轮新增；合成身份及选择传递回归 |
| `scripts/test-hook-cache-compatibility-contract.py` | 本轮新增；合成兼容性核验回归 |
| `scripts/test-hook-measurement-drivers.py` | 未提交；基线与真实宿主驱动器的合成契约，不是实际送达证据 |

其余基线与 CLI 证据入口不是缓存 Core 的编译依赖，但不可在整理第一阶段工具时遗漏：

- `scripts/hook_cli_fixture.py`：未提交；临时启用意愿、installation 与可验证存活进程身份。
- `scripts/test-hook-cli-contract.sh`、`scripts/test-additional-host-cli-contract.py`：已跟踪但有未提交差异；复用上述 fixture，区分 Debug 覆盖与正式 Release 边界。
- `scripts/measure-release-hooks.py`：已跟踪但有未提交差异；Release 重放限制与恢复保护，不纳入本轮执行。
- `scripts/measure-real-hook.py`、`scripts/measure-release-hook-timeout.py`：未提交；均直接导入上一行 Release 工具。
- `scripts/measure-host-hook-timeout.py`：未提交；宿主 timeout 证据入口，与缓存资格无关。

`scripts/verify-hook-cache-closeout.py` 与 `scripts/test-hook-cache-closeout-verifier.py` 已本地提交，
只负责保存材料的摘要契约；不是 benchmark 运行依赖，也不证明性能达标。
纯工具提交与未提交的实验接线不能混为一个已合入能力。

## 文档与发布依赖

已有本地提交的 ADR 0031/0032/0033 与历史 E1 报告分别描述预算闸门、arm64-only 和 proposed 刷新设计。
ADR 0033 仍未接受。本轮不修改它们或将已有工具提交解释为缓存核心已接受。

三份仍未提交的早期基线文档应独立整理，不能静默包含在核心提交中：

- `docs/performance/hook-path-architecture-review-2026-10-09.md`
- `docs/performance/hook-path-baseline-2026-10-10.md`
- `docs/performance/hook-version-cache-local-2026-10-10.md`

共享工作区中的 arm64 发布流程、full LTO、体积脚本、GUI 发布测试及其他 UI 差异属于其他边界。
未来复用历史构建条件时需单独核对这些前置条件；本清单不授权一并合入或修改性能/体积门禁。

## 合成验证与只读复评

修复前，单宿主 CLI 拒绝缺少另一宿主的 fixture，非法选择仍触发查找；Python 入口不支持传递选择。
兼容性脚本在优化模式执行和导入时均未拒绝，错误结果可被当作成功。
修复后的合成契约分别通过 7 tests 和 4 tests（后者含 7 种错误结果及 `-O/-OO` 子用例）。

身份契约编译实际 collector 和实际身份 CLI 分支，其 Core 定位/探测是临时 fixture stub。
Python 驱动 main 的前后选择契约全部替换构建、采样与统计端点；生成的是临时伪数据，没有性能样本。
兼容性契约使用伪造子进程，验证错误结果、stderr、字节/mtime 重写拒绝以及优化模式退出前没有 fixture 副作用。
这些结果不能替代完整 benchmark/helper 构建、真实版本/签名、真实新旧缓存兼容、音频或 Release 验收。

只读复评检查本轮限定差异与清单，不重新接受缓存核心。
历史 Core 两项超限、生产冷预算未冻结、真实刷新覆盖与周期收益未知等结论保留。
Codex resources/path 目录内部变化是否可能影响版本结果的依赖闭包仍需证明，本轮不修复或宣称验证。
默认缓存目录仍为 `nil`，本轮没有添加生产目录或连接/修复刷新接线。

核心合入条件仍未满足。当前建议保留本地候选与依赖清单，继续暂缓；本轮工具修复不提供进入 E2 的依据。

## 四项独立提交后的状态补充

2026-10-11，按固定 `f47e1e30eb4fc0519ee4390e982e4dd1998c6442` 核对
`95b2874...f47e1e3` 的四项本地提交。上文的“未提交”和“待拆分”保留为清单形成时的状态；
下表补充已拆分结果，不将共享工作区的其他未提交增量解释为已合入能力。

| 提交 | 已拆分结果与责任 |
| --- | --- |
| `8b89738` | 兼容性工具及合成契约已提交；拒绝 `-O/-OO` 执行与导入，真实两产物兼容仍待 child 入口及固定 harness 产物 |
| `c07b511` | 默认关闭的内存 observer、编排阶段接线及专项验证已提交；未包含 resolver/cache 接线 |
| `efb4e76` | CLI fixture 与契约已提交；共享 `hook_cli_fixture.py` 仅注册可验证的存活进程身份，shell 调用方准备启用意愿与 installation，additional-host 调用方通过真实 `integrations connect` 准备这些事实 |
| `f47e1e3` | 新增 submodule 身份回归及 Git 身份专项入口；worktree、symlink 和损坏 `.git` 覆盖原已存在，损坏 `.git` 测试搬入专项，生产算法不变 |

fixture 的职责分布与上文模块条目的概括不同，但清单未要求三项能力必须抽入同一个模块，
因此复核结果是文档描述不一致，不是已确认的功能缺口。observer 关闭路径不读时钟、不创建 `Record`；
这不构成整个调用路径零分配或零开销的证据。

四项提交的复核修订及验证结果追加在
`dist/hook-independent-candidates-2026-10-11/readonly-review.md` 的“已提交四项的复核修订”中。
缓存核心、实验接线、真实新旧缓存兼容及 E2 继续暂缓，ADR 0033 保持 proposed。
