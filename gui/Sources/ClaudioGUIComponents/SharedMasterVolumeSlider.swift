import AppKit
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// Shared native slider/commit lifecycle for every presentation of the one global master-volume
/// axis. Callers retain their own labels and focus identities; this control alone owns the
/// ``VolumeDragSession`` so drag coalescing, rollback, external rebase, close flush, and
/// termination flush cannot drift between the panel and unified Settings.
@MainActor
package struct SharedMasterVolumeSlider: View {
    let diskVolume: Double
    let isEnabled: Bool
    let language: ClaudioAppLanguage
    let accessibilityIdentifier: String
    let percentageWidth: CGFloat
    let flushRevision: Int?
    let flushesOnDisappear: Bool
    let usesSettingsAppearance: Bool
    let onCommit: (Double) -> Double?

    @State private var session: VolumeDragSession
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    package init(
        diskVolume: Double,
        isEnabled: Bool,
        language: ClaudioAppLanguage,
        accessibilityIdentifier: String,
        percentageWidth: CGFloat = 42,
        flushRevision: Int? = nil,
        flushesOnDisappear: Bool = false,
        usesSettingsAppearance: Bool = false,
        onCommit: @escaping (Double) -> Double?
    ) {
        self.diskVolume = diskVolume
        self.isEnabled = isEnabled
        self.language = language
        self.accessibilityIdentifier = accessibilityIdentifier
        self.percentageWidth = percentageWidth
        self.flushRevision = flushRevision
        self.flushesOnDisappear = flushesOnDisappear
        self.usesSettingsAppearance = usesSettingsAppearance
        self.onCommit = onCommit
        _session = State(initialValue: VolumeDragSession(baseline: diskVolume))
    }

    package var body: some View {
        let value = Binding(
            get: { session.draft },
            set: { value in
                if session.isDragging {
                    session.drag(to: value)
                } else {
                    commit(session.adjust(to: value))
                }
            })
        let editingChanged: (Bool) -> Void = { editing in
            if editing {
                session.begin()
            } else {
                commit(session.end())
            }
        }
        return HStack(spacing: 7) {
            Slider(value: value, in: 0...1, onEditingChanged: editingChanged)
                #if DEBUG
            .onAppear {
                SharedVolumeMountRecorder.register(
                    identifier: accessibilityIdentifier, value: value,
                    editingChanged: editingChanged)
            }
            .onDisappear {
                SharedVolumeMountRecorder.remove(identifier: accessibilityIdentifier)
            }
                #endif
            Text("\(Int((session.draft * 100).rounded()))%")
                .font(.system(size: 10.5 * typeScale, design: .monospaced))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .frame(width: percentageWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .tint(
            usesSettingsAppearance
                ? SettingsAppearance.accent(colorScheme) : ClaudioTheme.clay(colorScheme)
        )
        .accessibilityLabel(ClaudioL10n(language: language).text(.panelMasterVolume))
        .accessibilityValue("\(Int((session.draft * 100).rounded()))%")
        .accessibilityIdentifier(accessibilityIdentifier)
        .disabled(!isEnabled)
        .onChange(of: diskVolume) { session.rebase(to: $0) }
        .onChange(of: flushRevision) { _ in flush() }
        .onDisappear {
            if flushesOnDisappear { flush() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in
            flush()
        }
    }

    private func flush() {
        commit(session.flushPending())
    }

    private func commit(_ pendingValue: Double?) {
        guard let pendingValue else { return }
        if let landed = onCommit(pendingValue) {
            session.commitSucceeded(landed)
        } else {
            session.commitFailed()
        }
    }
}

#if DEBUG
/// Records the actual mounted Slider input callbacks, without another volume state or executor.
/// Harness callers still drive SwiftUI's Binding/editing entry; lifecycle signals use the real
/// modifiers and NotificationCenter subscription. Physical mouse/keyboard input is a separate gate.
@MainActor
package enum SharedVolumeMountRecorder {
    private struct Input {
        let value: Binding<Double>
        let editingChanged: (Bool) -> Void
    }
    private static var recording = false
    private static var inputs: [String: Input] = [:]

    package static func reset() { inputs = [:]; recording = true }
    package static func stopRecording() { inputs = [:]; recording = false }
    fileprivate static func register(
        identifier: String, value: Binding<Double>, editingChanged: @escaping (Bool) -> Void
    ) {
        guard recording else { return }
        inputs[identifier] = Input(value: value, editingChanged: editingChanged)
    }
    fileprivate static func remove(identifier: String) { inputs[identifier] = nil }
    package static func edit(_ editing: Bool, identifier: String) -> Bool {
        guard let input = inputs[identifier] else { return false }
        input.editingChanged(editing)
        return true
    }
    package static func setValue(_ value: Double, identifier: String) -> Bool {
        guard let input = inputs[identifier] else { return false }
        input.value.wrappedValue = value
        return true
    }
    package static func draft(identifier: String) -> Double? {
        inputs[identifier]?.value.wrappedValue
    }
}
#endif
