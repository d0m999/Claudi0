# claudi0 品牌资产

## T2 × C1 基础设计包

2026-10-10 版基础品牌包已归档于 [claudi0-basic-kit/](claudi0-basic-kit/)，共 26 件原始交付文件。入口：

- [文件清单与使用说明](claudi0-basic-kit/README.txt)
- [简明规范 PDF](claudi0-basic-kit/04-spec/quick-spec.pdf) / [离线 HTML](claudi0-basic-kit/04-spec/quick-spec.html)
- [品牌色值](claudi0-basic-kit/03-color/brand-tokens.json)
- [项目使用范围草案及字体来源](claudi0-basic-kit/LICENSE-usage.txt)

包内使用范围文件为待品牌方确认的草案，不修改仓库 [LICENSE](../../LICENSE)，也不代表已确认新的对外授权。

## App 运行资产（T2 × C1）

品牌包是唯一几何来源；下列运行资产只从包内素材派生，不重绘、不改色：

- `claudi0-app-icon.png`：品牌包 `02-icons/app-icon-1024.png` 的同字节副本（1024×1024 预览与商店素材）。
- `claudi0.icns`：macOS bundle 图标（含 16–1024 全尺寸），由脚本从上述母版缩放并封装。

App 内横向字标、菜单栏容器与面板头部图形由代码绘制，同源几何在
`gui/Sources/ClaudioGUIComponents/ClaudioBranding.swift`（`ClaudioT2Geometry`）；菜单栏使用同一几何的
18pt 酸柠容器，不嵌入位图。关于页身份块使用 96pt 容器与产品名，设置侧栏使用官方横向组合。

重新生成位图资产：

```sh
swift scripts/generate-brand-assets.swift
```

脚本会校验品牌包素材存在且为 1024×1024，再输出 PNG 母版与 `claudi0.icns`；不得用近似 SF Symbol
或手绘路径替代品牌包素材。
