# WorkBuddy Desktop 5.8.3 工作区目录证据采集（2026-10-16）

状态：**五个目标事件中四个已在本机 Desktop 5.8.3 上取得 A/B 目录证据；`StopFailure` 经三种
受控触发法（exit 1 / exit 2 / 不可执行路径的 Stop hook）均为零回调，与随包代码静态分析一致，
按 ADR 0005 证据门不开放 WorkBuddy 工作区资格。**

## 方法

- 宿主：WorkBuddy Desktop 5.8.3（`com.tencent.workbuddy.mac`，2026-09 月为 5.6.2，版本已变，
  5.6.2 的旧证据按版本不作数，全部重采）。任务全部由 GUI 自动化在真实 Desktop 中提交
  （`claudio-wb-A`/`claudio-wb-B` 两个空目录为工作空间），非 CLI 驱动。
- 观察器：`~/.workbuddy/settings.json` 临时 hook 组（UserPromptSubmit / Stop / SubagentStop /
  Notification / StopFailure），脚本只记录事件身份、`notification_type` 分类
  （仅 `permission_prompt`/`idle_prompt` 记原值，其余 `other`）、`cwd` 是否为顶层绝对
  字符串及规范化后与 A/B 的匹配结果；不保存 payload、路径、提示词、会话 ID 或凭据。
  匹配路径在观察脚本内硬编码，不落盘。
- 恢复点：采集前 `~/.workbuddy/settings.json` 0600 备份 + SHA-256 清单
  （`~/.claudio-spike-wb-20261016/`）；收尾恢复后 SHA-256 与备份逐字节一致
  （`8165587d…a60a`），观察器、临时 `permissions.ask`、毒 Stop hook 均无残留。
  采集期间临时改动：默认权限开关（已恢复为允许完全访问并确认）、`permissions.ask=["Read"]`
  （已随恢复点还原）。
- permission_prompt 触发法：5.8.3 下 `permissions.ask` 与默认权限模式均被旁路
  （工作空间内 Read 直接执行）；实际生效路径是「默认权限 + 工作空间外文件读取」——
  Desktop 显示「等你授权」横幅，同时观察到 `permission_prompt` 回调。

## 证据矩阵（53 条观察，0 解析错误）

| 事件 | A | B | 备注 |
|---|---|---|---|
| `UserPromptSubmit` | 5 | 9 | 全部有 `session_id`，cwd 顶层绝对字符串且精确匹配 |
| `Stop` | 5 | 9 | 同上 |
| `SubagentStop` | 1 | 0 | A 目录子代理任务；B 未驱动，对称性缺口 |
| `Notification` `permission_prompt` | 1 | 2 | 工作空间外 Read 触发，Desktop 同时显示授权横幅 |
| `Notification` `idle_prompt` | 3 | 2 | 任务完成后自然到达 |
| `Notification` `other` | 9 | 7 | 非目标 subtype，不作证据 |
| `StopFailure` | 0 | 0 | 三种受控触发法均为零（见下） |

7 条 `other` Notification 无 `session_id`（含最早的任务前通知）；目标事件与
`permission_prompt`/`idle_prompt` 均带 `session_id`。

## StopFailure 实验与结论

静态核对 5.8.3 随包 `codebuddy-lite-wb.mjs`（2026-10-15）：`StopFailure` 仅从
`executeStopHooks` 的异常捕获路径派发（与 5.6.2 结构相同），模型失败以 `stopReason:"failed"`
走 `Stop`。据此设计三种受控触发，均在真实 Desktop 任务上执行：

1. Stop hook `exit 1` —— 零 `StopFailure`；
2. Stop hook `exit 2`（stderr 附错误文本）—— 零 `StopFailure`；
3. Stop hook 指向不可执行路径（spawn 失败）—— 零 `StopFailure`。

三种失败形态下 `Stop` 回调均正常到达观察器，说明 hook 组确实执行、失败被宿主吞掉而不抛异常。
结论：**5.8.3 没有可复现的用户态 `StopFailure` 触发法**；API/模型失败路径按 5.6.2 证据仍走
`Stop`（本轮未重建 401 自定义模型基础设施）。事件在当前版本实际上不可达——不是「尚未找到」，
而是随包代码显示无派发路径可达。

## 决定（按 2026-10-16 计划 Q5：严守 ADR 0005 证据门）

- **不开放 WorkBuddy 工作区资格**，不实施五绑定/六命令与 5/5 展示；
- 若未来要把「放宽到 4/5（无 stop_failure）」作为产品决策，那是对 ADR 0005
  「五个目标事件缺一不可」的显式修订，需单独批准；本记录不构成该修订；
- 其余四个事件的本轮证据在 5.8.3 上有效；未来 Desktop 再升级须按版本重新取证；
- 子代理 B 目录、StopFailure 以外失败语义（如 401）的 5.8.3 复测留作后续。

## 证据边界

真实回调与目录匹配为本轮实测；`played` 回执、按工作区实际播放、人工听音、键盘/VoiceOver
与发布门禁均未涉及。观察器记录不含提示词与路径原文；私有观察日志与探针在核对后已清除，
A/B 空目录与 Desktop 测试任务暂留。GUI 自动化期间用户并行使用其他应用，未观察到干扰其数据。
