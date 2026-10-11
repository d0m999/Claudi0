---
status: accepted
---

# 仅支持 Apple Silicon

2026-10-10，产品所有者明确选择 Claudio 只支持 Apple Silicon（arm64），macOS 12 最低版本保持不变。
此决定取代 ADR 0030 的双架构支持及两 CPU 验收要求，避免为不再支持的平台继续维护构建和设备矩阵。
Intel Mac 不再接收新候选；历史 universal 产物及测量记录保留，不改写成 arm64 验收。

正式、公开预览和本地 bundle 的 GUI/helper/LoginItem 均必须精确为 arm64，统一门禁拒绝
x86_64-only、universal 和未知架构；原体积、性能、签名、公证、macOS 12 及实际运行门禁不放宽。
Sparkle 2.10.0 上游 framework 保留完整 universal 字节、内部链接及原独立体积预算，作为依赖
不代表 Claudio 支持 Intel。宿主 CLI 的架构资格与 Claudio 分发架构分别判断，不改变版本缓存规则。

预览 manifest 只声明 arm64。官方 generate_appcast 根据实际主程序生成 arm64 hardwareRequirements，
发布前必须核对已签名 feed 中该候选的要求，缺失即拒绝；不在签名后修改 XML，不覆盖历史 feed 项。
远端发布和旧 Intel 安装的实际升级排除仍须独立验证，代码修改不代表已经部署更新源。

这项支持范围变更不启用生产版本缓存。ADR 0031 的本地实现与隔离验证授权继续有效；生产冷预算
尚未冻结，生产启用、宿主执行策略及回执热路径仍暂停，现有回执历史和活动计数不动。

本地实现与证据见[分发和缓存复验报告](../performance/hook-arm64-cache-validation-2026-10-10.md)。
支持范围决定不表示性能门禁、全量 GUI 或正式发布已经验收通过。
