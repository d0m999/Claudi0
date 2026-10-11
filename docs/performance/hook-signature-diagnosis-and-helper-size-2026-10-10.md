# 真实签名长尾定位与 helper 体积修复

> 后续支持范围决定（2026-10-10）：[ADR 0032](../adr/0032-support-apple-silicon-only.md) 已改为 arm64-only。
> 本文 Intel/universal 阻断及工具链/VM 准备步骤属于历史调查，不再是本轮继续优化或新候选发布的要求。
> 真实 Release 批量测量仍须保护现有用户状态；当前只做临时根的 Core 隔离验证，不要求现在创建账户或 VM。


2026-10-10。承接[缓存复审和真实签名基线](hook-version-cache-review-and-native-baseline-2026-10-10.md)。
本轮只授权只读签名诊断、本地体积修复和隔离回归。生产冷预算不冻结，生产缓存、宿主策略和第三阶段继续暂停。
未启用、安装或启动生产候选，未重放真实宿主事件，未修改现有回执、历史或活动计数；无 commit/push。

## 签名长尾：已定位到内容校验读取，系统触发条件仍未证明

复跑上轮冻结的 `--native-version-cache-diagnostic --samples 4`：版本探测约 10–14 ms，
命中约 0.7–1.3 ms，签名冷解析约 600–930 ms。它是版本组件证据，不是完整 hook 或生产 helper。
新增 `--native-signature-diagnostic` 直接调用生产 `SystemHostVersionSignatureValidator`，
比较直接调用和前置真实 `--version` 后的签名调用；后者的子进程不计入签名计时。
每次调用新建静态 code/requirement，逐调用 autorelease pool 清理包含在计时内。
只读真实二进制，CPU 记录当前进程及其工作线程，不包含 Security 服务或子进程 CPU。
这里的冷路径指未复用版本观察，不控制 OS 文件或 Security 缓存；不是系统冷启动或冷盘测量。

本机 arm64 / Swift 6.4 / macOS 27.0.1；Claude Code 2.1.282 与 Codex 0.162.1，
两份二进制分别为 222,245,312 B 和 246,642,624 B，摘要与上轮正式批次相同。
各分组 n=24，共 96 行，全部实际签名通过、零 stderr，宿主身份和执行期源码前后核对通过。
原始数据、诊断构建源码快照与摘要保存在 `dist/hook-signature-size-2026-10-10/`。
这是手动组件诊断；源码在执行前捕获，未将其当作自动基准的构建前后归属验收。

| 宿主 / 签名前条件 | wall p50 | wall p95 | wall max | 进程 CPU p50 |
| --- | ---: | ---: | ---: | ---: |
| Claude / 直接 | 451.816 | 729.939 | 1074.523 | 137.184 |
| Claude / 已探测版本 | 339.675 | 650.298 | 828.783 | 133.949 |
| Codex / 直接 | 646.993 | 913.329 | 1057.759 | 175.255 |
| Codex / 已探测版本 | 653.714 | 798.145 | 3097.714 | 174.435 |

单位 ms。CPU 和 wall 是不同度量，不能相加；中位数不是同一条样本。
3,097.714 ms 的 Codex 样本自身 CPU 为 209.858 ms，主要成本是非 CPU 等待。
前置版本探测没有稳定消除等待，不能将 spawn 或版本输出解析认定为长尾原因。
原诊断行把 `ru_inblock` 标成了 `pageIns`，这是字段命名错误：SDK 定义为 block input operations，
不能解释成 page-in 次数。当前诊断修正为 `blockInputs`，`ru_majflt` 明确为 `majorFaults`；
原始行及对应源码快照保留。这两个计数均未用于定位等待机制或计算预算。

对本轮自己启动的冻结 benchmark 采样 5 秒：主线程 2,728 次栈采样中，2,178 次停在
`Security::UnixPlusPlus::FileDesc::read → read`，428 次在摘要更新；签名调用整体覆盖 2,650 次。
证书服务 IPC 的栈样本远少于读取，不能据此归因网络或证书服务。
Apple [API 文档](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity(_:_:_:))
说明该调用验证可执行文件及 sealed components；
[公开实现](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/StaticCode.cpp)
的 `validateExecutable` 包含逐页摘要和 `F_NOCACHE`。公开源码不是本机 macOS 27 私有实现的逐行证明。

在独立、非生产 benchmark 子进程中临时 interpose `read` 的 16 次签名诊断：
总签名 wall 10,406.275 ms；读取合计 8,387.065 ms、56,983 次、3,732,123,144 B，
最大单次读取 4.506 ms。它与采样方向一致：这一批等待由多次读取累积。
读取总量包含该进程其他文件读取，不是按 Security 调用精确分段；interpose 有额外开销，
不是正式性能基准。进程 CPU 2,711.007 ms 与 read 的 CPU 部分重叠，不能相加推导 wall。
该 instrumented 批次不是上述 3.10 s 样本的同一次 trace，不能替它证明逐读取分布。

也保留了两个否定对照：

- 不校验内容的证书/requirement-only 诊断约 3–6 ms，但它放弃完整性检查，**从未用于缓存资格或生产实现**。
- 普通只读循环的 4 KiB / 64 KiB 缓冲、启用/关闭 `F_NOCACHE` 各 n=8；中位数约 19–59 ms，
  未复现真实 validator 的长等待。因此 `F_NOCACHE` 或裸文件带宽本身不能解释全部现象。

已确认的机制是大二进制的完整内容校验及其读取等待。为何 Security 的读取在该系统条件下延迟，
包括调度、内核文件读取策略或资源争用的贡献，尚未证明。保留这一限制，而不是跳过完整性校验、
只验一个架构、缓存 SecStaticCode 对象、换用 subprocess codesign 或增加看门狗凑预算。
生产 validator、签名强度、版本缓存边界及授权行为均未修改。

复跑入口（开发 benchmark，只读组件，绝不接受 hook）：

```bash
swift build -c release --package-path helper --product claudio-hook-benchmark \
  --experimental-lto-mode full -Xswiftc -Osize
# 使用上面命令对应的 --show-bin-path 下的 claudio-hook-benchmark：
claudio-hook-benchmark --native-signature-diagnostic --samples 24
```

上表来自修复前 `Release -Osize` 的冻结诊断产物；当前复跑命令采用修复后的统一 LTO 参数。
它用于诊断趋势，不能混入上轮 14,400 个完整 Core 样本或替代短命生产 helper 基线。

## 体积修复：保留完整 helper，使用 full LTO

根因调查先复现实际超限，再比较同源码、同版本 `0.0.0-dev` 和同 Swift 6.4 工具链的构建。
SwiftPM native 后端的单变量对照中，开启 full LTO 后 `__text` 从 2,037,124 B 降到
1,602,112 B；源码、CLI 能力和签名策略保持相同。主要收益来自跨模块链接优化，
不是移走功能、移入资源、拆二进制或放宽门禁。

| arm64 产物 | strip -x 后 | 独立 ad-hoc 签名后 |
| --- | ---: | ---: |
| 原默认后端、无 LTO | 3,337,528 | 本轮未测 |
| native、无 LTO | 3,320,872 | 3,301,728 |
| native、full LTO | 2,760,616 | 2,744,736 |
| 默认后端、full LTO | 2,794,296 | 2,778,224 |

字节。重新签名还会重建链接器临时 signature blob，不能将签名前后的差额全部算成代码压缩。
临时签名与路径/identifier 对齐可造成少量字节差异；上轮 3,337,536 B 数值保留，不改写历史数据。
默认后端候选签名后距原 3,250,000 B 上限有 471,776 B 余量；`strip -x` 和 helper external symbol
处理合同未改变，没有添加 `-no_exported_symbols`。LTO 本身可消除不再需要的符号，CLI 帮助/参数行为由子进程对照核对。

修改范围：

- 本地 bundle 的 helper 构建/路径查询与 Release 的 arm64/x86_64 helper 命令统一增加
  `--experimental-lto-mode full`，保留 `-Osize`、macOS 12 floor 和原产物位置合同。
- 两个隔离 benchmark 驱动采用相同 Release 参数，并把 full LTO 记入测量 metadata。
  旧结果不重新标成 LTO 数据；Debug、harness、LoginItem 构建参数保持不变。
- `ReleaseLayoutSuite` 把允许的 LTO 命令精确扩为五条 GUI 与四条 helper 分发命令，
  继续拒绝 Debug/harness/LoginItem/thin 扩散。该跨文件回归先红 148 / 2，再绿 148 / 0。

`scripts/check-release-size.sh` 原字节保持不变，不设置任何预算环境覆盖。
把当前默认后端 helper 放入现有 app 的独立副本，运行原体积/布局脚本：helper 2,778,224 B，
逐架构、GUI exports、alias、LoginItem、Sparkle、资源及总量均通过；helper 自身签名验证通过。
这个副本借用了既有 GUI/LoginItem，未重签外层 app，未启动，**不是当前源码的完整打包或签名验收**。
现有 `dist/claudi0.app` 和已安装 app/helper 原样保留。

### Intel 外部阻断

本机默认与 native 后端的 full LTO x86_64 链接均失败，随后无 LTO 的 native 控制组同样失败：
`__swift_FORCE_LOAD_$_swiftCompatibility56` 未解析。实际 `libswiftCompatibility56.a` 和
`libswiftCompatibilityPacks.a` 只有 `arm64 arm64e`，缺少 x86_64。
这是本机工具链兼容库条件，不以移除 FORCE_LOAD、提高 macOS floor、下载替换系统库或跳过 Intel 门禁修复。
失败日志保留；Intel 体积/运行、固定 CI 工具链和真实 universal bundle 仍未验证，不能从 arm64 推定通过。

## LTO 隔离回归与预算复跑

按默认预热 10、测量 100、三轮运行完整 Core 对照，共 **16,240 个有效样本**：
12 场景的 bypass/hit 与 observer 开关共 14,400；miss/force/unknown 各 600，
已识别与未知布局的版本超时各 20。逐样本分支和副作用断言通过，全部 stderr 为空。
签名为合格 fixture，播放器及提示为模拟端点；不能代替真实签名冷路径或生产 helper。

首批 observer 关闭的最差轮 p95 在 8 个场景出现超界：空历史、静音、去抖、不可播放、
旧 installation、锁忙、普通目录规则及 Git 规则。原同步探测对照同样超界，例如锁忙
bypass 为 180.988 ms、hit 为 44.617 ms，均超过 39.04 ms。没有删除或改写这批样本，
没有将超界归因于具体后台程序，也没有扩展预算。

对上述 8 场景使用上轮冻结的无 LTO benchmark 与本轮冻结的 LTO benchmark 配对复跑。
ClaudioCore 源码摘要相同；benchmark 仅多出未启用的签名诊断入口及字段命名，旧/新构建参数有明确记录。
每轮每场景交替 old/LTO 顺序，各版本内部仍固定种子交替 observer 与 bypass/hit。
每格预热 10、测量 100，三轮共 **19,200 个有效样本**；期间没有并行本轮构建或 harness。
所有分支计数核对通过，全部 stderr 为空，执行前后源码和二进制摘要一致。

下表为 observer 关闭的**三轮中最大 p95**，单位 ms；每格 n=300，不合并首批和复跑分布。

| 场景 | 原上限 | old bypass | old hit | LTO bypass | LTO hit |
| --- | ---: | ---: | ---: | ---: | ---: |
| 空历史 | 15.50 | 13.643 | 9.048 | 12.484 | 7.117 |
| 静音 | 30.12 | 13.706 | 7.729 | 12.365 | 6.866 |
| 去抖 | 21.42 | 11.789 | 6.840 | 14.098 | 7.350 |
| 不可播放 | 18.52 | 12.725 | 7.149 | 11.985 | 6.906 |
| 旧 installation | 8.41 | 6.516 | 1.227 | 6.594 | 1.339 |
| 锁忙 | 39.04 | 12.102 | 6.371 | 11.918 | 6.927 |
| 普通目录规则 | 18.62 | 13.257 | 8.447 | 14.904 | 9.997 |
| Git 规则 | 35.01 | 28.605 | 23.465 | 30.768 | 25.368 |

复跑的 96 个逐轮预算检查全部通过；首批另外 4 场景两组均通过。
满载 miss/force/unknown 的最差轮 p95 分别为 19.358 / 19.651 / 14.147 ms，
均低于 27.29 ms。两类版本超时拒绝的 max 为 1,212.281 / 1,215.974 ms，包含实际启动和清理，
子进程已回收且无副作用，均低于已批准 2,000 ms；这不是系统签名成功冷路径的上限。

此次配对未复现 LTO 导致的持续预算退化；部分场景 LTO 仍稍慢，不能宣称 LTO 提升所有场景延迟。
机器层面的尾部波动尚未归因，生产性能及冷预算保持未验证。
原始数据、构建身份、源码快照与逐轮结果分别在 `lto-core-regression/`、`budget-rerun/` 和
`lto-core-source.zip`；诊断字段命名随后修正，不改变生产 Core 或本批测量的调用路径。

## 验证与后续边界

- Helper 全量：5,377 checks / 0 failures。
- Release layout：148 / 0；新合同修复前 148 / 2 的日志保留。
- 原生测量 driver 6 个 unittest、已有测量 driver 11 个 unittest 通过。
- 两种 LTO arm64 产物各 7 组 CLI parser/help/version/未知宿主对照与无 LTO 基线完全相同。
  没有执行获准的生产 hook；未知宿主在读取授权或状态之前即返回。
- 原体积/布局 gate 和候选 helper 的 strict signature verification 通过，边界如上。
- LTO Core 分支和副作用回归、预算复跑与两组超时拒绝检查通过，原超界批次保留如上。
- GUI Debug 原生构建通过；本机使用已安装的 macOS 26.5 SDK。
- 诊断计数命名修正后的 benchmark Debug 构建通过；测量产物及对应源码保持冻结。
- Swift 格式、Python 语法、shell 语法、localization JSON 和 diff 检查通过。

没有取得独立账户或 VM，生产完整 helper 批量、真实宿主/听音、完整当前 bundle、Intel、Developer ID
签名/公证、远端 CI 和正式验收继续未验证。旧 16 项 GUI 全量失败不由 Release layout 子集替代。
工作期间其他线程提交了 `PanelView.swift` 的两行垂直居中改动，HEAD 从 `8934524` 到 `52a5a5f`。
本轮未提交；这些 GUI 改动不属于本轮修复。helper 编译输入按文件摘要及源码快照核对，未因 HEAD 变化混用证据。

生产缓存仍默认关闭，体积修复不改变此前预算闸门。下一步必须先取得适合的隔离环境和兼容的 Intel
工具链证据，再测短命完整 Release helper、决策可接受冷路径阻塞；不会自动启用缓存或进入宿主策略/第三阶段。

后续同日补测已取得当前脏源码的**完整 arm64 ad-hoc bundle**，原体积和签名 gate 通过；
没有启动、安装或重放。Intel 仍缺兼容工具链，旧 Xcode 的宿主 OS 区间及隔离操作步骤见
[Release 补测与环境移交](hook-release-checks-and-isolation-2026-10-10.md)。本节以前的批次边界保持原样。
