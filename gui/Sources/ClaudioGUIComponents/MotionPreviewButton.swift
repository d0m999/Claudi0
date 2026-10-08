import AppKit
import SwiftUI

/// A real Button; presentation receives playback facts and never starts a timer of its own.
public struct MotionPreviewButton: View {
    public let isPlaying: Bool
    public let isEnabled: Bool
    public let playLabel: String
    public let stopLabel: String
    public var idleTitle: String?
    public var reservesSpace: Bool
    public let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public init(
        isPlaying: Bool, isEnabled: Bool = true, playLabel: String, stopLabel: String,
        idleTitle: String? = nil, reservesSpace: Bool = true, action: @escaping () -> Void
    ) {
        self.isPlaying = isPlaying
        self.isEnabled = isEnabled
        self.playLabel = playLabel
        self.stopLabel = stopLabel
        self.idleTitle = idleTitle
        self.reservesSpace = reservesSpace
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                PreviewMorphGlyph(progress: isPlaying ? 1 : 0)
                    .frame(width: 17, height: 17).accessibilityHidden(true)
                if idleTitle != nil || isPlaying {
                    Text(isPlaying ? stopLabel : (idleTitle ?? ""))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .id(isPlaying)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.animation(
                                    reduceMotion ? nil : .easeIn(duration: 0.12).delay(0.06)),
                                removal: .opacity.animation(
                                    reduceMotion ? nil : .easeOut(duration: 0.06))))
                }
            }
            .frame(width: idleTitle == nil ? (isPlaying ? capsuleWidth : 28) : nil, height: 28)
            .padding(.horizontal, idleTitle == nil ? 0 : 10)
            .foregroundColor(
                isPlaying ? ClaudioTheme.clay(colorScheme) : ClaudioTheme.secondaryText(colorScheme)
            )
            .background(
                RoundedRectangle(cornerRadius: isPlaying ? 14 : 6)
                    .fill(isPlaying ? ClaudioTheme.claySoft(colorScheme) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: isPlaying ? 14 : 6))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled && !isPlaying)
        .accessibilityLabel(isPlaying ? stopLabel : playLabel)
        .animation(reduceMotion ? nil : AppMotion.spring, value: isPlaying)
        .frame(width: reservesSpace && idleTitle == nil ? capsuleWidth : nil, alignment: .trailing)
    }

    // Reserve the localized stop title before playback, so English stays readable without
    // moving neighboring mute/edit controls when the capsule expands.
    private var capsuleWidth: CGFloat {
        let titleWidth = (stopLabel as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width
        return max(76, ceil(titleWidth) + 22)
    }
}
