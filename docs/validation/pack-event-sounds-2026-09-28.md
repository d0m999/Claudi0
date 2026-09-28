# 包级文件／系统音映射：实施与验证

本记录对应 [ADR 0021](../adr/0021-own-all-event-sounds-in-packs.md)。代码已实现，以下结果在提交前的工作树中收集。

## 实施范围

- 「默认组／工作区」保留选包、独立音量、事件开关、试听和同窗口编辑链接；具体声音统一在「声音」页编辑。
- `PackEventSoundSource` 贯通 manifest、共享包库、覆盖度、试听、播放和诊断。文件保持字符串，系统音保存名称对象；首次系统音写入升级为 schema 2。
- 文件选择、导入绑定、AI 采纳和系统音选择共用包锁内的去重与完整来源 CAS。既有重复仍播放并显示提示；新重复被拒绝，原绑定保留。
- 第一条系统音可原子发布新用户包。失败或取消不留下可选空包，不自动应用到组；系统文件不被导入或复制。
- 旧 `system_sounds`／`systemSounds` 值由现有 JSON 写入入口保留，退出播放及有效配置校验；设置页提示重新配置。
- 补齐双语文案，并更新词汇表、当前设计、设置规格、声音包格式与 ADR 取代关系。

## 自动化结果

环境：macOS 27.0（26A428）、arm64、Apple Swift 6.4、Command Line Tools。测试时 HEAD 为
`857d1f4`，附带本轮改动和已有并行改动。本轮未改写 `SettingsWindowController.swift` 或
`PanelSettingsHandbackSuite.swift` 中的无关修改。此记录不包含推送、安装或发布证据。

| 检查 | 结果 |
| --- | --- |
| helper 完整 executable harness | 4227 项全部通过 |
| GUI 系统音专项 `--system-sounds` | 2136 项，0 失败 |
| GUI 完整 executable harness | 11513 项，1 项既有图标断言失败，详见下节 |
| GUI Debug，显式 SDK 26.5 | 通过 |
| GUI Release，显式 SDK 26.5 | 通过 |
| 本地化 catalog `jq empty` | 通过；双语 key 与占位符校验包含在 GUI harness 中 |
| 本轮 43 个 Swift 路径的 strict-format 诊断差分 | 相对 HEAD 无新增；基线与当前均保留 10 条既有诊断 |
| `git diff --check` | 通过 |
| 统一设置集成脚本 | 未验证：脚本要求 clean HEAD，当前工作树在入口处被拒绝 |

回归覆盖文件／混合／纯系统音包，切包与独立组音量／开关，首音发布及失败清理，共享库发布与
系统音可用性刷新，纯系统音包复制，文件规范化及符号链接去重，既有重复修复，缺失系统音，
helper 不匹配，锁冲突，完整来源 CAS，以及真实异步导入／采纳暂停期间系统音绑定变化。
旧字段包含未知形状时仍可读、可写其他设置，并保持其原始 JSON 值。

可重复命令（从仓库根目录运行）：

```bash
swift run --package-path helper claudio-tests
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --package-path gui claudio-gui-tests --system-sounds
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --package-path gui claudio-gui-tests
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -c debug --package-path gui --product ClaudioGUI
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -c release --package-path gui --product ClaudioGUI
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
git diff --check
```

### 既有失败与环境限制

- `ReleaseLayoutSuite.swift:1235` 仍断言 App 图标包含右上信号点。测试文件及
  `assets/branding/claudi0-app-icon.svg` 均与 HEAD 相同；HEAD 资产已无该点，符合 `DESIGN.md`
  的 2026-09-28 现行修订。本轮保留该无关失败，没有修改品牌资产或放宽测试。
- 规定的默认 GUI Debug 命令实际运行失败：默认 SDK 27 缺少 `SwiftUIMacros.StateMacro` 插件。
  `xcstringstool` 也不可用；当前包的资源规则使用 `.copy("Resources")`，因此显式 SDK 26.5
  可以完成本轮 GUI harness 和构建。未改变全局工具链或仓库的 SDK 配置。
- `bash scripts/verify-settings-experience.sh 0d73da1` 在入口报告
  `unified settings evidence must be collected from a clean HEAD`。单项结果不能合并宣称该门禁通过。

本机日志位于 `/tmp/claudio-pack-helper-final.log`、`/tmp/claudio-pack-gui-targeted-final.log`、
`/tmp/claudio-pack-gui-full-final.log`、`/tmp/claudio-pack-gui-debug-sdk26.log`、
`/tmp/claudio-pack-gui-release-sdk26.log`、`/tmp/claudio-pack-format-current.log` 和
`/tmp/claudio-pack-settings-gate.log`。

## 界面与外部证据

完整 GUI harness 的 `SettingsSoundsLayoutSuite` 挂载生产视图，检查中文 1240×820、英文
960×640 两种 fixture，并生成截图。本轮已读图检查包列表、滚动详情及固定操作栏，未见新增
横向裁切。此证据覆盖受控文件包 fixture；没有操作真实系统音下拉菜单，也不代表真实键盘焦点
或 VoiceOver 验收。截图可用 `CLAUDIO_LAYOUT_CAPTURE_DIR` 环境变量复现。

仍为 **NOT VERIFIED**：实际设置窗口中的系统音选择／试听／错误恢复、两种语言下的新菜单与
重复提示、键盘和 VoiceOver、真实听音、真实宿主回调、Intel 架构以及签名／公证／发布。
