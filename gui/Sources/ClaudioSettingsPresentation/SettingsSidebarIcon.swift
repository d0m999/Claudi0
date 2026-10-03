import ClaudioGUICore
import SwiftUI

/// Decorative destination artwork; the enclosing navigation row owns its accessible name.
@MainActor
package struct SettingsSidebarIcon: View {
    let destination: SettingsDestination
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    package init(destination: SettingsDestination) {
        self.destination = destination
    }

    package var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4.5, style: .continuous)
        let increasedContrast = contrast == .increased
        ZStack {
            shape.fill(
                LinearGradient(
                    colors: [increasedContrast ? palette.bottom : palette.top, palette.bottom],
                    startPoint: .top, endPoint: .bottom))
            glyph
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
        }
        .frame(width: 20, height: 20)
        .overlay {
            if increasedContrast {
                shape.strokeBorder(colorScheme == .dark ? .white : .black, lineWidth: 1)
            } else {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.40), .white.opacity(0.08)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5)
            }
        }
        .shadow(
            color: .black.opacity(increasedContrast ? 0 : 0.24),
            radius: 0.65, x: 0, y: 0.65
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch destination {
        case .eventsAndSounds:
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
        case .sounds:
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .medium))
        case .integrations:
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 13, weight: .regular))
        case .notifications:
            Image(systemName: "bell.fill")
                .font(.system(size: 13, weight: .medium))
        case .general:
            Image(systemName: "gear")
                .font(.system(size: 16, weight: .regular))
        case .shortcuts:
            ZStack {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(.white.opacity(contrast == .increased ? 0 : 0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .strokeBorder(
                                .white.opacity(contrast == .increased ? 0.9 : 0.50),
                                lineWidth: contrast == .increased ? 0.8 : 0.5)
                    }
                    .frame(width: 14, height: 14)
                Image(systemName: "command")
                    .font(.system(size: 10.5, weight: .semibold))
            }
        case .usage:
            HStack(alignment: .bottom, spacing: 1.8) {
                RoundedRectangle(cornerRadius: 0.7).frame(width: 2.8, height: 6)
                RoundedRectangle(cornerRadius: 0.7).frame(width: 2.8, height: 10)
                RoundedRectangle(cornerRadius: 0.7).frame(width: 2.8, height: 13)
            }
        case .about:
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14, weight: .regular))
        }
    }

    private var palette: (top: Color, bottom: Color) {
        switch destination {
        case .eventsAndSounds: (color(0xFFAC24), color(0xF18B08))
        case .sounds: (color(0xB368F3), color(0x963EE3))
        case .integrations: (color(0x2699FF), color(0x087EE9))
        case .notifications: (color(0xFF5E6B), color(0xEC354B))
        case .general: (color(0xACADB4), color(0x83848C))
        case .shortcuts: (color(0x9699A3), color(0x6E727E))
        case .usage: (color(0x3CD968), color(0x23B84E))
        case .about: (color(0x2FA9FF), color(0x0B85EE))
        }
    }

    private func color(_ rgb: UInt32) -> Color {
        Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }
}
