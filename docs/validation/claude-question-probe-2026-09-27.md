# Claude Code 提问入口受控验证：2026-09-27

## 结论

**真实 `PreToolUse → AskUserQuestion` 回调仍未验证。** 本次仅启动一个新的 Claude Code
交互进程；它在提问前因 `api.anthropic.com` 返回 `403` 退出，进程退出码为 `1`。
探针收到 **0 条回调**，没有观察到问题界面，没有产生 Claudio 回执或播放尝试。
这次结果只能证明该隔离运行条件下的启动阻塞，不能推断工具名、字段、提示音或当前激活。

对应开发范围见 [跨宿主提问提醒计划](../../plan/PLAN-CROSS-HOST-QUESTIONS.md)。

## 运行条件

- 本机可执行文件：`~/.local/bin/claude`。
- 实际 `claude --version` 输出：`2.1.282 (Claude Code)`。
- 新建私有临时根，分别提供空的工作目录、配置目录和宿主临时目录。
- 新交互 PTY；未使用 `--resume`、`--continue`、`attach`，没有操作已有会话。
- 工具集只有 `AskUserQuestion`；权限模式为 `manual`。未使用 `--bare`、`--safe-mode`
  或任何跳过权限的选项。
- 未读取、复制或设置认证值；所查的 API key、auth token、OAuth token 和自定义 API
  endpoint 环境变量均未设置。未进行登录或网络配置调整。
- 仅准备一个无敏感内容的 A/B 选择 fixture。宿主在处理该提问前已退出，未重试。

本次启动形状如下；`<probe-root>` 是该次新建的私有临时目录：

```text
CLAUDE_CONFIG_DIR=<probe-root>/config
CLAUDE_CODE_TMPDIR=<probe-root>/tmp
CLAUDE_CODE_SKIP_PROMPT_HISTORY=1
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

claude --setting-sources '' --settings <probe-root>/settings.json \
  --strict-mcp-config --tools AskUserQuestion --disable-slash-commands \
  --no-chrome --permission-mode manual \
  --system-prompt <仅允许一次受控提问的测试指令> <无敏感 A/B fixture>
```

临时 settings 只安装 `PreToolUse` 的精确 matcher `^(AskUserQuestion)$`，回调命令仅执行
临时 Python 探针，超时为 2 秒。它不调用 `claudio hook`，不使用真实 installation ID，
也不写入真实活动摘要、receipt 或声音配置。

## 探针与保留范围

探针最多读取 65,537 字节，在内存中解码 JSON；超过 64 KiB 或无法解码时只输出固定拒绝码。
可输出的字段限定为：

- `hook_event_name`、`tool_name` 的目标值或固定的 `other_or_missing` 分类。
- `session_id`、`tool_use_id`、`cwd` 是否为非空字符串，以及各自的 SHA256 摘要。
- `tool_input` 是否为对象。
- 自此次进程启动起的单调时钟毫秒数。

不输出或持久化问题、答案、工具参数正文、原始 payload、原始会话身份或目录。
本次回调文件未生成，因此也没有身份摘要或回调延迟样本。

独立配置根用于隔离用户设置与宿主存储。官方说明 `CLAUDE_CONFIG_DIR` 将设置、历史和插件
放入指定目录；macOS Keychain 条目也按该目录区分，因此本次没有借用或迁移已有登录。
[环境变量参考](https://code.claude.com/docs/en/env-vars)、
[认证存储说明](https://code.claude.com/docs/en/authentication)

本机帮助确认 `--no-session-persistence` 仅适用于 `--print`，所以本次交互进程采用官方的
`CLAUDE_CODE_SKIP_PROMPT_HISTORY=1`。该变量覆盖 prompt history 与 session transcript。
[会话数据与历史说明](https://code.claude.com/docs/en/claude-directory#plaintext-storage)

## 实际观察与验收状态

宿主终端的错误要点为：`Unable to connect to Anthropic services`，
`Failed to connect to api.anthropic.com: Status 403`。未尝试绕过该限制。

| 项目 | 结果 |
|---|---|
| 启动当前版本的新交互进程 | 已执行；在服务连接阶段退出 `1` |
| 一次受控问题的真实 `PreToolUse` | 未观察到；回调数 `0` |
| 实际工具名、会话身份、请求身份、目录字段 | 未验证；没有回调可供判定 |
| 调用意图与明确输入请求的区分 | 未验证；没有问题调用或问题界面 |
| 首次回调延迟 | 未测得；没有可计时回调 |
| 快速回答、取消、自动回答、重复真实回调 | 未验证；未追加请求 |
| 当前用户安装 receipt / 当前激活 | 未验证；本探针不写真实 receipt |
| 临时安装的 Claudio 完整副作用链 | 未执行；本次只配置脱敏探针 |
| 实际播放与人工听音 | 未验证；没有播放尝试 |
| 原生问题界面、焦点与辅助功能 | 未验证；未到达问题界面 |

## 隔离核对与清理

启动前后在内存中计算并比较以下三个文件的 SHA256，均逐字节不变；未保存它们的原文：

- `~/.claude.json`
- `~/.claude/settings.json`
- `~/.claudio/config.json`

临时根的文件清单只包括测试 settings、探针、上述比较所需的摘要，以及独立配置根中的
宿主 app state、其备份和一次临时 team 配置。没有发现 `.jsonl` transcript/history 或
`config/projects/` 文件。没有扫描或回放已有会话内容。

新进程已退出。记录脱敏结果后，仅删除本次创建的精确临时根；没有恢复覆盖用户配置的步骤。
后续仍需在能正常启动且已授权的真实 Claude Code 会话中完成回调、问题界面、当前安装
receipt、人工听音和受影响原生 UI 的独立验收。
