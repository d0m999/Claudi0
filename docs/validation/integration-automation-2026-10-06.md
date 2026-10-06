# 集成自动化与设置改版验证记录

日期：2026-10-06。实现基线：`main` / `5a0be8821cc115428742bc605230249f052a47b1`。
规格：[PLAN-INTEGRATION-AUTOMATION.md](../../plan/PLAN-INTEGRATION-AUTOMATION.md)；
合同：[ADR 0025](../adr/0025-automatically-maintain-explicit-host-intent.md)。

后续 GUI 阅读器修复与串行全量通过的结果见
[事件阅读器回归修复记录](gui-event-reader-repair-2026-10-06.md)。本文保留首次实现时的验证结果。

## 实现与来源

- 共享持久意愿、首次/后续安装迁移、独立 GUI 运行身份和同步短期发布许可已实现。
- 三个正式来源逐个维护；250 ms 合并、60 秒发现兜底、1/3/10 秒锁忙重试。后续安装的意愿迁移
  同样保留锁忙错误并有限重试，保存成功前不发布接入。启动失败后的兜底等待相关变化/用户重试，
  未取得或已撤销运行资格时拒绝后台维护发布。相关文件变化按来源隔离，无关活动/日志写入
  不清除其他来源的失败状态。维护由 app lifetime 持有。
- hook 入口及活动、去重、回执、播放启动和通知发布点使用 token；正常退出与内核身份失效拒绝新事件。
  GUI 通知接收、异步导航返回和最终 reducer 校验 revision；关闭仅隐藏该来源横幅。
- 原生列表、应用详情、诊断详情、typed route、逐来源保存及双语文案已实现。
- HTML 原型原先已有用户未提交布局；本次沿用该布局并增补未安装和生命周期/竞争场景。
  前后 SHA-256 见实施规格，没有把既有原型描述成从零创作。

## 工具链与命令

helper 使用本机 Swift 6。GUI 本地使用兼容的 SDK 26.5：当前 Command Line Tools 的 SDK 27
缺少可用的 SwiftUI macro 插件；这个选择不代表默认 SDK 27 或完整 Xcode 的验证结果。

```bash
swift run --package-path helper claudio-tests
swift run --package-path helper claudio-tests --host-automation

SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  swift run --package-path gui --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk claudio-gui-tests
# 同一 GUI 命令另运行 --integration-automation 和 --integration-automation-native

SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  swift build -c debug --package-path gui --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --product ClaudioGUI
# 同样运行 -c release

jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
git diff --check
bash scripts/test-settings-format-diagnostics.sh
bash scripts/verify-settings-experience.sh 5a0be8821cc115428742bc605230249f052a47b1
```

所有原生 GUI harness 与 baseline 重现串行执行；没有重叠 GUI 测试进程。

## 自动与原生 harness 结果

| 检查 | 结果 | 范围 |
|---|---|---|
| helper 全量 | 4,752 checks，0 failures | 包含现有功能及新门禁/维护回归 |
| helper 集成专项 | 92 checks，0 failures | 意愿、竞争、内核身份、后续安装、锁忙、启动失败及来源隔离 |
| GUI 集成专项 | 58 checks，0 failures | 状态/路由、持久开关、通知 revision 与已接受提醒保留 |
| 新详情/诊断原生布局 | 216 checks，0 failures | 3 来源 × 2 层级 × 2 语言 × 2 明暗 × 2 尺寸，共 48 个实际 NSHostingView 组合 |
| GUI 全量 | 17,723 checks，30 failures | 29 项 baseline 失败；额外一项 package JSON 解析检查，隔离重跑通过 |
| Release layout 隔离复跑 | 147 checks，0 failures | 全量的额外失败未持续重现；Package.swift 未改动 |
| GUI Debug / Release | 通过 | 本机 arm64、SDK 26.5 |
| localization JSON / harness | 通过 | JSON 合法、已登记 key、双语与占位符合同 |
| 原型 JavaScript | `node --check` 通过 | 语法检查，不代表浏览器交互验收 |
| 格式 | 变更 Swift 严格检查通过；固定 baseline 格式增量 0 | 原有 GUI main.swift 格式诊断保留，新增注册符合格式；诊断比较保留重复次数 |
| `git diff --check` | 通过 | 无空白错误 |
| 格式诊断脚本自测 | 通过 | 既有稳定诊断比较逻辑 |
| 固定 baseline settings gate | 未通过入口条件 | 脚本要求 clean HEAD；工作树有本次实现和用户原型改版，未擅自提交绕过 |
| OpenCode 嵌入检查与插件 | 通过，36 scenarios | 兼容性回归，未扩大正式支持范围 |
| Additional-host CLI | 通过，161 checks | 隔离 fixture、真实 helper 子进程；无运行注册零写入，并检查无回执不推断授权、支持数量与真实事件分开 |
| sound-pack selector / candidates | 通过，候选脚本 15 tests | 既有声音合同回归 |
| 本机 `integrations status --json` | 通过，三正式来源均可发现 | 仅只读发现，未执行实际 hooks 迁移、回调或播放验收 |

布局 harness 验证挂载身份、内容横向边界、相同来源开关和正确层级的焦点请求；它没有证明键盘实际
焦点到达、VoiceOver 输出、视觉审美、列表/历史 sheet 的完整人工矩阵或实际听音。

## 既有 GUI 失败的独立重现

将上述未修改 HEAD 通过 `git archive` 导出到 `/tmp/claudio-integration-baseline-20261006`，
以同一 SDK 26.5 构建、逐个串行运行：

| baseline flag | 结果 | 当前全量同类失败 |
|---|---|---|
| `--panel-settings-handback` | 127 checks，17 failures | PanelSettingsHandbackSuite 焦点/窗口交接 |
| `--event-attention` | 1,147 checks，10 failures | EventNoticeReaderSuite 原生按钮 backing class 前提 |
| `--settings-review-repairs` | 68 checks，2 failures | SettingsNativeShellSuite 阅读区 key window 前提 |

这 29 项在未修改 baseline 上同样失败，不能据此声称当前 GUI 全量通过，也不能用布局请求断言替代
真实焦点、键盘或辅助功能验收。本次未修改这些既有测试以掩盖失败。

最终全量另有一项 `ReleaseLayoutSuite.swift:713` 失败：SwiftPM package JSON 无法解析。
停止同包并行构建后，串行 `--release-layout` 的 147 项检查全部通过；未改动 Package.swift 或这条
断言。测试将子进程输出合并后解析 JSON，与并行构建的锁等待诊断混入输出相符，但没有保留该次
子进程原始 JSON，不能把这个推断当作已定位的根因。前一轮全量为 17,723 / 29；最终全量仍记为失败。

最后的 CLI/doctor 文案收尾不改变原生呈现：无回执只说明“接入已准备好”，支持数量与“已收到事件”
分开，不要求 `/hooks` 确认。此收尾在最终全量原生运行期间实施，另由 helper 全量、161 项 CLI
子进程检查、最终 GUI 构建及最新专项 harness 覆盖；没有声称旧 native binary 执行了新 CLI 文案路径。

## 本地同版本开发包

为保留正在运行的 `dist/claudi0.app`，构建输入复制到独立的
`/tmp/claudio-integration-build-20261006`。来源 manifest 记录 662 个输入文件的 SHA-256，
包含新文件；GUI、LoginItem、helper 都由此源码快照使用 SDK 26.5 构建。

```bash
# 在上述独立构建目录运行
CLAUDIO_BUILD_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash scripts/dev-bundle.sh
```

最终包：[dist/integration-automation-20261006/claudi0.app](../../dist/integration-automation-20261006/claudi0.app)。
开发脚本签名检查及复制后的 `codesign --verify --deep --strict` 均通过；复制后独立运行尺寸脚本通过：

| 项目 | 实际 bytes / 限额 |
|---|---|
| GUI arm64 | 6,083,984 / 7,000,000 |
| helper arm64 | 3,138,160 / 3,250,000 |
| LoginItem arm64 | 54,208 / 500,000 |
| 非可执行资源 | 2,421,331 / 3,100,000 |
| 包正规文件合计 | 11,697,683 / 13,850,000 |

`source-manifest.json` 校验工作树和独立源码目录的 662 个文件完全相同；`artifact-manifest.json`
记录复制后 42 个正规文件的 SHA-256，两份 manifest 都在上述本地产物目录内，保持 Git 忽略。

- GUI SHA-256：`29978e6ae62c427f1cac9eec44edd73944af68f48dea12b10c57a7f9be78d484`
- helper SHA-256：`123790764780752851f220898c26267b7c9a3abd36e4872ae5c60b69b9fd9e8a`

该包是 `0.0.0-dev`、当前架构、ad-hoc 签名的本地检查产物；不等于 universal、Developer ID
签名、公证或正式发布。没有启动新包替换用户运行中的应用，也没有覆盖其原 `dist/claudi0.app`。

中间构建曾因源码副本位于仓库 `dist/` 内而被全源码审计识别为重复写入点；将副本移至仓库外后重跑，
未弱化审计。目录移动后旧绝对 module cache 失效，独立构建重新生成 cache。中间失败不作为最终通过证据。
旧 additional-host CLI fixture 原先未建立 GUI lifetime，按新门禁不能生成回执；已改为在临时根保存测试
进程的真实内核启动身份，并额外验证缺失注册的零副作用。这个进程 fixture 不代表实际 GUI 或宿主接受。

## 尚未验证

- 三个真实宿主逐个的首次安装、升级、自有 hooks 恢复、关闭、退出/强杀/崩溃、重启后的真实回调与听音。
- 原生列表/详情/诊断及所有历史 sheet 的完整人工双语、明暗、默认/最小窗口矩阵；实际键盘顺序、
  焦点归还、VoiceOver 与关闭后的提醒主动导航。
- Intel/universal、完整 Xcode/默认 SDK、Developer ID 签名、公证、正式发布与产品接受。
- clean HEAD 的固定 baseline 设置 gate。没有 commit、push、release 或 issue 状态变更。

## 本机执行记录

临时日志不纳入 Git，不含可共享的真实宿主 payload；关键结果已在本记录摘要：

- `/tmp/claudio-automation-helper-final.log`、`/tmp/claudio-automation-helper-focused-final.log`
- `/tmp/claudio-automation-gui-focused.log`、`/tmp/claudio-automation-native-final.log`
- `/tmp/claudio-automation-gui-focused-final.log`、`/tmp/claudio-automation-release-layout-final.log`
- `/tmp/claudio-automation-gui-full-final.log`
- `/tmp/claudio-automation-baseline-focus.log`、`/tmp/claudio-automation-baseline-event.log`、`/tmp/claudio-automation-baseline-reading.log`
- `/tmp/claudio-automation-debug-final.log`、`/tmp/claudio-automation-release-final.log`、`/tmp/claudio-automation-bundle-final.log`
- `/tmp/claudio-automation-format-changed-delta.log`、`/tmp/claudio-automation-settings-gate.log`
- `/tmp/claudio-automation-cli-contract.log`、`/tmp/claudio-automation-size-final.log`

真实宿主配置、receipt、私人路径/内容和签名材料没有复制进提交范围。
