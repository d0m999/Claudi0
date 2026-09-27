# Codex App Server 只读归属探针（2026-09-27）

## 结论

在本机 `codex-cli 0.157.1` 的**一个新建隔离 CLI 会话**中，原 CLI 的同步
`request_user_input` A/B 问题界面保持待答时，另起的 `codex app-server` 进程
成功执行一次 `thread/read`，参数为 `includeTurns: false`。响应的 thread ID
与目标相符；该独立进程报告的 runtime status 为 `notLoaded`。读取后，原 CLI
的问题界面仍可操作；操作者在**原 CLI** 选择 A，原会话继续并确认选择。

这证明本次独立进程的一次只读调用没有接管该问题。它没有提供实时输入请求事件：
在该测试窗口内，App Server 没有收到提问通知，唯一的非请求通知是通用
`remoteControl/status/changed`。官方文档也明确 `thread/read` 不订阅线程事件，
不将线程载入内存。[OpenAI Docs：App Server](https://learn.chatgpt.com/docs/app-server#read-a-stored-thread-without-resuming)
因此这条路径尚不能作为 Claudio 的**明确输入请求**入口。

## 隔离与操作

- 使用独立私有临时 `CODEX_HOME` 和空工作目录；认证文件仅由 symlink 引用，
  没有读取、复制或记录其内容。CLI 以 `--no-daemon`、Plan mode、只读 sandbox
  运行，原 CLI 自己显示同步 A/B 问题。
- 从该隔离会话自身的索引取得 thread ID。另起 App Server stdio 进程，仅发送
  `initialize`、`initialized` 和一次 `thread/read`；没有调用 `thread/resume`、
  `thread/start`、`turn/start`，也没有通过 App Server 回答问题。
- 探针只检查响应是否成功、thread ID 是否一致、status 类型、是否存在 `turns`
  键和非请求通知的方法名。尽管传入 `includeTurns: false`，响应中仍有 `turns`
  键；探针没有检查其数量或内容，因此不声称该键缺失或历史为空。
- 原 CLI 回答完成后，两个进程均退出。临时根和探针清单已精确删除；没有修改
  用户现有 Codex hook 配置、安装 Claudio hook、产生声音、提示、hook receipt
  或活动计数。没有保存原始请求、答案、thread ID 或响应。

## 证据边界

| 判定 | 本次结果 |
| --- | --- |
| 独立 App Server 读取隔离 CLI 的 thread 摘要 | **已验证一次**；ID 对应，`status.type=notLoaded` |
| 本次读取未改变原 CLI 的问题处理归属 | **已验证一次**；原界面仍可回答，原 CLI 继续完成 |
| App Server 只读订阅原客户端的新提问 | **未验证**；没有收到输入请求事件，`thread/read` 本身不订阅 |
| 根客户端、快速回答、取消、自动回答及延迟 | **未验证**；本探针只覆盖一个新建 CLI 同步问题 |

本次没有尝试 `thread/resume`：它会改变观察者与线程的关系，不满足这个只读归属
试验的边界。正式 Codex 入口仍须按[开发计划](../../plan/PLAN-CROSS-HOST-QUESTIONS.md)
完成 P0 的明确请求和当前客户端验证。
