# 百炼 Audio 3.1 实施与验证

合同：[ADR 0027](../docs/adr/0027-use-bailian-beijing-audio-31.md)。本记录不包含完整下载 URL、Key 或业务空间 ID。

## 当前实现

- 唯一 `bailian-beijing` 路线；旧北京／新加坡调用撤下。业务空间为类型化 DNS 标签，地址固定北京 HTTPS。
- Flash 固定中英音色、新 SSE PCM 封装 WAV；Next JSON 的实测 OSS 地址先经限定 HTTPS 转换，再立即匿名下载。三种风格实际发送、必须三项全部有效；生成 POST 不重试，预算 60/180 秒沿用共享绝对 deadline。
- Key 与业务空间、真实生成验证事实保存在同一原子 Keychain 记录。保存先检查两模型推理权限，失败保留原配置；一次生成捕获同一配置租约，版本变化拒绝迟到发布。
- 可重复旧四槽迁移；失败可重试，其他服务继续可用。旧选择映射到百炼待配置，不 fallback；旧历史服务标签与没有模型 ID 的记录可识别，新批次记录实际模型 ID。
- 先改现行 HTML 凭据表单，再同步原生双语表单。保留单在途与后台生成生命周期。未修改 `designs/app-motion/`。
- `bash scripts/dev-bundle.sh --bailian-acceptance` 显式构造非分发验收 app，编译 `CLAUDIO_BAILIAN_ACCEPTANCE`，plist 标记 `ClaudioBailianAcceptance`。普通构建不开放新选择入口；旧选择可呈现待配置身份。

## 真实配置与资源发现（2026-10-08）

使用本机已安装 `bailian-cli` 2.1.0，用户完成控制台浏览器登录。唯一北京业务空间及普通 Key 已写入 Git 忽略、0600 的 `.env`。仅显式开启 Flash/Next 两模型 `inference` 权限；重新读取 `AUTHORIZED` / `INFERENCE` 均通过。未开启全部模型、微调或部署。

`python3 scripts/discover-bailian-assets.py --discover` 发出 **1 次** Next POST（14.5 秒）；返回 URL 的脱敏 origin 为 `http://dashscope-result-bj.oss-cn-beijing.aliyuncs.com:80`。不符合已确认的 HTTPS / 443 合同，立即停止 Next 验收。**没有下载、没有将 HTTP 改成 HTTPS、没有 redirect、没有追加生成或备用模型调用。MIME、匿名下载及最终 URL 稳定性均未验证。**

随后用户明确授权调整“返回地址必须直接满足 HTTPS”的规则。仅允许同一实测域名的 HTTP 默认端口或 80 输入转换为 HTTPS / 443，路径和签名 query 字节保持原样；不发明文请求，不跟随跳转。HTTPS 输入原样校验，其他域名、IP、userinfo、fragment、端口和非法路径拒绝。

第二次（也是最后一次）资源发现发出 **1 次** Next POST（16.63 秒），返回相同 HTTP origin；转换后匿名 GET `https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com:443` 返回 **200**，MIME **`audio/x-wav`**、134444 字节、WAV magic 通过、零跳转、最终 URL 与转换后的请求完全一致。未持久化完整下载 URL、响应或 Key，也未保存发现音频。

`BailianAssetContract` 固定这个 HTTPS origin、实测 MIME 和限定转换规则；验收 registry / runtime 使用同一政策。下载边界仍然由代码持有，不从运行时响应学习。缺失政策的注入接缝仍在 Next POST 前关闭。普通构建资格没有改变。

请求预算状态仅存于忽略的 `dist/bailian-acceptance/request-budget.json`，发现最多 2 次，总生成最多 20 次；失败先计数，不自动重试。资源发现阶段消耗 **2 次生成请求、用完 2 次资源发现额度**。随后六组执行结果及最新预算见本文末尾。

## 自动与原生证据

使用已安装的 `MacOSX26.5.sdk`，按 CONTRIBUTING 的兼容 SDK 接缝运行本机检查：

- helper executable harness：5023 项全部通过。
- GUI `--bailian-regression` 最终集中复查：706 项、0 失败，包含新 provider、engine、dispatcher、view model、历史、gallery 与现行 HTML 合同（初次核心回归 291 项通过）。
- `--senseaudio-isolation`：247 项、0 失败。修正迁移新增后按 profile 存储验证状态的测试夹具，未放宽隔离断言。
- `--sound-editor-ai-lifecycle` 独立复查：92 项、0 失败。使用模拟生成器挂载原生 UI，验证表单和后台生命周期；不是真实 provider 的听感、保存重启或采用验收。
- 普通 GUI Debug / Release `ClaudioGUI` 构建通过。
- `--release-layout` 独立复查：147 项、0 失败。完整 harness 首次遇到 package dump JSON 解析失败；独立 `swift package dump-package` 返回合法 JSON，未修改该基线测试。
- 定位目录 `jq empty`、HTML 所有 script 的 `node --check`、Python 编译、bundle shell 语法及 `git diff --check` 通过。
- `CLAUDIO_BUILD_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash scripts/dev-bundle.sh --bailian-acceptance` 通过，包含 ad-hoc 签名验证、arm64 可执行体与资源体积检查。
- 调整规则前的 Bundle `dist/claudi0.app` 曾记录 345 个源码文件摘要；`source_digest` 为 `c45326c1582919cf4887265c2bc1de4a2ee28d0f6e2caefa58ba565d7b533cb4`，资源政策 `null`，`distribution_eligible: false`，plist 验收标记为 true。
- 完整 GUI executable harness 已运行：15084 项，首次 40 项失败，exit 1。其中 10 项来自迁移触发的测试 metadata 全局变量、1 项来自旧 provider 数量断言，两者已修正并通过上述集中复查；27 项原生生命周期断言在独立运行的 92 项中全部通过，1 项 Release package JSON 解析在 147 项独立复查中通过。完整串联运行尚未重新取得通过结果，不将独立复查替代为全套通过。
- 剩余 `EventAnimationIntegrationSuite.swift:266` 引用已缺失的 `designs/pixel-motion/Pixel Motion Prototype.html`；HEAD 中也不存在该文件，该测试没有改动。未重建删除的历史原型。

资源下载合同现已通过。真实六组生成与原生采用尚未完成，不得宣称整个 profile 已取得生产资格。原生保存重启、实际听感、试听、归档、显式采用和失败保留原绑定均未验证。本地 ad-hoc Bundle 不是双架构签名、公证或发布证据。当前未 commit、push、发布或变更 issue 状态。

## HTTPS 规则调整后的验证

已新增限定域名/端口转换、签名字节不变、匿名 HTTPS GET 与各种边界绕过的确定性回归。当前 GUI 集中回归首次构建被并行试听功能改动阻断：`SettingsPresentationDependencies.manualPreview` 在非隔离上下文访问 MainActor 属性。未改动或回滚这些并行文件。

已复制当前 core 源码与百炼 suite 到私有隔离目录，仅缩小临时 harness 的依赖与入口；没有替换被测 core 代码。隔离普通构建的百炼 core suite 为 **122 项、0 失败**。四个本次变更的百炼 core 文件（provider、asset contract、registry、runtime）与隔离副本逐字节一致。隔离验收编译标记构建最终为 **125 项、0 失败**（增加实测 `audio/x-wav` 正控与 MIME 漂移拒绝；初次验收标记为 121 项）。普通构建额外检查旧选择待配置投影，因此数量不同。上一版本 Bundle 的签名/摘要不作为本次规则的证据，新 Bundle 结果见下文。

本次 shell 语法、Python 编译、定位目录 JSON 与 `git diff --check` 通过；Bundle 身份脚本已独立执行，确认从 Swift 源码读取实测 origin / `audio/x-wav`，包含限定转换规则并保持 `distribution_eligible: false`。这不替代 app Bundle 的实际构建、签名或原生验收。

并行试听 owner 随后修正了属性的 MainActor 隔离，现已开始当前工作区 GUI 集中复查；不是本任务修改该并行文件。

当前工作区 GUI 集中 harness 又遇到并行试玩接缝新增 `previewSession` 参数、尚未同步的 MountedVolume/PanelMounted 测试调用；未修改这些测试。当前 GUI Debug 产品构建已通过（与整套 harness 编译是不同门禁）。随后已重建绑定新政策的本地验收 Bundle。

最终 `CLAUDIO_BUILD_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash scripts/dev-bundle.sh --bailian-acceptance` **exit 0**，GUI Release 验收构建、helper/LoginItem、ad-hoc 签名、导出符号和体积检查通过。`dist/claudi0.app` 包含 352 个源码文件摘要，构建开始快照与打包身份文件逐字节一致，打包完成时与工作区一致，构建期间没有源文件漂移。最后复查时并行修改已继续更新 `NativeUIRegressionController.swift`；Bundle 保留构建快照，四个百炼 core 文件及下载政策仍与当前工作区一致。`source_digest`：`54a5219a1034f43d1327a6789db1fccaa44b64d199ceae0430c3effd68b1547c`。下载政策记录为实测 HTTPS origin / `audio/x-wav` / 限定 HTTP 输入转换 / 匿名 GET / 零跳转 / 最终 URL 与转换请求一致；`distribution_eligible: false`。

本次规则修正与资源下载验证完成。原请求中六组三候选及真实原生保存重启、听感、试听、历史、显式采用和失败保留原绑定验收仍未完成；不将资源发现、隔离 suite 或本地 Bundle 构建替代为这些验收。未追加生成、未 commit/push/发布，未修改并行试听和动效工作。

## 六组真实生成执行结果（2026-10-08）

使用冻结的源码副本、生产 `AICueRuntime`、顺序候选适配器、真实 HTTPS transport / asset fetcher 与 AVFoundation 时长检查执行。凭据从本机私密配置读取，运行器使用隔离的内存 credential vault；这不是应用 Keychain 配置验收。两个模型的只读权限检查通过后，每组仅执行一次，生成请求在发送前持久计数。

| 组 | 模型 | POST 数 | 结果 |
|---|---|---:|---|
| 中文“任务完成” | `qwen-audio-3.1-tts-flash` | 3 | 完整三项，1040 / 1120 / 1200 ms；49964 / 53804 / 57644 字节 |
| 英文“Task complete” | `qwen-audio-3.1-tts-flash` | 3 | 完整三项，1360 / 1440 / 1440 ms；65324 / 69164 / 69164 字节 |
| 自然动物声 | `qwen-audio-3.1-tts-next` | 1 | 首项约 10.67 秒 `transportFailure`，终止整批 |
| 车站短旋律 | `qwen-audio-3.1-tts-next` | 1 | 首项约 10.27 秒 `transportFailure`，终止整批 |
| 特效 | `qwen-audio-3.1-tts-next` | 1 | 首项约 10.67 秒 `transportFailure`，终止整批 |
| 混合声音 | `qwen-audio-3.1-tts-next` | 1 | 首项约 10.67 秒 `transportFailure`，终止整批 |

成功两批通过生产 `GenerationHistoryStore` 保存到 `~/.claudio/generation-history`；独立 WAV 检查确认六条均为 mono / 24 kHz / 16-bit PCM。六组临时目录清理通过，失败四组没有残缺归档。未裁剪、补发、fallback 或生成 POST 重试。累计 **12 / 20** 个生成 POST（含两次发现）；尚余额度不构成重跑授权，遵守失败不追加调用的合同。

失败原因已由生产 transport 接缝复现：Next 同步响应使用默认 `.connectionBudget`，约 10 秒尚未收到响应头即取消；资源发现已观察到 14–17 秒的生成等待。修复为 Next 使用 `.generationDeadline`，保持原整批 180 秒绝对 deadline，Flash 和权限 GET 保留连接预算。延迟响应回归在修复前失败、修复后通过；没有用真实请求复测修复。

修复后的隔离 core harness **219 项、0 失败**；当前工作区普通集中回归及最终 `CLAUDIO_BAILIAN_ACCEPTANCE` 集中回归均为 **743 项、0 失败**。验收编译标记下的 dispatcher 和 view-model 测试夹具改为使用编译配置的实际 profile roster；未放宽不完整注入的拒绝断言。完整 GUI harness 没有重新取得全套通过，前述基线缺失原型文件仍不作为本任务恢复对象。

## 原生验收 Bundle 与配置边界（2026-10-08）

保留实际生成对应的 `dist/bailian-acceptance/claudi0.app`：352 个源码摘要，`source_digest` 为 `f0ccd710afeee7e628e663118f4168ccc906af9026c5fed4e2b45796e1208c7f`，可执行体 SHA-256 为 `38c2f4bdc8c2cc146aa6696743afa4af7f46327ff72174953da184635b4d9e0f`。这份源码在 Next 超时修复前。

另构造 `dist/bailian-acceptance/claudi0-native.app`，仅在冻结源码中同步 Next 等待修复与验收启动时展示既有 retained settings window；不创建第二个窗口 owner，不自动生成。其 `source_digest` 为 `a81e85051f7a0cf569a0524679a8b0000c650a586a810a956bc7d4febc6d917c`，可执行体 SHA-256 为 `b8e9b8308e2b2d0c35417705445a3f45baa6fb907c0022c350e75e0151ebbf97`。GUI Release、helper/LoginItem、ad-hoc 签名、导出符号和体积检查通过。两份 Bundle 均记录相同固定下载政策且 `distribution_eligible: false`；与生成后修复的差异明确保留，不宣称失败组在新 Bundle 已通过。

用户报告旧验收 App 双击无窗口和菜单图标。旧进程实际仍在 `NSApplication.run` 等待事件，因此进程存活不作为可操作证据。新版启动展示设置窗口已通过实际 AX 观察；重新进入“声音 → 生成记录”后，实际原生页面显示两批、六条及各自时长。点击中文候选“试听”后观察到“停止试听”状态；真实听感等待用户确认。

应用配置保存尚未通过：生产 Keychain vault 在旧槽删除时返回 `-34018`，写入未发生，原配置保留；新进程读取同样不可用。只读 `security find-identity -v -p codesigning` 返回 0 个可用签名身份。依据 [Apple TN3137](https://developer.apple.com/documentation/Technotes/tn3137-on-mac-keychains) 与 [Apple 的错误说明](https://developer.apple.com/forums/thread/114456)，Data Protection Keychain 需要相应签名 entitlement，`-34018` 为缺失 entitlement。没有改用普通文件、降级 Keychain 政策或添加未经验证的 entitlement 绕过。Keychain 保存与重启、真实听感、显式采用及真实失败保留绑定仍需分别记录；本地 Bundle 不作为签名、公证或发布证据。

## 原生采用与新进程读取结果（2026-10-08，最新）

用户截图显示多个同名菜单图标，因此仅退出本任务旧验收实例，保留其他普通 App、UI Regression 和 App Motion 实例。新版窗口通过精确 Bundle 路径连接，最终留在生成记录页供人工试听。听感问题尚未得到确认，不能把播放按钮状态作为真实听感通过。

实际原生操作：新建“百炼验收 2026-10-08”草稿，从“响应结束 → 设置… → 从生成记录选择…”选择中文清晰候选并点击“选用”，首项成功发布为普通用户声音包；再从“用户发起”事件同一路径采用英文清晰候选。最终包 ID 为 `cue-3f1c0c28-64e1-44a6-8a82-6370206d92f1`。原生详情显示 `stop → 任务完成 1`、`task_start → Task complete 1`。包内两条独立 WAV 副本与对应历史音频 SHA-256 逐字节一致，采用后的包试听按钮也能进入“停止试听”状态。

原有六个声音包 manifest 的摘要与采用前一致，`~/.claudio/config.json` 摘要不变；未更改默认组／工作区选包或事件开关。新包和两批历史保留供用户复核。对本次验收进程执行精确 SIGTERM 后，用同一 Bundle 启动新进程，原生详情仍显示上述两条绑定，重新进入记录页仍显示完整两批六条。此证据为已落盘采用和新进程读取，不是凭据保存重启通过，也不是优雅退出路径验收。

原生页面发现两个尚未解决的呈现问题：首次进入历史页可能显示空记录，返回声音页再进入后显示两批；草稿首项发布后短暂落在“当前目标不可用”，返回声音包列表后能进入已发布包并读取正确绑定。新建名称曾停留在忙碌状态，随后保存完成。没有修改并行任务所有的声音页呈现文件，也没有把这些恢复操作报告为初次导航成功。

当前结论：六组均按失败即终止合同执行一次，只有 Flash 两组取得完整生成和真实原生采用／新进程读取证据；四组 Next 没有取得完整生成证据。累计仍为 **12 / 20**，未追加修复后真实调用。权限查询、资源下载合同与确定性检查通过；应用 Keychain 配置、全部六组成功、人工听感、首次导航和真实生成失败后的原生旧绑定保留仍未通过或未验证。新 profile 继续仅在非分发验收构建开放。

## 本地提交候选检查（2026-10-09）

为落实用户的本地 `commit` 指令，按百炼范围暂存 45 个路径；8 个共用文件只纳入百炼部分。试听、App Motion 及其原生回归的并行改动保留在工作区。将暂存 tree 导出到独立目录后逐字节核对，再执行检查；未复制 `.env`、生成音频或 `dist/`。以下结果针对这个提交候选，不替代前述 Bundle 的源码身份或真实验收证据。

- helper executable harness：**5024 项、0 失败**，exit 0。
- 普通构建 GUI `--bailian-regression`：**744 项、0 失败**，exit 0。
- GUI `ClaudioGUI` Debug / Release：均 exit 0。使用 `MacOSX26.5.sdk` 和 `--build-system native`；本轮没有重建验收 Bundle。
- 定位目录 JSON、现行 HTML script、Python AST、两个相关 shell 脚本语法、四个新百炼 Swift 文件的严格格式检查及暂存 diff 空白检查通过。`verify-settings-experience.sh` 的 suite 注册由旧 Qwen 更新为百炼；其 37 个具名 suite 的入口匹配检查通过。
- 完整 GUI harness 进入 `SettingsSoundsLayoutSuite` 后停留超过 5 分钟；进程采样显示正在进行 AppKit 位图渲染，同时日志出现 `com.apple.tsm.uiserver` 通信警告。随后中断这个独立测试进程，**exit 130，未取得完整运行结果**。通信警告是否导致变慢未确认；不将集中回归记为全套通过。
- 要求 clean HEAD 的 `verify-settings-experience.sh` 综合门禁本轮未执行；共享工作区保留并行改动，独立目录是暂存候选而非已提交的 clean HEAD。

本轮没有新增真实生成请求、原生操作、凭据写入、push 或发布。累计仍为 **12 / 20**，完整真实与原生验收结论维持上节所述。

## 私有本地配置保存（2026-10-09）

所有者明确选择与 WorkBuddy 类似的私有本地文件方式，记录于 [ADR 0029](../docs/adr/0029-save-bailian-configuration-in-private-local-file.md)。百炼配置由原凭据 owner 保存到 `~/Library/Application Support/Claudio/Credentials/bailian-beijing.json`，一个版本化记录包含 API Key、业务空间 ID 和真实生成验证状态。复用 SenseAudio 的 fd / 权限 / ACL / 私有 staging / 原子替换边界；SenseAudio 路径及字节格式不变，其他服务仍使用各自原 Keychain 槽。百炼操作不再依赖旧 Keychain 清理，不查询或自动导入旧值或仓库 `.env`。

先加入原凭据管理接口上的回归：旧 Keychain 返回 `-34018` 时，新百炼配置保存被阻断，**2 项失败**。实现独立文件政策后该回归通过。新增完整配置生命周期、权限失败保旧值、记录损坏／超限、staging ACL 查询故障保旧值与清理、双语披露及文件恢复错误检查；仅使用假 Key 与临时目录。

- `--ai-cue-local-credentials`：**116 项、0 失败**。重新装配 manager / vault 后恢复完整配置及模拟生成验证状态；这是同一测试进程内的重新装配，不能当作真实 Key 的 App 重启验收。
- 普通 `--bailian-regression`：**775 项、0 失败**；`CLAUDIO_BAILIAN_ACCEPTANCE` 集中回归：**774 项、0 失败**。
- `--senseaudio-isolation`：**247 项、0 失败**。
- helper executable harness 首次因源码绊线仍查找旧专用 actor 名称失败；同步为共享文件 writer 后，**5030 项、0 失败**。所有私有 staging、完整 fd 写、fsync、原子 rename 断言保留。
- GUI Debug 产品构建通过；`CLAUDIO_BUILD_SDK=.../MacOSX26.5.sdk bash scripts/dev-bundle.sh --bailian-acceptance` 通过 GUI Release、helper/LoginItem、ad-hoc 签名、体积和资源检查。定位目录 JSON、新 key 的双语及 `allKnown` 注册、原型 script 语法、核心／新增 suite 严格 Swift 格式及 `git diff --check` 通过。原有 `EventSettingsAICueView.swift:502` 行长 lint 警告与 HEAD 一致，本次未修改该行。
- 新 `dist/claudi0.app` 的 `source_digest` 为 `ff4ea31765fad0003713b5780f426330e781832dbb2b6b2f3f84504702131ac1`，包内身份与打包后源码内容一致；构建期间的源文件快照未变化。plist `ClaudioBailianAcceptance=true`，`distribution_eligible=false`。旧普通包保留在忽略的 `dist/package-backups/before-bailian-local-20261009-144532/`。
- 退出精确的旧验收实例后启动新包，进程路径核对为 `dist/claudi0.app/Contents/MacOS/claudi0-app`。实际原生声音页显示百炼“未配置”；打开配置表单后 AX 与截图确认业务空间、掩码 Key 输入框、未加密／当前用户权限披露、取消及空输入下禁用的“验证并保存”。表单留空供用户录入，没有预置 Key 或发生成请求。

本轮未读取实际用户 API Key，未写入真实百炼配置，未执行真实 Key 保存／App 重启、付费生成、听感、VoiceOver、双架构签名、公证或发布。未重跑完整 GUI harness，不将集中回归替代为全套通过。生成预算仍为 **12 / 20**，普通分发构建的百炼入口资格仍由 ADR 0027 控制。
