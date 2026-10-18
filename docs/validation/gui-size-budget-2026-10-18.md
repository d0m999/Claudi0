# GUI 体积回归：将 Codex 审批解析器留在 helper

> 以下是同轮切换修复前的体积与测试记录。后续 [ADR 0034 修订](../adr/0034-qualify-codex-approval-reminders.md)
> 已撤掉无法证明请求审批人的 transcript 推断；这些历史结果不代表当前人工提醒能力或本轮构建结果。

## 问题与根因

当前工作树的原签名包 `claudi0-app` 为 7,013,392 B，原门禁为 7,000,000 B，超出
13,392 B。签名前为 6,999,424 B；签名增加 13,968 B，使最终包越界。

真实 GUI 的字符串与未 strip 的符号表均包含 `CodexApprovalRoutingResolver` 及其
Codable 类型。审批解析器放在 GUI/helper 共享的 `ClaudioCore` 中，虽然只有 hook 进程
需要读取 transcript，其实现与类型元数据仍进入 GUI。不能依赖 full LTO 自动移除它们。

## 修复

将原解析器完整移动到已有的 CLI 专用 `ClaudioHookInput` target，保持解析逻辑不变。
将拆分后的枚举和解析器按原格式拼接，其 SHA-256 与前一包的源码清单完全一致。
`ClaudioCore` 只保留类型化路由接口，未注入时静默返回 unavailable；CLI 显式注入真实
解析器。自动审批静默、人工审批提醒、身份校验、有界读取、回执及活动语义均保留。

新增 `scripts/check-hook-input-boundary.py` 检查实际包的两个二进制：解析器必须出现在
helper，且不得进入 GUI。旧包运行该检查返回失败，新包通过；本地标准打包脚本已接入。
原体积阈值、架构、LTO、优化参数、签名及导出符号要求均未放宽。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| helper 完整 executable harness | 5,701 checks，0 failures |
| GUI `--release-layout` | 191 checks，0 failures |
| GUI Debug product build | 通过 |
| 构建参数回归 | 7 tests，通过 |
| Bailian 源身份与构建编排回归 | 8 scenarios，通过 |
| 标准 `dev-bundle.sh` | exit 0，签名前后原门禁均通过 |
| 实际 GUI/helper 解析器边界 | 通过 |
| 签名后 GUI | 6,980,320 / 7,000,000 B |
| 签名后 helper | 2,800,272 / 3,250,000 B |
| LoginItem | 54,208 / 500,000 B |
| Sparkle 独立预算 | 2,705,105 / 3,500,000 B |
| 非可执行资源 | 2,425,761 / 3,100,000 B |
| bundle 正规文件合计 | 14,965,666 / 16,555,105 B |
| ad-hoc 签名及 Sparkle 校验 | 通过 |
| 与旧包的完整文件清单及产品资源内容对比 | 一致 |

GUI 减少 33,072 B，最终余量为 19,680 B。旧包、旧 helper、日志、源码及 bundle 清单
保留在本机 `dist/package-size-fix-20261018-150950/`，不进入 Git。

GUI 打包回归首次运行有两项失败：路径保留夹具缺少新增 gate 的替身；并行 Release
构建使 SwiftPM 清单输出不可解析。补齐隔离夹具、待构建结束后串行重跑，191 项全部通过。
这些改动未移除实际包的二进制边界检查。

本轮未重跑 GUI 全量运行时 harness；GUI 源码与产品资源未因本修复改变。本地构建和
自动检查不代表真实宿主授权框、音频、人工原生 UI、Developer ID、公证或正式发布验收。
