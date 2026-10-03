import ClaudioCore
import ClaudioLocalization
import Foundation

/// 菜单栏声音作用域的稳定身份。`global` 不是伪造的 Host；Surface 始终保留真实
/// `HostSurfaceID`，供配置写入、窗口路由和焦点恢复共同消费。
public enum PanelSoundScopeID: Sendable, Equatable, Hashable, Identifiable {
    case global
    case workspace(UUID)
    // Kept only for rejecting stale routes; never a selectable sound target.
    case surface(HostSurfaceID)

    public var id: String { storedValue }

    public var storedValue: String {
        switch self {
        case .global: "global"
        case .workspace(let id): "workspace:" + id.uuidString
        case .surface(let surface): surface.rawValue
        }
    }

    public var workspaceID: UUID? {
        guard case .workspace(let id) = self else { return nil }; return id
    }

    public var surface: HostSurfaceID? {
        guard case .surface(let surface) = self else { return nil }
        return surface
    }
}

public let panelSoundScopeDefaultsKey = "claudio.panel.selected-surface"

/// A directory detail keeps the identity captured at entry, including across configuration reloads.
public enum WorkspaceSettingsDetail: Sendable, Equatable {
    case configuration
    case workspaces
    case scope(WorkspaceSoundWriteTarget)
}

/// “事件与提示音”表面的显式入口。路由直接携带声音作用域与可选公共事件，避免把展示
/// 名称或 Host Product 重新解析成配置写入目标。
public struct EventSettingsWindowRoute: Sendable, Equatable, Hashable {
    public let scope: PanelSoundScopeID
    public let event: Event?
    /// A panel shortcut retains the directory selected when it was created. A later UUID rebind
    /// cannot turn the request into an edit of another workspace.
    public let workspaceTarget: WorkspaceSoundWriteTarget?
    public let unavailableRequestedScopeStoredValue: String?
    public let detail: WorkspaceSettingsDetail

    public init(
        scope: PanelSoundScopeID,
        event: Event? = nil,
        workspaceTarget: WorkspaceSoundWriteTarget? = nil,
        unavailableRequestedScopeStoredValue: String? = nil,
        detail: WorkspaceSettingsDetail = .configuration
    ) {
        self.scope = scope
        self.event = event
        self.workspaceTarget = workspaceTarget
        self.unavailableRequestedScopeStoredValue = unavailableRequestedScopeStoredValue
        self.detail = detail
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(scope)
        hasher.combine(event)
        hasher.combine(workspaceTarget?.id)
        hasher.combine(workspaceTarget?.directory.kind.rawValue)
        hasher.combine(workspaceTarget?.directory.path)
        hasher.combine(workspaceTarget?.directory.commonGitDirectory)
        hasher.combine(unavailableRequestedScopeStoredValue)
        switch detail {
        case .configuration:
            hasher.combine(0)
        case .workspaces:
            hasher.combine(1)
        case .scope(let target):
            hasher.combine(2)
            hasher.combine(target.id)
            hasher.combine(target.directory.kind.rawValue)
            hasher.combine(target.directory.path)
            hasher.combine(target.directory.commonGitDirectory)
        }
    }

    public func workspaceTargetIsCurrent(in config: ClaudioConfig) -> Bool {
        if let workspaceTarget {
            guard case .workspace(let id) = scope, workspaceTarget.id == id,
                let rule = config.workspaceRules.first(where: { $0.id == id })
            else { return false }
            guard rule.directory == workspaceTarget.directory else { return false }
        }
        guard case .scope(let detailTarget) = detail else { return true }
        guard case .workspace(let id) = scope, detailTarget.id == id,
            let rule = config.workspaceRules.first(where: { $0.id == id })
        else { return false }
        return rule.directory == detailTarget.directory
    }

    public var surface: HostSurfaceID? { scope.surface }

    public func soundPacksRoute(packID: String, event: Event) -> SoundPacksWindowRoute {
        .editEvent(
            scope: scope, packID: packID, event: event, workspaceTarget: workspaceTarget)
    }

    /// Missing-sound deep link for a read-only pack. The scope is retained explicitly so the
    /// Sounds page can copy first and apply only to this Default Group/Workspace target.
    public func soundPacksCopyAndApplyRoute(
        packID: String,
        event: Event
    ) -> SoundPacksWindowRoute {
        .copyAndApply(
            scope: scope, packID: packID, event: event, workspaceTarget: workspaceTarget)
    }
}

/// Resolves the file that both event surfaces may preview. Keeping the stale-coverage recheck in
/// one place prevents the panel and retained window from drifting on symlink or empty-file safety.
public func eventPreviewFileURL(
    row: EventRow,
    packID: String,
    environment: AudioImportEnvironment
) -> URL? {
    guard row.coverage.previewEnabled,
        let packDirectory = resolvePackDirectory(
            id: packID,
            userPacksDirectory: environment.userPacksDirectory,
            bundledPacksDirectory: environment.bundledPacksDirectory),
        let file = row.soundSource?.audioURL(
            in: packDirectory, catalog: environment.systemSoundCatalog),
        nonEmptyRegularFileExists(at: file)
    else { return nil }
    return file
}

/// Stable focus identities for the retained Events & Sounds window. The first scope is always the
/// deterministic entry point; event controls follow the visible row order through SwiftUI's key
/// view loop.
public enum EventSettingsFocusTarget: Sendable, Equatable, Hashable {
    case title
    case scope(PanelSoundScopeID)
    case unavailableScope
    case workspaceRemove(UUID)
    case workspaceDeleteResult
    case workspaceDeleteFeedback
    case event(Event)
    case previewAll
    case masterVolume
    case packPicker
    case retryLibrary
    case manageSoundPacks
    case generateAICue(Event)
    case soundChoice(Event)
    case configure(Event)
    case preview(Event)
    case mute(Event)
}

public func eventSettingsFirstFocusTarget(
    scopes: [PanelSoundScopeID]
) -> EventSettingsFocusTarget? {
    scopes.first.map(EventSettingsFocusTarget.scope)
}

/// Repeated typed deep links must focus the same stable event identity. A stale scope never leaves
/// focus pointing at a row whose writes would target another Surface.
public func eventSettingsRouteFocusTarget(
    route: EventSettingsWindowRoute,
    scopes: [PanelSoundScopeID],
    events: Set<Event> = Set(Event.allCases)
) -> EventSettingsFocusTarget? {
    guard scopes.contains(route.scope) else {
        return eventSettingsFirstFocusTarget(scopes: scopes)
    }
    if let event = route.event, events.contains(event) {
        return .event(event)
    }
    return .scope(route.scope)
}

/// 全宽声音作用域菜单的一项。状态仍是语义枚举；图标与颜色只在 SwiftUI 层选择。
public struct PanelSoundScopePresentation: Sendable, Equatable, Identifiable {
    public var id: PanelSoundScopeID { scope }
    public let scope: PanelSoundScopeID
    public let host: HostID?
    public let name: String
    public let supportedCount: Int
    public let totalCount: Int
    public let status: HostSourceRowStatus
    public let coverageText: String
    public let stateText: String
    public let summaryText: String
    public let hasSparseOverride: Bool
    public let accessibilityLabel: String

    public init(
        scope: PanelSoundScopeID,
        host: HostID?,
        name: String,
        supportedCount: Int,
        totalCount: Int,
        status: HostSourceRowStatus,
        coverageText: String,
        stateText: String,
        summaryText: String,
        hasSparseOverride: Bool,
        accessibilityLabel: String
    ) {
        self.scope = scope
        self.host = host
        self.name = name
        self.supportedCount = supportedCount
        self.totalCount = totalCount
        self.status = status
        self.coverageText = coverageText
        self.stateText = stateText
        self.summaryText = summaryText
        self.hasSparseOverride = hasSparseOverride
        self.accessibilityLabel = accessibilityLabel
    }
}

/// 声音作用域浮层在当前滚动视口内的尺寸决策。面板只负责选择 Scope；集成管理与诊断
/// 由 Settings 目的页承载。菜单底部不再保留 footer 入口（2026-09-10 起改为异常状态行的
/// 行内状态动作），因此诊断入口不占用纵向高度。
public struct PanelSoundScopeMenuLayout: Sendable, Equatable {
    public let optionHeight: Double
    public let optionsContentHeight: Double
    public let optionsHeight: Double
    public let diagnosticsHeight: Double
    public let totalHeight: Double
}

public func panelSoundScopeMenuLayout(
    scopeCount: Int,
    typeScale: Double,
    availableHeight: Double
) -> PanelSoundScopeMenuLayout {
    let count = max(0, scopeCount)
    let scale = max(1, typeScale)
    let optionHeight = max(46, 46 * typeScale)
    let diagnosticsHeight: Double = 0
    let chromeHeight: Double = 21
    let designHeightLimit = 250 * scale
    let effectiveAvailableHeight =
        availableHeight.isFinite && availableHeight > 0
        ? availableHeight : designHeightLimit
    let optionsContentHeight =
        Double(count) * optionHeight + Double(max(0, count - 1)) * 3
    let designOptionsLimit = max(0, designHeightLimit - diagnosticsHeight - chromeHeight)
    let viewportOptionsLimit = max(
        0,
        effectiveAvailableHeight - diagnosticsHeight - chromeHeight)
    let optionsHeight = min(optionsContentHeight, designOptionsLimit, viewportOptionsLimit)
    return PanelSoundScopeMenuLayout(
        optionHeight: optionHeight,
        optionsContentHeight: optionsContentHeight,
        optionsHeight: optionsHeight,
        diagnosticsHeight: diagnosticsHeight,
        totalHeight: min(
            effectiveAvailableHeight,
            optionsHeight + diagnosticsHeight + chromeHeight))
}

public func panelSoundScopePresentations(
    sourceRows: [HostSourceRowPresentation],
    config: ClaudioConfig,
    language: ClaudioAppLanguage
) -> [PanelSoundScopePresentation] {
    let l10n = ClaudioL10n(language: language)
    let separator = language == .english ? ", " : "，"
    let globalName = l10n.text(.panelGlobalDefaults)
    let globalCoverage = l10n.format(
        .panelSoundScopeGlobalCoverage,
        Int64(Event.allCases.count))
    let globalState = l10n.text(.panelSoundScopeStatusDefault)
    let globalSummary = [globalCoverage, globalState].joined(separator: " · ")
    let global = PanelSoundScopePresentation(
        scope: .global,
        host: nil,
        name: globalName,
        supportedCount: Event.allCases.count,
        totalCount: Event.allCases.count,
        status: .ready,
        coverageText: globalCoverage,
        stateText: globalState,
        summaryText: globalSummary,
        hasSparseOverride: false,
        accessibilityLabel: [globalName, globalSummary].joined(separator: separator))

    let workspaces = config.workspaceRules.map { rule in
        let name = rule.name
        let state = l10n.text(rule.profile == nil ? .workspaceNeedsRepair : .workspaceLabel)
        return PanelSoundScopePresentation(
            scope: .workspace(rule.id), host: nil, name: name,
            supportedCount: Event.allCases.count, totalCount: Event.allCases.count,
            status: rule.profile == nil ? .needsAttention : .ready,
            coverageText: globalCoverage, stateText: state,
            summaryText: globalCoverage + " · " + state,
            hasSparseOverride: false, accessibilityLabel: name + separator + state)
    }
    return [global] + workspaces

}

/// 行内状态动作的决策级投影：只有异常状态（待回执 / 旧版 / 需要处理）的 Surface 行产生
/// 集成入口，返回值为 typed route `.integrations(IntegrationsSettingsRoute)` 需要的真实宿主身份。
/// Global 与 「已激活」行保持只读；`.notConnected` 本就不进入选择器，即使出现也 fail closed。
/// 视图只原样转发此结果，不做二次判断。
public func panelSoundScopeIntegrationActionHost(
    _ scope: PanelSoundScopePresentation
) -> HostID? {
    guard let host = scope.host, scope.scope.surface != nil else { return nil }
    switch scope.status {
    case .awaitingActivation, .legacy, .needsAttention:
        return host
    case .ready, .notConnected:
        return nil
    }
}

/// 行内状态动作的无障碍 label：与选择按钮的「名称 + 状态摘要」明确区分。
public func panelSoundScopeIntegrationActionLabel(
    name: String,
    language: ClaudioAppLanguage
) -> String {
    ClaudioL10n(language: language).format(.panelSoundScopeIntegrationAction, name)
}

/// A missing Workspace keeps its typed identity so a refreshed panel cannot silently turn the
/// next sound edit into a Default Group write. Unknown legacy values still display Global.
/// 呈现层薄包装：解析核心在 `SoundScopeSelection.swift` 的 ID 版（C1 单一事实）。
public func resolvedPanelSoundScopeSelection(
    storedValue: String?,
    scopes: [PanelSoundScopePresentation]
) -> PanelSoundScopeID {
    resolvedPanelSoundScopeSelection(
        storedValue: storedValue, availableScopes: scopes.map(\.scope))
}

/// The retained selection stays visibly unavailable until the user picks a current scope.
public func panelSoundScopeSelectionPresentation(
    storedValue: String?,
    scopes: [PanelSoundScopePresentation],
    language: ClaudioAppLanguage
) -> PanelSoundScopePresentation {
    panelSoundScopeSelectionPresentation(
        selection: resolvedPanelSoundScopeSelection(storedValue: storedValue, scopes: scopes),
        scopes: scopes,
        language: language)
}

/// typed 选择版：`SoundScopeSelection` 投影（C1 单一事实）直接给出 selection，无需再解析
/// 持久化字节。缺失工作区保留 typed identity 并呈现为不可用；其余未命中回落到 Global 行。
public func panelSoundScopeSelectionPresentation(
    selection: PanelSoundScopeID,
    scopes: [PanelSoundScopePresentation],
    language: ClaudioAppLanguage
) -> PanelSoundScopePresentation {
    if let current = scopes.first(where: { $0.scope == selection }) { return current }
    if case .workspace = selection {
        let l10n = ClaudioL10n(language: language)
        let name = l10n.text(.workspaceLabel)
        let reason = l10n.text(.workspaceUnavailable)
        return PanelSoundScopePresentation(
            scope: selection, host: nil, name: name,
            supportedCount: 0, totalCount: Event.allCases.count,
            status: .needsAttention, coverageText: "", stateText: reason,
            summaryText: reason, hasSparseOverride: false,
            accessibilityLabel: name + (language == .english ? ", " : "，") + reason)
    }
    return scopes[0]
}

/// 延迟执行的选择动作在写入前必须针对最新可用集合重验目标。失效目标返回 `nil`，调用方据此
/// 保留已经完成的回退，而不是把陈旧 Surface 再写回持久化选择与声音投影。
public func validatedPanelSoundScopeSelection(
    _ requestedSelection: PanelSoundScopeID,
    availableScopes: [PanelSoundScopeID]
) -> PanelSoundScopeID? {
    availableScopes.contains(requestedSelection) ? requestedSelection : nil
}

/// Produces the typed Events route used by the global shortcut. Known Surface identities remain
/// intact even when currently unavailable. Unknown persisted identities cannot be represented as a
/// typed scope, so they retain the exact raw value beside a non-writable Global presentation.
/// 呈现层薄包装：路由核心在 `SoundScopeSelection.swift` 的 ID 版（C1 单一事实）。
public func globalShortcutEventSettingsRoute(
    storedValue: String?,
    scopes: [PanelSoundScopePresentation]
) -> EventSettingsWindowRoute {
    globalShortcutEventSettingsRoute(
        storedValue: storedValue, availableScopes: scopes.map(\.scope))
}

/// Resolves a retained Events & Sounds route only when its exact typed scope is currently visible.
/// A missing Workspace retains its identity; an unknown raw shortcut value
/// never turns its Global presentation into a writable fallback.
public func resolvedEventSettingsScope(
    route: EventSettingsWindowRoute,
    scopes: [PanelSoundScopePresentation]
) -> PanelSoundScopeID? {
    if let unavailableValue = route.unavailableRequestedScopeStoredValue,
        unavailableValue != route.scope.storedValue
    {
        return nil
    }
    guard scopes.contains(where: { $0.scope == route.scope }) else { return nil }
    return route.scope
}

/// A first launch displays the Default Group; only a manual choice persists a different scope.
/// Refreshes retain a missing Workspace's stored identity until the user selects another scope.
public func panelSoundScopeStoredValueToPersist(
    storedValue: String?,
    resolvedSelection: PanelSoundScopeID
) -> String? {
    let isPendingFirstSelection = storedValue == nil || storedValue == "unselected"
    if isPendingFirstSelection, resolvedSelection == .global { return nil }
    return resolvedSelection.storedValue
}

/// 事件行两个写/试听动作的唯一可用性投影。视图与焦点顺序必须消费同一实例。
public struct PanelEventControlAvailability: Sendable, Equatable {
    public let previewEnabled: Bool
    public let muteEnabled: Bool
    public let previewAvailability: EventPreviewAvailability

    public init(
        previewEnabled: Bool,
        muteEnabled: Bool,
        previewAvailability: EventPreviewAvailability
    ) {
        self.previewEnabled = previewEnabled
        self.muteEnabled = muteEnabled
        self.previewAvailability = previewAvailability
    }
}

/// 菜单栏单一来源的五行事件呈现。Global 行使用 claudi0 事件 ID；Surface 行使用能力
/// catalog 的原生事件名、接口支持和实现事实。
public struct PanelEventPresentation: Sendable, Equatable, Identifiable {
    public var id: Event { event }
    public let event: Event
    public let title: String
    public let nativeEventText: String
    public let capabilityText: String
    public let soundFileText: String
    public let selectedSystemSound: Bool
    public let enabled: Bool
    public let support: HostCapabilitySupport?
    public let implementation: HostCapabilityImplementation?
    public let controls: PanelEventControlAvailability
    public let accessibilityLabel: String
}

public func panelEventPresentations(
    rows: [EventRow],
    scope: PanelSoundScopeID,
    masterVolume: Double,
    language: ClaudioAppLanguage,
    configWritesAllowed: Bool = true,
    safetyFailures: [Event: EventPreviewSafetyFailure] = [:]
) -> [PanelEventPresentation] {
    let l10n = ClaudioL10n(language: language)
    let separator = language == .english ? ", " : "，"
    let rowsByEvent = Dictionary(uniqueKeysWithValues: rows.map { ($0.event, $0) })
    return Event.allCases.map { event in
        let row = rowsByEvent[event] ?? EventRow(event: event, coverage: .unmapped, enabled: false)
        let selectedSystemSound = row.soundSource?.systemSoundName
        let effectiveCoverage = row.coverage
        let binding: HostCapabilityBinding?
        switch scope {
        case .global, .workspace:
            binding = nil
        case .surface(let surface):
            binding = HostID.productVisibleCases
                .first(where: { $0.surfaceID == surface })
                .flatMap { HostCapabilityCatalog.binding(host: $0, event: event) }
        }
        let implemented: Bool
        switch scope {
        case .global, .workspace:
            implemented = true
        case .surface:
            implemented =
                binding.map {
                    $0.implementation != .notImplemented && $0.support != .unsupported
                } ?? false
        }
        let previewAvailability = eventPreviewAvailability(
            coverage: effectiveCoverage,
            masterVolume: masterVolume,
            safetyFailureReason: (selectedSystemSound == nil ? safetyFailures[event] : nil).map {
                localizedEventPreviewSafetyFailure($0, language: language)
            })
        let controls = PanelEventControlAvailability(
            previewEnabled: implemented && previewAvailability.isAvailable,
            muteEnabled: implemented && configWritesAllowed,
            previewAvailability: previewAvailability)
        let nativeEventText: String
        if let binding {
            nativeEventText = binding.nativeEvent ?? l10n.text(.panelNoNativeEvent)
        } else {
            nativeEventText = event.cliName
        }
        let capabilityText: String
        if let binding {
            capabilityText = panelCapabilityText(binding, language: language)
        } else {
            capabilityText = l10n.text(
                scope.workspaceID == nil ? .panelGlobalDefaults : .workspaceLabel)
        }
        let soundFileText: String
        switch effectiveCoverage {
        case .present(let fileName):
            if selectedSystemSound != nil {
                soundFileText = l10n.format(.workspaceSystemSoundFile, fileName)
            } else if let displayName = row.audioDisplayName {
                soundFileText = "\(fileName) · \(displayName)"
            } else {
                soundFileText = fileName
            }
        case .unmapped: soundFileText = l10n.text(.panelNoSoundAssigned)
        case .broken(let fileName):
            if selectedSystemSound != nil {
                soundFileText = l10n.format(.workspaceSystemSoundMissing, fileName)
                break
            }
            let missingSoundText = l10n.format(.panelMissingSound, fileName)
            if let displayName = row.audioDisplayName {
                soundFileText = "\(missingSoundText) · \(displayName)"
            } else {
                soundFileText = missingSoundText
            }
        }
        let enabled = row.enabled
        let enabledText =
            enabled
            ? l10n.text(.eventEnabled)
            : l10n.text(.eventMuted)
        let clauses = [
            localizedEventName(event, language: language), nativeEventText, capabilityText,
            soundFileText, enabledText,
        ]
        return PanelEventPresentation(
            event: event,
            title: localizedEventName(event, language: language),
            nativeEventText: nativeEventText,
            capabilityText: capabilityText,
            soundFileText: soundFileText,
            selectedSystemSound: selectedSystemSound != nil,
            enabled: enabled,
            support: binding?.support,
            implementation: binding?.implementation,
            controls: controls,
            accessibilityLabel: clauses.joined(separator: separator))
    }
}

private func panelCapabilityText(
    _ binding: HostCapabilityBinding,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    if binding.implementation == .notImplemented {
        switch binding.support {
        case .supported:
            return l10n.text(.panelCapabilitySupportedNotImplemented)
        case .partial:
            return l10n.text(.panelCapabilityPartialNotImplemented)
        case .unsupported:
            return l10n.text(.panelCapabilityUnsupportedNotImplemented)
        }
    }
    switch binding.support {
    case .supported: return l10n.text(.panelCapabilitySupported)
    case .partial: return l10n.text(.panelCapabilityPartial)
    case .unsupported: return l10n.text(.panelCapabilityUnsupported)
    }
}
