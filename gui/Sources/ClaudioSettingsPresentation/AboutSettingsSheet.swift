import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// The session owns presentation identity and navigation blocking; this view owns modal focus.
@MainActor
struct AboutSettingsSheet: View {
    @ObservedObject var session: SettingsPresentationSession
    let stamp: SettingsNavigationStamp
    @FocusState private var focusedTarget: SettingsWindowFocusTarget?

    var body: some View {
        let preferences = session.dependencies.preferences
        let l10n = ClaudioL10n(language: preferences.language)
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n.text(.settingsDestinationAbout)).font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                AboutSettingsView(
                    model: session.dependencies.aboutSettings,
                    preferences: preferences, focusedTarget: $focusedTarget,
                    onAnnouncement: { session.send(.announceDestinationUpdate($0)) })
            }
            HStack {
                Spacer()
                Button(l10n.text(.soundsClose)) { session.send(.dismissAbout(stamp)) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings.about.close")
            }
        }
        .padding(24).frame(width: 620, height: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.about.sheet")
        .task {
            await Task.yield()
            guard !Task.isCancelled, session.aboutPresentation == stamp else { return }
            focusedTarget = .firstAction(.about)
        }
    }
}
