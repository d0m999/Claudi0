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

/// Selects a system-owned sound for one Default Group event. `nil` restores this event's
/// selected-pack audio. The existing config lock and surgical JSON writer own the mutation.
public func setSystemSound(
    _ event: Event,
    name: String?,
    catalog: SystemSoundCatalog = SystemSoundCatalog(),
    configFile: URL = ClaudioPaths.configFile,
    lockFile: URL = ClaudioPaths.configLockFile
) -> Result<Void, SystemSoundSelectionError> {
    if let name, catalog.audioURL(named: name) == nil {
        return .failure(.unavailable(name: name))
    }
    let locked = withNonBlockingLock(path: lockFile.path) {
        updateConfigJSON(at: configFile, onMissing: .failClosed) { json in
            if let name, catalog.audioURL(named: name) == nil {
                return .failure(.mutationRejected)
            }
            var sounds = json["system_sounds"] as? [String: Any] ?? [:]
            sounds[event.cliName] = name
            if sounds.isEmpty {
                json.removeValue(forKey: "system_sounds")
            } else {
                json["system_sounds"] = sounds
            }
            return .success(())
        }
    }
    switch locked {
    case .ran(.success): return .success(())
    case .ran(.failure(.mutationRejected)):
        return .failure(.unavailable(name: name ?? ""))
    case .ran(.failure(.postPublishConflict(let path))):
        return .failure(.publishedConflict(recoveryPath: path))
    case .ran(.failure(.postPublishPathChanged)):
        return .failure(.publishedConflict())
    case .ran(.failure(let error)):
        return .failure(.configFailure(reason: error.reason))
    case .skipped: return .failure(.lockBusy)
    case .failed(let code): return .failure(.lockFailed(errno: code))
    }
}
