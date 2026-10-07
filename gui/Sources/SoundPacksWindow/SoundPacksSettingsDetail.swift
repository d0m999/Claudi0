import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization

/// Navigation owns presentation only; mutations still consume the owner's signed capabilities.
/// The session-side arbitration owns how this value changes; the view only renders it.
package enum SoundPacksSettingsDetail: Equatable, Sendable {
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

    /// The typed route destination expressing this detail. Local open/back intents carry it to
    /// the session; the outer route itself is never rewritten by local detail navigation.
    package var routeDestination: SoundPacksWindowRoute.Destination {
        switch self {
        case .overview: .overview
        case .event(let packID, let event): .editEvent(packID: packID, event: event)
        case .audio(let packID): .audio(packID: packID)
        case .service: .service
        case .panel: .panel
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
}

package func soundPackDeleteExplanationKey(
    _ pack: SoundPackEditorPackPresentation
) -> ClaudioL10nKey {
    if pack.isBuiltinReadOnly { return .soundPacksPackDeleteBuiltin }
    if pack.usage.usageIsIncomplete { return .settingsSoundsAICueScopeIncomplete }
    if pack.isReferencedByAnyScope { return .soundPacksPackDeleteActive }
    return pack.deleteAction == nil
        ? .soundPacksPackDeleteConfigUnavailable : .soundPacksPackDeleteHint
}
