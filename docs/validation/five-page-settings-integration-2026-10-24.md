# 五页设置本地整合与验证（2026-10-24）

整合前 `main` 为 `f47f9e17f16096809ab5bc15be5855d2408dcc73`，功能分支原提交为
`a36cc7e4800259b548657cd99615b8d402479a80`。本轮通过完整门禁的源码提交为
`f8f042ddb847223266fc38c730cecd1f416d5538`，已快进合入本地 `main`；本记录是其后的纯文档补记。
未推送、发布或部署。

## 整合结果

- 保留 `4be0e3d` 的完整五页设置实现和 `a36cc7e` 的原验收记录。
- 将功能 worktree 中的历史恢复修复及五页回归收口为 `c64cdbc`；整合主线时采用
  `41f3f04` 的历史遍历修复，去掉重复的生产分支条件，保留两组行为回归。
- `3c1bd1c` 整合原型与讨论稿的两个 add/add 冲突。首启 Swift 测试、浏览器回归、
  渲染对照页和截图保持整合前 `main` 的字节。
- 历史六页 HTML 演示保留评审和离线回归价值，显著标明历史边界并链接五页主原型。
  `DESIGN.md`、ADR 0008 和两份相关计划同步这一保留边界；现行五页合同不变。
- `c2fc9c2` 修正既有 native hover 测试的误判；`f8f042d` 为原生来源菜单添加失败诊断。
  两项测试工作均未修改生产组件。

## 最终自动验证

从干净 HEAD 执行：

```bash
bash scripts/verify-settings-experience.sh f47f9e17f16096809ab5bc15be5855d2408dcc73
```

退出码 **0**，通过提交为 `f8f042ddb847223266fc38c730cecd1f416d5538`。
环境为 Apple Silicon、macOS 27.0.1、Apple Swift 6.4。沿用 `CONTRIBUTING.md` 允许的
macOS 26.5 SDK 本地兼容方案：`SDKROOT`、`CLAUDIO_BUILD_SDK` 和 SwiftPM native build system。
临时 Bash 包装仅为缺少参数的 `swift run/build` 补参数；启动真实 Swift 前移除导出函数，
避免影响 harness 内的 PATH fixture。仓库门禁和断言未被放宽。

| 检查 | 结果 |
|---|---|
| helper 完整 executable harness | 6,187 项通过 |
| GUI 完整 executable harness | 24,862 项通过 |
| Settings target Debug / Release | 通过 |
| GUI app Debug / Release | 通过 |
| 本地化 JSON、suite 注册、格式诊断回归 | 通过 |
| arm64 开发 bundle、ad-hoc 签名结构、Sparkle 链接与架构 | 通过 |
| helper 独占 Codex transcript reader | 通过 |
| 尺寸与产品导出符号 | 通过 |
| strict format 基线差分 | 无新增诊断；baseline 743、HEAD 689，不代表全仓零诊断 |
| 工作树与基线至提交的 whitespace 检查 | 通过 |

最终开发 bundle 的 GUI 为 **6,979,312 / 7,000,000 B**，helper 为
**2,806,224 / 3,250,000 B**，正规文件合计 **14,966,221 / 16,555,105 B**。
该 bundle 只用于本机检查，随后随 worktree 清理，未作为发布物保留。

整合提交 `3c1bd1c` 的聚焦导航回归为 **240 项、0 失败**；五页浏览器回归 **6 项**、
历史原型浏览器回归 **17 项**、主原型 Node 回归 **109 项**全部通过。
后续两项提交只改变 Swift 测试，未改变这些浏览器测试消费的页面。

## 失败记录与诊断边界

第一次完整门禁在 `3c1bd1c` 的 GUI harness 中失败 **1 / 24,853**：既有命中测试要求
条件动作重现后 hover 必须为 false。将测试窗口放到静止鼠标下方可受控复现，记录显示
`hasAction=true → actionHovered=false → nativeHover=true → actionHovered=true`，
最后的 true 是新收到的原生进入事件。`c2fc9c2` 分别覆盖鼠标内外位置，断言新原生 hover
到达前不能出现陈旧状态。聚焦 **65 项、0 失败**；临时删除真实清理逻辑的反例验证产生
**1 / 65** 预期失败，恢复生产源码后重新通过。临时故障注入未提交。

第二次完整运行在 `ReviewFindingRepairSuite` 的 English / left 场景中，来源菜单未打开
表单，引发四条连锁断言失败。仅停止了经 UID、可执行文件和 cwd 核对的本轮 GUI harness；
该轮门禁退出 143，不计为通过。单独运行该 suite **68 项、0 失败**。
八轮重复诊断尝试在 300 秒预算处超时，也不计为通过；临时 runner 修改由 finally 恢复。
未稳定复现其原因，未宣称修复该问题；保留菜单未挂载、禁用、索引和动作未送达的诊断。
最终完整运行通过该 suite 及全部 24,862 项，不能据此把先前失败描述为已定位修复。

本机原生日志还出现 `TSMSendMessageToUIServer` 系统消息及现有编译弃用提示。
本记录不宣称控制台零警告或完成原生人工接受。

## 清理与隔离

合并后核对两个原分支提交及整合前主线均为 `main` 的祖先，且主线与通过门禁的功能分支树
一致。对应 worktree 无 tracked、untracked 修改，ignored 内容只有 `dist/` 和两个 `.build/`；
没有打开句柄或活动 GUI / 编译进程。使用精确路径 `git worktree remove`，随后
`git branch -d codex/five-page-settings`；worktree 注册和 `prune --dry-run` 均无残留。
其他分支及主 checkout 保留。

清理本轮五个私有临时 fixture，以及临时日志、进程采样、包装脚本和诊断目录。
三个 helper fixture 临时文件继承了测试的 `UF_IMMUTABLE`；逐文件以 `lstat` 和打开后的
inode 确认普通文件、当前 UID、单硬链接后，仅移除该标志并删除，未跟随符号链接。
未保留源码副本、恢复包或独立 patch。

在 fixture setup 前与上述清理后，对本轮记录的 **16 个已安装工具路径**比较实际目标、
SHA-256 和 POSIX mode，均一致。两个 Swift 例子如下，前后 mode 均为 `0755`：

| 实际可执行文件 | 前后相同的 SHA-256 |
|---|---|
| `/usr/bin/swift` | `34129c71a01a74f7f3b2443521519b2e5447553fa187f5fcafaaf8c42cc192e2` |
| CLT `swift-frontend` | `cf81104bf554eef05e28a8bb5285c763f1323b4511b944d755d8bdd6cb8db717` |

## 未验证

人工键盘与焦点顺序、VoiceOver、真实音频与宿主回调、真实 Provider、系统授权及登录项、
CI 指定 Xcode / 工具链、最低系统和其他 Apple Silicon 机器、Developer ID / 公证、发布与
正式接受均未在本轮验证。自动挂载、浏览器回归、本地兼容 SDK 和 ad-hoc bundle 不替代这些证据。
