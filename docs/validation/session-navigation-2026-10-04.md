# 本地会话导航实施与验证（2026-10-04）

源码基线：`main` / `7472120b54d5300015a1b0550951029f4b70d397`。本文记录本地提交前的实施与验证；未 push、发布扩展或发行应用。原先的原生参考资料、Onboarding 原型及 event-animation 验证文件未修改。

## 实施状态

公共合同、helper 有界采集/降级传输、唯一模型内存目标、统一导航入口、iTerm2/Terminal/tmux/IDE/Codex 适配器、私有 IDE socket、双语新增文案、Apple Events 构建配置和本地 VSIX 已实现。原始证据接收后释放；只有宿主读回确认才能消除捕获的提醒版本。固定 URL/动作不接受任意执行接口，回退和定位共享三秒预算；预期焦点交接在固定聚焦动作前显式标记。

用户计划第 4.1 节要求先确认 HTML 原型再改原生呈现。已发出确认请求，尚未收到答复。因此当前原生正文/主按钮/面板仍使用旧呈现和旧 App 入口；新适配器尚未成为原生按钮的正式导航能力。拟议呈现变更完整保存于 `plan/session-navigation-native.patch`，覆盖正文独立按钮、主操作统一入口、反馈、焦点交接、父会话标签、Panel 和 Diagnostics；已通过 `git apply --check` 及 Swift 语法解析，但未应用，也未取得完整类型检查或原生验收。

ADR 0023 为 proposed；DESIGN 的待确认段明确与现行“正文静态/App 打开即收起”合同的替代关系，未提前声明原生生效。此交付不是整个计划已完成。

## 自动验证

| 门禁 | 结果与边界 |
| --- | --- |
| `swift run --package-path helper claudio-tests` | PASS：4299/4299 |
| `bash scripts/test-session-navigation-core.sh` | PASS：196/196；编译真实 ClaudioGUICore 与不含 SwiftUI 的导航适配器，运行模型、原/新协调器、tmux 格式和真实私有 socket fixture；独立替代检查，不冒充完整 GUI harness |
| `node scripts/test-panel-settings-prototype.js` | PASS：106/106 |
| `python3 scripts/test-panel-settings-prototype-browser.py` | PASS：19/19；真实浏览器 HTML 检查，不代表原生呈现 |
| `npm test --prefix extensions/vscode` | PASS：10/10；固定动作、多窗口实例、取消、超时、失连、terminal 关闭、PID 歧义、主动切走 |
| `npm run package --prefix extensions/vscode` / VSIX ZIP 完整性 | PASS；`dist/claudio-session-navigation-1.0.0.vsix`，SHA-256 `476b6177446a2b1058381153dafbbbafee3536248f181cb28158c24602e8c660` |
| 完整 GUI executable harness | BLOCKED：Command Line Tools 缺少 `SwiftUIMacros.StateMacro` 插件，未执行测试 |
| GUI Debug / Release product build | BLOCKED：同一插件缺失；相关 `@State` 错误及不可变 self 诊断随之产生 |
| 新增导航适配器独立编译 / Runtime 独立类型检查 | PASS；后者使用单独生成的导航组件模块，不代表 GUI 产品构建 |
| `jq empty` / 新增 en 与 zh-Hans 键及 `allKnown` | PASS：新增三个无占位符键，匹配注册 |
| entitlement plist / bundle 脚本语法 / release 配置检查 | PASS：Apple Events entitlement 与用途说明均存在；本地 ad-hoc 签名仍保留既有无 entitlement 合同 |
| 本地 Claudio bundle、签名、体积 | NOT RUN：GUI 构建阻塞；未删除/覆盖旧 bundle 来重复失败，旧 artifact 不算本轮产物 |
| 原生待确认补丁 / `git diff --check` | PASS：可应用检查、语法解析、diff 空白检查；原生补丁尚未应用 |

提交前复核：导航核心 196/196、扩展 10/10、HTML 原型状态检查 106/106、本地化 JSON 与脚本语法检查均通过。helper 首次与导航构建并行重跑时出现 1/4299 项失败，输出截断未保留具体断言；随后单独完整重跑为 4299/4299 通过。没有为此修改业务代码，首轮失败原因尚未定位，不能据一次重跑排除间歇问题。暂存检查另发现补丁文件的空白上下文行被当作尾随空格；已规范为空行，`git apply --check` 仍通过，原生补丁保持未应用。

## 真实宿主验收

全部未验证。仅读取了版本/安装元数据，没有操作真实会话，没有安装 VSIX，没有请求 Apple Events 权限。

| 宿主 | 可读元数据 | 正确窗口/tab/pane/thread、键盘与 VoiceOver |
| --- | --- | --- |
| Terminal.app | 2.15 | NOT VERIFIED |
| iTerm2 | 标准 `/Applications/iTerm.app` 未发现；其他位置未查全 | NOT VERIFIED |
| tmux | 3.7c | NOT VERIFIED：server/client、detach/reattach、外层窗口 |
| VS Code | 1.140.0 | NOT VERIFIED：两个同工作区窗口、多个 terminal、真实扩展连接 |
| Cursor | 标准 `/Applications/Cursor.app` 未发现；其他位置未查全 | NOT VERIFIED |
| Codex desktop | 26.930.31428 / `com.openai.codex`，安装目录名为 ChatGPT.app | NOT VERIFIED；只允许 requestSent，不具备 thread 读回 |

最小化、其他 Space、全屏、目标关闭、权限拒绝、点击后立即切走、键盘焦点和 VoiceOver 仍待逐宿主人工验证。IDE 未连接不能可靠推断“未安装”（例如自定义 extension 目录/禁用/重载）；目前提供未连接、已验证连接、版本不支持状态及主动安装步骤，“未安装”专属状态尚未完成可靠检测。

## 本轮误操作与恢复（独立于 Claudio 交付）

读取 Codex 桌面元数据时，`plutil -extract … json` 未显式指定 `-o -`，误覆盖 `/Applications/ChatGPT.app/Contents/Info.plist`。已停止元数据探测并完成恢复：从官方同版本 `ChatGPT-darwin-arm64-26.930.31428.zip` 提取原文件；先验证 archive 的 `Contents/MacOS/ChatGPT` 和 `_CodeSignature/CodeResources` 与本机逐字节相同，再原子恢复 Info.plist。

恢复文件 SHA-256：`8b72fd3f7925f1c4dfc480bc20b769cb554a55eb56a9876848ac89fd2433bc90`（20810 bytes）。恢复后 `codesign --verify --deep --strict --verbose=2 /Applications/ChatGPT.app` exit 0，显示 `valid on disk` 和 `satisfies its Designated Requirement`。没有重签名、升级或替换主程序；本项验证的是误操作恢复，不是 Claudio bundle 签名。

## 下一步

1. 用户确认整合 HTML 原型后，应用原生补丁并将 ADR/设计合同转为现行；补齐原生交互回归。
2. 在具备 SwiftUI macro 插件的完整工具链上执行 GUI harness、Debug/Release、本地 bundle 与签名/体积检查。
3. 用户主动安装 VSIX，按计划逐宿主进行真实跳转、焦点、拒绝权限和 VoiceOver 验收，再决定正式能力资格。
