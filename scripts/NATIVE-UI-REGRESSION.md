# 原生自动点击检查

仅使用 `scripts/build-native-ui-regression.sh` 构建的 DEBUG fixture。正常 Debug 和 Release 不编译测试入口。fixture 在生产 owner 创建前校验 bundle 身份和 `ClaudioUIRegressionFixture=v1`，配置、声音包、活动、defaults 均隔离到临时根。Provider、凭据、宿主操作和来源应用打开使用替身；本地编辑、采用和窗口呈现复用真实 owner。

从仓库根目录构建：

```bash
bash scripts/build-native-ui-regression.sh
# 默认 SDK 不可用时可显式设置 CLAUDIO_UI_REGRESSION_SDK；证据会记录该选择。
# 新规格使用自己的固定基线时，显式设置 CLAUDIO_UI_REGRESSION_BASE_SHA。
# 不设置该值时继续使用完整原生迁移原有的固定基线。
```

输出专用 app 路径及 `build-evidence.json`。用 `mcp__cua_repl` 获取该 app，执行脚本：

```javascript
let app = await cua.getApp(appPath);
let { createNativeUIRegression } = await import(repoPath + '/scripts/native-ui-regression.mjs');
let run = await createNativeUIRegression({ cua, app, buildEvidence, outputDirectory });
// 分次执行，保留每一步的当前 AX 状态。
await run.matrix(1); // 依次 1–8
await run.flow(1);
await run.reminderFlow(1);
await run.flow(8);
await run.reminderFlow(8);
await run.generationExceptions();
await run.exceptions();
```

每次 `mcp__cua_repl` 调用内必须 `await` 完成所执行的用例。不要启动未等待的后台
Promise 后结束调用；后续 CUA 行动会失去执行上下文，必须记为失败，不能算通过。
较长异常组可通过已有的固定 `outcomes`、`includeTimeout`、`includeReminders` 和
`scenarios` 参数拆分执行，避免长时间占用单次调用。重新运行时使用新的证据目录保留
失败尝试；不要把不同 bundle 的结果拼接成一次通过。

矩阵为简中／English × 浅色／深色 × 默认／最小窗口。每页检查路由、侧栏选择、标题，采集顶部和底部 AX／截图，并核对实际窗口尺寸和外观。完整流程检查工作区定向编辑和返回、生成锁定、取消、改名、真实本地采用、离页清理、提醒复制／移除、跳转失败／重试以及窗口关闭归还。固定异常场景覆盖 partial／失败、超时、提醒更新／过期、零音量、失效工作区、陈旧快照、重复绑定、损坏包和空库。

设置一致性矩阵还复用实际挂载的 frame recorder 与只读位图取样，检查八页内容底色、
侧栏组内／组间间距、五张独立事件卡、选择器高度、信息卡间距，以及主辅栏位置。
位图先按其 ICC 色彩空间转换到 sRGB，再比较无文字区域，单通道容差为 3；不能对
`colorAt()` 返回的 calibrated NSColor 单独转换并忽略位图原有的显示器配置。
这些只读证据仅编译在专用 DEBUG fixture，正常 Debug／Release 均无此入口。

`results.json` 逐项保存结果、失败原因、AX、截图、本地 readback 和构建证据；接口不可用或找不到唯一控件均失败，不把点击本身计为通过。每次行动后重新读取 AX，禁止复用历史索引。动态控件的 AX 行动不可用时，使用构建时生成的 `screenshot-ocr` 读取 CUA 当前截图，按唯一文字与事件锚点定位，再重验当前 AX 身份后通过 CUA 点击。OCR 仅解析截图文件，不读取桌面或发送输入；记录截图、AX、坐标及脚本摘要。脚本只通过公开 CUA 控制 UI，不接受任意测试命令。临时时钟仅通过固定控件推进。

控制窗口可用 Command+Shift+0 返回；Command+Shift+9 退出 fixture。Command+Shift+B 聚焦真实横幅，Command+Shift+L 仅聚焦当前设置窗口，不触发重新呈现或刷新。陈旧快照场景通过同一个 `SoundPackLibrary` 的 DEBUG 观察流回放刷新失败，复用消费者的真实处理接缝。原生可写文本控件用当前 AX 值输入并读回；自动 AX 输入不能代替真实键盘验收。保留临时数据与证据便于复查，不改变真实 Claudio 的安装和数据。

自动点击不能证明真实键盘遍历、VoiceOver、实际听感、人工布局可读性、真实 Provider 或来源应用激活。完整设置门禁仍要求获准提交后的干净候选；本次工作树交付不满足该前置条件。
