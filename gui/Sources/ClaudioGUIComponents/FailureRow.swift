import ClaudioGUICore
import Foundation
import SwiftUI

/// The panel defaults used by the shared failure surface. Values stay derived from
/// `ClaudioColorHex`, the GUI package's single source of truth for DESIGN.md's palette.
private enum FailureRowColor {
    static func error(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(failureRowHex: ClaudioColorHex.errorDark)
            : Color(failureRowHex: ClaudioColorHex.errorLight)
    }

    static func textSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(failureRowHex: ClaudioColorHex.text2Dark)
            : Color(failureRowHex: ClaudioColorHex.text2Light)
    }
}

extension Color {
    fileprivate init(failureRowHex: String) {
        var value: UInt64 = 0
        Scanner(string: failureRowHex).scanHexInt64(&value)
        self.init(
            red: Double((value & 0xFF0000) >> 16) / 255,
            green: Double((value & 0x00FF00) >> 8) / 255,
            blue: Double(value & 0x0000FF) / 255)
    }
}

/// Shared in-place failure component: a semantic error icon and a neutral sentence.
/// Standard-window callers retain their window-owned VoiceOver announcement channel.
/// Settings select system colors through an internal environment; other callers keep panel defaults.
public struct FailureRow: View {
    public let message: String
    public var disclosure: Disclosure?

    public enum Disclosure {
        case collapsed
        case expanded
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.usesSettingsAppearance) private var usesSettingsAppearance
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    public init(message: String, disclosure: Disclosure? = nil) {
        self.message = message
        self.disclosure = disclosure
    }

    @ViewBuilder
    public var body: some View {
        if usesSettingsAppearance {
            row.accessibilityLabel(Text(message))
                .accessibilityAddTraits(.isStaticText)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11 * typeScale))
                .foregroundColor(
                    usesSettingsAppearance
                        ? SettingsAppearance.error(colorScheme) : FailureRowColor.error(colorScheme)
                )
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 11 * typeScale))
                .foregroundColor(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let disclosure {
                Spacer(minLength: 4)
                Image(systemName: disclosure == .expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9 * typeScale))
                    .foregroundColor(secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var secondaryText: Color {
        usesSettingsAppearance
            ? SettingsAppearance.secondaryText(colorScheme)
            : FailureRowColor.textSecondary(colorScheme)
    }
}
