import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SoundPacksWindow
import SwiftUI

@MainActor
struct SettingsSoundsDestinationView<Header: View, ScopePicker: View>: View {
    let aiCueViewModel: AICueGenerationViewModel
    let editorOwner: SoundPacksEditorOwner
    let route: SoundPacksWindowRoute
    let routeRequestRevision: UInt64
    let detail: SoundPacksSettingsDetail
    let onDetailIntent: @MainActor (SoundPacksWindowRoute.Destination) -> Void
    let languageStore: ClaudioPreferences
    let nativeEffects: SoundPacksEditorNativeEffectsDispatcher
    let pageHeader: Header
    let scopePicker: ScopePicker
    let returnToScope: (@MainActor () -> Void)?
    let onAnnouncement: @MainActor (String) -> Void
    @Binding var credentialSheetIsPresented: Bool
    @Binding var playingCandidateID: UUID?

    var body: some View {
        SettingsSoundsAICueView(
            viewModel: aiCueViewModel,
            editorOwner: editorOwner,
            languageStore: languageStore,
            nativeEffects: nativeEffects,
            route: route,
            routeRequestRevision: routeRequestRevision,
            detail: detail,
            onDetailIntent: onDetailIntent,
            pageHeader: AnyView(pageHeader),
            scopePicker: AnyView(scopePicker),
            returnToScope: returnToScope,
            onAnnouncement: onAnnouncement,
            credentialSheetIsPresented: $credentialSheetIsPresented,
            playingCandidateID: $playingCandidateID
        )
        .settingsMountIdentity(SettingsPresentationAccessibilityID.destination(.sounds))
    }
}
