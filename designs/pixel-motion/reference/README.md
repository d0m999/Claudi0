# 事件动画固定来源

`approved-source.html` 是已批准动画的原始绘制与选帧输入，逐字节取自提交 `3bf3840` 的
`designs/pixel-motion/Pixel Motion Prototype.html`。SHA-256 为
`447509d637fef2e11bb8c3c65e249476bc8dbd127f771fa219729b428ded22fc`，
与现有样本、播放／像素参考和运行资源的来源指纹一致。

它只用于重建与核对三组角色的画面、逐帧时长、循环范围和静态帧，作为固定验证输入归档。
2026-10-07 退役的独立原型不重新作为产品设计入口；面板、横幅与设置的现行画面仍由
[`Panel and Settings Prototype.html`](../../panel-and-settings/Panel%20and%20Settings%20Prototype.html)
拥有。主原型引用导出图片，不能代替独立的原始 Canvas 绘制输入验证这些图片。

`export-original-samples.py` 与 `export_runtime.py` 共用此来源；`--check-runtime` 在临时目录
重建并比较 480 个原始帧、2,809 个选帧边界和全部资产，不改写已跟踪资源。
来源更新必须与批准的动画变更及重新导出的参考一同交付；不能从运行资源反推期望值。
