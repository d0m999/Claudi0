import ClaudioGUIComponents
import SwiftUI

package enum AICueTaskFocus: Hashable { case generate, cancel, results, retrySave }

/// A stable outer shape. Only its content has semantic identity changes.
package struct AICueTaskSurface<Content: View>: View {
    let expanded: Bool
    let stateKey: String
    @ViewBuilder let content: (FocusState<AICueTaskFocus?>.Binding) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedControl: AICueTaskFocus?
    @State private var availableWidth: CGFloat = 572
    @State private var contentHeight: CGFloat = 68

    package init(
        expanded: Bool, stateKey: String,
        @ViewBuilder content: @escaping (FocusState<AICueTaskFocus?>.Binding) -> Content
    ) {
        self.expanded = expanded
        self.stateKey = stateKey
        self.content = content
    }

    package var body: some View {
        ZStack(alignment: .topLeading) {
            content($focusedControl)
                .frame(width: expanded ? max(124, availableWidth - 32) : 124, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { updateContentHeight(proxy.size.height) }
                            .onChange(of: proxy.size.height, perform: updateContentHeight)
                    }
                )
                .padding(expanded ? 16 : 0)
                .id(stateKey)
                .transition(
                    .asymmetric(
                        insertion: .opacity.animation(
                            reduceMotion ? nil : .easeIn(duration: 0.12).delay(0.06)),
                        removal: .opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.06))))
        }
        .frame(
            width: expanded ? availableWidth : 124,
            height: expanded ? max(96, contentHeight + 32) : 34, alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: expanded ? 17 : 7)
                .fill(expanded ? ClaudioTheme.surface(colorScheme) : Color.accentColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: expanded ? 17 : 7)
                .strokeBorder(
                    expanded ? ClaudioTheme.hairline(colorScheme) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: expanded ? 17 : 7))
        .animation(reduceMotion ? nil : AppMotion.spring, value: expanded)
        .animation(reduceMotion ? nil : AppMotion.spring, value: contentHeight)
        .animation(reduceMotion ? nil : AppMotion.spring, value: stateKey)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateAvailableWidth(proxy.size.width) }
                    .onChange(of: proxy.size.width, perform: updateAvailableWidth)
            }
        )
        .onChange(of: stateKey) { key in
            switch key {
            case "generating": focusedControl = .cancel
            case "results": focusedControl = .results
            case "pending": focusedControl = .retrySave
            case "failed", "ready": focusedControl = .generate
            default: focusedControl = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.sounds.ai.task-surface")
    }
    // Observe the current content's geometry directly. Identity transitions can suppress the
    // old preference delivery when a task card is replaced by a substantially taller result.
    private func updateContentHeight(_ height: CGFloat) {
        if height > 0 { contentHeight = height }
    }

    private func updateAvailableWidth(_ width: CGFloat) {
        if width > 0 { availableWidth = width }
    }
}
