# Codex 当前 TUI：受信任临时 hook 与对照探针（2026-09-27）

## 结论

当前 TUI 的 `/hooks` 将精确提问 hook 显示为 `Trusted`；用户在 TUI 看到了并回答了受控异步问题，但该 hook 记录 **0 条回调**。随后新增并由用户确认受信任的 `^Bash$` 对照 hook，在本代理的 `exec_command` 路径执行 `/usr/bin/true` 后同样记录 **0 条回调**。因此本轮不能把提问回调为零单独归因于提问工具不受支持；运行中会话的 hook 加载状态、本代理工具桥接路径与 TUI 原生工具路径之间仍未区分。Codex 正式提问入口继续未验证。

隔离 Codex CLI 0.157.1 的同步与异步提问 `PreToolUse` 曾分别真实命中；那是另一个进程与配置根的证据，见[独立 CLI 探针](codex-question-hook-probe-2026-09-27.md)。

## 受控条件与观察

- 启动前 `~/.codex/hooks.json` SHA-256 为 `5c4b19ca1ce6e929aa03557965b5dc4115ba835f72f9d695c1a2b55b647d952d`，权限 `0644`，无 `PreToolUse` 槽位。未运行 ClaudioGUI；本轮不预期铃音、横幅、回执或活动记录。
- 在 `0700` 私有临时目录准备只读 stdin 的诊断脚本，最大输入 64 KiB，拒绝重复 JSON 键。脚本只写事件、工具、会话和请求身份的 SHA-256、字段存在性、字节数和时间；不保存问题、选项、答案、命令正文或原始回调。两个脚本均先用合成输入预检各写 1 条，然后清空预检记录。
- 提问组 matcher 为 `^(request_user_input|request_user_input_async)$`，脚本 SHA-256 为 `b48a6792449785a31e7613a3fb9b06a9e900c50abcb49fffb426264c25a17169`。用户提供的 `/hooks` 截图先显示该组需要审核，随后回报 `Trust: Trusted`。信任后发起两次 `request_user_input_async`：工具均返回 `accepted: true`；用户确认第一条问题可见，并在第二条问题中回复 `Trusted`。两次之后提问脚本记录数均为 **0**。
- 为核对本代理的工具调用路径，另加独立 matcher `^Bash$`，脚本 SHA-256 为 `d3a1447e5cfe343b5bb00bb34d060c7a0cb5c3d34fd2ed63ee96cb798ae17538`。脚本只记录事件、工具、是否为预期会话及输入是否为对象，不保存 shell 命令。用户回报两组均为 `Trusted`。随后本代理的 `exec_command` 执行 `/usr/bin/true`，退出码 `0`；对照脚本记录仍为 **0**。这个对照只覆盖本代理工具桥接路径，不能当作用户在 TUI 原生会话手动触发的工具调用。
- 每次受控调用前核对临时配置与脚本摘要未变。官方文档列出 `PreToolUse` 对统一 exec 的一般覆盖，也提醒专门工具路径可能例外；本轮没有得到可区分这两种路径的当前会话证据。[Codex Hooks 文档](https://learn.chatgpt.com/docs/hooks#tool-coverage)

## 收尾

按临时候选配置摘要核对后，原始 `hooks.json` 字节与 `0644` 权限已恢复；恢复后 SHA-256 仍为 `5c4b19ca1ce6e929aa03557965b5dc4115ba835f72f9d695c1a2b55b647d952d`，`PreToolUse` 槽位为 0。提问与 Bash 日志均为 0 条，私有脚本、备份和日志目录已精确删除。没有改动 WorkBuddy 或 Claude Code 的 hook 配置。

下一步若要判断当前客户端的真实 hook 覆盖，须从明确由该 TUI 本身调度的工具路径建立正向对照，并核对运行中会话何时加载信任状态；在此之前不增加 Codex 正式 binding，也不把 TUI 可见问题升级为 Claudio 可消费的明确输入请求。
