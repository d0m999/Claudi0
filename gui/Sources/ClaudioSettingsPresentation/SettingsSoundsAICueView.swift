import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SoundPacksWindow
import SwiftUI

package enum AICuePackDraftNameEdit: Equatable {
    case noDraft
    case unchanged
    case pending(AICuePackName)
    case invalid

    package var needsSave: Bool {
        switch self {
        case .pending, .invalid: true
        case .noDraft, .unchanged: false
        }
    }

    package var savableName: AICuePackName? {
        guard case .pending(let name) = self else { return nil }
        return name
    }
}

package func aiCuePackDraftNameEdit(draftName: String?, input: String) -> AICuePackDraftNameEdit {
    guard let draftName else { return .noDraft }
    guard let name = try? AICuePackName(input) else { return .invalid }
    if name.value == draftName { return .unchanged }
    return .pending(name)
}

/// Compatibility composition seam; the reachable page is the pack-centered native library.
@MainActor
struct SettingsSoundsAICueView: View {
    @ObservedObject var viewModel: AICueGenerationViewModel
    @ObservedObject var editorOwner: SoundPacksEditorOwner
    @ObservedObject var languageStore: ClaudioPreferences
    let nativeEffects: SoundPacksEditorNativeEffectsDispatcher
    let route: SoundPacksWindowRoute
    let routeRequestRevision: UInt64
    let detail: SoundPacksSettingsDetail
    let onDetailIntent: @MainActor (SoundPacksWindowRoute.Destination) -> Void
    var onInspectPack: (@MainActor (String) -> Void)? = nil
    var pageHeader: AnyView = AnyView(EmptyView())
    var scopePicker: AnyView = AnyView(EmptyView())
    var returnToScope: (@MainActor () -> Void)? = nil
    let onAnnouncement: @MainActor (String) -> Void
    @Binding var credentialSheetIsPresented: Bool
    @Binding var playingCandidateID: UUID?

    var body: some View {
        SettingsSoundsLibraryView(
            model: viewModel, owner: editorOwner, preferences: languageStore,
            effects: nativeEffects, coordinator: viewModel.coordinator,
            history: viewModel.coordinator.history,
            drafts: editorOwner.draftStore, route: route, requestRevision: routeRequestRevision,
            navigate: onDetailIntent, modalIsPresented: $credentialSheetIsPresented)
    }
}
