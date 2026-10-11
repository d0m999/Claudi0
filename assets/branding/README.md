# claudi0 品牌资产

## T2 × C1 基础设计包

2026-10-10 版基础品牌包已归档于 [claudi0-basic-kit/](claudi0-basic-kit/)，共 26 件原始交付文件。入口：

- [文件清单与使用说明](claudi0-basic-kit/README.txt)
- [简明规范 PDF](claudi0-basic-kit/04-spec/quick-spec.pdf) / [离线 HTML](claudi0-basic-kit/04-spec/quick-spec.html)
- [品牌色值](claudi0-basic-kit/03-color/brand-tokens.json)
- [项目使用范围草案及字体来源](claudi0-basic-kit/LICENSE-usage.txt)

本次同步仅归档设计资产；App 运行资源、原生字标和菜单栏图形仍使用下述既有实现，尚未接入 T2 × C1。包内使用范围文件为待品牌方确认的草案，不修改仓库 [LICENSE](../../LICENSE)，也不代表已确认新的对外授权。

## 既有 App 运行资产（Orbit Zero）

既有运行资产方向为 **Orbit Zero**：末尾 `0` 是持续工作的信号容器，倾斜轨道表达 AI coding 的运行方向。2026-09-28 起不绘制原偏心装饰点；真实宿主状态继续由各自的状态组件表达。产品名写作 `claudi0`，仍读作 “Claudio”。

- `claudi0-mark.svg`：亮色表面的黏土色 Orbit Zero 主标志。
- `claudi0-app-icon.svg`：深色硬件感 macOS App 图标母版。
- `claudi0-app-icon.png`：1024×1024 预览与商店素材母版，由脚本生成。
- `claudi0.icns`：macOS bundle 图标，由脚本生成。

App 内横向字标由 `gui/Sources/ClaudioGUIComponents/ClaudioBranding.swift` 直接绘制；
菜单栏使用同一几何的 16pt 减法版本，不嵌入位图。

重新生成位图资产：

```sh
swift scripts/generate-brand-assets.swift
```

图形几何来自已选定的 Orbit Zero branding 稿，生成脚本不得用近似 SF Symbol 替代。
