# 三宿主事件正式交付验收（2026-09-27）

目标：Claude Code **5/5**、Codex **4/5**、WorkBuddy Desktop **4/5**。
基线为 `47882d7daf49a1d67b327bb4b33fe311dcc7f8ba`。本记录首先采集于未提交的
本地候选，**正式交付尚未完成**；本文件跟踪构建、当前安装、真实回调、人工体验与发布各层证据。

## 交付边界

覆盖率继续按五个公共 `Event` 计算。同一声音事件下的多个提醒类型分别核验回执。

| 声音事件 | Claude Code | Codex | WorkBuddy Desktop |
| --- | --- | --- | --- |
| `task_start` | `UserPromptSubmit` | `UserPromptSubmit` | `UserPromptSubmit` |
| `stop` | `Stop` | `Stop` | `Stop` |
| `stop_failure` | `StopFailure` | 不支持 | 未实现 |
| `notification` | `Notification`；另有精确 `AskUserQuestion` 的 `PreToolUse` | `PermissionRequest`，仅授权请求 | `Notification`，仅 `permission_prompt`、`idle_prompt` |
| `subagent_stop` | `SubagentStop` | `SubagentStop` | `SubagentStop` |

Claude 的提问前置信号只显示瞬时“即将提问”。明确输入请求沿用“需要你”，普通 idle
保持信息提醒。Codex 提问观察仍只用于显式 DEBUG 验证，不进入本次正式 4/5 的范围；
WorkBuddy 没有加入未经 Desktop 实测的新提问 matcher。合同见
[ADR 0018](../adr/0018-separate-question-intent-and-observation-evidence.md)和
[提问提醒验收](cross-host-questions-2026-09-27.md)。

Open Island 的增量研究没有扩大上述能力声明。其 rollout 路径中的
`activityUpdated(.waitingForAnswer)` 与 App Server 路径中的 `questionAsked` 必须分开看待；
状态观察不提供 Claudio 所需的完整请求身份或已有客户端只读订阅证据。
版本化证据见[入口记录](cross-host-question-entry-2026-09-27.md)。

## 本轮解除的自动化阻塞

1. `ClaudioLocalization` 直接解析 string catalog JSON，以支持应用内显式语言选择。
   Swift Build 对单个 `.xcstrings` 资源会尝试调用本机缺失的 `xcstringstool`。
   改为复制整个资源目录，并从对应子目录加载 catalog；本地化解析合同保留。
2. 本机 Command Line Tools 的 macOS 27 SDK 缺少可用的 `SwiftUIMacros.StateMacro`。
   通过 `SDKROOT` 选择已安装的 macOS 26.5 SDK，继续使用标准 Swift 命令和默认构建器。
3. 编译访问权限探针原先写死旧版 SwiftPM 的模块位置。隔离构建复现
   `module map file not found` 和 `no such module ClaudioGUICore`；只调整模块路径的正向
   对照通过。测试现同时识别原有 SwiftPM 与 Swift Build 布局，保留正、反向编译断言。
4. 共享工作区包含另行开发的声音包，导致固定出厂包清单测试失败。使用精确源码清单
   创建隔离候选，保留共享工作区及用户声音包。候选的 selector 和 Python 回归均通过。

此前 Vision OCR 的慢调用在本轮最终完成，相关断言通过。没有跳过 OCR 或放宽断言。

本轮构建与测试统一使用以下环境前缀，以便子编译进程也继承 SDK 选择：

```bash
env -i PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  <command>
```

## 自动化与本地候选证据

机器：macOS 27.0、Apple Swift 6.4、arm64。未使用被弃用的 `--build-system native`。

| 检查 | 本轮结果 |
| --- | --- |
| `swift run --package-path helper claudio-tests` | **4,146 checks，0 failures** |
| `swift run --package-path gui claudio-gui-tests` | **10,928 checks，0 failures**，隔离候选 |
| `bash scripts/test-hook-cli-contract.sh` | **通过**，包括 Debug/Release、stdin、静默退出和提问入口合同 |
| `node scripts/test-sound-pack-selector-state.js` | **通过**，隔离候选 |
| `python3 scripts/test-sound-pack-candidates.py` | **11 tests，通过** |
| `swift build -c debug --package-path gui --product ClaudioGUI` | **通过**，默认构建器与 SDKROOT 26.5 |
| `bash scripts/dev-bundle.sh` | **通过**，Release GUI、LoginItem、helper 和资源打包 |
| `bash scripts/check-release-size.sh dist/claudi0.app` | **通过** |
| `bash scripts/verify-dev-bundle-signature.sh dist/claudi0.app` | **通过**，ad-hoc 签名结构 |
| `jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings` | **通过** |
| 本轮三个构建修复文件的严格 Swift 格式检查 | **通过** |
| 全目录格式基线比较 | 基线 861 条、候选 850 条；改动文件新增诊断 **0** |
| `bash scripts/test-settings-format-diagnostics.sh` | **通过** |
| `git diff --check` | **通过** |
| `verify-settings-experience.sh <baseline>` | **未完成**，要求已提交的干净 HEAD |
| `swift build -c release --package-path helper --arch x86_64 --product claudio` | **本机未通过**：编译至最终链接，CLT 的 `libswiftCompatibility56.a`／`libswiftCompatibilityPacks.a` 只有 arm64、arm64e 切片，缺少 x86_64 的 `__swift_FORCE_LOAD_$_swiftCompatibility56` |
| `swift build -c release --package-path gui --arch x86_64 --product ClaudioGUI` | **本机未通过**：同一 x86_64 兼容库链接缺口；另有 `CoreAudioTypes` 与 `SwiftUICore` 链接警告，不推断其在兼容库补齐后的最终结果 |
| CI、完整双架构包、Developer ID、公证及发布 | **未验证／未执行** |

本地包大小：GUI 6,751,648 B、helper 3,115,152 B、LoginItem 54,144 B、非可执行资源
737,888 B；总计 **10,658,832 B / 12,250,000 B**。

Release 包的身份：

- GUI SHA-256：`2eb34f175f1bdfb2d77f68572cbc363d18c939b1df167d490348a4eaf4175f79`
- helper SHA-256：`0ba74dd2b824b05412fd8086f5a9fb942fc4dfc3ad382c8179641536dee229a8`

Release GUI 中不存在三个 Codex 开发观察入口环境变量的字符串；源码同时受 DEBUG
编译条件约束。此包是当前架构、ad-hoc 签名的本地验收包，尚未成为正式发布产物。

## 当前安装与恢复准备

- 已建立私有恢复备份并逐文件校验：104 个普通文件，共 6,922,658 bytes；包含安装的
  helper、声音包、配置、当前安装标记和回执，以及三宿主配置。备份及原始记录不入 Git。
- 22:00 SGT 前后的切换中，已核对旧 GUI 进程与原二进制摘要，退出旧进程并启动隔离
  候选包。当前运行 GUI 的 SHA-256 为上述候选值；安装 helper 也与候选 helper 摘要一致。
  CUA 对菜单栏应用返回窗口超时，因此进程与二进制证据不代替原生界面检查。
- 用候选 helper 的 `integrations connect` 逐项连接 Claude Code、Codex、WorkBuddy，三项
  均成功。连接后共享 runtime 为 ready，三宿主配置均为 configured。隔离 Codex TUI
  的 `/hooks` 已分别审核并信任四条 Claudio 定义；四条 Vibe Island 定义仍待审核，
  没有批量信任第三方 hook。下表记录连接后的本代回调。
- 切换前发现 Codex 配置与五条回执在首次备份后有变化，已另作当前副本并核对哈希。
  默认组配置与 WorkBuddy 设置文件逐字节不变；Claude、Codex 配置的顶层非 hook 字段
  不变。旧 hook 条目中被替换的九条均为 Claudio 自有项，第三方条目未移除。
  WorkBuddy 的旧回执不充当本次候选的受控听音验收。
- 三个独立测试目录均不处于已配置工作区目录内。声音沿用默认组的“共鸣钵音”，音量
  0.95，五个事件开关开启；保留原有工作区规则与声音偏好。
- 每次受控有声测试前先通知用户；用户此前已就位并要求执行切换验收。安装动作前复核
  关键配置有无并发变化；通过现有连接流程更新，Codex 信任由单条原生审核完成。

## 当前候选的真实验收矩阵

每一行同时需要受控宿主行为、候选安装的有效回执和人工听音记录。`played` 只证明
播放器启动。对同一公共事件下的不同提醒类型分别记录，不用能力计数推断当前激活。

| 宿主与场景 | 真实回调／当前候选回执 | 人工听音／对应提示 |
| --- | --- | --- |
| Claude Code：提交与正常完成 | 隔离短请求返回 `2`、exit 0；15:13:00Z `UserPromptSubmit`、15:13:01Z `Stop` 均为本代 `played` | 人工确认两次铃音、两张对应横幅 |
| Claude Code：API 错误结束 `StopFailure` | 无效模型的两轮快速错误，以及本机受控 API 端点延迟 6 秒返回固定错误的复测，均触发真实 `StopFailure`；复测 15:48:30Z `UserPromptSubmit`、15:48:37Z `StopFailure` 为本代 `played`，间隔约 6.1 秒 | **间隔复测通过**：人工确认两次铃音、两张“开始／失败结束”横幅。快速错误两轮仍只听到一次，第二轮只看到“开始”；该短间隔现象保留为限制，不用本次通过覆盖旧记录 |
| Claude Code：`Notification` | 15:19:06Z 本代 `played`；交互 `AskUserQuestion` 在 TUI 显示，通知 subtype 未另行记录 | 人工确认该组第三次铃音和“需要你”横幅；不据此推定所有 `Notification` subtype 均为明确待答 |
| Claude Code：`AskUserQuestion` 前置信号 | 精确工具的 `PreToolUse` 15:19:00Z 本代 `played`；TUI 显示 A/B 原生问题 | 人工确认“即将提问”铃音与横幅，前后还看到“开始”和“需要你” |
| Claude Code：子代理完成 | 受控 Task 子代理计算 `6+7`，父任务 exit 0 回答 `13`；15:15:49Z `UserPromptSubmit`、15:16:23Z `SubagentStop`、15:16:30Z `Stop` 均为本代 `played` | 人工确认三次铃音、三张对应横幅 |
| Codex：提交与正常完成 | 隔离 TUI 单独运行 `sleep 8` 后回答 `2`；15:23:03Z `UserPromptSubmit`、15:23:19Z `Stop` 本代 `played` | 人工确认两次铃音、两张对应横幅 |
| Codex：授权请求 | 15:24:27Z `UserPromptSubmit`、15:24:53Z `PermissionRequest` 本代 `played`；TUI 在工作区外受控文件写入前显示审批，取消后文件不存在 | 人工确认“开始／授权”各一声、两张对应横幅 |
| Codex：子代理完成 | 两段 `sleep 5` 分隔的受控任务回答 `13`；15:26:02Z `UserPromptSubmit`、15:26:24Z `SubagentStop`、15:26:33Z `Stop` 本代 `played` | 人工确认三次铃音、三张对应横幅 |
| WorkBuddy Desktop：提交与正常完成 | 隔离 Desktop 任务运行 `sleep 5` 后回答 `2`；15:30:03Z `UserPromptSubmit`、15:30:18Z `Stop` 均为本代 `played` | 人工确认两次铃音、两张“开始／正常结束”对应横幅；另有并行任务，按隔离任务单独计数 |
| WorkBuddy Desktop：`permission_prompt` | 默认权限下原生 `Read` 请求：先前脱敏探针记录 `Notification/permission_prompt` 且 `cwd` 为绝对字符串，14:35:30Z 同代回执 `played`；本轮受控读取在 15:38:18Z 再有 `Notification` `played`，Desktop 出现原生审批 | 人工确认“开始／授权／结束”三次铃音、三张对应横幅和原生审批；本轮未另装 subtype 探针，不以回执单独推定 subtype |
| WorkBuddy Desktop：`idle_prompt` | 隔离任务 15:41:54Z 正常结束后，脱敏探针在 15:42:54Z 记录 `Notification/idle_prompt` 且目录匹配隔离工作区；同刻本代 `Notification` 回执 `played` | 人工确认一声铃音、信息提示横幅；未升级为明确待答 |
| WorkBuddy Desktop：子代理完成 | 两段 `sleep 5` 分隔的受控任务回答 `13`；15:33:22Z `UserPromptSubmit`、15:33:42Z `SubagentStop`、15:33:54Z `Stop` 均为本代 `played` | 人工确认三次铃音、三张“开始／子代理完成／正常结束”对应横幅 |

Claude Code 五类、Codex 四类公共事件均有当前候选的真实宿主行为与本代回执。
WorkBuddy 四类也有 Desktop 行为与本代回执；`permission_prompt` 和 `idle_prompt` 均有
独立脱敏 subtype 证据。Codex 的四类人工听音与对应横幅已通过；Claude 五类在受控
间隔下通过人工听音，其中快速 `StopFailure` 的声音与自动横幅仍有限制。WorkBuddy 的
开始、正常结束、子代理完成、授权和空闲提醒
均已通过人工听音与横幅。用户选择与 Desktop 的另一项任务并行测试，受控
任务放在独立工作区，人工计数明确限定在受控任务。
并行任务后续可更新 WorkBuddy 的“最新回执”文件；矩阵中的受控时间点已在各次执行后
即时核对，不能用测试结束时的最新文件反推它们的任务归属。

Claude Code 2.1.282 初始模型配置不可用：隔离 `--model sonnet` 短请求得到 404，
CLI 帮助列出的 `fable` 别名得到 400“模型未找到”，原默认模型请求在 90 秒后超时。
验收期间宿主模型配置发生并发变化，后来指向 `glm-5.3-flash`；Claudio 六个 hook 仍为
configured。新的 0.05 美元单次上限先触发 `error_max_budget_usd`，随后将单次上限
设为 0.5 美元且限一轮，短请求以 0.014195 美元成功；子代理请求以 0.11595 美元成功。
原生 A/B 问题由 `AskUserQuestion` 提出并在本次隔离会话内结束。配置中的凭据和原始
宿主记录均未纳入本文件；本轮没有改变用户模型配置。

WorkBuddy 探针仅记录 `Notification` subtype 与 `cwd` 是否为绝对字符串，不保存目录、
问题、答案或原始回调。临时 `permissions.ask: ["Read"]` 和两条 probe hook 在默认权限
测试后按事前摘要比较恢复；`~/.workbuddy/settings.json` SHA-256 恢复为
`4c86fca881f8c0897e495df566a1afb88a6974c57998bae378dbd693b02c3865`。
首轮探针共记录两次 `permission_prompt`，未记录 `idle_prompt`。第二次出现在 A/B 等待
问题期间，缺少请求身份，不能单凭时间把它解释成问题提醒。后续人工听音验收再次临时
设置 `permissions.ask: ["Read"]`，在隔离任务中看到原生读取审批与“授权”提示，随后
按 CAS 和 SHA-256 恢复设置。空闲补测仅临时增加只记录允许 subtype、目录匹配布尔值
与时间的观察 hook；15:42:54Z 捕获隔离工作区的 `idle_prompt` 后也按 CAS 恢复。
两轮恢复后 `~/.workbuddy/settings.json` 均与原始 SHA-256
`4c86fca881f8c0897e495df566a1afb88a6974c57998bae378dbd693b02c3865` 相同，
未保留临时权限规则或观察 hook。

Claude `StopFailure` 的间隔复测使用只监听 `127.0.0.1` 的固定错误端点、占位凭据和
六秒响应延迟；禁用 hooks 的预演先确认请求到达本机端点且占位鉴权生效，正式运行保留
原有 hooks，CLI 因受控 API 错误退出。端点只记录方法、去参数路径、占位鉴权布尔值与
时间，不保存请求体、问题、答案或凭据；测试后端点已停止。两轮快速错误的开始与失败
分别相隔 0.250 秒和 0.263 秒（本代回执历史）。当前默认组映射的 `task_start`、
`stop_failure` 音频经 `ffprobe` 测得分别为 1.150454 秒和 1.420000 秒；若两次播放器
及时启动，音频会明显重叠，这与人工只辨出一声相符，但未采集系统混音输出，不能据此
确认唯一听感原因。提示模型的 `canAutomaticallyDisplay` 在当前横幅进入／显示期间为
false；现有 `EventNoticeModelSuite` 明确断言普通瞬时提示不替换、不延长、不自动排队。
所以若第二条提示在该期间送达，第二张横幅按现有合同不会出现；本轮未采集该次 GUI
接收结果，不能证明具体投递时刻。本次没有改动提示模型或声音播放策略，短间隔下两段
声音能否被人工区分仍不以 `played` 回执推定。

Claude 官方将 `StopFailure` 定义为 API 错误导致回合结束；普通工具返回失败不能代替
这一场景。[Claude Code hooks 参考](https://code.claude.com/docs/en/hooks#stopfailure)

## Release 候选原生界面补测（2026-09-28 SGT）

用户打开候选包的「设置 → 集成」后，原生 UI 控制接口成功附着窗口；菜单栏只有后台
窗口时该接口曾超时。用户独立确认三宿主覆盖数为 5/5、4/5、4/5。候选窗口的原生
accessibility tree 亦显示 Claude Code、Codex、WorkBuddy 均为本代「已激活」，并可读出
各 binding 的「当前回执」：Claude Code 包含 `StopFailure` 与精确提问 `PreToolUse`，
Codex 四条、WorkBuddy 四条。它证明当前 UI 所展示的事实，不替代前述真实宿主回调。

同一候选窗口已查看浅色／深色 × 简体中文／English 四种组合的集成页截图，顶部覆盖数、
状态行和当前视口内的连接文案均可见；浅色中文还检查了滚动至底部的逐 binding 回执。
应用语言从「简体中文」切至 English 后已恢复原值；系统外观原为「自动」，临时切至
「浅色」后已恢复「自动」。accessibility tree 对三宿主按钮给出状态和覆盖数，并暴露
回执文本及操作标签。此项是 AX 结构证据，**实际 VoiceOver 播报仍未验证**。

双架构补测使用同一隔离候选的 `--arch x86_64` Release 命令。两个产品均编译到链接
阶段后失败；`lipo -info` 独立确认当前 `/Library/Developer/CommandLineTools` 的上述
Swift 兼容库仅有 arm64、arm64e。机器没有发现完整 Xcode 安装，本次未通过替换链接
参数制造不可用产物。运行中的 arm64 候选及用户宿主配置没有因构建而切换。

Tab 键已在集成页尝试，但自动化没有取得可判定的焦点位置或顺序，因此完整键盘路径仍
未验证。当前没有可用于独立原生阅读／移除验收的新待接手提醒；提醒阅读、移除及其
焦点归还仍未验证。用户已暂停人工测试，本次补测未触发新的宿主回调或提示音。早先
开发合成触发的非抢焦点人工记录保留为历史证据，不转记为当前 Release 候选结果。
