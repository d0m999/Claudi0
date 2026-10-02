import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization

/// Navigation owns presentation only; mutations still consume the owner's signed capabilities.
package enum SoundPacksSettingsDetail: Equatable {
    case overview
    case event(packID: String, event: Event)
    case audio(packID: String)
    case service
    case panel

    package var capturedPackID: String? {
        switch self {
        case .event(let packID, _), .audio(let packID): packID
        default: nil
        }
    }

    package func targetIsAvailable(in sounds: SoundsEditorPresentation) -> Bool {
        switch self {
        case .event(let packID, let event):
            return
                ((sounds.selectedPack?.id == packID
                && sounds.selectedPack?.availability == .installed)
                || sounds.draft?.packID == packID)
                && sounds.eventRows.contains { $0.event == event }
        case .audio(let packID):
            return sounds.selectedPack?.id == packID
                && sounds.selectedPack?.availability == .installed
        default: return true
        }
    }

    package func visibleEventRows(in sounds: SoundsEditorPresentation)
        -> [SoundPackEditorEventPresentation]
    {
        guard targetIsAvailable(in: sounds) else { return [] }
        switch self {
        case .overview: return sounds.eventRows
        case .event(_, let event): return sounds.eventRows.filter { $0.event == event }
        default: return []
        }
    }

    package func unavailableFocusTarget(in sounds: SoundsEditorPresentation)
        -> SoundPacksWindowFocusTarget?
    {
        targetIsAvailable(in: sounds) ? nil : .managedScopeFailure
    }

    package func reconciled(
        with presentation: SoundPacksEditorPresentation,
        copyTransition: SoundPacksSettingsDetailCopyTransition?
    ) -> Self {
        guard let copyTransition, copyTransition.detail == self,
            let packID = copyTransition.resultPackID(in: presentation)
        else { return self }
        switch self {
        case .event(_, let event): return .event(packID: packID, event: event)
        case .audio: return .audio(packID: packID)
        default: return self
        }
    }
}

/// Snapshot/focus publications may repeat the same editor request. Only a new request replaces
/// local navigation; an initially pending deep link may still finish resolving once.
package struct SoundPacksSettingsDetailRouteTracker {
    package private(set) var requestRevision: UInt64?
    private var awaitsInitialResolution = false

    package init() {}

    package mutating func detailAfterFocusRequest(
        route: SoundPacksWindowRoute, sounds: SoundsEditorPresentation,
        currentDetail: SoundPacksSettingsDetail
    ) -> SoundPacksSettingsDetail {
        if requestRevision != sounds.requestRevision {
            requestRevision = sounds.requestRevision
            awaitsInitialResolution =
                route.editTarget == nil && sounds.route.editTarget != nil
                && sounds.routeState == .pendingFreshSnapshot
            if let target = route.editTarget {
                return .event(packID: target.packID, event: target.event)
            }
            return .overview
        }
        if awaitsInitialResolution {
            if let target = route.editTarget {
                awaitsInitialResolution = false
                return .event(packID: target.packID, event: target.event)
            }
            if case .staleTarget = sounds.routeState, let target = sounds.route.editTarget {
                awaitsInitialResolution = false
                return .event(packID: target.packID, event: target.event)
            }
        }
        return currentDetail
    }
}

/// One explicitly accepted copy may replace a detail identity with that operation's result.
/// Ordinary inspection and snapshot fallback never supply a transition.
package struct SoundPacksSettingsDetailCopyTransition {
    package let detail: SoundPacksSettingsDetail
    private let operationID: SoundPackEditorOperationID
    private let activityKind: SoundPackEditorActivityKind
    private let previousStatusRevision: Int

    package init?(
        detail: SoundPacksSettingsDetail, actionKind: SoundPackEditorAction.Kind,
        operationID: SoundPackEditorOperationID,
        previousPresentation: SoundPacksEditorPresentation
    ) {
        guard detail.capturedPackID != nil,
            case .sounds(let sounds) = previousPresentation.mode,
            sounds.selectedPack?.id == detail.capturedPackID
        else { return nil }
        switch actionKind {
        case .fork: activityKind = .fork
        case .copy, .copyAndApply: activityKind = .copy
        default: return nil
        }
        self.detail = detail
        self.operationID = operationID
        previousStatusRevision = sounds.windowStatuses.map(\.revision).max() ?? 0
    }

    package func resultPackID(in presentation: SoundPacksEditorPresentation) -> String? {
        guard case .sounds(let sounds) = presentation.mode,
            let activity = presentation.activities.first(where: { $0.operationID == operationID }),
            activity.kind == activityKind, activity.packID == detail.capturedPackID,
            activity.phase != .busy,
            let status = sounds.windowStatuses.first(where: {
                $0.kind == .packFork && $0.severity == .notice
                    && $0.revision > previousStatusRevision
            }), let packID = status.packID, packID != detail.capturedPackID
        else { return nil }
        return packID
    }

    package func isPending(in presentation: SoundPacksEditorPresentation) -> Bool {
        presentation.activities.contains { $0.operationID == operationID && $0.phase == .busy }
    }
}

package func soundPackDeleteExplanationKey(
    _ pack: SoundPackEditorPackPresentation
) -> ClaudioL10nKey {
    if pack.usage.usageIsIncomplete { return .settingsSoundsAICueScopeIncomplete }
    if pack.isReferencedByAnyScope { return .soundPacksPackDeleteActive }
    return pack.deleteAction == nil
        ? .soundPacksPackDeleteConfigUnavailable : .soundPacksPackDeleteHint
}
