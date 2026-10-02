# claudi0 · macOS 设置：来源与验证索引

2026-10-01 为八页原型设计、能力盘点与浏览器验证日期；该阶段只修改独立 HTML、配套说明与浏览器回归。2026-10-02 已将该原型固定为 #215 的设置呈现基线，见 [DESIGN.md 的现行八页设置章节](../../DESIGN.md) 与 [八页迁移规格](../../plan/PLAN-MACOS-SETTINGS-MIGRATION.md)。设置基线的采用、原生实现和验证结果分别记录，不由其中一项推定全部完成。

历史源码盘点基线为 `7ca63a4af0497b74b53e89225ccf4de30d900c12`；修订前 HTML SHA-256 为 `0986119bc2d289f6a77abd7e503fca9222cbf26a6eeb1019e39ecde04afc8951`。下方浏览器结果绑定修订后的指纹，旧版通过记录不能作为修订版证据。

## 现行来源与证据

本次先交付文档与忽略规则。标为“工作树待提交”的原型、素材、实现和固定证据保留路径及历史指纹，尚未纳入该 Git 提交；交付边界见 [对齐记录](../../docs/validation/sot-implementation-alignment-2026-10-02.md)。

| 来源 | 拥有的事实与适用范围 |
| --- | --- |
| [DESIGN.md](../../DESIGN.md) 与 [#215 迁移规格](../../plan/PLAN-MACOS-SETTINGS-MIGRATION.md) | 已固定的八页设置呈现合同、领域边界及验收要求。设置基线 HTML 为本目录的 `claudi0 macOS Settings Prototype.html`，指纹 `f49c338fde51a03fa4ada9b5f31f071a281e6708038dbac609f3c7931b93fe91`。 |
| [整合原型](<../panel-and-settings/Panel and Settings Prototype.html>) | 菜单栏、面板和横幅的呈现基线；其中旧设置部分已由 #215 取代。 |
| [#216 事件动画规格](../../plan/PLAN-EVENT-ANIMATION.md) 与 Pixel Motion Prototype（工作树待提交：`designs/pixel-motion/Pixel Motion Prototype.html`） | 后续授权的动画增量；角色画面、时序、循环与静态帧由 Pixel 原型拥有，指纹 `d2b3cf0e8440785149a803e6927e72171bceb30892afdd218d31da2bd21529c4`。新增通知详情及动画偏好不属于旧 C01–C48 的浏览器覆盖。 |
| 动画设置原型（工作树待提交：`designs/macos-settings-native/Animation Settings Prototype.html`）、配套 CSS（工作树待提交：`designs/macos-settings-native/animation-settings-prototype.css`） 和 配套 JavaScript（工作树待提交：`designs/macos-settings-native/animation-settings-prototype.js`） | 动画设置布局比较及模拟交互；生产沿用 #216 指定的 A 并排布局和现行原生设置合同。原型读取 GUI 导出资源，不成为角色画面或时序的第二个来源。 |
| [实现映射](IMPLEMENTATION-MAP.md) 与 [能力对照表](CAPABILITY-MATRIX.md) | 将合同和原型入口关联到既有领域 owner；源码描述实际实现，不因代码存在而自动改变合同或证明验收。 |
| VERIFICATION.json（工作树待提交：`designs/macos-settings-native/VERIFICATION.json`）、`verification/` 与 `screenshots/` | 2026-10-01 的固定 HTML 浏览器证据；保留其日期、指纹、结果和当时交付状态。 |
| [八页原生迁移记录](../../docs/validation/macos-settings-native-2026-10-02.md) | #215 迁移阶段的原生构建、矩阵、交互与未完成项；各结果绑定原记录中的候选及环境。 |
| [当前 SoT 与实现对齐记录](../../docs/validation/sot-implementation-alignment-2026-10-02.md) | 本次源码／原型差异、当前验证边界及待修复项。当前原生现场观察因工具超时为 `BLOCKED`；历史原生通过项不能直接作为 #216 工作树的验收。 |

## 打开与重现

双击 [`claudi0 macOS Settings Prototype.html`](<claudi0 macOS Settings Prototype.html>) 即可离线预览，也可从仓库根目录打开：

```bash
open -a 'Google Chrome' 'designs/macos-settings-native/claudi0 macOS Settings Prototype.html'
```

| 查询参数 | 值与作用 |
| --- | --- |
| `page` | `events`、`sounds`、`integrations`、`notifications`、`general`、`shortcuts`、`usage`、`about`，依次为八页；HTML 预览标识不新增生产 route。 |
| `theme` | `light`、`dark`、`system`；Codex 图标随解析后的主题切换官方变体。 |
| `size` | `default`（1240×820）或 `minimum`（960×640）。 |
| `lang` | `zh`、`en`、`system`；即时翻译页面、sheet、错误与辅助功能名称，演示包名、目录与用户描述保留原值。 |
| `scene` | 固定演示场景 ID，如 `stale`、`draft`、`copyApplyFailure`、`importBindFailure`、`hostAwaiting`、`reminderExpired`。 |
| `clean` | `1` 隐藏窗外审阅工具，以浏览器视口作为窗口尺寸；截图须同时设置实际视口。 |

例如：`?page=events&theme=dark&size=minimum&lang=en&scene=stale&clean=1`。跟随系统可用 `systemLanguage=en` 重现解析为 English 的情况。

窗外审阅工具不是产品功能。当前共有 **96 个固定演示场景**，覆盖加载、进行中、失败、禁用、partial、损坏与恢复，可在场景选择器查看，或在控制台读取 `window.prototypeReview.scenes`。切换场景会重建固定内存数据并清理在途演示；“重置演示”恢复正常场景。声音包库的“恢复工厂内容”是独立操作，只恢复工厂包并保留用户包，不能用重置演示替代。

从仓库根目录执行可重复的浏览器回归：

```bash
python3 scripts/test-macos-settings-prototype-browser.py
```

回归输出本次 `artifacts` 目录路径，包含默认／最小窗口截图与详细结果；2026-10-01 的固定浏览器验证记录为本目录的 `VERIFICATION.json`。控件定位失败或点击后预期结果未出现均判失败，点击本身不算通过。

## 能力与视觉范围

[能力对照表](CAPABILITY-MATRIX.md) 的 **C01–C48 共 48 项**来自 2026-10-01 盘点，逐项关联原生入口、已有 owner、HTML 控件、状态、结果与回归 ID，并作为 #215 的能力索引。该基线迁移不新增 Swift 公共接口、配置字段、持久化合同、Provider 或宿主协议；#216 的动画字段和路由是后续授权增量，独立按其规格核对。八页映射与边界见 [实现映射](IMPLEMENTATION-MAP.md)，Apple 参考及适用范围见 [设计研究](APPLE-DESIGN-RESEARCH.md)。

- 工作区名称由解析后的目录派生；Git／普通目录范围可见，零适用来源合法，创建前必须明确确认音量。失效目标保持不可写，选择默认组须由用户明确执行。
- 查看包、普通复制、用于当前作用域与明确目标的复制并应用分别表达；应用失败保留副本。共享使用者与引用不完整状态可见，引用不完整时禁止删除。
- 未发布草稿只由首条 AI 采用或系统音绑定成功发布；此前不提供普通文件导入、复制或应用。只有草稿可改名。候选共享一个采用名称输入，风格／编号身份仍由路线拥有。
- 导入已成功但绑定失败、部分成功、隔离文件保留及回滚失败分别报告，不能统一显示完全回滚。凭据、集成、静默、快捷键、活动、提醒与关于的状态和恢复入口就近可见。
- 面板显示集是**已有 owner 能力补回设置原型**：新增最多四项，已有第五项或损坏包仍可取消星标。它不表示生产面板恢复声音包画廊；本轮不修改面板。
- 已删除没有当前接缝的设置搜索、通用返回／前进历史、帮助页、已安装包改名、自定义副本名、工作区改目录／自定义名、声音页整包试听、未绑定音频独立试听、七日日柱图、日志条数及窗口生命周期伪设置。

已固定的八页基线使用系统字体，统一白色／深色主底、轻灰功能组与每页一个主滚动区。默认 1240×820、最小 960×640；侧栏 252/210、断点 1100、三组间距 24。单列最大宽度 780，**包含内边距**；左右默认 32、窄窗 26；section 间距 28、group 间距 16、圆角 10；普通行最小 48、多行最小 61，长英文、路径与错误自然增高。页名约 17、主要标签 13、辅助文字 11–12。这些数值是项目的呈现合同，不是 Apple 官方规定。

**设置 SoT 的覆盖关系已经固定。** #215 的系统白底、系统字体、10 圆角与分组单列覆盖 #214／#213 中冲突的暖色主底、Rounded 页标题、13 圆角、独立事件卡与主辅栏；旧要求作为历史保留。整合原型继续拥有菜单栏、面板和横幅，`CONTEXT.md`、ADR 和既有 owner 继续决定领域语义。#216 只增加其规格明确的动画行为和通知详情，不据此改写无关设置能力。

## 集成的官方图标

Agent 列表与来源详情沿用官方资产。Claude 使用官网橙色产品图标，Codex 使用官方深浅变体，WorkBuddy 保留原图；不重新着色。

| 集成 | 原图来源 | 呈现 |
| --- | --- | --- |
| Claude Code | [Claude 官网](https://claude.ai/)实际声明的 [apple-touch-icon.png](https://cdn.prod.website-files.com/6889473510b50328dbb70ae6/68c33859cc6cd903686c66a2_apple-touch-icon.png)，256×256 PNG | 橙色底、白色 Spark；保留原图，不用单色 SVG 或 CSS 染色。 |
| Codex | 本机签名的 `com.openai.codex` 26.928.20755 安装包资源 `icon-codex-light.png` / `icon-codex-dark-color.png`，OpenAI OpCo, LLC（`2DC432GLL2`） | 蓝紫 `>_` 产品图，随深浅主题切换官方对应版本。 |
| WorkBuddy | [`workbuddy.png`](../../assets/host-icons/workbuddy.png)，与本机腾讯签名的 `com.tencent.workbuddy.mac` 5.7.3 安装包资源 `icon.png` 逐字节一致 | 保留原图、颜色与透明边缘。 |

以上为 2026-10-01 资产采集记录，不表示本轮重新验证了安装版本。四份原图以 data URI 内嵌，单个 HTML 离线可用；相邻产品名称提供辅助功能名称，装饰图像不重复朗读。旧 `codex.svg` 为 OpenAI Blossom 标识，八页基线不用它代替 Codex 产品图。WorkBuddy [既有来源记录](../../assets/host-icons/WORKBUDDY-SOURCE.md)描述旧安装版本。

原图 SHA-256 保持：

- Claude：`1bec5f7b12a4a46fea879633464ebf1d32144ef731a0f054539b2d7251871cb6`
- Codex 浅色：`de7d43f3386105ab20952958c2c25beb0d903e2aeb6e1aef57c49a648c0d1c07`
- Codex 深色：`69fb4384e161be8a20dcb94a9ac34aea4fbfaeb67514110a71e7b0732eccb0fc`
- WorkBuddy：`3c2bc7d338c9eacc027af2b27693056b7cbea3a6c0a09225cf87020afe57fd7b`

## 建议评审路线

1. 在默认组／工作区调整选包、音量与五事件，定向编辑并返回；检查保存仍生效、焦点归还及失效目标不可写。添加工作区，确认目录派生名、零来源与明确音量确认。
2. 查看内置包后普通复制，再尝试明确目标的复制并应用；检查不改组／不串目标及应用失败保留副本。检查引用不完整删除保护、工厂恢复保留用户包，以及面板显示集上限和取消星标。
3. 新建草稿并改名保存／取消，经系统音首绑定或 AI 采用发布；检查发布前文件导入不可用、共同名称不改变候选身份、取消与离页清理及迟到结果保护。
4. 检查音频与凭据的正常、在途、失败与禁用；重点查看导入成功但绑定失败、多文件部分成功、Qwen 延迟验证／待替换和 SenseAudio 私有未加密文件说明。
5. 修复旧接入，检查配置完成后仍等待当前回执；通知策略不改声音配置。通用页即时切换两语言，检查登录项和三个快捷键的恢复。
6. 刷新冻结提醒、复制有效会话，检查旧版拒绝及过期清空；分别清理日志、计数、回执与提醒。关于页先显示并选择安全诊断，再复制同一内容。
7. 用侧栏上下键、Tab 和 Escape 检查顺序与取消焦点；在双语、明暗和两尺寸检查全部滚动末尾、长路径、错误和品牌图标。

## 2026-10-01 浏览器验证记录

最终 HTML SHA-256：`f49c338fde51a03fa4ada9b5f31f071a281e6708038dbac609f3c7931b93fe91`。以下为当时的浏览器结果，绑定此指纹；汇总见 VERIFICATION.json（工作树待提交：`designs/macos-settings-native/VERIFICATION.json`），逐项记录见 `verification/`。JSON 中的“待用户评审、未修改 SoT、未提交／推送”描述该次运行结束时的状态，保留为历史，不表示当前交付状态。它不覆盖后续动画原型、#216 实现或当前原生 UI。

| 项目 | 本轮结果 | 证据范围 |
| --- | --- | --- |
| 8 页 × 2 语言 × 2 外观 × 2 尺寸 | **64/64 通过**，另检查 96 个场景布局 | 浏览器布局、底色、尺寸、溢出、滚动、控件与辅助功能名称；截图见回归输出 artifacts。 |
| C01–C48 能力与交互回归 | **48/48 通过，511 项能力断言** | 可达入口、状态及结果；查看／应用分离、复制目标、草稿发布、引用保护、实际失败结果、回执与清理独立。 |
| 详情与 sheet 的正常／进行中／失败／禁用 | **376 入口组合、776 状态快照通过**；独立复核共 1984 观察点 | 固定演示场景与流程；取消焦点、键盘顺序、目标生命周期及迟到结果。 |
| JavaScript、离线资源与图标 | 语法通过；0 页面异常、0 网络请求；四原图字节一致 | 语法、page error、请求边界、四份内嵌原图与主题变体；仅浏览器证据。 |
| 原生布局、真实键盘／焦点、VoiceOver、实际听感 | 该次 HTML 验证未覆盖 | 后续证据与未完成项另见八页原生迁移记录，不能由本表推定。 |
| 真实权限、宿主回调／当前激活、Provider、双架构、签名／公证／发布 | 未验证 | 不属于固定演示与本阶段交付。 |

交付截图：中文浅色默认窗口（工作树待提交：`designs/macos-settings-native/screenshots/zh-light-default-events.png`）、中文浅色最小窗口（工作树待提交：`designs/macos-settings-native/screenshots/zh-light-minimum-sounds.png`）、英文深色默认窗口（工作树待提交：`designs/macos-settings-native/screenshots/en-dark-default-integrations.png`）、英文深色最小窗口（工作树待提交：`designs/macos-settings-native/screenshots/en-dark-minimum-sounds.png`）、关于（工作树待提交：`designs/macos-settings-native/screenshots/en-dark-minimum-about.png`）、凭据 sheet（工作树待提交：`designs/macos-settings-native/screenshots/en-dark-minimum-credential.png`）、系统音 sheet（工作树待提交：`designs/macos-settings-native/screenshots/en-dark-minimum-system-sound.png`）。全部 64 页级截图由回归入口输出，不把滚动页首截图当作全页内容证据。

独立布局原始记录包含 23 个 `.progress span` 几何告警：3px 装饰动画被父容器的 `overflow:hidden` 正常裁剪。24 个忙碌变体按可见裁剪范围复核通过，无可执行控件或文本溢出；原始结果和解释分别保留在 原始记录（工作树待提交：`designs/macos-settings-native/verification/independent-layout-raw.json`）、复核结论（工作树待提交：`designs/macos-settings-native/verification/independent-layout-reviewed.json`） 与 裁剪复核（工作树待提交：`designs/macos-settings-native/verification/animation-clipping.json`）。

回归需要 Python Playwright 与已安装 Chrome，只启动临时离线上下文。完整命令检查全部页面、详情、状态和能力；也可将 `--skip-details` 与 `--details-only` 分开执行，须绑定相同 `--expected-sha` 才能合并证据。`--cases-only --case C47` 可复核 Tab 顺序与取消焦点。长矩阵按变体重启隔离浏览器；控件、结果、页面错误、网络请求或指纹漂移均判失败。

原型不接收真实 Key，不读写用户配置、声音包、Keychain 或 SenseAudio 凭据文件，不请求 Provider、不申请系统权限、不修改 hooks。试听为浏览器合成示意声音；文件、Finder、来源打开、登录项、凭据与生成均为固定内存反馈。显式复制只涉及已显示演示值，拒绝或失败可见。旧版 32 个布局组合及 299 项断言不计入本轮双语与能力完整性证据。

## 当前交接与后续工作

八页设置基线已固定，原生迁移及后续修复已有独立记录；仍按 retained 窗口、typed route、现有配置／包／AI／活动 owner、macOS 12 兼容与焦点归还核对实际行为。完整原生验收、外部动作及当前候选门禁的状态以其绑定版本的验证记录为准。

#216 的资源、入口和预览独立对照 [事件动画规格](../../plan/PLAN-EVENT-ANIMATION.md)。通知总览资源失败投影的 `EA-D01` 原发现、并行源码修正与待补运行／原生验证，以及当前现场观察的 `BLOCKED`，见 [当前对齐记录](../../docs/validation/sot-implementation-alignment-2026-10-02.md)；修正和验证状态分别记录，不通过修改合同消除差异。文档同步不授权提交、推送、发行或 issue 状态变更。
