# 第四批保留证据

这是隔离 fixture 的测试与验收证据，不含真实宿主配置、Provider 请求或用户声音包。结论和边界见[验收记录](../../settings-batch-four-2026-10-26.md)。真实 VoiceOver 尚未验收；历史工作树结果与干净候选门禁分开记录。

- `checks/`：有效原始失败、修复后结果、原型迁移前后输出。大日志仅移除 harness 开始之前的编译输出，文件头记录原始 SHA-256 和保留行号；断言、状态、按键记录未改写。三个早期诊断模式 GREEN 只保留结果行及源文件摘要，最终普通模式三轮另存完整 harness 输出。`keyboard-native-sdk-green-1.txt` 虽然原文件名含 green，实际为 **943 / 2 失败**，不得计入通过。
- 浏览器的两份 RED 含有意义的原始尾随空格，用 JSON `verbatimLines` 转义保存；拼接该数组可逐字节还原保留文本。未删空格，也未豁免格式门禁。
- `visual/`：正确 Mach-O SDK 26.5 下的导航 48 组合、反馈 48 组合及 AI 八组合审阅联系图。联系图是缩小排版，不能用于重新测量像素阈值；像素断言由实际挂载的原尺寸 view 完成。
- `animation-frames/`：中文亮色生成展开的 16 张连续原帧及 Reduce Motion 对照 16 帧，约每 16 ms 采样；其余 936 帧审阅后只保留联系图，清理重复原帧。普通 16 帧不同，降低动态效果的同阶段 16 帧相同。这里保留真实生产动画事务，不代表真实 Provider 时延或音频验收。
- `native/`：独立新 App 进程的外部 AX 文本、原生窗口截图、真实键盘取消／返回、系统紫色强调色及三项无障碍偏好的实际对照。AX 不替代 VoiceOver 听读。截图内版本与当前 macOS 为 fixture 固定展示值。
- `environment/`：构建来源、格式差分、系统偏好恢复与工具隔离记录。`fixture-builds.json` 保留最终对照 App 的源文件 SHA-256；第一个构建覆盖导航和系统外观，第二个构建包含最终通用／关于 AX 容器修复。harness 矩阵对应同阶段的生产呈现代码。早期外部 AX RED 保留原始读取文本，不能当作最终构建画面。
- `selection.json`：保留材料的来源与摘要；最终完整清单使用 `lstat` 生成，不跟随符号链接。临时 App、编译副本、fixture 数据与未保留截图已清理，清单在 `environment/cleanup.json`。

已保存的失败没有用跳过测试或放宽行为断言来消除。早期 `.regular` 夹具、窗口尚未出现在 WindowServer、旧链接 SDK 配色与实际正文焦点缺陷分别记录；尚未确定根因的瞬时失焦仍保留为失败证据。

最终综合门禁在干净实现提交 `da4928782e482a5698a377603c2d2d612dd16e0f` 上通过，见 `checks/integration-gate.json`：原始结果行及行号、源日志摘要、运行时段和开发 bundle 的 `lstat` 清单。后续证据提交不改变实现，不声称门禁在该文档提交上重跑。`commit-scope.txt` 保留首次实现提交的 180 文件范围，新增门禁记录由最终 manifest 覆盖。最终自动外观切为 Dark，具体读回及边界见 `environment/isolation-closeout.json`。
