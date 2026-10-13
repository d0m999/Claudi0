# GUI 体积门禁修复：2026-10-13

最终签名 GUI 为 **6,996,064 B / 7,000,000 B**，余量 **3,936 B**。相对之前
7,045,616 B 的包减少 **49,552 B**。仓库原始 `dev-bundle.sh --bailian-acceptance`
在签名前、完整签名后都通过原始 `check-release-size.sh`；没有预算覆盖、跳过检查、
临时编译优化参数、反射删除或运行时检查删除。当前包是 arm64 ad-hoc 本地走查包。

## 定位与调整

未剥离 Mach-O 的成对 N_FUN STABS 给出精确函数长度：记录范围覆盖 4,732,980 B，
`__TEXT,__text` 为 4,805,020 B，剩余 72,040 B 未归因。value witness 合计 542,088 B。
这些函数大小是归因证据，不等于可直接回收的分发字节；最终结果由相同配方的完整包门禁确认。

- 声音详情仲裁原先保存整份上一编辑器发布，却只读取包 ID、最大状态 revision、草稿 ID。
  `SettingsSoundsDetailArbitration` 的值复制函数合计 14,980 B。现在只记录这三项历史事实，
  并继续在非 Sounds 发布及 reset 时清空；复制和草稿身份过渡逻辑保持原合同。
- 编辑器模式和上下文的完整关联值反复嵌入快照、排队发布和能力账本。两个包内枚举改用
  Swift 的 `indirect` 值语义存储，保留全部字段、合成值相等与 Context 的 Sendable 合同。
  Context、epoch、selectionGeneration、snapshotRevision 和完整目录目标校验全部保留。
  Swift 为关联值增加存储间接层，涉及构造时分配与引用计数；没有改为可变引用快照或增添事实 owner。
  [Swift 官方说明](https://docs.swift.org/latest/documentation/the-swift-programming-language/declarations/)
  定义了此存储形式及枚举的值语义。

同一 SDK 参数、full LTO、-Osize、arm64、Bailian 走查开关下的未签名 GUI 对照：

| 调整 | 未签名 GUI | 相对原包 payload |
| --- | ---: | ---: |
| 原始 | 7,031,576 B | — |
| 仅上一发布字段收缩 | 7,015,072 B | -16,504 B |
| 加上模式间接存储 | 6,998,600 B | -32,976 B |
| 加上完整上下文间接存储 | 6,982,128 B | -49,448 B |

最后一行经过完整组装和签名得到 6,996,064 B；阶段差异不能算作额外代码压缩。

## 验证与交付

- 新增发布／复制／草稿／旧快照独立性及完整目录目标／请求版本回归：11 项，0 失败。
- GUI 全量 executable harness：24,747 项，0 失败。此次通过不证明已经修复之前的
  20 项原生焦点／布局失败；此前失败记录继续保留。
- Debug GUI 与标准 Release GUI 编译、严格格式检查、catalog JSON、diff whitespace：通过。
- 最终包原始预算、无产品导出符号、arm64、相对 helper alias、资源、运行时依赖、
  ad-hoc 深层签名与 Sparkle 检查：通过。新包在隔离路径、暂存副本和最终主路径逐次复验。
- helper 源码没有变化；本轮没有重跑 helper 全量 harness，之前 5,558 项通过记录保留。

验证及打包时，主 HEAD 为 `9e408d62206d2411a5005377aff8ea6e56055537`，本轮修改当时尚未暂存、提交或推送。
隔离验证快照为 `10aebad00423be629adbfc5bd997428e8999f1ac`，当前生产源文件逐项字节／mode
与包内 source identity 核对一致。完整证据目录：
`/Users/d0m999/.codex/evidence/claudio-gui-size-20261013-220142/`。

当前包位于 `dist/claudi0.app`，新 receipt 为 `dist/latest-package.json`；
原包及旧记录保留于 `dist/package-backups/before-gui-size-repack-20261013-225402`。GUI SHA-256 为 `db73afa407c198484c9f1da0755f96abff45d762a597d9583c66ece421ccdd13`。

没有安装或启动新包。原生启动、真实音频／Provider／宿主回调、人工键盘与 VoiceOver、
Apple Silicon 运行时兼容性、远端 CI、Developer ID、公证与正式发行验收未验证。
当前签名 GUI 的预算余量仅 3,936 B，后续改动和不同工具链仍须重新实测原门禁。
