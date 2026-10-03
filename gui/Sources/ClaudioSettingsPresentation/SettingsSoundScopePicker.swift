import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SoundPacksWindow
import SwiftUI

@MainActor
struct SettingsSoundScopePicker: View {
    @ObservedObject var session: SettingsPresentationSession
    @ObservedObject private var model: PanelConfigController

    init(session: SettingsPresentationSession) {
        self.session = session
        _model = ObservedObject(wrappedValue: session.dependencies.eventSettingsModel)
    }

    private var scope: PanelSoundScopeID {
        if case .sounds(let route) = session.state.routeResolution.route { return route.scope }
        return .global
    }

    var body: some View {
        let l10n = ClaudioL10n(language: session.state.language)
        let scopes = panelSoundScopePresentations(
            sourceRows: [], config: model.configState.resolvedConfig,
            language: session.state.language)
        SettingsControlRow(
            title: l10n.text(.settingsNativeManagementScope),
            subtitle: l10n.text(.settingsNativeViewDoesNotApply)
        ) {
            Picker(
                l10n.text(.settingsNativeManagementScope),
                selection: Binding(
                    get: { scope },
                    set: { newScope in
                        guard scopes.contains(where: { $0.scope == newScope }) else { return }
                        let target = newScope.workspaceID.flatMap { id in
                            model.workspaceRules.first(where: { $0.id == id })
                        }.map(WorkspaceSoundWriteTarget.init(rule:))
                        _ = session.send(
                            .route(.sounds(.overview(scope: newScope, workspaceTarget: target))))
                    })
            ) {
                if !scopes.contains(where: { $0.scope == scope }) {
                    Text(l10n.text(.workspaceUnavailable)).tag(scope)
                }
                ForEach(scopes) { item in Text(item.name).tag(item.scope) }
            }
            .accessibilityLabel(l10n.text(.settingsNativeManagementScope))
            .accessibilityIdentifier("settings.sounds.management-scope")
            .soundPacksLayoutProbe("settings.sounds.management-scope.control")
        }
        .soundPacksLayoutProbe("settings.sounds.management-scope.row")
        .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
    }
}
