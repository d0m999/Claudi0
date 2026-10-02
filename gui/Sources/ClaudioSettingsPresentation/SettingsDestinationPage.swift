import ClaudioGUIComponents
import ClaudioGUICore
import SoundPacksWindow
import SwiftUI

/// One concrete implementation of the shared page chrome. Type erasure stays at this internal
/// visual boundary; navigation and child owners retain their existing types and identities.
struct SettingsDestinationPage: View {
    private let destination: SettingsDestination
    private let header: SettingsPageHeader
    private let content: AnyView

    init<Header: View, Content: View>(
        destination: SettingsDestination,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.destination = destination
        self.header = SettingsPageHeader(content: header)
        self.content = AnyView(content())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: true) {
                content
                    .soundPacksLayoutProbe("settings.reading.\(destination.rawValue)")
                    .settingsReadingColumn()
            }
            .accessibilityIdentifier("settings.scroll.\(destination.rawValue)")
        }
    }
}
