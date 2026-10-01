# 设置原型一致性纠偏：实现与验证

## 结论与范围

已按 [#214](https://github.com/d0m999/Claudio/issues/214) 实现八页统一底色、侧栏三组留白、
默认组／工作区和声音页的独立功能卡及五事件卡。规格通过用户指定的 to-spec 工作流发布，
保持 `OPEN`、`ready-for-agent`；没有修改旧 issue 状态。

设置使用专用颜色：浅色背景 `#FAF8F4`、卡片 `#FFFFFF`；深色背景 `#1A1815`、卡片
`#1C1A17`。卡片圆角 13 pt、普通描边 1 pt，沿用增加对比度的加强边框。菜单栏面板的
通用颜色没有修改。三个侧栏组使用 24 pt 留白、组内 3 pt，保持既有八页顺序和路由身份。

五事件分别成卡，间距 12 pt；配置／包信息卡与事件间距 24 pt；选择器至少 70 pt，
与下一区域间距 36 pt。宽窗口辅助栏 260 pt，窄窗口辅助卡位于事件与主要操作之后。
设置页标题统一为 26 pt 系统圆角 semibold，外壳横向留白为 36 pt。

声音映射、生成表单、候选与错误保留在所属事件卡内。工作区的试听动作移到事件卡之后，
文案改为“试听可用事件”，默认组补上真实适用说明。配置、包库、锁／CAS、类型化返回、
试听和 AI 生命周期继续使用原有 owner；没有新增领域 owner、写入链、schema 或付费请求。

## 固定基线与提交前证据

本记录描述提交前保留既有改动的验证工作树。既有设置焦点修复、对应回归及浏览器的
面板回归修正不属于本次视觉提交，以下完整工作树结果绑定所列工作树与 bundle 摘要，
不自动等同于后续干净候选。

| 项目 | 值 |
| --- | --- |
| 固定基线／验证时 HEAD | `840b361a4c6ba9ad3d8f9329bfcd2a257369eced` |
| 已确认原型 SHA-256 | `a85010e2f1371e1addaf855ec8fe5adfc83bade6fd912732fffa9763f4c7e1ab` |
| 原型入口 | `designs/panel-and-settings/Panel and Settings Prototype.html` |
| 原生 fixture 构建工作树指纹 | `babb0022368020aa2ced07377a5b73ee91bbf2a3582128576a7421d01d2ac01f` |
| fixture bundle SHA-256 | `352ee6ef4515f27783b63c6dcc5c9b43a34c79510bbb73af3ed9aa70b80d333f` |
| 自动点击脚本 SHA-256 | `0f103a64753153c94f1c1c9a050a72bea2eb7d91d4f3e290326ddfd264a6dcea` |
| 环境 | macOS 27.0、arm64、Swift 6.4、MacOSX26.5.sdk |
| 原生 fixture 身份 | `com.claudio.app.ui-regression`、`ClaudioUIRegressionFixture=v1` |
| 原始日志与初始工作树快照 | Git 外的本地验证证据目录 |
| 最终原生结果／AX／截图 | 该证据目录内 `native-verified/` |
| fixture 构建清单 | 本地构建证据文件 `build-evidence.json`，未纳入 Git |

22 个最终用例使用同一 bundle、进程和隔离数据根，保留 152 份 AX 与 170 张截图。
核对时 710 个构建源码清单条目、16 个 bundle 文件与执行脚本摘要均匹配，截图及 AX
文件无缺失。之后仅调整 `ViewWiringSuite` 的函数定位和换行归一化，并补充本验证记录及
自动点击说明；应用编译源、执行脚本和被测 bundle 未改变。

默认 MacOSX27 SDK 缺少 `SwiftUIMacros`，验证显式使用已安装的 MacOSX26.5 SDK；
`SDKROOT` 同时传给 harness 子编译进程。构建存在非致命的弃用与 CLT 搜索路径警告。

## 自动验证

| 检查 | 结果／日志 |
| --- | --- |
| 原型 Node 行为回归 | 101 项通过；`prototype-node.log` |
| 原型浏览器回归 | 14 项通过；`prototype-browser.log` |
| helper harness | 4247 项通过；`helper.log` |
| 完整 GUI harness | 12024 项通过；`gui-final-verified.log` |
| 设置原生挂载定向检查 | 465 项通过；`layout.log`，完整 harness 再次通过 |
| GUI Debug／Release 构建 | 通过；`debug-build.log`、`release-build.log` |
| 本次 Swift 文件严格格式检查 | 通过；`format.log` |
| 本地化 JSON、键与占位符 | JSON 检查及完整 GUI harness 通过 |
| 自动点击脚本／构建脚本语法 | 通过 |
| `git diff --check` | 通过 |
| 普通 Debug／Release／开发包测试入口隔离 | fixture 标记与符号均不存在；`normal-isolation.json` |

浏览器检查覆盖八页底色、三组间距、五张事件卡及 AI 展开后的自然增高。真实
`SettingsRootView` 挂载复用 frame recorder，检查卡片数量、间距、AI 归属、主辅栏移动
和固定操作栏。位图按原有 ICC 配置转换到 sRGB 后采样，无文字区域的单通道容差为 3；
源代码与 OCR 不作为颜色证明。高对比度 NSAppearance 的实色表面挂载检查已通过，
系统 Increase Contrast 开关和真实辅助功能仍需独立验收。

完整 GUI harness 的初轮两项失败来自旧测试按旧函数签名截取视图，第二轮一项失败来自
新增调用断言对换行敏感。最终读取方式保留宽窄布局、共享滚动状态区、空态恢复和固定
动作栏的接线断言，完整重跑通过。失败日志保留为 `gui-full.log` 与 `gui-final.log`。

最初尝试将 CUA 操作放在工具返回后的后台 Promise，接口报告执行上下文不可用；
这些失败尝试保留在 `native-final/`。最终在每次工具调用内同步等待用例结束，全部重新
运行在 `native-verified/`，没有将定位或接口失败计为通过。

## 原生自动点击

| 用例组 | 数量 | 最终结果 |
| --- | --- | --- |
| 双语 × 浅／深 × 默认／最小窗口 | 8 | 八页导航、选择、实际尺寸、颜色及卡片布局通过，共 64 次页面检查 |
| 完整 AI 操作 | 2 | 简中浅色默认、English 深色最小；工作区定向编辑／返回、生成锁定／取消、改名、采用写盘及离页清理通过 |
| 完整提醒操作 | 2 | 同上两种组合；复制／移除、横幅失败／重试、成功保留提醒及关闭归还通过 |
| AI partial／失败与来源超时 | 3 | 实际候选数、失败保旧映射、3 秒超时反馈通过 |
| 提醒更新／过期与声音异常 | 7 | 显式刷新、过期隐私释放、零音量、失效工作区、陈旧快照、重复映射、损坏包及空库通过 |
| 合计 | 22 | 22 passed、0 failed |

步骤和固定场景见 [NATIVE-UI-REGRESSION.md](../../scripts/NATIVE-UI-REGRESSION.md)。
每次行动按当前 AX 定位并重读结果；动态按钮使用当前截图的唯一文字定位。断言同时
核对可见状态和隔离配置／manifest 的真实本地副作用。Provider、凭据、宿主操作及来源
应用激活为替身，不作为真实外部验证。验收实例已正常退出并执行剪贴板归还。

## 本地开发包与工作树

已执行 `scripts/dev-bundle.sh`，输出 `dist/claudi0.app`；大小门禁、无产品导出符号及
launch-compatible ad-hoc 签名检查通过。独立签名后大小检查结果为：

| 项目 | 大小／上限 |
| --- | --- |
| arm64 GUI | 6,938,736／7,000,000 B |
| arm64 helper | 3,179,520／3,250,000 B |
| arm64 LoginItem | 54,144／500,000 B |
| 非可执行资源 | 758,206／1,500,000 B |
| 正规文件合计 | 10,930,606／12,250,000 B |

GUI 文件 SHA-256 为 `0e1f14346457f5a1a40975818b84c31acbdaa9be0c99b014a59271d0c841d2d8`。
签名后正规文件清单摘要为 `7db2caa63da5e2acf426ec0721b45f185ff42693b7e12b378f13da26a9089458`；
计算方式与 native 构建清单相同：相对路径排序的文件记录 JSON（`sort_keys=True`）求 SHA-256，
符号链接单独登记，不重复计入正规文件大小。详见 `development-bundle-evidence.json`。

最新版常规开发包已启动。通过新进程启动时间及 `lsof` 核对，运行文件指向上述
`dist/claudi0.app/Contents/MacOS/claudi0-app`，文件摘要与新构建一致。
CUA 无法绑定初始无窗口的菜单栏应用，自动化未能访问菜单栏入口。因此常规包设置
窗口的现场核对仍未完成，没有把启动进程当作窗口证据。
最后的保护文件、bundle 文件及执行脚本核对见临时证据目录内 `final-audit.json`。

初始 `RetainedSettingsWindow.swift`、`PanelSettingsHandbackSuite.swift`、未跟踪原生参考原型、
两个旧横幅原型删除和已确认整合原型均保留。浏览器脚本保留原有回归，新增视觉检查并
修复语言切换前未展开场景控制的测试操作。上述验证采集时尚未 Git 提交，没有执行
push、PR、发行或旧 issue 状态修改。

## 独立验收状态

| 证据轴 | 状态 |
| --- | --- |
| 行为回归／原生挂载／隔离自动点击 | 已验证，范围如上 |
| 最新常规开发包启动／设置窗口 | 启动及运行文件已验证；设置窗口现场核对未完成 |
| 人工布局可读性 | 未验收；代理已查看截图，不能代替用户验收 |
| 真实键盘、VoiceOver | 未验收 |
| Reduce Motion／Increase Contrast／Reduce Transparency 系统开关 | 未验收 |
| 实际试听与听感 | 未验收 |
| 真实 Provider、来源应用激活、宿主回调 | 未执行／未验证 |
| Intel、universal、Developer ID 签名与公证 | 未验证 |
| 干净候选完整设置门禁 | 提交前未运行；`verify-settings-experience.sh` 要求获准提交后的干净 HEAD，验证时保留未提交工作树 |
| 完整迁移正式验收 | 未通过，不由上述自动结果推定 |

本次完成视觉实现和可执行验证，不把本地 arm64 ad-hoc 开发包视为正式发布产物。
