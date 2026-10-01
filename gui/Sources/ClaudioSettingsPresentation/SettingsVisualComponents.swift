import ClaudioGUIComponents
import SwiftUI

#if DEBUG
private struct SettingsReduceTransparencyOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Controlled visual-environment seam. Production leaves this nil and follows AppKit;
    /// deterministic render and snapshot hosts may inject the same platform fact explicitly.
    package var settingsReduceTransparencyOverride: Bool? {
        get { self[SettingsReduceTransparencyOverrideKey.self] }
        set { self[SettingsReduceTransparencyOverrideKey.self] = newValue }
    }
}
#endif

/// One shared native Settings surface. It keeps the approved 13 pt group radius and strengthens
/// its boundary under Increase Contrast without replacing the system control background.
struct SettingsSectionCard: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    #if DEBUG
    @Environment(\.settingsReduceTransparencyOverride) private var reduceTransparencyOverride
    #endif

    private let content: AnyView
    private let padding: CGFloat

    init<Content: View>(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = AnyView(content())
    }

    var body: some View {
        content
            .modifier(
                SettingsSectionSurface(
                    padding: padding, reduceTransparencyOverride: effectiveReduceTransparency)
            )
    }

    private var effectiveReduceTransparency: Bool {
        #if DEBUG
        reduceTransparencyOverride ?? reduceTransparency
        #else
        reduceTransparency
        #endif
    }
}

extension View {
    func settingsSectionSurface(padding: CGFloat = 16) -> some View {
        SettingsSectionCard(padding: padding) { self }
    }
}
