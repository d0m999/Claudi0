# 整合原型原生迁移：实现与验证记录

## 当前结论

已在保留既有工作树修改的前提下完成 P0–P6 的代码、文档和隔离原生检查工具。
原型 101 项、helper 4244 项、GUI 11549 项及最终 fixture 的 22 个原生用例通过。
GUI harness 包含生产设置根、声音页、AI 描述控件与横幅的原生挂载检查。
这些结果不等于人工布局、真实键盘、VoiceOver、实际听感或外部系统验收。

完整设置门禁未运行：`scripts/verify-settings-experience.sh` 要求干净 HEAD，
实现阶段未获准 Git 提交；用户随后另行授权本地提交，但原有修改仍保留在工作树。
没有为了执行该门禁改变固定基线或清理工作树。
因此不宣布完整原生迁移验收通过。

规格入口为 [PLAN-NATIVE-PROTOTYPE-MIGRATION.md](../../plan/PLAN-NATIVE-PROTOTYPE-MIGRATION.md)，
按用户指定的 to-spec 工作流发布为 [#213](https://github.com/d0m999/Claudio/issues/213)，
保持 `OPEN`、`ready-for-agent`；没有修改 #201 或 #207 的状态。

## 实现合同

- 原型删除整包导入按钮、演示创建及绑定分支；现行 DESIGN、设置计划与 ADR 0008、0016、
  0019 明确覆盖侧栏排序、声音包用语和无详情横幅合同，保留历史决策。
- retained 设置窗口共用八页顺序，保留路由身份与历史 `display` 兼容；页头、区块、控件行
  与响应式辅助栏使用新呈现规范。通知页按横幅、自动静默和当前状态组织。
- 声音与默认组／工作区读取真实集合，使用顶部选择器和纵向五事件卡。工作区定向编辑
  保存类型化返回上下文，返回时重验身份和目录目标，失效时显式拒绝；损坏声音包显示
  修复原因，不回退到默认组。普通复制、锁／CAS、草稿、共享使用者与失败保旧绑定保持原合同。
- `EventNoticeModel` 唯一持有提醒事实，独立发布横幅与共享冻结阅读投影。
  面板／诊断共用至多 50 项冻结集合，显式刷新，最后阅读消费者关闭后释放。
  4 秒横幅预算与提醒 TTL 独立，阅读界面不暂停或重置横幅预算。
- 组合根共享 `SessionNavigationCoordinator`。横幅静态正文、语义动作、失败就地重试；
  成功仅收起对应动作的横幅，保留提醒，也不会收起另一条较新的横幅。
  来源未确认时定位面板提醒，不猜测应用或会话路径。
- 面板顶部内嵌“需要你”列表与详情，事件行使用用户名称及可见异常原因；
  底部从共享活动投影读取所有来源今日／近七日五事件总数。
  活动与诊断默认折叠待处理事件记录，复制有效会话 ID；日志、计数和提醒清理相互独立。
- AI 卡使用既有五个 profile、路线能力、凭据与候选语义；锁定描述、取消、改名、显式采用
  和离页清理沿用真实 owner。内置包不提供生成入口；布局迁移不自动生成或新增付费调用。
  English 与 `zh-Hans` 同步登记，新增键注册到 `ClaudioL10nKey.allKnown`。
- 专用 DEBUG fixture 在生产 owner 创建前校验 bundle 身份与启动标记。
  临时配置、包库、活动与 defaults 隔离；真实视图及本地写入链保留。
  Provider、凭据、宿主操作、来源应用打开使用确定性替身，计时通过固定控件推进。

## 固定身份与环境

| 项目 | 值 |
| --- | --- |
| 仓库／分支 | Claudio／`main` |
| 固定基线与验证时 HEAD | `30446c56cd010d3d3338b2e8d19618939885319b` |
| 原型初始 SHA-256 | `7b6f04114fde9df726462eec72aacd3bb8648e89d8af4b84f2d07db0072c8a89` |
| 原型迁移后 SHA-256 | `628b0b5d4109bc789b2799df05fcfa495d9251170ae3f5e01ed1ba659896e895` |
| fixture 构建工作树指纹 | `c4e17006520bcc572ee7afb7d0c31cb78f8e55fc89f169b07822f478a37685c0` |
| fixture bundle SHA-256 | `b3637ea099383099099a05a37778d2f94d074aa7b4e98eccf058cc6d2bf60185` |
| fixture bundle 大小 | 37,108,770 B，DEBUG 检查包 |
| 自动点击脚本 SHA-256 | `2c74d68f62d5cebc6dd1890d7cbe0fa7e7cf2c27852f9651d86b663206bb27e1` |
| 截图 OCR 工具 SHA-256 | `6b4347ef80027cc7be95c7c553b9dbed27e78e0374ee573c55a3c65b0ed40a87` |
| 系统／架构 | macOS 27.0／arm64 |
| Swift／SDK | Swift 6.4／MacOSX26.5.sdk |
| 原生窗口 | 默认 1240×820pt，最小 960×640pt；记录实际 frame 与 2× backing scale |
| fixture 身份 | `com.claudio.app.ui-regression`，`ClaudioUIRegressionFixture=v1` |

默认 MacOSX27 SDK 缺少 `SwiftUIMacros`，本次显式使用已安装的 MacOSX26.5 SDK。
GUI harness 的子编译进程也需要 `SDKROOT`，不能仅给父 SwiftPM 传 `--sdk`。
本记录在 fixture 构建后新增；最终核对执行代码、测试与脚本仍与构建清单逐文件摘要一致。

本机临时原始证据：

- 最终 bundle 与构建清单：
  `/var/folders/1m/2jsf455s4r7dx9t8l233n55c0000gp/T/claudio-native-ui-build.AXw1WE/`
- 最终自动点击结果、AX 与截图：`/tmp/claudio-native-ui-evidence-AXw1WE/`
- 初始工作树内容摘要及 diff：`/tmp/claudio-native-migration-baseline/`

这些临时产物留在本机供复查，未加入 Git。最终原生结果使用同一 bundle、PID 与隔离根，
不是把不同源码版本的通过项拼接成一次通过。
独立只读核对确认 22 项结果的 AX、截图、driver 摘要、16 个 bundle 文件摘要和 705 个
源码清单条目一致，三个指定的初始修改文件摘要保持不变。

## 自动检查

从仓库根目录执行。GUI 命令统一使用：

```bash
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift run --package-path helper claudio-tests
swift run --package-path gui --scratch-path /tmp/claudio-native-sdk26 --sdk "$SDKROOT" claudio-gui-tests
swift build --package-path gui --scratch-path /tmp/claudio-native-sdk26 --sdk "$SDKROOT" -c debug --product ClaudioGUI
swift build --package-path gui --scratch-path /tmp/claudio-native-sdk26 --sdk "$SDKROOT" -c release --product ClaudioGUI
node scripts/test-panel-settings-prototype.js
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
bash scripts/dev-bundle.sh
git diff --check
```

| 检查 | 最终结果／原始日志 |
| --- | --- |
| 原型回归 | 101 项通过；`/tmp/claudio-native-prototype-final.log` |
| helper harness | 4244 项通过；`/tmp/claudio-native-helper-final-repeat.log` |
| GUI harness | 11549 项通过；`/tmp/claudio-native-gui-final.log` |
| 提醒／导航定向回归 | 817 项通过；`/tmp/claudio-native-attention-final.log` |
| GUI Debug 构建 | 通过；`/tmp/claudio-native-debug-final.log` |
| GUI Release 构建 | 通过；`/tmp/claudio-native-release-final.log` |
| 本次修改的 Swift 严格格式检查 | 52 个文件通过；`/tmp/claudio-native-format-final.log` |
| 本地化 JSON／键与占位符 | JSON 检查及 GUI harness 通过 |
| `git diff --check` | 通过 |
| 普通 Debug／Release 测试入口隔离 | `nm` 无专用 fixture 符号，`strings` 无 bundle／启动标记；`/tmp/claudio-native-normal-{debug,release}-isolation.json` |

构建仍有非致命的弃用、未使用变量和 CLT linker 搜索路径警告；不把构建通过表述为零警告。
helper 的上一轮有两项真实 shim 启动探测失败，涉及生产 1 秒超时。
独立重跑通过，未修改宿主版本探测行为；偶发根因未确认，失败日志保留在
`/tmp/claudio-native-helper-final.log`。此前 GUI 子编译 SDK 不一致及 General 默认路由
测试假设问题已分别通过显式 `SDKROOT` 和明确选择 General 修正，最终完整 harness 通过。

本次新增导航回归先确认红灯：旧提醒成功回调会关闭另一条较新横幅。
修复后只消费匹配动作的横幅，并验证两条提醒均保留。
损坏包的原生检查也推动补上作用域卡的可见修复原因，避免以“未配置”掩盖损坏状态。

## 原生自动点击结果

执行入口与固定场景见 [NATIVE-UI-REGRESSION.md](../../scripts/NATIVE-UI-REGRESSION.md)。
操作由 `mcp__cua_repl` 执行；每次操作重读 AX。AX 动作不可用时，解析 CUA 当前截图的
唯一文字与事件锚点，记录坐标和缩放后再通过 CUA 点击；不使用其他桌面输入 API。
断言检查最终可见状态及本地配置／manifest 副作用，点击本身不算通过。

| 用例组 | 数量 | 结果与边界 |
| --- | --- | --- |
| 八页导航矩阵 | 8 | 双语 × 浅／深色 × 默认／最小窗口；路由、选择、标题、顶部／底部滚动和实际窗口尺寸通过 |
| 完整 AI 操作 | 2 | 简中浅色默认窗口、English 深色最小窗口；工作区定向编辑／返回、生成锁定／取消、改名无额外请求、采用写盘、离页清理通过 |
| 完整提醒操作 | 2 | 同上两组；展开／详情、真实会话 ID 复制、移除、横幅失败／重试、成功保留提醒、关闭归还通过 |
| AI 与来源异常 | 3 | 路线拥有的 partial 数量、失败保旧映射、来源打开 3 秒超时通过 |
| 提醒与声音异常 | 7 | 更新后冻结／显式刷新／过期隐私释放、零音量、失效工作区、陈旧快照、重复绑定、损坏包、空库通过 |
| 合计 | 22 | 22 passed，0 failed；152 份 AX、170 张截图，含中间观察与 18 次有记录的截图定位动作 |

陈旧快照使用同一个 `SoundPackLibrary` 的 DEBUG 刷新失败回放，验证真实消费者接缝；
没有新增扫描 owner。候选音频为合成 fixture，不构成真实供应商质量或实际听感证据。
复制检查同时观察 UI 和真实 pasteboard；正常退出按 fixture 生命周期恢复此前剪贴板。
最终 fixture 已正常退出，保留隔离数据与证据，不启动普通 app 或安装宿主集成。

## 开发包

`SDKROOT` 指向 MacOSX26.5 SDK 执行 `scripts/dev-bundle.sh`。
原始日志为 `/tmp/claudio-native-dev-bundle-final.log`，最终包为 `dist/claudi0.app`。
脚本内大小预算、无产品导出符号及 launch-compatible ad-hoc 签名检查全部通过。

| 大小门禁 | 实际／默认上限 |
| --- | --- |
| arm64 GUI | 6,961,672／7,000,000 B |
| arm64 helper | 3,197,960／3,250,000 B |
| arm64 LoginItem | 54,304／500,000 B |
| 非可执行资源 | 747,390／1,500,000 B |
| 签名前 bundle 正规文件合计 | 10,961,326／12,250,000 B |

签名后正规文件合计为 10,912,622 B。最终 GUI 可执行文件 SHA-256 为
`1be1ad85d2d4ac7f62789c7d1d5288ce2fd63a9ffcede620d52c9c6032659aa9`，
UUID 为 `125DFA04-9873-3B5F-8AA8-7E3F73B42907`（arm64）。
签名后文件清单摘要为 `cd6a3c1955c5c0e517076bbfbbfdd79d24dea44d23d1543839d5122d626abb10`，
计算方式为相对路径排序后，对 `sha256  path` 行以换行连接的文本求 SHA-256，无末尾换行。
逐文件清单及普通包无 fixture 启动标记的检查保存在
`/tmp/claudio-native-dev-bundle-final-evidence.json`。

该包仅为当前架构 ad-hoc 本地检查产物，
没有把它表述为 universal、Developer ID 签名或公证发布包。

## 未完成的独立验收

| 证据轴 | 状态 |
| --- | --- |
| 行为回归 | 已验证，以上 harness 结果 |
| 原生挂载 | 已验证，限 harness 生产根与布局探针 |
| 原生自动点击 | 已验证，限最终 DEBUG fixture 的 22 用例 |
| 人工布局可读性 | 未验证；截图与 OCR 不能代替人工验收 |
| 真实键盘／焦点遍历 | 未验证；自动 AX 输入与 Escape 路径是独立证据 |
| VoiceOver | 未验证 |
| Reduce Motion／Increase Contrast | 未验证 |
| 实际试听／听感 | 未验证 |
| 真实来源应用激活／宿主回调 | 未验证，fixture 使用替身 |
| 真实 Provider 请求 | 未执行，没有费用或真实凭据读取授权 |
| Intel／双架构／正式签名与公证 | 未验证 |
| 获准提交后的干净候选完整设置门禁 | 未运行，当前工作树不满足前置条件 |
| 完整迁移正式验收 | 未通过，不由上述自动结果推定 |

## 工作树边界

初始修改的 `RetainedSettingsWindow.swift`、`PanelSettingsHandbackSuite.swift` 与
`test-panel-settings-prototype-browser.py` 内容摘要保持不变。
初始两个旧横幅原型删除、整合原型改动及未跟踪的原型 JS 脚本均保留；只有本次针对原型
整包导入合同的调整与相应回归算作新增迁移结果。
期间出现的未跟踪 `designs/macos-native-references/` 未触碰，不归入本次实现。
用户在实现与验证完成后另行授权本地提交。提交范围包含迁移代码、规格、验证报告、
回归工具与整合原型；上述初始焦点修复、Python 回归、旧横幅删除及参考目录不在提交范围。
本记录中的计数与原生 bundle 对应整合工作树，不推定为排除这些初始修改后的干净候选结果。
没有执行 push、PR、合并、部署、发行或旧 issue 状态变更。
