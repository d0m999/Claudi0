import ClaudioCore
import Combine
import Foundation

/// 不落盘的隔离 defaults：预览与测试 fixture 专用（镜像 `SettingsFixtureDefaults` 的形状）。
/// 生产注入 `.standard`（见 `MenuBarController`）；默认构造的 owner 绝不能碰真实用户面板选择，
/// 所以这里所有读写都停在内存里，底层 suite 用一次性 UUID 保证不与任何持久域共享。
public final class SoundScopeSelectionFixtureDefaults: UserDefaults {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    public init() {
        super.init(suiteName: "Claudio.SoundScopeSelection.Unused.\(UUID().uuidString)")!
    }

    public override func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    public override func string(forKey key: String) -> String? { object(forKey: key) as? String }

    public override func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    public override func removeObject(forKey key: String) { set(nil, forKey: key) }
}

/// 可用声音作用域的 ID 投影：Global 恒在，加上当前 config 里的每一条工作区规则。
/// 与 `panelSoundScopePresentations` 的作用域集合一一对应，但不携带任何呈现事实。
public func soundScopeAvailableScopeIDs(config: ClaudioConfig) -> [PanelSoundScopeID] {
    [.global] + config.workspaceRules.map { PanelSoundScopeID.workspace($0.id) }
}

/// ID 版选择解析：缺失工作区保留 typed identity（刷新不能把下一次声音编辑静默变成默认组写入）；
/// 未知旧值显示 Global；nil / `unselected` 表示从未选择，同样显示 Global。
public func resolvedPanelSoundScopeSelection(
    storedValue: String?,
    availableScopes: [PanelSoundScopeID]
) -> PanelSoundScopeID {
    if storedValue == PanelSoundScopeID.global.storedValue { return .global }
    if let storedValue,
        let exact = availableScopes.first(where: { $0.storedValue == storedValue })
    {
        return exact
    }
    if let storedValue, storedValue.hasPrefix("workspace:"),
        let id = UUID(uuidString: String(storedValue.dropFirst("workspace:".count)))
    {
        return .workspace(id)
    }
    return .global
}

/// ID 版全局快捷键路由：已知的 Surface / 工作区身份即使当前不可用也原样保留（Events 页据此
/// 显示可见的恢复原因）；无法表示成 typed scope 的未知持久值只保留原始字符串，挂在一个
/// 不可写的 Global 呈现旁边。
public func globalShortcutEventSettingsRoute(
    storedValue: String?,
    availableScopes: [PanelSoundScopeID]
) -> EventSettingsWindowRoute {
    if storedValue == PanelSoundScopeID.global.storedValue {
        return EventSettingsWindowRoute(scope: .global)
    }
    if let storedValue, storedValue.hasPrefix("workspace:"),
        let id = UUID(uuidString: String(storedValue.dropFirst(10)))
    {
        let scope = PanelSoundScopeID.workspace(id)
        return EventSettingsWindowRoute(
            scope: scope,
            unavailableRequestedScopeStoredValue: availableScopes.contains(scope)
                ? nil : storedValue)
    }
    if let storedValue, let surface = HostSurfaceID(rawValue: storedValue) {
        let requestedScope = PanelSoundScopeID.surface(surface)
        if availableScopes.contains(requestedScope) {
            return EventSettingsWindowRoute(scope: requestedScope)
        }
        return EventSettingsWindowRoute(
            scope: requestedScope,
            unavailableRequestedScopeStoredValue: storedValue)
    }
    let resolved = resolvedPanelSoundScopeSelection(
        storedValue: storedValue, availableScopes: availableScopes)
    let unavailableValue = storedValue == nil || storedValue == "unselected" ? nil : storedValue
    return EventSettingsWindowRoute(
        scope: resolved,
        unavailableRequestedScopeStoredValue: unavailableValue)
}

/// C1：声音作用域选择的**单一 app 生命周期事实**。此前同一份选择有五个所有者（面板的
/// `@AppStorage`、`PanelConfigController` 的三个存储属性、快捷键直读 UserDefaults、设置侧的
/// `applyRoute` 与 `EventSettingsWindowSelection.route`），并且存在两个 `PanelConfigController`
/// 实例靠 `configProjectionToken` 自排除互相协调。现在：这个 owner 持有 typed 选择、钉定的
/// 工作区写目标、陈旧度与持久化字节；`PanelConfigController` 只派生读取，面板只呈现，
/// 快捷键经 ``shortcutRoute()`` 消费同一份事实。
///
/// 语义钉死（与 ADR 0005 的失败关闭一致）：
/// - 首次启动显示默认组；只有用户的显式选择才持久化（`nil` / `unselected` 绝不落盘）。
/// - 选择工作区时**钉定**当时的写目标；config 重读**不**自动重钉 —— 目录换绑必须表现为
///   `staleRule` 失败关闭，只有显式重选（`select`）才重钉。
/// - 缺失工作区保留 typed identity；垃圾持久值在 `applyConfig` 时规范化回 `global`。
@MainActor
public final class SoundScopeSelection: ObservableObject {
    /// 投影的陈旧度：与 `PanelConfigController.applyEffectiveConfig` 的判定顺序逐字对齐
    /// （先钉定目标 / 目录守卫 → `staleRule`，再 profile 解析 → `invalidRule`）。
    public enum Staleness: Sendable, Equatable {
        case current
        case staleRule
        case invalidRule
    }

    /// 对外只读投影：typed scope、钉定的写目标、陈旧度、可用性与当前持久化字节。
    public struct Projection: Sendable, Equatable {
        public let scope: PanelSoundScopeID
        public let writeTarget: WorkspaceSoundWriteTarget?
        public let staleness: Staleness
        public let isAvailable: Bool
        public let persistedStoredValue: String?
    }

    /// 只在真变化时发布（`guard next != projection`；Combine 的 `@Published` 不看等值）。
    @Published public private(set) var projection: Projection

    private let defaults: UserDefaults
    private var config: ClaudioConfig
    private var hasAppliedConfig = false

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        let empty = ClaudioConfig(selectedPack: "", eventsEnabled: [:])
        self.config = empty
        let storedValue = defaults.string(forKey: panelSoundScopeDefaultsKey)
        let scope = resolvedPanelSoundScopeSelection(
            storedValue: storedValue, availableScopes: [.global])
        projection = Self.makeProjection(
            scope: scope, writeTarget: nil, config: empty, persistedStoredValue: storedValue)
    }

    /// config 重读入口：只重算可用性 / 陈旧度并规范化持久**字节**（垃圾 → `global`，pending 不写）。
    /// 选择本身是 owner 的内存事实，config 重读**不**改写它 —— 非持久化选择（Surface / 未知工作区）
    /// 必须撑过 reload（旧 `PanelConfigController` 存储属性的行为；写失败后的 `reloadConfigOnly`
    /// 不能把 Surface 选择冲成 Global 而让下一次切包落进默认组）。仅首次 apply 时钉写目标，
    /// 之后保留已钉目标（目录换绑必须表现为 `staleRule` 失败关闭）。
    public func applyConfig(_ config: ClaudioConfig) {
        self.config = config
        let availableScopes = soundScopeAvailableScopeIDs(config: config)
        var storedValue = defaults.string(forKey: panelSoundScopeDefaultsKey)
        let resolved = resolvedPanelSoundScopeSelection(
            storedValue: storedValue, availableScopes: availableScopes)
        if let persisted = panelSoundScopeStoredValueToPersist(
            storedValue: storedValue, resolvedSelection: resolved),
            persisted != storedValue
        {
            defaults.set(persisted, forKey: panelSoundScopeDefaultsKey)
            storedValue = persisted
        }
        let writeTarget =
            hasAppliedConfig
            ? projection.writeTarget
            : Self.pinWriteTarget(for: projection.scope, config: config)
        hasAppliedConfig = true
        publish(
            scope: projection.scope, writeTarget: writeTarget,
            persistedStoredValue: storedValue)
    }

    /// 显式选择：Global 与当前可用的工作区持久化；Surface 与未知工作区不持久化但投影照移
    /// （失败关闭）。总是重钉写目标 —— 这是 stale 读回之后唯一的重钉通道。
    public func select(_ scope: PanelSoundScopeID) {
        let availableScopes = soundScopeAvailableScopeIDs(config: config)
        if scope == .global || (scope.workspaceID != nil && availableScopes.contains(scope)) {
            defaults.set(scope.storedValue, forKey: panelSoundScopeDefaultsKey)
        }
        publish(
            scope: scope,
            writeTarget: Self.pinWriteTarget(for: scope, config: config),
            persistedStoredValue: defaults.string(forKey: panelSoundScopeDefaultsKey))
    }

    /// 全局快捷键的 Events 路由：从持久化字节与当前可用集合即时解析，stale 的已知 scope
    /// 原样保留（设置窗口显示恢复原因，而不是静默猜另一个目标）。
    public func shortcutRoute() -> EventSettingsWindowRoute {
        globalShortcutEventSettingsRoute(
            storedValue: defaults.string(forKey: panelSoundScopeDefaultsKey),
            availableScopes: soundScopeAvailableScopeIDs(config: config))
    }

    private static func pinWriteTarget(
        for scope: PanelSoundScopeID,
        config: ClaudioConfig
    ) -> WorkspaceSoundWriteTarget? {
        scope.workspaceID.flatMap { id in
            config.workspaceRules.first(where: { $0.id == id }).map {
                WorkspaceSoundWriteTarget(rule: $0)
            }
        }
    }

    private static func makeProjection(
        scope: PanelSoundScopeID,
        writeTarget: WorkspaceSoundWriteTarget?,
        config: ClaudioConfig,
        persistedStoredValue: String?
    ) -> Projection {
        guard let id = scope.workspaceID else {
            return Projection(
                scope: scope, writeTarget: nil, staleness: .current,
                isAvailable: scope == .global, persistedStoredValue: persistedStoredValue)
        }
        let rule = config.workspaceRules.first(where: { $0.id == id })
        let staleness: Staleness
        if let target = writeTarget, rule?.directory == target.directory {
            switch config.resolveWorkspaceProfile(id: id) {
            case .success:
                staleness = .current
            case .failure(let error):
                staleness = error == .invalidRule ? .invalidRule : .staleRule
            }
        } else {
            staleness = .staleRule
        }
        return Projection(
            scope: scope, writeTarget: writeTarget, staleness: staleness,
            isAvailable: rule != nil, persistedStoredValue: persistedStoredValue)
    }

    private func publish(
        scope: PanelSoundScopeID,
        writeTarget: WorkspaceSoundWriteTarget?,
        persistedStoredValue: String?
    ) {
        let next = Self.makeProjection(
            scope: scope, writeTarget: writeTarget, config: config,
            persistedStoredValue: persistedStoredValue)
        guard next != projection else { return }
        projection = next
    }
}
