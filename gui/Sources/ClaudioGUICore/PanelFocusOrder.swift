import ClaudioCore
import Foundation

/// 面板内稳定可聚焦控件身份。来源卡、包卡和“管理声音包”不属于
/// 生产面板的焦点空间；兼容身份只供可复用声音包组件/State Gallery 编译。
public enum PanelFocusTarget: Sendable, Hashable {

    case headerSettings
    case recentNotices
    case soundScope
    case activityRange
    case activityMetric(Event)
    case libraryRefreshRetry
    case eventPreview(Event)
    case eventMute(Event)
    case masterVolume
    case soundPackPicker
    case workspaceDetails
    case openSoundSettings
    case resetSurface
    case configReveal
    case writeFailureConfigReveal
    case writeFailureRecoveryFile(path: String)
    case bootstrapReportRetry(id: String)
    case bootstrapReportDiagnostics(id: String)
    case bootstrapReportReveal(id: String)
    case bootstrapReportManageSounds(id: String)
    case bootstrapReportAcknowledge(id: String)
    case quitApplication

    // 非生产面板兼容身份。`PanelView` 与 `panelFocusOrder` 均不会生成它们。
    case hostSource(HostID)
    case packCard(id: String)
    case manageSounds
}

/// 作用域浮层存在期间的临时焦点空间。收起后仍只向生产面板暴露一个 `.soundScope`
/// 焦点目标，避免把当前可见来源数固化进主面板焦点模型。行内状态动作（2026-09-10
/// 起替换菜单底部 footer）只进入 Tab 焦点序，方向键顺序仍只遍历作用域选项。
public enum PanelSoundScopePickerFocusTarget: Sendable, Equatable, Hashable {
    case scope(PanelSoundScopeID)
    case integrationAction(PanelSoundScopeID)
}

public func panelSoundScopePickerFocusOrder(
    scopes: [PanelSoundScopeID]
) -> [PanelSoundScopePickerFocusTarget] {
    scopes.map(PanelSoundScopePickerFocusTarget.scope)
}

/// The production panel's one live focus space. The retired onboarding/operational shapes had
/// no production caller: `PanelView` only ever derives `.activityOperational`.
public enum PanelFocusScope: Sendable, Equatable {
    case activityOperational(
        events: [PanelEventPresentation],
        hasActivityOverview: Bool,
        hasMasterVolume: Bool,
        hasConfigFailureNotice: Bool = false,
        hasRefreshFailedNotice: Bool = false,
        writeFailureRecoveryPaths: [String] = [],
        hasWriteFailureConfigRecovery: Bool = false,
        hasSoundPackPicker: Bool = false,
        hasWorkspaceDetails: Bool = false)
}

/// 生产顺序与视觉顺序相同：作用域 → 启动/配置恢复 → 每行可用试听/静音 → 播放设置 →
/// 条件 reset → 固定退出 footer。禁用动作不制造幽灵 Tab stop。
public func panelFocusOrder(_ scope: PanelFocusScope) -> [PanelFocusTarget] {
    switch scope {
    case .activityOperational(
        let events,
        let hasActivityOverview,
        let hasMasterVolume,
        let hasConfigFailureNotice,
        let hasRefreshFailedNotice,
        let writeFailureRecoveryPaths,
        let hasWriteFailureConfigRecovery,
        let hasSoundPackPicker,
        _):
        var order: [PanelFocusTarget] = [.headerSettings, .recentNotices, .soundScope]
        if hasRefreshFailedNotice { order.append(.libraryRefreshRetry) }
        if hasConfigFailureNotice { order.append(.configReveal) }
        for event in events {
            if event.controls.previewEnabled { order.append(.eventPreview(event.event)) }
            if event.controls.muteEnabled { order.append(.eventMute(event.event)) }
        }
        if hasSoundPackPicker { order.append(.soundPackPicker) }
        if hasMasterVolume { order.append(.masterVolume) }
        order.append(
            contentsOf: writeFailureRecoveryPaths.map { .writeFailureRecoveryFile(path: $0) })
        if hasWriteFailureConfigRecovery { order.append(.writeFailureConfigReveal) }
        order.append(.quitApplication)
        return order
    }
}

/// 面板打开时落在当前真实可操作顺序的第一项。例外：近期提示入口按 spec 在 Tab 序中排在
/// Sound Scope 之前，但打开焦点必须继续落在声音作用域——面板的主任务是对声音作用域的直接
/// 操作，提示入口只做阅读。Settings 关闭归还的显式目标（`requestedTarget`）仍然渲染时优先；
/// 已被内容变化移除的目标不得复活。
public func panelFirstFocusTarget(
    _ scope: PanelFocusScope,
    requestedTarget: PanelFocusTarget? = nil
) -> PanelFocusTarget? {
    let order = panelFocusOrder(scope)
    if let requestedTarget, order.contains(requestedTarget) {
        return requestedTarget
    }
    return order.first(where: { $0 == .soundScope }) ?? order.first
}
