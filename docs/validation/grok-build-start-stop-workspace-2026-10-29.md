# Grok Build 开始／结束与工作区资格验证（2026-10-29）

状态：实现、自动检查和真实宿主回调已验证；人工听音、运行中 TUI 热加载、普通 Release
准入、Developer ID 签名与公证未完成。本记录对应 [ADR 0035](../adr/0035-integrate-grok-build-native-attention-hooks.md)
的 2026-10-29 修订。

实现基线：Claudio `b944d80438dd018b57d53962f4c4e1cf8d301f6c` 之上的未提交工作区。
真实宿主：`grok 1.0.70 (f50904eaee6c)`，`~/.grok/bin/grok` 的 SHA-256 为
`5c8a688251bf61e35370b828b6a353b0a20fcc3f64000de8a91d426039f29cec`。

## 绑定与边界

| 公共事件 | 原生绑定 | 准入条件 | 当前实现 |
| --- | --- | --- | --- |
| `task_start` | `UserPromptSubmit` | 标准 UUID `promptId`；拒绝 `task-completed-*`、`subagent-completed-*`、`scheduled-*` 及 `<system-reminder>` 合成提示 | acceptance 候选 |
| `stop` | `Stop` | `reason == end_turn`、存在 `promptId`、`stopHookActive == false` | acceptance 候选 |
| `stop_failure` | 主会话 `StopFailure` | 原有 API 错误规则 | acceptance 候选 |
| `notification` | `Notification(permission_prompt)` | 原有授权规则 | acceptance 候选 |
| `notification` | 精确 `PreToolUse(ask_user_question)` | 原有提问意图规则，恒用默认组 | acceptance 候选 |
| `subagent_stop` | `SubagentStop` | 仍未实现 | 未实现 |

`Stop` 仍是可阻止的结束尝试：若另一个 Stop hook 在首个 `end_turn` fire 后阻止继续，提醒
可能早于真正结束；若前一 fire 已被阻止，后续 `stopHookActive == true` 的继续轮不会播放。
会话结束的 `shutdown`／`channel_closed` Stop 没有 turn `promptId`，不会播放。这些边界在
binding qualification 中呈现。

两条新增绑定仍只是 acceptance 候选：`AdditionalHostReleasePolicy.verifiedBindings` 不增加，
普通 Release 不显示 Grok 入口。`SubagentStop`、取消、拒绝授权、普通 idle 与工具失败不映射。

## 真实宿主回调证据

### 普通提示词（vibe-trading）

在 `vibe-trading` 用真实 headless Grok 运行 `Reply with exactly OK and nothing else.`，
使用安装后的 5-hook 配置（installation `BD420DEB-9EBA-490A-94A7-8F8422B4A364`）：

| 时间 | 原生事件 | 回执 | 结果 |
| --- | --- | --- | --- |
| 17:13:35 | `UserPromptSubmit` | `grok-build:UserPromptSubmit:task_start:prompt_origin_unavailable:v1` | `playback_result: played` |
| 17:13:38 | `Stop` | `grok-build:Stop:stop:completion_gate_only:v1` | `playback_result: played` |

同一窗口内捕获的横幅为 `Grok Build 开始执行` 与 `Grok Build 本轮已结束`，来源均为
`vibe-trading`。`afplay` 实际参数为：

```text
/usr/bin/afplay -v 0.8 /Users/d0m999/.claudio/packs/resonant-bowl/task_start.mp3
/usr/bin/afplay -v 0.8 /Users/d0m999/.claudio/packs/resonant-bowl/stop.mp3
```

这证明开始／结束事件命中了 `vibe-trading` 工作区规则（共鸣钵音、0.8），而不是默认组
（古琴、0.3）。工作区规则新增了 `grok-build` 来源；提问意图仍按设计使用默认组。
`integrations status` 显示 `Grok Build: 已收到事件；支持 4/5 类提醒`。

### 自动唤醒与结束边界

在隔离 `GROK_HOME` 中用真实 Grok TUI 触发后台任务完成，捕获到：

- 自动唤醒 `UserPromptSubmit` 的 `promptId` 为 `task-completed-<任务 UUID>`，`prompt` 以
  `<system-reminder>` 开头；admission 不把它映射为用户开始。
- 正常 `Stop` 的 `reason == end_turn`、`stopHookActive == false`、有 `promptId`。
- 会话结束 `Stop` 的 `reason == "shutdown"` 且没有 `promptId`。
- `Stop` 输入同时携带 `backgroundTasks`／`sessionCrons`；当前轮的正常结束仍播放，
  后台任务或计划唤醒不改变本轮结束提醒。

### 目录通道

真实 Grok 在三个启动目录回传的 `cwd`／`workspaceRoot` 与启动目录一致：

| 启动目录 | `cwd`／`workspaceRoot` | Git common dir |
| --- | --- | --- |
| `/Users/d0m999/Desktop/vibe-trading` | 同路径 | `/Users/d0m999/Desktop/vibe-trading/.git` |
| `/Users/d0m999/Desktop/Claudio` | 同路径 | `/Users/d0m999/Desktop/Claudio/.git` |
| `/tmp/claudio-grok-wt`（vibe-trading 关联 worktree） | `/private/tmp/claudio-grok-wt` | `/Users/d0m999/Desktop/vibe-trading/.git` |

关联 worktree 的 common git dir 与主仓相同，符合 ADR 0005 的 Git 工作区匹配；目录证据采集
使用隔离 `GROK_HOME` 与被动 dump hook，不改写用户宿主配置。采集后 worktree 与临时根已删除。

## 自动检查

| 检查 | 结果 |
| --- | --- |
| helper 完整 executable harness | **6243 checks，0 failures**（备份路径修复后重跑） |
| GUI 完整 background harness | **15391 checks，0 failures**（编译修复与备份路径后重跑） |
| additional-host CLI 合同（Debug + Release） | **356 checks passed** |
| Grok 专项 | 343 checks，0 failures（含工作区包/默认组分离） |
| `swift format lint --strict`（变更及新增 Swift 文件） | 通过 |
| `jq empty`、`git diff --check` | 通过 |
| 普通 Release 来源列表 | 仍只有既有五个来源；Grok 不开放 |
| 验收 app 构建、输入边界、无产品导出符号、ad-hoc 签名、Sparkle | 通过 |

CLI 合同验证了新增 5-hook 模板、旧 3-hook 模板的安全升级、非法合成／shutdown／
gated Stop 零写入，以及 Debug／Release 的准入差异。

## 构建与体积

使用本机 macOS 26.5 SDK 与 `scripts/dev-bundle.sh --additional-host-acceptance` 构建：

- 签名后 GUI：**6,994,880 B**（预算 7,000,000 B）
- helper：**2,806,848 B**（预算 3,250,000 B）
- LoginItem：**54,208 B**（预算 500,000 B）
- Sparkle：**2,705,105 B**（预算 3,500,000 B）
- 非可执行资源：**2,423,979 B**（预算 3,100,000 B）
- app 正规文件合计：**14,985,020 B**（预算 16,555,105 B）
- 共享 runtime：`~/.claudio/bin/claudio` 与 `claudi0`，SHA-256
  `65b4162e260049789f286ae80538cf1ddc812baefa90d04a4e21500fc0ca39fb`，与 app 内 helper 相同

GUI 体积门禁非常接近页边界。为避免把 helper-only 的 start/stop payload 字段链接进 GUI，
原生字段校验放在新 `ClaudioHookInput` admission 中，由 CLI 预校验后把安全来源交给共享
runner；共享 Grok parser 未增加新事件字段。最终签名 GUI 低于预算，未调整任何预算。

### hooks 目录旧备份遮蔽当前配置

2026-10-29 晚在 Ghostty 的真实 Grok TUI 中再次没有提示音或横幅。检查发现
`~/.grok/hooks/claudio.json.claudio.bak` 仍是旧 3-hook、旧 installation ID
`040C9D03-3B59-4A58-B284-7DA0B1409C26` 的文件；Grok 会把 hooks 目录中的该备份也作为
hook 源载入，当前 5-hook 文件因此没有执行。把备份移出 hooks 目录后，19:19 与 19:41 的
最小真实请求再次得到 `UserPromptSubmit` 和 `Stop` 的 `played` 回执，hooks 目录只剩
`claudio.json`。

修复：Grok 的一次性备份改写到 `~/.grok/claudio-hooks.backup.json`，位于扫描目录外。
本机旧备份已移到 `~/.claudio/integrations/backups/grok-build/`。GUI 体积接近 16 KB 页
边界，自动迁移旧备份未链接进 GUI；旧安装需一次性移出遗留备份。运行中的 TUI 仍需重启或
`/hooks` reload 才会重新发现 hook。

## 配置、升级与回退

- `~/.grok/hooks/claudio.json` 由 app 的自动维护升级为 5 个 hook，均为 `timeout = 2`；
  `UserPromptSubmit`／`Stop` 不设置 matcher。安装 scope 包含 5 个 binding、Grok 1.0.70
  与 `acceptance=true`。
- 旧 3-hook 模板仍按 exact bytes 识别为 Claudio 所有，可安全 repair／disconnect；外来、
  编辑或重复 binding 文件继续拒绝。
- 用户 `vibe-trading` 工作区规则的 `surfaces` 增加了 `grok-build`；其他工作区未自动改动。
  该配置可逆：在设置中取消勾选或从 `surfaces` 移除即可。
- 运行中的旧 Grok TUI 不会自动加载新增 hook；需重启 Grok 或在 `/hooks` 中 reload。
- 回退代码用 Git 审阅范围；宿主配置用受管 disconnect 或既有一次性备份恢复。源码回退
  不代表宿主配置已恢复。

## 未完成的验收

- 人工听音（助手只观察到 `afplay` 启动与参数，未主观确认音量）。
- 运行中 TUI 的热加载、真实主／子会话组合、所有终端与多屏导航。
- VoiceOver、键盘焦点、Reduce Motion 与原生布局的人工验收。
- 普通 Release 的 Grok 准入（仍无经审阅的真实回调、原生提示和人工听音证据）。
- Developer ID 签名、公证、Gatekeeper、CI、Intel 架构与正式发布。
- `scripts/verify-settings-experience.sh` 要求 clean HEAD；当前任务变更使其停在前置条件，
  未为通过该门禁而提交或清理无关工作。
