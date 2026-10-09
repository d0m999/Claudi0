---
status: accepted
---

# 在应用内录入并私有本地保存百炼配置

2026-10-09 所有者明确选择与 WorkBuddy 类似的私有本地文件方式，而不是传统 Keychain。此决定仅取代 ADR 0027 的百炼 Keychain 存储和首次使用前强制删除旧 Qwen 槽的要求；固定北京业务空间、双模型权限检查、生成合同和非分发验收门禁保持不变。

用户在 Claudio 内输入 API Key 和业务空间 ID，通过两个模型的只读权限检查后，将完整生成服务配置原子保存到当前用户的 `~/Library/Application Support/Claudio/Credentials/bailian-beijing.json`。同一版本化记录保存 Key、业务空间和真实生成验证状态；保存不会生成音频，不预置共享 Key，不自动导入仓库 `.env`。Key 与业务空间不能分别写入或分别替换，失败保留完整旧配置。

复用 ADR 0015 的文件安全边界：目录 `0700`、文件 `0600`，从已打开的文件描述符检查当前用户所有权、权限和无扩展 ACL；拒绝符号链接、硬链接、非普通文件、空内容、损坏记录与超过 2048 字节的记录。同目录私有 staging 在写敏感字节前检查权限，`fsync` 后原子替换，失败只清理本次 staging，不自动修复不安全对象。状态查询、读取和缺失项删除不创建目录或文件。

文件未加密，不隔离拥有同一用户文件访问权限的其他程序。原生表单与原型必须如实披露；普通配置、defaults、日志、错误、诊断导出、声音包和 Git 不包含凭据内容。删除百炼配置只删除这个文件，保留已生成音频和绑定。SenseAudio 原有路径和字节格式、其他服务的 Keychain 槽均保持原样。

这是显式存储政策，不是 Keychain 失败后的 fallback。百炼的新配置操作不查询、复制、迁移、覆盖或删除已有百炼／旧 Qwen Keychain 项；它们保留且不用于新生成。用户在 Claudio 内重新录入。其他服务既有的独立旧槽清理行为不作为百炼可用性的前置条件，不将未执行的 Keychain 清理标记为完成。

依据：[WorkBuddy 模型配置](https://www.codebuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Model) 明确含 API Key 的参数存于本地 `models.json`；本机 5.7.7 的静态保存链确认其当前文件 codec 未启用加密。此选择不宣称文件方案具有 Keychain 的隔离能力。保存、重新读取、原生重启、真实生成和发布资格分别验证；普通包的百炼入口仍由 ADR 0027 的验收门禁控制。
