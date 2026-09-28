import Foundation

public enum SystemSoundSelectionError: Error, Sendable, Equatable, CustomStringConvertible {
    case unavailable(name: String)
    case outdatedHelper
    case configFailure(reason: String)
    case publishedConflict(recoveryPath: String? = nil)
    case lockBusy
    case lockFailed(errno: Int32)

    public var isPublishedConflict: Bool {
        if case .publishedConflict = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .unavailable(let name): "系统提示音 \(name) 不可用；未更改选择。"
        case .outdatedHelper: "已安装 helper 与当前应用不一致；请先修复连接。"
        case .configFailure(let reason): reason
        case .publishedConflict: "配置已发布但检测到并发冲突；请重新读取当前选择。"
        case .lockBusy: "配置正被其他进程使用，请稍后重试。"
        case .lockFailed(let code): "无法获取配置锁（errno \(code)），请稍后重试。"
        }
    }
}

/// Retired group-level entry point. Preserve existing config bytes and direct callers to the
/// pack editor; only pack manifest operations may create system-sound mappings (ADR 0021).
public func setSystemSound(
    _ event: Event,
    name: String?,
    catalog: SystemSoundCatalog = SystemSoundCatalog(),
    configFile: URL = ClaudioPaths.configFile,
    lockFile: URL = ClaudioPaths.configLockFile
) -> Result<Void, SystemSoundSelectionError> {
    .failure(.configFailure(reason: "组级系统提示音选择已停用；请前往声音编辑包映射。"))
}
