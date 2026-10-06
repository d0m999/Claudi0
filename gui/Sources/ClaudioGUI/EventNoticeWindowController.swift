import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Combine
import Foundation
import SwiftUI

/// One transparent retained panel. Automatic arrivals remain nonactivating; complete card
/// measurements select the visible FIFO prefix and each card owns its presentation animation.
@MainActor
final class EventNoticeWindowController: NSObject, NSWindowDelegate {
    let model: EventNoticeModel
    private let languageStore: ClaudioPreferences
    private let onWillBecomeInteractive: @MainActor () -> (@MainActor () -> Void)?
    private var focusRestoration: (@MainActor () -> Void)?
    private let onViewInPanel: @MainActor (EventNoticeAction?) -> Void
    private let navigation: SessionNavigationCoordinator
    private let window: EventNoticePanel
    private let geometry = EventNoticeStackGeometry()
    private var subscriptions: Set<AnyCancellable> = []
    private var presentationScreen: NSScreen?
    private var isInteractive = false
    private var isPositioning = false
    private var measurements: [String: Double] = [:]
    private var renderedEpoch: UUID
    private var modalDepth: [String: Int] = [:]
    private let animationVisibility = EventAnimationVisibility(isVisible: false)

    init(
        model: EventNoticeModel,
        languageStore: ClaudioPreferences,
        navigation: SessionNavigationCoordinator,
        eventAnimations: EventAnimationResources? = nil,
        onViewInPanel: @escaping @MainActor (EventNoticeAction?) -> Void,
        onWillBecomeInteractive: @escaping @MainActor () -> (@MainActor () -> Void)? = { nil }
    ) {
        self.model = model
        self.navigation = navigation
        self.onViewInPanel = onViewInPanel
        self.languageStore = languageStore
        self.onWillBecomeInteractive = onWillBecomeInteractive
        renderedEpoch = model.receiverEpoch
        window = EventNoticePanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 44),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isFloatingPanel = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        window.title = "claudi0 event notice"
        window.onEscape = { [weak self] in self?.close() }
        model.setVisibleCapacity(0, measuredIDs: [])
        window.contentView = EventNoticeHostingView(
            rootView: EventNoticeView(
                model: model, languageStore: languageStore, navigation: navigation,
                eventAnimations: eventAnimations, animationVisibility: animationVisibility,
                geometry: geometry,
                onViewSource: { [weak self] in self?.viewSource($0) },
                onNavigate: { [weak self] action, id in
                    self?.openSourceApplication(action, owner: id)
                },
                onDismiss: { [weak self] in self?.closeBanner(id: $0) },
                onQueueInteraction: { [weak self] in self?.toggleQueue() },
                onMeasurements: { [weak self] in self?.receiveMeasurements($0) },
                onClose: { [weak self] in self?.close() }))
        // Published snapshots send before assignment; defer presentation until the model's
        // transaction has committed, also coalescing redraws and one batch's new arrivals.
        model.$stackSnapshot.sink { [weak self] snapshot in
            if !snapshot.hasPresentation || self?.renderedEpoch != snapshot.receiverEpoch {
                // Privacy and source removal must not leave a retired frame on screen while
                // waiting for SwiftUI's next layout transaction.
                self?.window.orderOut(nil)
                self?.animationVisibility.isVisible = false
            }
            Task { @MainActor [weak self] in self?.render() }
        }.store(in: &subscriptions)
        navigation.$feedback.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.repositionIfVisible() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .sink { [weak self] _ in self?.repositionIfVisible() }.store(in: &subscriptions)
        for (name, active, kind) in [
            (Notification.Name.claudioSettingsModalWillBegin, true, "file-picker"),
            (.claudioSettingsModalDidEnd, false, "file-picker"),
            (NSWindow.willBeginSheetNotification, true, "sheet"),
            (NSWindow.didEndSheetNotification, false, "sheet"),
        ] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] notification in
                    guard let self else { return }
                    let key = kind + String((notification.object as? NSWindow)?.windowNumber ?? 0)
                    let depth = max(0, (self.modalDepth[key] ?? 0) + (active ? 1 : -1))
                    self.modalDepth[key] = depth > 0 ? depth : nil
                    self.model.setPauseReason(
                        .modal, active: self.modalDepth.values.contains { $0 > 0 })
                }
                .store(in: &subscriptions)
        }
    }

    func openInteractive() { onViewInPanel(nil) }

    #if DEBUG && CLAUDIO_UI_REGRESSION
    func focusForRegression() { becomeInteractive() }
    #endif

    private func becomeInteractive() {
        if !isInteractive { focusRestoration = onWillBecomeInteractive() }
        isInteractive = true
        window.allowsKeyboardInteraction = true
        positionWindow()
        window.makeKeyAndOrderFront(nil)
        model.setPauseReason(.windowFocus, active: true)
    }

    func viewSource(_ action: EventNoticeAction) {
        guard model.isCurrent(action) else { return }
        onViewInPanel(action)
    }

    func openSourceApplication(_ action: EventNoticeAction, owner: UUID) {
        guard model.isCurrent(action), model.containsPresentation(owner), !navigation.isNavigating
        else { return }
        becomeInteractive()
        navigation.navigateSource(action, generation: navigation.capabilityGeneration, owner: owner)
        {
            [weak self] outcome in
            guard let self else { return }
            if [.exactReturnConfirmed, .applicationFallback, .requestSent].contains(outcome) {
                self.releaseInteraction()
            }
        }
    }

    @discardableResult
    func copySessionID(_ action: EventNoticeAction) -> Bool {
        navigation.copy(action) { sessionID in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(sessionID, forType: .string)
        }
    }

    private func toggleQueue() {
        if model.stackSnapshot.visible.isEmpty {
            onViewInPanel(model.stackSnapshot.queued.first?.record.action)
        } else {
            becomeInteractive()
            model.setQueueExpanded(!model.stackSnapshot.isQueueExpanded)
        }
    }

    private func closeBanner(id: UUID) {
        navigation.cancelSourceApplication(owner: id)
        model.dismissBanner(id: id)
        if model.stackSnapshot.visible.isEmpty && model.stackSnapshot.queued.isEmpty {
            handBackFocus()
        }
    }

    func close() {
        for item in model.stackSnapshot.visible {
            navigation.cancelSourceApplication(owner: item.id)
        }
        model.dismissStack()
        handBackFocus()
    }

    private func handBackFocus() {
        let owesHandback = isInteractive && window.isKeyWindow && NSApp.isActive
        let restoration = focusRestoration
        releaseInteraction()
        if owesHandback { restoration?() }
    }

    private func releaseInteraction() {
        focusRestoration = nil
        isInteractive = false
        window.allowsKeyboardInteraction = false
        model.setPauseReason(.windowFocus, active: false)
        model.setKeyboardFocused(false)
    }

    func clearForPrivacy() {
        animationVisibility.isVisible = false
        releaseInteraction()
        presentationScreen = nil
        measurements.removeAll()
        window.orderOut(nil)
        navigation.reset()
        model.clearForPrivacy()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if isInteractive { model.setPauseReason(.windowFocus, active: true) }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        animationVisibility.isVisible = window.isVisible && window.occlusionState.contains(.visible)
    }

    func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, !self.window.isKeyWindow else { return }
            self.finishResigningKey()
        }
    }

    private func finishResigningKey() {
        if navigation.permitsFocusHandoff(
            to: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        {
            releaseInteraction()
        } else if navigation.isNavigating {
            for item in model.stackSnapshot.visible {
                navigation.cancelSourceApplication(owner: item.id)
            }
            releaseInteraction()
        } else if isInteractive {
            close()
        } else {
            model.setPauseReason(.windowFocus, active: false)
        }
    }

    private func render() {
        let snapshot = model.stackSnapshot
        if renderedEpoch != snapshot.receiverEpoch {
            renderedEpoch = snapshot.receiverEpoch
            measurements.removeAll()
            releaseInteraction()
        }
        guard snapshot.hasPresentation else {
            animationVisibility.isVisible = false
            releaseInteraction()
            model.setHovering(false)
            presentationScreen = nil
            if window.isVisible { window.orderOut(nil) }
            return
        }
        let isModal = modalDepth.values.contains { $0 > 0 }
        if model.stackSnapshot.pauseReasons.contains(.modal) != isModal {
            model.setPauseReason(.modal, active: isModal)
        }
        positionWindow()
        window.alphaValue = 1
        if !window.isVisible { window.orderFront(nil) }
        animationVisibility.isVisible = window.occlusionState.contains(.visible)
        // An exiting-only frame is immediately ineligible for mouse and keyboard interaction.
        window.ignoresMouseEvents =
            model.stackSnapshot.visible.isEmpty && model.stackSnapshot.queued.isEmpty
        #if DEBUG
        logDevelopmentPresentation(model.stackSnapshot)
        #endif
    }

    #if DEBUG
    private func logDevelopmentPresentation(_ snapshot: EventNoticeStackSnapshot) {
        guard ProcessInfo.processInfo.environment["CLAUDIO_DEV_CODEX_QUESTION_OBSERVER"] == "1"
        else { return }
        for item in snapshot.visible + snapshot.exiting
        where item.record.provenance == .developmentCodexRollout {
            // Preserve fixed AppKit observation codes without logging source contents or IDs.
            let state = item.phase.rawValue
            let ordered = window.isVisible ? "ordered" : "not_ordered"
            let activeSpace = window.isOnActiveSpace ? "active_space" : "other_space"
            let occlusion = window.occlusionState.contains(.visible) ? "unoccluded" : "occluded"
            let key = window.isKeyWindow ? "key" : "not_key"
            let screens = NSScreen.screens.isEmpty ? "no_screen" : "screen_available"
            FileHandle.standardError.write(
                Data(
                    "claudio.codex-question-window \(state) \(ordered) \(activeSpace) \(occlusion) \(key) \(screens)\n"
                        .utf8))
        }
    }
    #endif

    private func receiveMeasurements(_ values: [String: Double]) {
        let current = model.stackSnapshot
        let valid = Set((current.candidates + current.exiting).map { "card.\($0.id.uuidString)" })
        for (key, height) in values where height.isFinite && height > 0 {
            if !key.hasPrefix("card.") || valid.contains(key) { measurements[key] = height }
        }
        measurements = measurements.filter { !$0.key.hasPrefix("card.") || valid.contains($0.key) }
        // Preferences arrive during SwiftUI layout; never publish model changes inside that pass.
        Task { @MainActor [weak self] in self?.repositionIfVisible() }
    }

    private func repositionIfVisible() {
        guard model.stackSnapshot.hasPresentation else { return }
        positionWindow()
    }

    private func positionWindow() {
        guard !isPositioning else { return }
        isPositioning = true
        defer { isPositioning = false }
        if let presentationScreen, !NSScreen.screens.contains(where: { $0 === presentationScreen })
        {
            self.presentationScreen = nil
        }
        guard let screen = presentationScreen ?? screenUnderPointer() ?? NSScreen.main else {
            return
        }
        if presentationScreen == nil { presentationScreen = screen }
        let visible = screen.visibleFrame
        let width = Double(EventNoticePlacement.clampedWidth(visibleFrame: visible))
        if geometry.width != width {
            geometry.width = width
            measurements.removeAll()
        }
        let available = Double(
            EventNoticePlacement.availableHeight(
                screenFrame: screen.frame, visibleFrame: visible,
                safeAreaTop: screen.safeAreaInsets.top))
        let snapshot = model.stackSnapshot
        let candidates = snapshot.candidates
        let heights = candidates.map { measurements["card.\($0.id.uuidString)"] ?? 0 }
        let layout = EventNoticeStackLayout.resolve(
            cardHeights: heights, totalCount: snapshot.totalCount, availableHeight: available,
            queueEntryHeight: measurements["queue-entry"] ?? 44,
            capacityHintHeight: snapshot.capacityHintCount > 0
                ? measurements["capacity-hint"] ?? 60 : 0,
            queueExpanded: snapshot.isQueueExpanded,
            queueContentHeight: measurements["queue-content"] ?? 220)
        let measuredIDs = Set(
            candidates.enumerated().compactMap { index, item in
                heights[index] > 0 ? item.id : nil
            })
        model.setVisibleCapacity(layout.visibleCapacity, measuredIDs: measuredIDs)
        var positions: [UUID: Double] = [:]
        var top: Double = 0
        for item in model.stackSnapshot.visible {
            positions[item.id] = top
            top +=
                (measurements["card.\(item.id.uuidString)"] ?? 0) + EventNoticeStackLayout.spacing
        }
        model.updateDisplayPositions(positions)
        if geometry.queueHeight != layout.queueHeight { geometry.queueHeight = layout.queueHeight }
        let exitHeight =
            model.stackSnapshot.exiting.map {
                $0.positionY + (measurements["card.\($0.id.uuidString)"] ?? 0) + 6
            }.max() ?? 0
        let height = min(available, max(1, layout.height, exitHeight))
        let x = EventNoticePlacement.clampedX(visibleFrame: visible, width: width)
        let y = EventNoticePlacement.topAnchorY(
            screenFrame: screen.frame, visibleFrame: visible,
            safeAreaTop: screen.safeAreaInsets.top, height: height)
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    private func screenUnderPointer() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
    }
}
