# Claude/Codex 单次集成检查的版本观察复用

## 范围与结果

基于 `b84bcd0ac0e28cd5f159d364e31c60b9d15357da` 实现用户选择的第 ① 项优化。
Claude Code、Codex 的一次只读集成检查现在取得一份不可变 `HostDiscoveryObservation`，
将同一份真实版本分别投影为 discovery 与完整 activation scope。
GUI、自动维护及 `doctor` 的集成检查复用相同 adapter。

已配置且可正常探测的宿主，每次检查从两次 `--version` 降至一次。
未配置宿主仍为一次，缺少可执行文件为零次；后续及并发检查各自重新观察。
正常连接保留两次前置观察和一次完成后的新检查，即 2＋1；
完整 `doctor` 另有一次独立 Claude 兼容性探测，不能把集成检查计数当作整个命令的计数。

`ClaudeCodeIntegrationEnvironment` / `CodexIntegrationEnvironment` 的旧
`availability`、`scopeFingerprint` 注入合并为 `observeHost`；
`DoctorIntegrationsEnvironment` 对应使用 `observeClaude` / `observeCodex`。
默认初始化用法不变，显式注入旧参数的源码需要迁移，仓库内调用已同步迁移。
完整注入消除了部分 fixture 注入后隐式回退本机 CLI 的路径。

## 保留的合同

- 默认闭包每次重新构造标准 executable locator；不在 environment 中固定安装发现结果。
- 沿用 `HostVersionResolver` 的强制真实探测、原始 shim 路径、1 秒超时及 publication lease 门禁。
- 失败不立即重试、不复用上次成功值，下一次检查可以恢复。
- discovery 的 SemanticVersion token 判据与 scope 的资格独立。
  非语义版本的短字符串仍可能生成 scope，但不会因此成为 available。
- Codex 的 `cli=` 前缀及加前缀后的 256 字节上限、现有 fingerprint 格式保持不变。
- 版本变化使旧 installation scope 和回执失效；显式修复发布新的 installation。
- 持久缓存仍默认关闭，hook 执行策略、维护定时、JSON 格式及其他宿主策略不变。

## 验证

新增 `HostDiscoveryObservationSuite`，在完整 helper harness 和
`--host-integration-checks` 注册。通过受控 `CommandRunning` 和临时可执行 shim，
覆盖 adapter / doctor 的计数、成功与失败、后续恢复、并发检查、版本变化、
已有回执失效、连接前后观察、两个资格判据和 publication lease。
只读检查前后以 `lstat` 比较 fixture 树的内容、权限与链接本身，不通过链接读取目标。

| 检查 | 结果 |
| --- | --- |
| 相关 helper 检查，首轮 | 785 checks，0 failures |
| 完整 helper harness，含随后补充的回执和完整 doctor 断言 | 5884 checks 全部通过 |
| 完整 GUI harness | 25016 checks 全部通过 |
| GUI Debug 构建 | 通过 |
| 修改文件的 `swift-format lint --strict` | 通过 |
| 本地化 catalog `jq empty` | 通过 |
| `git diff --check` | 通过 |

helper 使用本机 Apple Swift 6.4；GUI 按仓库说明显式使用 macOS 26.5 SDK，
同时给 harness 的嵌套编译设置相同 `SDKROOT`。这些结果属于本机自动验证，
不代表 CI、真实宿主回调、音频、人耳延迟、签名、公证或发布验收。

## 轻量隔离测量

GUI harness 和构建结束后，以同一个 Debug `ClaudioCore` 构建测量两种已配置 adapter。
旧链在候选构建中重建：先 `HostDiscovery.detect`，再独立调用
`HostActivationScope.claudeCode/codex`，不是单独编译旧提交。
新链使用 environment 的生产默认观察闭包。两者都调用真实 `SystemCommandRunner`，
通过隔离 `PATH` 启动临时合成 CLI；没有执行本机安装的 Claude/Codex。
合成 CLI 输出 `2.1.282 (fixture)`，并向私有计数文件追加一字节。
fixture 配置与 marker 的创建、预热、计数文件读取都在计时区间之外；
每次计时包括完整 adapter inspection。

每宿主先预热两组，再测 20 组，按 AB / BA 交替顺序执行；
使用 `DispatchTime.uptimeNanoseconds`，每组验证两侧 snapshot 相同且探测次数为 2 / 1。
默认 `doctor` 集成入口另行计数，结果为 Claude 一次、Codex 一次。

| 合成宿主 | 旧链探测数（20 次检查） | 新链探测数 | 旧链中位耗时 | 新链中位耗时 |
| --- | ---: | ---: | ---: | ---: |
| Claude Code | 40 | 20 | 13.22 ms | 8.37 ms |
| Codex | 40 | 20 | 11.64 ms | 7.13 ms |

这是 macOS 27.0.1 / arm64 上的 Debug fixture 证据，包含合成进程及计数文件的成本。
实际 CLI 的启动成本与环境不同；这些数值不代表真实宿主检查或 agent hook 的性能改善。
硬性验收是删除重复探测且保留正确性，不设耗时显著性或生产延迟达标结论。
合成脚本使用的 `/bin/sh` 在 setup 前及全部临时文件清理后核对 SHA-256 与 POSIX mode，
两者均一致，mode 保持 `0755`。测量源码、二进制、fixture、原始日志和临时架构报告已清理；
本文件保留必要的方法、数值及验证结果。

<details>
<summary>20 组耗时记录（ms，保留三位小数）</summary>

| 组 | Claude 旧 | Claude 新 | Codex 旧 | Codex 新 |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 13.642 | 7.996 | 12.008 | 7.822 |
| 2 | 14.087 | 9.549 | 12.436 | 7.722 |
| 3 | 12.582 | 8.135 | 11.531 | 7.374 |
| 4 | 13.359 | 8.079 | 11.598 | 7.834 |
| 5 | 14.051 | 8.449 | 11.440 | 7.232 |
| 6 | 12.199 | 8.310 | 11.924 | 7.098 |
| 7 | 13.254 | 8.203 | 11.905 | 7.066 |
| 8 | 13.089 | 8.308 | 11.365 | 6.674 |
| 9 | 13.176 | 8.833 | 12.285 | 7.154 |
| 10 | 13.317 | 8.706 | 11.439 | 7.616 |
| 11 | 12.363 | 8.797 | 12.228 | 7.088 |
| 12 | 12.278 | 8.131 | 11.507 | 7.018 |
| 13 | 13.780 | 8.603 | 11.234 | 6.731 |
| 14 | 12.303 | 7.726 | 11.345 | 6.804 |
| 15 | 13.867 | 8.514 | 11.966 | 6.996 |
| 16 | 13.921 | 8.295 | 11.772 | 6.764 |
| 17 | 12.232 | 8.297 | 10.877 | 7.414 |
| 18 | 12.837 | 9.067 | 12.011 | 8.003 |
| 19 | 12.767 | 9.163 | 11.686 | 6.859 |
| 20 | 13.522 | 8.421 | 11.468 | 7.543 |

</details>

## 安全回退与避免过度测试

本次没有持久化迁移，回退只需通过 Git 撤销本任务源码改动，不需要恢复用户宿主配置。
主题计划文件原有未提交修改保持不变。相关检查后执行一次完整门禁；
耗时比较只作辅助证据，不以重复运行直到显著降时作为通过条件，也不重启暂停的缓存、
async、receipt A/B 或其他性能实验。
