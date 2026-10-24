# 工作区来源勾选呈现验证（2026-10-24）

实施基线为干净的 `main@1224485c3e0d058c30ba0dd5b1e65f5ab6cc2538`。
本记录汇总实施阶段的提交前验证，不包含 push、发布、宿主连接配置变更或用户声音规则迁移。

## 呈现与行为

- 工作区详情和添加表单共用专用中英标题、常驻说明、勾选提示及零来源文案；摘要的短标题保留。
- 来源勾选行只显示名称，继续使用系统 checkbox 和原有资格门控。配置写入、失败反馈及原值保留路径不变。
- 详情底部的「管理来源连接…」通过现有 `SettingsPresentationSession` 提交 `.destination(.integrations)`，进入同窗口连接首页；返回恢复原工作区、事件身份及阅读位置。
- 添加表单不提供跨页入口，保留模态导航约束、来源初始选择和零来源保存能力。
- 主原型的实际创建及详情界面、`DESIGN.md` 同步；原型的键盘勾选保留焦点。

## 验证方式

本机为 Apple Silicon、macOS 27.0.1、Apple Swift 6.4。GUI 使用 `CONTRIBUTING.md`
允许的本地兼容 SDK：`/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`，
SwiftPM 参数为 `--build-system native --sdk <该路径>`，GUI harness 同时设置 `SDKROOT`。
这不是 CI Xcode 或其他系统版本的运行证据。

| 检查 | 本轮结果 |
|---|---|
| helper 完整 executable harness | 6,187 项通过 |
| GUI 工作区相关 harness `--workspace-sounds` | 3,034 项通过 |
| 原生表单 harness `--five-page-forms-native` | 541 项通过 |
| GUI 完整 executable harness | 最终 25,302 项通过，退出码 0 |
| 既有 AI Cue 表单独立复验 `--ai-cue-gallery` | 等待修正后 62 项通过 |
| 既有声音编辑 AI 原生生命周期 `--sound-editor-ai-lifecycle` | 等待修正后 109 项通过 |
| GUI Debug app 构建 | 通过 |
| GUI Release app 构建 | 通过，采用封包相同的 arm64、full LTO、`-Osize` 参数 |
| 新增浏览器回归 | 2 项通过，详情覆盖中英 × 深浅 × 960/1240；创建覆盖中英 |
| 修改的 Swift 文件 strict format lint、本地化 JSON、`git diff --check` | 通过 |
| 开发 bundle、签名、体积、Hook 边界 | 全部通过；arm64、ad-hoc，Sparkle 结构／链接／架构／签名通过 |
| 包内本地化资源 | 五个新增键的中英内容与源码 catalog 完全一致 |
| 工具隔离 | 11 个实际可执行文件的 SHA-256 与 POSIX mode 均未改变 |

隔离配置 fixture 通过原有 `PanelConfigController.changeWorkspace(.surfaces(...))` 写入零来源和重新勾选，
核对默认组、工作区目录及完整声音配置、未知 JSON 字段和退役来源字段保持原值；宿主配置 fixture 字节不变。
现有目录匹配、来源资格、陈旧写目标和配置失败回归继续运行。

原生自动探针挂载生产设置树，覆盖中英 × 深浅 × 960/1240 的详情与添加表单，
核对完整说明、checkbox 名称与无障碍提示、资格门控、全部取消说明、连接入口及原生历史返回。
原生截图仅作本次临时走查，收尾后删除，不保留源码、构建或截图备份。

首轮完整 GUI harness 在 `senseaudio-cn.voice-unavailable` 的凭据 sheet 挂载处失败一次，
独立 gallery 复验通过。第二轮在 AI 部分成功场景进入声音包时发现目标 AX 控件尚未挂载，
后续生成与候选检查产生连带失败；该轮停止以修正等待逻辑。
两处原生测试现通过带 2 秒期限的实际控件／sheet 挂载条件等待，再执行原动作和断言；
不增加动作重试，不改变生成、候选、凭据或准入行为，未移除原断言。
修正后两个相关原生 suite 独立通过，随后完整 GUI harness 的 25,302 项全部通过。

浏览器定向回归命令：

```bash
python3 scripts/test-panel-settings-prototype-browser.py \
  PanelSettingsPrototypeBrowserTests.test_workspace_sound_sources_detail_and_connections_history \
  PanelSettingsPrototypeBrowserTests.test_workspace_sound_sources_creation_zero_selection_and_modal_navigation
```

## 本机走查包

`CLAUDIO_BUILD_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash scripts/dev-bundle.sh`
退出码 0。产物为 `dist/claudi0.app`，旧进程在封包前停止；本轮未启动新包或发起真实宿主／Provider 操作。
可用 `open dist/claudi0.app` 重新打开走查。

重新执行开发签名检查、Sparkle 验证、体积检查及 Hook 输入边界检查均为退出码 0。
GUI 为 **6,979,328 / 7,000,000 B**，helper 为 **2,806,224 / 3,250,000 B**，
LoginItem 为 **54,208 / 500,000 B**；包内正规文件合计 **14,968,802 B**。
GUI 无产品导出符号，Codex transcript reader 只在 hook helper 中。
legacy `claudio` 是指向同目录 `claudi0` 的相对符号链接，按链接核对，未作为独立文件读取。

GUI executable SHA-256：`ab18645c1b6d0f60370c16f76fc8dbf0c9f97e4bb932ee759fc349a315d62822`。

## 验收边界

- 原生截图视觉走查：已抽查中英、深浅和两种宽度的来源区域及创建表单；说明、零来源文字与操作可见，无横向截断。
- 浏览器 Tab/Space：已自动验证；原生 checkbox AX 动作和提示：已自动验证。
- 人工原生 Tab/Space 与 VoiceOver 实际朗读：未验证。
- 真实宿主回调、真实音频、Provider、其他 macOS/设备、CI Xcode、Developer ID 签名及公证、发布和正式验收：未验证。
- 完整 `scripts/verify-settings-experience.sh 1224485c3e0d058c30ba0dd5b1e65f5ab6cc2538`
  要求干净 HEAD。提交前未运行该门禁；获得本轮提交授权后，在包含本记录的干净提交上执行并另行报告。
  上表分项检查不构成该门禁通过。
