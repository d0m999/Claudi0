---
status: accepted
---

# 分离 ad-hoc 公开预览与正式签名渠道，用固定 EdDSA 身份更新

所有者选择先提供无 Developer ID、未公证的公开预览构建，以 GitHub prerelease DMG 分发；支持目标仍为 macOS 12+、arm64 与 x86_64、登录时启动。首次预览为 `0.0.1`，后续 `0.0.N`，标签为 `preview-v0.0.N`。它不是 ADR 0014/0027 的非分发验收候选，也不取得未获准 Provider 的生产资格。正式 `vMAJOR.MINOR.PATCH` 流程保留 Developer ID、hardened runtime、公证与原有真机门禁，不因缺少 Apple 凭据回退。

采用固定 Sparkle 2.10.0，仅 GUI executable 引入 Framework。一个 app-lifetime adapter 持有标准 updater；Foundation `AppUpdateModel` 只是 About 与菜单共享的投影。第二次启动询问检查意愿，同意后每日检查；禁止自动下载和安装。后台提醒不打开窗口、不激活 app；用户显式点击才交给标准窗口。DMG、只读卷或 Translocation 路径关闭更新，提示安装到应用程序目录。标准窗口的原生语言、焦点、权限与系统确认必须单独验收。

更新退出复用现有应用退出协议：生成／未保存结果提示损失，采用事务不能中断，完成后重新判断风险；取消保留旧进程和应用。重启复用 helper 字节核对、原子替换与宿主维护，事件仍为 best-effort、无磁盘回放。预览按存储能力关闭 Data Protection Keychain Provider 的状态查询、读写、生成和旧槽清理；既有凭据、选择、历史与采用音频保留。SenseAudio 的私有文件存储与百炼 ADR 0029 不降级、不 fallback，仍遵守各自准入门禁。

预览／正式包共享 bundle ID `com.claudio.app`、LoginItem identity、既有用户数据与 EdDSA 公钥。预览固定 feed 为 `https://d0m999.github.io/Claudi0/preview/appcast.xml`；正式包固定 `.../release/appcast.xml`。归档提取前验证签名，feed 必须签名，签名失败永不自动过期。只用完整 DMG，不生成 delta。私钥丢失时停止 feed 发布，从固定官方页面人工恢复，不能禁用验签或自动换钥。

候选 build 固定 clean source commit，产出 universal 原始 DMG、校验和及 manifest。publish 读取唯一验收账本、GitHub run/workflow/artifact identity 和官方 archive digest，消费已验收字节；不重编译。用官方 `generate_appcast` 从 stdin 取私钥，先核对公钥、签名并上传 Release；公网原始资产、版本和签名复验通过后才部署 Pages。任一前置失败不改 feed。正式版只有通过独立验收后才能加入预览 feed，用户确认安装后由正式包转入正式 feed；首次实现不自动开放这一迁移。

真浏览器下载、正常 quarantine、HTTPS 两版本替换、系统放行、菜单应用原生 UI、VoiceOver、真实宿主与登录、两 CPU 和 macOS 12/13+ 均须记录候选身份。缺证据时 `public_launch` 保持未通过，实现和本地自动门禁不能替代公开首发验收。

依据：[Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0)、[Gentle Reminders](https://sparkle-project.org/documentation/gentle-reminders/)、[安全配置](https://sparkle-project.org/documentation/customization/)、[Apple 安全打开应用](https://support.apple.com/en-us/102445)。
