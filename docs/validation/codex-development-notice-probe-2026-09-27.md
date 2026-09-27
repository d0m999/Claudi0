# Codex 当前客户端与 Claudio 开发提醒受控验收（2026-09-27）

## 结论

在当前 Codex TUI 的一次真实 `request_user_input_async` 调用前，显式启动隔离的
DEBUG Claudio 会话观察实例。用户确认**听到一次短铃、看到 Claudio 横幅**；
用户没有看清横幅文字，因此本次不宣称“即将提问／开发观察”的具体文案经人工确认。
观察器固定码依次为 `reader_started`、`model_accepted`、`player_started`、
`player_exited_successfully`。这些程序记录与人工听音、可见反馈分别成立。

前两次当前客户端异步探针只启动了[只读诊断](codex-current-client-async-visibility-probe-2026-09-27.md)，
没有运行 ClaudioGUI 或提问 hook；当时没有 Claudio 反应是测试设置的结果，
不是播放器故障。此前将用户的“没看见”解释成 Codex TUI 没显示问题，现已按其澄清
更正：用户在 Codex TUI 看到了问题，关注的是 Claudio 横幅和声音。

## 环境与步骤

- 使用本次工作区的 DEBUG `ClaudioGUI`，通过本机 native build system 和
  `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` 构建通过。此命令是
  当前缺少 `xcstringstool` 时的替代编译证据，不等于标准 GUI 门禁通过。
- 在 0700 私有临时根组装独立 `.app`，使用不同的 bundle ID、
  `CLAUDIO_TEST_ROOT` 和 `CLAUDIO_TEST_HOME`。私有状态及 app 资源均包含仓库
  `minimal-chime`；`notification` 开启，测试音量 0.8，其 MP3 时长约 0.522 秒。
  临时 app 的签名验证、Info.plist 和资源预检通过；没有替换现有安装。
- 取得用户明确就位回复后，给 DEBUG app 指定当前根会话的**单个精确 rollout
  文件**和会话身份，启用 `CLAUDIO_DEV_CODEX_QUESTION_OBSERVER=1`。观察器报告
  `reader_started` 后才发出一条真实异步问题。读取从新 EOF 开始，不回放历史。
- 用户在原 Codex TUI 接收问题，并人工报告听音和横幅；不记录问题、选项、答案、
  原始会话路径或请求 ID。本次没有量取问题到声音／横幅的端到端延迟。

## 边界与恢复

| 项目 | 本次判定 |
| --- | --- |
| 当前 Codex TUI 的真实异步调用 | 已发生；不推断任务暂停 |
| Claudio 开发观察的铃音 | **人工听到**；程序另记录播放器正常退出 |
| Claudio 开发观察的横幅 | **人工看到**；具体文字未看清，仍未验证 |
| 原输入焦点、VoiceOver、明暗主题 | 本轮未测试；既有合成焦点试验另记 |
| 明确输入请求、“需要你” | 未验证；此来源只输出调用意图 |
| Codex `PreToolUse`、正式 binding、当前安装回执 | 本轮未安装或产生，仍未验证 |

人工反馈后按精确进程路径关闭临时 app，并确认无该实例进程；清点私有临时根
后将其删除。开发观察路径不调用 hook receipt 或活动写入入口，本轮没有取得
当前安装回执。用户 `~/.codex/hooks.json` 的 SHA-256 与本轮开始前一致，
仍没有 `PreToolUse` 槽位；因此此次通过的是**开发会话观察原型**，不表示
Codex 正式 hook 已接入。
