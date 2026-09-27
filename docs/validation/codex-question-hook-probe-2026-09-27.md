# Codex 提问工具 `PreToolUse` 隔离探针（2026-09-27）

## 结论

在本机 `codex-cli 0.157.1` 的**三个新建、隔离的 CLI 会话**中，精确
`PreToolUse` matcher 两次命中 `request_user_input`，一次命中
`request_user_input_async`。三个回调均提供非空的 `session_id`、`turn_id`、
`tool_use_id`、`cwd`，`tool_input` 为对象；每个 `tool_use_id` 均与该临时会话
rollout 中的同一 `function_call.call_id` 对应，`cwd` 均为临时工作目录。

同步工具在 Default mode 的一次调用进入了 hook，但工具随后返回不可用；在独立
Plan mode 会话中，原 CLI 显示 A/B 选择界面，操作者选 A 后会话继续完成。异步工具
在 Default mode 的独立会话中进入 hook，工具结果为 `accepted: true`；CLI 随后
显示 A/B 问题文字，操作者用下一条普通输入回复 A。异步结果不能据此认定为可靠的
**明确输入请求**，也不证明宿主其他工作暂停。

这是 CLI 这一表面的真实 hook 与问题界面证据。此前根线程的异步调用只读观察属于
另一个客户端实例；本探针没有给那一实例安装 hook，不能把 CLI 的 hook 命中当作其
当前安装回执或生产接入证据。正式入口仍须遵守
[开发计划](../../plan/PLAN-CROSS-HOST-QUESTIONS.md)的 P0 门槛。

## 隔离与采集

- 新建 0700 私有临时根、空工作目录和独立 `CODEX_HOME`；以 `--no-daemon` 启动
  新 CLI 会话，使用 `read-only` sandbox。临时 `CODEX_HOME` 通过 symlink 引用
  现有认证文件，没有复制或记录认证内容。临时 hook 定义经人工核对后，仅在这些
  隔离进程中使用一次性 hook trust bypass；没有编辑用户的 Codex hook 配置。
- 诊断配置包含一个锚定的候选工具 matcher，以及仅用于发现工具名称的临时 `*`
  matcher。后者不属于 Claudio binding。回调处理最多读取 64 KiB stdin，只记录
  事件/工具名、字段类型、身份摘要、输入字节数和时间；不写原始回调、目录、问题、
  选项或答案。两个诊断 handler 对同一调用分别写一条，因此**精确 matcher 的真实
  调用数为三次**，不是六次。
- 每个临时会话自己的 rollout 只在测试后有界解析 `function_call` 名称、`call_id`
  摘要及工具结果类别，以核对 hook 请求身份。没有读取用户旧会话或把原始记录复制
  到仓库。隔离 CLI 会话与临时认证 symlink 随整个临时根精确删除；仓库只保留本篇
  脱敏结论，另有私有临时摘要，不保留原始回调。

## 场景与覆盖

| 场景 | 精确 `PreToolUse` | 宿主后续 | 可证范围 |
| --- | --- | --- | --- |
| Default mode 同步 | `request_user_input`，一次 | 工具返回 Default mode 不可用；无问题 UI | hook 可先于失败的工具调用触发 |
| Plan mode 同步 | `request_user_input`，一次 | A/B 原生选择界面出现，输入 A 后完成 | 同步可用路径的工具名、身份与 UI |
| Default mode 异步 | `request_user_input_async`，一次 | 工具返回 `accepted: true`，CLI 显示问题文字；下一条输入 A | 异步调用意图、身份与接受结果；未证明可靠待答 |

三次回调来自三个不同会话，三个请求 ID 互不相同。每次 hook payload 均为合法对象，
大小分别为 748、748、647 bytes；目录摘要均与该次临时工作目录相符。精确 matcher
命中与 rollout `call_id` 关联是同一临时会话内的验证，不使用相近时间猜测跨源身份。

未安装 Claudio 播放或提示入口，因此本探针没有铃音、GUI 提示、hook receipt、
当前激活或活动计数。问题到声音、原生焦点、真实用户安装回执与异步明确待答延迟
均未测量。官方文档说明 `PreToolUse` 支持多数本地函数工具，但专用路径可能例外；
本记录以当前 CLI 的实测为准。[OpenAI Docs：Hooks](https://learn.chatgpt.com/docs/hooks#tool-coverage)
