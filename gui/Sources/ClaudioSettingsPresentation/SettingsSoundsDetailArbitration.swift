import ClaudioCore
import ClaudioGUICore
import SoundPacksWindow

/// The typed route destination a Sounds detail renders as. Deep links resolve through this same
/// mapping, so a local disclosure click and a retained route converge on one detail identity.
package func settingsSoundsImpliedDetail(
    _ destination: SoundPacksWindowRoute.Destination
) -> SoundPacksSettingsDetail {
    switch destination {
    case .overview:
        return .overview
    case .editEvent(let packID, let event), .copyAndApply(let packID, let event):
        return .event(packID: packID, event: event)
    case .audio(let packID):
        return .audio(packID: packID)
    case .service:
        return .service
    case .panel:
        return .panel
    }
}

/// Side effects the session performs after an arbitration pass. Draft cancellation stays
/// separate: it fires only when a draft actually exists, never as a blanket reset.
package struct SettingsSoundsDetailEffects: Equatable, Sendable {
    package var detailChanged = false
    /// Parity with the retired view-side leave-detail cleanup: stop native playback, clear the
    /// candidate playback identity, end the composer session and unsign the owner's composer.
    package var stopPreviewAndEndAISession = false
    package var cancelAICueDraft = false

    package init(
        detailChanged: Bool = false,
        stopPreviewAndEndAISession: Bool = false,
        cancelAICueDraft: Bool = false
    ) {
        self.detailChanged = detailChanged
        self.stopPreviewAndEndAISession = stopPreviewAndEndAISession
        self.cancelAICueDraft = cancelAICueDraft
    }

    package var isEmpty: Bool {
        !detailChanged && !stopPreviewAndEndAISession && !cancelAICueDraft
    }
}

/// One explicitly accepted copy may replace a detail identity with that operation's result.
/// Ordinary inspection and snapshot fallback never supply a transition.
package struct SettingsSoundsDetailCopyTransition: Equatable, Sendable {
    package let detail: SoundPacksSettingsDetail
    private let operationID: SoundPackEditorOperationID
    private let activityKind: SoundPackEditorActivityKind
    private let previousStatusRevision: Int

    package init(
        detail: SoundPacksSettingsDetail,
        operationID: SoundPackEditorOperationID,
        activityKind: SoundPackEditorActivityKind,
        previousStatusRevision: Int
    ) {
        self.detail = detail
        self.operationID = operationID
        self.activityKind = activityKind
        self.previousStatusRevision = previousStatusRevision
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

    package func reconciledDetail(
        _ detail: SoundPacksSettingsDetail,
        in presentation: SoundPacksEditorPresentation
    ) -> SoundPacksSettingsDetail {
        guard self.detail == detail, let packID = resultPackID(in: presentation)
        else { return detail }
        switch detail {
        case .event(_, let event): return .event(packID: packID, event: event)
        case .audio: return .audio(packID: packID)
        default: return detail
        }
    }
}

/// Session-owned arbitration for the Sounds destination's visible detail. Owner snapshot
/// publications may repeat the same editor request: only a new request replaces the retained
/// detail, and an initially pending deep link may still finish resolving once. Local open/back
/// intents arrive through `requestDetail` and never rewrite the retained outer route.
package struct SettingsSoundsDetailArbitration {
    package private(set) var detail: SoundPacksSettingsDetail = .overview
    private var requestRevision: UInt64?
    private var awaitsInitialResolution = false
    private var copyTransition: SettingsSoundsDetailCopyTransition?
    private var unavailableDetailIdentity: SoundPacksSettingsDetail?
    private var lastPublication: SoundPacksEditorPresentation?
    /// A copy transition may only start on the publication where its busy activity first
    /// appears — parity with the retired view constructing it at invoke time. A detail opened
    /// while the operation is already busy must never capture that in-flight operation later.
    private var seenBusyOperationIDs: Set<SoundPackEditorOperationID> = []

    package init() {}

    /// Destination unmount parity with the retired view-local state: the next activation
    /// re-derives the detail from its own route request.
    package mutating func reset() {
        self = SettingsSoundsDetailArbitration()
    }

    /// A local open/back intent from the rendered destination. The intent is already validated
    /// by the session against the live destination; anything stale renders as the in-page
    /// unavailable reason instead of navigating away.
    @discardableResult
    package mutating func requestDetail(
        _ destination: SoundPacksWindowRoute.Destination,
        publication: SoundPacksEditorPresentation
    ) -> SettingsSoundsDetailEffects {
        let target = settingsSoundsImpliedDetail(destination)
        guard target != detail else { return SettingsSoundsDetailEffects() }
        var effects = SettingsSoundsDetailEffects(
            detailChanged: true, stopPreviewAndEndAISession: true)
        if case .sounds(let sounds) = publication.mode, sounds.draft != nil {
            effects.cancelAICueDraft = true
        }
        copyTransition = nil
        unavailableDetailIdentity = nil
        detail = target
        return effects
    }

    @discardableResult
    package mutating func consume(
        _ publication: SoundPacksEditorPresentation
    ) -> SettingsSoundsDetailEffects {
        defer { lastPublication = publication }
        guard case .sounds(let sounds) = publication.mode else {
            return SettingsSoundsDetailEffects()
        }
        var effects = SettingsSoundsDetailEffects()
        var next = detail

        let reduced: SoundPacksSettingsDetail?
        if requestRevision != sounds.requestRevision {
            requestRevision = sounds.requestRevision
            awaitsInitialResolution =
                sounds.routeState == .pendingFreshSnapshot
                && sounds.route.destinationPackID != nil
            copyTransition = nil
            switch sounds.routeState {
            case .resolved(let route):
                reduced = settingsSoundsImpliedDetail(route.destination)
            case .pendingFreshSnapshot, .staleTarget:
                reduced = .overview
            }
        } else if awaitsInitialResolution {
            let resolvedRoute: SoundPacksWindowRoute?
            switch sounds.routeState {
            case .resolved(let route):
                resolvedRoute = route.destinationPackID != nil ? route : nil
            case .staleTarget:
                // A deep link that proves stale only after a fresh snapshot still lands on its
                // captured identity; the detail renders the in-page unavailable reason.
                resolvedRoute =
                    sounds.route.destinationPackID != nil ? sounds.route : nil
            case .pendingFreshSnapshot:
                resolvedRoute = nil
            }
            if let resolvedRoute {
                awaitsInitialResolution = false
                reduced = settingsSoundsImpliedDetail(resolvedRoute.destination)
            } else {
                reduced = nil
            }
        } else {
            reduced = nil
        }
        if let reduced, reduced != next {
            // Only leaving a non-overview detail cleans it up; initial resolution may already
            // have a composer.
            if next != .overview { effects.stopPreviewAndEndAISession = true }
            if sounds.draft != nil { effects.cancelAICueDraft = true }
            copyTransition = nil
            unavailableDetailIdentity = nil
            next = reduced
        }

        // A newly busy fork/copy against the captured pack is the one accepted operation that
        // may later retarget this detail to its result identity.
        if copyTransition == nil, let capturedPackID = next.capturedPackID,
            let previous = lastPublication, case .sounds(let previousSounds) = previous.mode,
            previousSounds.selectedPack?.id == capturedPackID,
            let activity = publication.activities.first(where: {
                $0.phase == .busy && ($0.kind == .fork || $0.kind == .copy)
                    && $0.packID == capturedPackID
                    && !seenBusyOperationIDs.contains($0.operationID)
            })
        {
            copyTransition = SettingsSoundsDetailCopyTransition(
                detail: next,
                operationID: activity.operationID,
                activityKind: activity.kind,
                previousStatusRevision: previousSounds.windowStatuses.map(\.revision).max() ?? 0)
        }
        for activity in publication.activities where activity.phase == .busy {
            seenBusyOperationIDs.insert(activity.operationID)
        }

        if let transition = copyTransition {
            next = transition.reconciledDetail(next, in: publication)
            if next != transition.detail || !transition.isPending(in: publication) {
                copyTransition = nil
            }
        }

        let previousDraftID: String? = {
            guard case .sounds(let previousSounds) = lastPublication?.mode else { return nil }
            return previousSounds.draft?.packID
        }()
        if let draftID = sounds.draft?.packID, draftID != previousDraftID {
            next = .event(packID: draftID, event: .taskStart)
        }

        if next.unavailableFocusTarget(in: sounds) != nil {
            if unavailableDetailIdentity != next {
                unavailableDetailIdentity = next
                effects.stopPreviewAndEndAISession = true
            }
        } else {
            unavailableDetailIdentity = nil
        }

        if next != detail {
            detail = next
            effects.detailChanged = true
        }
        return effects
    }
}
