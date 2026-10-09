# 设计归档与素材管理索引

更新日期：2026-10-02。本索引登记来源角色与后续归档决策；不移动、删除或忽略当前实现／检查依赖。当前 UI 与实现状态见 [对齐记录](../docs/validation/sot-implementation-alignment-2026-10-02.md)。

本次提交只交付文档与忽略规则；标为“工作树待提交”的原型、素材和固定证据尚未纳入 Git。下方“应进入版本管理”表示后续交付要求。

## 历史方向与替代关系

| 文件 | 状态与保存方式 | 当前依据 |
|---|---|---|
| macOS 两方向探索（工作树待提交：`designs/macos-native-references/claudi0-macos-native-variants.html`） | 2026-10-01 探索稿，未被现行设置合同采用；保留原路径作为历史参考。SHA-256 `afb796b728e0b1fc521956e6712e28e2c73498a84696f7735158ca00a36de6e5`。 | [DESIGN](../DESIGN.md) 的八页设置章节和固定设置原型拥有当前设置呈现。 |
| `event-banner-redesign/Event Banner Redesign.html` 与 `event-banner-redesign/Event Banner — 行动优先（定稿）.html` | 独立横幅呈现已被整合原型覆盖；本轮开始前工作树已删除，Git 历史保留。本轮没有恢复或重新删除。已跟踪文件不通过 `.gitignore` 处理。 | [整合原型](panel-and-settings/Panel%20and%20Settings%20Prototype.html)、DESIGN 现行横幅合同及 #216 角色呈现增量。 |
| [设置研究与能力索引](macos-settings-native/README.md) 的原始日期／盘点／验证记录 | 保留研究推导和历史证据，配套说明同步当前状态；原始 JSON 与截图不改写。 | 八页设置合同、#215 原生迁移记录和 #216 独立增量。 |
| 动画设置原型（工作树待提交：`designs/macos-settings-native/Animation Settings Prototype.html`） 的 B/C 比较布局 | 保留为探索选项；当前产品采用 A 并排布局，比较器不属于产品功能。 | [事件动画规格](../plan/PLAN-EVENT-ANIMATION.md)。 |

## 应进入版本管理的素材

- 批准的源原型、导出脚本与对应规格。
- `pixel-motion/reference/approved-source.html` 与说明：2026-10-09 按原 SHA-256 保存的动画绘制／时序固定输入，仅供导出校验；不恢复已退役的独立产品原型。
- `gui/Sources/ClaudioGUI/Resources/EventAnimations/` 的正式图集、时序与清单。
- `designs/pixel-motion/samples/` 的 provenance、播放／像素参考、E/G/H 规范样本，以及 `previewFiles` 登记的 17 张预览。导出检查、集成 suite 或来源审计直接依赖这些文件。
- `macos-settings-native/screenshots/`、`verification/` 和 `VERIFICATION.json` 的固定历史证据，以及引用它们的文档。

“可生成”本身不足以决定忽略；应用、检查或固定证据依赖的素材应与代码和来源一起保存。

## 只在本机保留的输出

`.gitignore` 仅新增以下精确路径；文件仍留在本机：

```gitignore
/designs/pixel-motion/samples/claudi0-pixel-motion-samples.zip
/designs/pixel-motion/samples/G-compare-idle.gif
/designs/pixel-motion/samples/H-compare-stop.gif
```

ZIP 是脚本生成的分发包，当前检查不以它为输入；两个比较 GIF 未被当前源码、原型、来源清单或检查引用。将来若成为固定文档证据或测试输入，应移除对应忽略规则并补来源记录。

浏览器回归默认将逐次运行输出写入系统临时目录；当前无需追加整个截图、验证或素材目录的忽略规则。现有 `.build/`、`dist/`、`__pycache__/` 和机器私有数据规则继续适用。
