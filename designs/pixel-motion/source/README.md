# Pixel Motion 归档源

`Pixel Motion Prototype.html` 是动画导出与回归的固定来源，按 Git 历史原字节恢复。
它不作为当前产品界面，不进入 app bundle；原生呈现遵循 `DESIGN.md`。

- 来源 commit：`d188e5801c54dbbbba23794ac80adf40d7373409`。
- 删除 commit：`da2a035160494ed9f7d6ad1b9db2cc037b7e9002`。
- 完整 SHA-256：`447509d637fef2e11bb8c3c65e249476bc8dbd127f771fa219729b428ded22fc`。

该 SHA 与既有 runtime provenance 和 playback reference 一致。`export-original-samples.py`、
`export_runtime.py`、资源检查与 GUI 集成套件共同读取本路径，继续核对逐帧时序、循环边界、
480 个参考帧和源变更拒绝旧导出的合同。此次恢复没有重新绘制角色或修改导出资源。
