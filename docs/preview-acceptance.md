# 公开预览验收账本

当前 `public_launch = not_evaluated`。本次实现分支基于 `f8662197a30939338ec74f87a7b26cb6142428aa`，
有未提交实现；其本机检查不是可 publish 的候选身份。正式签名账本 `release-acceptance-0.1.0.md`
继续独立。本文件记录证据；`preview-acceptance.json` 是 publish 唯一候选身份和 gate 来源。

## 候选登记

每个条目固定 version、source_commit、run_id、artifact_id、artifact_digest（GitHub API 的
`sha256:...`）、DMG SHA-256。不得在 artifact 下载后重编译或修改 DMG。当前 candidates 为空。`build-preview.py --inspection` 可从冻结的未提交源树生成本机 universal
走查 DMG，manifest 的 channel 固定为 `local-inspection`，publish 验证器必定拒绝。
收到真实候选后逐项记录人、时间、机器、OS、下载 URL、命令与脱敏原始输出，再按证据更新 JSON。
发布 Secret、保护环境 `public-preview` 和 Pages Actions 部署均须在 GitHub 配置；本轮未写入。

JSON gate 必须全部精确为 `passed`；缺失、`not_evaluated`、风险接受或 fixture 通过均不满足：

| Gate | 必需证据 | 当前 |
|---|---|---|
| automation | 双 harness、Debug/Release、CLI/plugin、本地化、universal bundle、体积、版本比较、验签、发布字节回归 | 未完成，见下方运行记录 |
| browser_download_quarantine | 独立账号、浏览器真实下载；DMG 与 app/helper 各阶段正常 quarantine | not_evaluated |
| two_version_https_upgrade | 固定两版 `0.0.1 → 0.0.2`；真实 HTTPS 检测、下载、替换、重启 | not_evaluated |
| native_ui_keyboard_voiceover | 菜单／About 提醒、后台不抢焦点、标准窗口、键盘与 VoiceOver | not_evaluated |
| real_host_receipts | 更新后 helper 字节、配置、显式 OFF、宿主维护、新代次真实回执 | not_evaluated |
| arm64 / x86_64 | 两机器的 OS/CPU/候选 identity 与真实升级结果 | not_evaluated |
| macos12_login / macos13plus_login | 旧 LoginItem／现代注册；开关、授权、注销／重启后真实启动 | not_evaluated |
| system_open_anyway | 真实系统拒绝／放行过程，确认下载安装指引对应该候选 | not_evaluated |
| local_storage_provider_admission | SenseAudio 与百炼各自的真实调用／原生／最终构建准入；未准入服务保持关闭 | not_evaluated |
| failure_recovery | 下列故障矩阵与未损坏旧应用／恢复入口证据 | not_evaluated |

## 两版本与故障矩阵

采用／生成中点击安装：取消退出须保留旧 app；采用锁内事务完成后重新判断。
保留声音包、音量、五事件开关、显式宿主 OFF、登录项状态、Provider 选择、旧 Keychain 凭据、
历史与已采用文件 SHA。记录新旧 app/helper version 与 SHA、运行路径、安装完成／重启和新宿主回执。
事件仍为实时 best-effort，更新期间不补播。

分别验证：feed 篡改、DMG 篡改、签名缺失、错公钥、断网、下载权限拒绝、DMG／只读卷／
Translocation、不具备替换权限、安装失败、重启失败。验签失败不能替换应用，固定官方恢复入口
必须可达。自动 EdDSA 负例只能证明 verifier 拒绝，不能代替 Sparkle 在真实替换路径的拒绝证据。

密钥只有一个专用 Keychain account `com.claudio.app.preview`，公钥已固定。仓库外本机导出副本
不能证明异机备份可恢复；独立安全备份与 CI Secret 的恢复演练保持 `not_evaluated`。禁止记录私钥。

## 本轮自动化运行记录

2026-10-09，本机 arm64，Swift 6.4 / Command Line Tools，显式使用 MacOSX26.5 SDK
与 native build system。下列是未提交实现的本机证据，不是已验收的 CI 候选。不得用本机
单架构构建替代上述平台格子。

| 检查 | 结果 | 本机原始记录 |
|---|---|---|
| helper executable harness | 5035 checks，0 failures | `/tmp/claudio-preview-helper-tests.log` |
| GUI executable harness，全量 | 15454 checks，9 failures；门禁失败 | `/tmp/claudio-preview-gui-final.log` |
| 更新、安装限制、退出等待及凭据限制专项 | 普通构建与 `CLAUDIO_PUBLIC_PREVIEW` 构建各 27 checks，0 failures | `/tmp/claudio-preview-focused-final.log`、`/tmp/claudio-preview-flag-tests.log` |
| 采用与导入专项 | 171 checks，0 failures | `/tmp/claudio-preview-adoption-final.log` |
| 生成历史与采用 lease 专项 | 166 checks，0 failures | `/tmp/claudio-preview-generation-final.log` |
| CLI、legacy install | 通过；不是真宿主激活证据 | `/tmp/claudio-preview-cli-tests.log` |
| plugin、附加宿主与迁移合同 | plugin 37 scenarios；CLI 161 checks；迁移 140 checks，0 failures；均为 fixtures | `node scripts/test-opencode-plugin.mjs`、`python3 scripts/test-additional-host-cli-contract.py`、`/tmp/claudio-preview-migration-final.log` |
| Sparkle 原生版本比较器 | `0.0.9 → 0.0.10 → 0.1.0` 通过 | `/tmp/claudio-preview-sparkle-verify.log` |
| EdDSA 归档／feed、错私钥及篡改负例 | 通过；不证明实际 app 替换路径 | 同上 |
| 官方 generate_appcast 两 DMG 回归 | 两个 fixture app 的 ad-hoc DMG；嵌入说明、保留旧条目、无 delta、原字节不变与签名通过 | 同上；不是 Claudio 两版本升级 |
| 发布 provenance／验收／字节回归 | fixture 通过，拒绝未验收或 inspection 产物 | `python3 scripts/test-preview-artifact.py` |
| workflow 静态检查 | actionlint 1.7.12 检查 preview、release、ci 三份通过 | `/tmp/claudio-preview-actionlint.log` |
| universal inspection 构建 | **未通过**；x86_64 GUI 链接失败，没有 universal 候选 DMG | `/tmp/claudio-preview-universal.log` |

全量 GUI 的九项失败为：缺失历史 `Pixel Motion Prototype.html` 一项、声音包选型板状态回归
一项、百炼 credential gallery 的原生附属表单六项、采用后刷新次数一项。最后一项在独立
采用专项复验时未重现；后续诊断已确定未等待后台扫描的测试竞态，见下文。不能用专项通过抵消全量失败。未补造历史素材、降低
断言或将原生失败标为通过。

本机 `libswiftCompatibility56.a` 和 `libswiftCompatibilityPacks.a` 只有 arm64/arm64e，
x86_64 链接缺少 `__swift_FORCE_LOAD_$_swiftCompatibility56`；没有可用的其他 Xcode／Swift
工具链。须在具备完整双架构工具链的 CI／机器上重跑 universal，不修改部署目标绕过兼容库。

收尾检查：GUI Debug 通过（`/tmp/claudio-preview-debug-final.log`）；最终
`CLAUDIO_VERSION=0.0.1 bash scripts/dev-bundle.sh --public-preview` 完整成功退出
（`/tmp/claudio-preview-bundle-final.log`），包括 Release 编译、ad-hoc app／LoginItem／helper
与 Sparkle 五个 Mach-O 的逐层签名、动态链接和 arm64 核对。产物只在本机
`dist/claudi0.app`，没有 universal DMG／候选 manifest，不可公开 publish。
app、helper、LoginItem 均读回 `0.0.1`；安全 feed 配置、第二次启动同意所需的偏好缺省、
每日间隔和禁用自动下载／安装的 plist 值通过检查，二进制身份记录在
`/tmp/claudio-preview-bundle-metadata.json`。这不是启动、系统放行、音频或真实更新证据。

最终签名后的 arm64 GUI `6,738,416 B`、helper `3,155,552 B`、LoginItem `54,208 B`；
Sparkle 独立正规文件 `2,705,105 B / 3,500,000 B`，普通资源
`2,502,206 B / 3,100,000 B`，bundle 合计 `15,155,487 B`。原各产品／资源预算通过，
没有为本机 Intel 工具链失败放宽预算或架构要求。

格式化后更新专项再次为 27 checks、0 failures（`/tmp/claudio-preview-focused-formatted.log`）。
新 Swift 文件按 `.swift-format` strict lint 通过；Python 编译、shell 语法、JSON／catalog
解析、14 个新增英文／简中文案的同占位符和 `allKnown` 注册、`git diff --check` 均通过。
本轮未提交、推送、触发 GitHub workflow、创建 Release 或部署 Pages。

### 全量九项失败的后续诊断（2026-10-09）

基线为同一 `f8662197a30939338ec74f87a7b26cb6142428aa`、没有 Sparkle 的独立
`Claudio-preview-baseline-diagnosis` worktree。只在该 worktree 的三个测试文件临时增加套件
选择入口、带标签的观测和受控扫描排队；原始断言保持不变。诊断后已逐字节恢复三个文件，
该 worktree 为 clean。可重放的诊断 patch 保存在仓库外
`/tmp/claudio-diagnose-preview9.patch`，不会进入候选或 Git。

| 原失败数 | 已确认原因 | 对照证据 |
|---|---|---|
| 1 | `da2a035160494ed9f7d6ad1b9db2cc037b7e9002` 删除了旧 `Pixel Motion Prototype.html`，`EventAnimationIntegrationSuite` 仍读取它核对导出参考 | 删除前 Git blob 的 SHA-256 与现有 playback reference 的 `sourceSHA256` 都是 `447509d637fef2e11bb8c3c65e249476bc8dbd127f771fa219729b428ded22fc`；不是 Sparkle 删除资源 |
| 1 | HTML 固定列出 6 个包，但 `.gitignore` 只允许版本化 `minimal-chime`；测试以磁盘目录作期望，错误依赖另 5 个本机忽略包 | `node scripts/test-sound-pack-selector-state.js` 在原工作目录通过，在预览和独立基线 checkout 均失败；`/tmp/claudio-diagnose-selector-{main,current,baseline}.log` |
| 6 | 普通构建不准入百炼，`SettingsSoundsLibraryView.present(.service)` 正确拒绝；gallery 却无条件期望凭据附属表单。`8a3f14c` 已增加此准入 guard，测试矩阵未同步 | 基线普通构建六项均为 `admitted=false`、modal 被清除、无 attached sheet；只加 `CLAUDIO_BAILIAN_ACCEPTANCE` 后同样六项 `admitted=true`、attached=true，6 checks / 0 failures；`/tmp/claudio-diagnose-gallery-{baseline,admitted}.log` |
| 1 | 采用返回后立即读 scanner recorder；mutation 结束只排程后台扫描，不保证扫描已经执行。该断言没有等待共享库事务与扫描收敛 | 正常基线最小场景 30/30 通过；受控占住进程内同一 serial scan queue 时 3/3 原断言失败：活动为 true，计数仍 1；释放并等待后计数恰为 2，无重复刷新；`/tmp/claudio-diagnose-adoption-{base-loop,gated-repeat}.log` |

这些原始断言、gallery／registry／service 入口、选型板及 ignore 文件均与基线相同；受控
采用失败也在没有预览退出协调的基线上复现。此次查因未改产品、测试断言、准入政策或资源。
后续修复应同步被退休资源的验证契约、消除对忽略音频的测试依赖、分别验证普通构建拒绝入口
与百炼验收构建的六种表单状态；采用检查应等待现有
`waitForMutationTransactionsToQuiesceForTesting()` seam 后继续保留 exactly-once 断言，
不加固定 sleep、不让生产采用阻塞等待扫描。

本次再次执行预览分支全量得到 15453 checks / 10 failures
（`/tmp/claudio-diagnose-current-full.log`）：原八个确定性失败重现，采用竞态未重现，另有两项
I-04 sibling compilation probe 因本次直接运行 harness 未继承 `SDKROOT` 而失败。其子
`xcrun swiftc` 使用默认 27.0 SDK，不能加载用 26.5 SDK 构建的模块；这两项不是原先九项。
用相同原始 Positive／Negative 源码、原参数和当前预览模块，补上
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` 后全部原始断言通过
（`/tmp/claudio-diagnose-sdk-{positive,negative}.log`）。没有把这次全量失败改记为通过。

### 九项失败修复（2026-10-09）

修复在 `Claudio-public-preview` 隔离 worktree 内，保留上述失败与诊断记录。

- 从删除前 Git blob 按原字节恢复 `designs/pixel-motion/source/Pixel Motion Prototype.html`。
  SHA-256 仍为 `447509d637fef2e11bb8c3c65e249476bc8dbd127f771fa219729b428ded22fc`。
  导出、资源回归和 GUI 集成套件读取同一路径；它是归档来源，不恢复历史 UI 为当前产品。
- 选型板以已版本化 `packs/LICENSES.md` 的当前 curated roster 核对精确名单，继续拒绝缺项、
  多项和重复项。忽略的本地候选音频不再是状态回归的隐式前提；音频／许可证检查仍独立执行。
- gallery 按 Provider 准入和凭据存储能力分别断言打开或拒绝，并核对 modal 清理。
  新 `--ai-cue-gallery` 接口供普通、百炼验收与公开预览构建回归；CI 增加后两种矩阵。
  当前声音页的生成／管理按钮与 service 表单入口同步检查存储能力，底层 Keychain 防线保留。
- 采用回归先受控占住共享扫描队列，验证生产采用完成写入时扫描仍排队，随后等待现有
  `waitForMutationTransactionsToQuiesceForTesting()` seam。继续要求恰好一次刷新、只失效原包
  和真实活动，不使用固定 sleep，也不让生产采用等待扫描。

修复后验证统一继承 `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`，
避免 sibling probe 使用另一个 SDK。本次全量为 23891 checks、0 failures；原九项失败全部消除。检查数增加来自恢复完整的
2809 个动画边界样本及追加准入／竞态断言，没有删掉套件或降低断言。

| 修复后检查 | 结果 | 本机原始记录 |
|---|---|---|
| GUI 全量，普通构建 | **23891 checks，0 failures** | `/tmp/claudio-fix-nine-gui-full.log` |
| helper 全量 | 5035 checks，0 failures | `/tmp/claudio-fix-nine-helper-full.log` |
| 采用／导入，含受控扫描排队 | 172 checks，0 failures | `/tmp/claudio-fix-nine-adoption.log` |
| credential gallery，普通构建 | 56 checks，0 failures | `/tmp/claudio-fix-nine-gallery-normal.log` |
| credential gallery，`CLAUDIO_BAILIAN_ACCEPTANCE` | 62 checks，0 failures；含六种准入表单 | `/tmp/claudio-fix-nine-gallery-admitted.log` |
| credential gallery，`CLAUDIO_PUBLIC_PREVIEW` | 49 checks，0 failures；受限入口拒绝并清除 modal | `/tmp/claudio-fix-nine-gallery-preview.log` |
| 公开预览更新／凭据专项 | 27 checks，0 failures | `/tmp/claudio-fix-nine-preview-focused.log` |
| 动画来源／资源 | SHA 一致；480 帧、2809 边界样本、7 个 runtime 文件一致；修改源拒绝旧导出 | `/tmp/claudio-fix-nine-animation-export.log` |
| 选型板 | clean fixture 不依赖本地音频；缺项／多项／重复项均拒绝 | `node scripts/test-sound-pack-selector-state.js` 及仓库外受控 fixture |
| 候选包 | 15 tests，0 failures，8 个本地音频项因目录缺失 skip；未取得音频证据 | `python3 scripts/test-sound-pack-candidates.py` |
| CI 静态合同 | 缓存身份、YAML 解析、actionlint 1.7.12 三份 workflow 均通过 | `/tmp/claudio-fix-nine-actionlint.log` |
| GUI Debug | 通过 | `/tmp/claudio-fix-nine-gui-debug.log` |
| 预览版 Release／bundle | arm64 编译、逐层 ad-hoc 签名、Framework 链接／架构、各独立体积预算通过 | `/tmp/claudio-fix-nine-bundle.log` |
| 版本与更新配置读回 | app／helper／LoginItem `0.0.1`；固定 feed／公钥、签名合同、每日间隔、自动检查偏好缺省及关闭自动安装符合合同 | `/tmp/claudio-fix-nine-bundle-metadata.json` |

这些是本机自动化和 fixture 证据。`public_launch=not_evaluated` 与空候选列表保持不变；
没有提交／推送／触发 CI／发布 Release／部署 Pages。真实升级、平台、宿主与原生人工门禁仍待验收。

## 密钥与渠道准备

只需一次 `generate_keys --account com.claudio.app.preview`。重跑时必须取回既有身份，不重新生成替代密钥。
本机 `generate_keys -p` 的输出须与 `config/sparkle-public-key.txt` 完全一致；导出只写仓库外 `0600` 文件。
独立离线备份确认后，将同一 base64 32-byte seed 设置为 CI `SPARKLE_PRIVATE_KEY`。不要写入 issue、
普通配置、终端输出或 Git。CI 先从 stdin 派生公钥比对，缺失／不匹配立即停止。

先运行 preview workflow `mode=build`，其 `target_commit` 必须等于触发 `main` 的完整 SHA。
验收固定的 run/artifact 后登记候选身份与各 gate，明确公开发布授权后才能运行 `mode=publish`。
环境 `public-preview` 应配置负责人审批；该环境审批与 workflow 的 `release_authorized` 只记录既有授权，
不代替用户授权。若 Pages 已承载额外内容，先完成共享站点部署方案；当前输出只拥有项目预览站点。
