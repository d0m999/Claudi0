# 五页设置实施与验收（2026-10-23）

基线 `ed66169e7df2b30140a9be361ca574082368f946`；独立 worktree `Claudio-five-page-settings`、分支 `codex/five-page-settings`。主 checkout 的首启测试及原始讨论工作未改动。本轮未提交、未推送、未发布。

## 实施范围

侧栏固定为工作区、声音包、连接、提醒与静音、通用，前四页与通用用间距分组。八个兼容 raw values 保留，五页导航投影统一供侧栏、方向键和焦点消费。活动与诊断从连接进入，保留实际历史、阅读位置与返回入口。旧 `about`／`shortcuts`／`display` 持久化值只投影通用，不自动展示关于、不报损坏、不改写旧值。

显式关于请求在通用展示原生附属表单；带 stamp 的展示／关闭、现有模态导航阻断和归焦请求共同拒绝迟到操作。工作区为列表→详情，摘要与详情消费同一配置投影；包级修改进入声音包并定位事件，可以返回原工作区。失效目标拒写、删除确认、内置包只读、收藏限制、草稿、导入和生成记录保持既有 owner。

声音包服务入口使用紧凑的原生 DisclosureGroup，展开复用现有服务状态、profile 切换及凭据管理，保留不可用原因。AI 仍由 app-lifetime `AICueGenerationCoordinator` 管理生成、保存、待处理、已保存和请求失败；没有将领域模型缩成原型的演示状态。提醒与静音按自动静默、横幅提醒、事件动画排序，健康信息渐进披露。通用集中语言、登录项、软件更新和关于；关于保留身份、资源、诊断摘要，移除重复更新区。

全局快捷键模型、Carbon 注册、动作、设置页、专用 fixture 与测试已移除。旧偏好不读取、不注册、不删除。共享 handback 与原生键盘导航保留；Carbon framework 仍供 Zed 导航键码使用。

当前合同见 [ADR 0008](../adr/0008-use-one-retained-unified-settings-window.md)、[DESIGN](../../DESIGN.md) 与 [ADR 0026](../adr/0026-retain-generated-audio-in-local-history.md)。设置画面的唯一 SoT 为[主原型](<../../designs/panel-and-settings/Panel and Settings Prototype.html>)。讨论原型保留原首启 A/B/C 和共用评审备注，设置部分只链接主原型；首启三组 markup 与主 checkout 保持一致。

## 验证记录

本机 macOS 27.0.1、Apple Silicon，Swift 6.4；默认 SDK 27 缺少 SwiftUI macro plugin，按 `CONTRIBUTING.md` 的本地兼容方案显式使用 macOS 26.5 SDK 和 SwiftPM native build system。GUI 运行时同时设置 `SDKROOT`，开发 bundle 设置 `CLAUDIO_BUILD_SDK`。这不代表 CI Xcode、最低系统或发布验收。

| 检查 | 结果 |
|---|---|
| helper executable harness | **6,187 项，0 失败** |
| GUI executable harness | **24,791 项，0 失败** |
| 五页／隐藏诊断原生布局矩阵与附属表单 | **494 项，0 失败**；其中表单／详情聚焦检查 132 项 |
| 导航兼容、旧值恢复、诊断历史、关于模态、摘要与快捷键退役 | 聚焦 suite 通过，最终 GUI harness 包含迟到解除模态阻断的归焦回归 |
| AI 生成聚焦回归 | **156 项，0 失败**；完整 GUI 包含 coordinator、selection lifecycle、生成记录／待处理／部分废纸篓失败回归 |
| 设置生命周期 | **262 项，0 失败**；最终完整 GUI 重跑 |
| 工作区列表、捕获写目标、包事件定位与返回 | **27 项，0 失败**；最终完整 GUI 重跑 |
| 主原型与讨论原型浏览器回归 | **6 tests，0 失败**；离线 Chrome／Playwright，无真实 Provider 请求 |
| 主原型既有 Node 回归 | **109 tests，0 失败** |
| Debug／Release `ClaudioGUI` | 均通过 |
| 开发 bundle | 构建、资源、arm64 架构与 ad-hoc 签名检查通过 |
| release-size | 全部通过，见下表 |
| 本地化 | `jq empty` 通过；双语、placeholder、`allKnown` 由 GUI harness 检查 |
| 格式 | 基线诊断差分无新增；变更 Swift 文件 strict lint 通过；格式诊断回归脚本通过 |
| `git diff --check` | 通过 |
| `verify-settings-experience.sh` | **待本轮精确范围本地提交授权后执行**；clean HEAD 前置保留，未以工作区检查冒充整体验收 |

GUI 完整 harness 后仅调整原生测试的截图采集、增加关于表单多控件 Tab 遍历和滚动断言；生产 Swift 源码未变，受影响原生 suite 单独重跑。原生截图取自真实 NSWindow／NSHostingView 的受控 fixture，布局检查测量渲染几何，不由源码 inset 推断。矩阵为五个可见页加隐藏诊断 × English／zh-Hans × 明／暗 × 1240×820／960×640，共 48 组；960 宽场景启用测试用 Reduce Motion override，1240 宽关闭。关于表单另检查两种语言、两种窗口宽度的 Tab／Shift+Tab key-view loop、Escape 和实际关于入口归焦。

迭代期间发现并修复关于表单关闭后的 native sheet unblock 覆盖显式归焦书签；更新了仍期待旧侧栏／旧工作区入口的断言。首轮横幅计时检查受到实际鼠标悬停影响，移出测试窗口后完整回归通过，未改变横幅暂停合同。讨论原型移除设置画面时的共用备注和残留 markup 也经浏览器检查修复。关于截图改为采集 native sheet frame，避免透明 hosting content 丢失背景和 AppKit 按钮合成。

| arm64 开发产物 | 实测 | 上限 |
|---|---:|---:|
| GUI | 6,979,312 B | 7,000,000 B |
| helper | 2,806,224 B | 3,250,000 B |
| LoginItem | 54,208 B | 500,000 B |
| Sparkle | 2,705,105 B | 3,500,000 B |
| 非可执行资源 | 2,421,372 B | 3,100,000 B |
| bundle 正规文件合计 | 14,966,221 B | 16,555,105 B |

GUI 没有产品导出符号。`dist/claudi0.app` 是当前工作区生成的 arm64、ad-hoc 本地检查产物，不是 Developer ID 签名／notarized 发布物。

## 原生截图

保留 16 张代表图，完整 48 组矩阵由自动检查执行。尺寸、语言、外观、测试环境和逐图 SHA-256 见 [manifest](five-page-settings-2026-10-23/manifest.json)。文件先经 `lstat` 确认为 regular file，再复制；没有跟随 symlink。截图是原生窗口／表单 frame 的 AppKit view cache，不是桌面 compositor 录屏或人工验收。关于表单滚动后的 view-cache 存在剪裁合成限制，未保留该类图片；滚动可达由真实 NSScrollView 几何断言证明。

图片中的包、宿主状态、版本及 OS 信息为 fixture，不是当前真实安装事实。工作区详情故意使用缺失包／未配置声音，保留失败态；活动计数不代表真实使用量。关于表单为 620×520 pt，文件名中的宽度代表父窗口。

| 正文 | 中文／明色／1240×820 | English／暗色／960×640 |
|---|---|---|
| 工作区列表 | [截图](five-page-settings-2026-10-23/events-and-sounds-zh-Hans-light-1240.png) | [截图](five-page-settings-2026-10-23/events-and-sounds-en-dark-960.png) |
| 声音包 | [截图](five-page-settings-2026-10-23/sounds-zh-Hans-light-1240.png) | [截图](five-page-settings-2026-10-23/sounds-en-dark-960.png) |
| 连接 | [截图](five-page-settings-2026-10-23/integrations-zh-Hans-light-1240.png) | [截图](five-page-settings-2026-10-23/integrations-en-dark-960.png) |
| 提醒与静音 | [截图](five-page-settings-2026-10-23/notifications-zh-Hans-light-1240.png) | [截图](five-page-settings-2026-10-23/notifications-en-dark-960.png) |
| 通用 | [截图](five-page-settings-2026-10-23/general-zh-Hans-light-1240.png) | [截图](five-page-settings-2026-10-23/general-en-dark-960.png) |
| 活动与诊断（隐藏目的页） | [截图](five-page-settings-2026-10-23/usage-zh-Hans-light-1240.png) | [截图](five-page-settings-2026-10-23/usage-en-dark-960.png) |
| 关于附属表单 | [截图](five-page-settings-2026-10-23/about-sheet-1240.png) | [截图](five-page-settings-2026-10-23/about-sheet-960.png) |
| 工作区完整详情 | [截图](five-page-settings-2026-10-23/workspace-detail-1240.png) | [截图](five-page-settings-2026-10-23/workspace-detail-960.png) |

聚焦原生复验入口为 `claudio-gui-tests --five-page-settings-native`；使用前述 SDK 构建后直接运行 native binary，`SDKROOT` 保持一致。浏览器回归为 `python3 scripts/test-five-page-settings-prototype.py`，既有原型回归为 `node scripts/test-panel-settings-prototype.js`。

## 未验证项

- 人工逐控件键盘顺序、完整 VoiceOver 朗读与焦点树、系统 Full Keyboard Access 开关组合。
- 人工观察全部动效、系统 Reduce Motion／Increase Contrast／Reduce Transparency／显示缩放组合。自动环境 override 和几何检查不代替这些观察。
- 真实音频、真实宿主回调、旧快捷键偏好在真实安装中的按键实测、Focus／Calendar 授权和真实登录项。
- 真实 Provider 请求、费用／配额及声音质量。本轮不包含真实 Provider 调用。
- CI 指定 Xcode／工具链、最低系统与其他 Apple Silicon 机器兼容性、Developer ID、notarization、发布与正式接受。

## 安全回退与避免过度测试

导航、页内呈现与快捷键退役保持明确文件范围，可用 Git 逐段回退；不以删除用户配置、旧快捷键偏好、生成记录或音频作为回退。未保留源码备份副本。迭代只运行受影响的导航、AI、设置和组合 suite；最终执行两个 executable harness、Debug／Release、开发 bundle、尺寸、本地化、格式差分和 `git diff --check`。新增截图采集与断言只重跑原生 suite。

`scripts/verify-settings-experience.sh` 已将退役快捷键 suite 替换为五页导航／原生表单和共享 handback 的注册检查，其余门禁及干净 HEAD 前置未削弱。精确范围提交获授权后，应以本节基线执行该门禁，并另记 commit 与结果。
