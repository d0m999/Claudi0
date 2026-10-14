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
    private let presentation: EventNoticeStackPresentation
    private var subscriptions: Set<AnyCancellable> = []
    private var presentationScreen: NSScreen?
    private var isInteractive = false
    private var programmaticHide = false
    private var hideGeneration: UInt64 = 0
    private var viewportRefreshPending = false
    private var hiddenLayoutPending = false
    private var focusResetPending = false
    private var renderedEpoch: UUID
    private let modalPauseObserver: EventNoticeModalPauseObserver
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
        presentation = EventNoticeStackPresentation(
            model: model, preferences: languageStore, navigation: navigation)
        self.navigation = navigation
        self.onViewInPanel = onViewInPanel
        self.languageStore = languageStore
        self.onWillBecomeInteractive = onWillBecomeInteractive
        renderedEpoch = model.receiverEpoch
        let noticeWindow = EventNoticePanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 44),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true)
        window = noticeWindow
        modalPauseObserver = EventNoticeModalPauseObserver(model: model, owner: noticeWindow)
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
        window.contentView = EventNoticeHostingView(
            rootView: EventNoticeView(
                model: model, languageStore: languageStore, navigation: navigation,
                eventAnimations: eventAnimations, animationVisibility: animationVisibility,
                presentation: presentation,
                onViewSource: { [weak self] in self?.viewSource($0) },
                onNavigate: { [weak self] action, id in
                    self?.openSourceApplication(action, owner: id)
                },
                onDismiss: { [weak self] in self?.closeBanner(id: $0) },
                onQueueInteraction: { [weak self] in self?.toggleQueue() },
                onClose: { [weak self] in self?.close() }))
        // Consume the committed callback value, including synchronous privacy withdrawal.
        presentation.outputs.sink { [weak self] value in self?.render(value) }
            .store(in: &subscriptions)
        model.$stackSnapshot.sink { [weak self] _ in
            self?.scheduleViewportRefresh()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .sink { [weak self] _ in self?.updateViewport() }.store(in: &subscriptions)
    }

    func openInteractive() { onViewInPanel(nil) }

    #if DEBUG && CLAUDIO_UI_REGRESSION
    private var regressionViewport: (width: Double, height: Double?)?
    /// Fixed native scenario using the real retained panel and its delegate, with only the
    /// viewport and domain clock substituted. This does not simulate external mouse clicks.
    func runGeometryRegression(advance: @MainActor (TimeInterval) -> Void) async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        func waitFor(_ predicate: @MainActor () -> Bool) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 4
            while !predicate() && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if !predicate() {
                print(
                    "geometry-regression timeout: visible=\(window.isVisible) key=\(window.isKeyWindow) eligible=\(presentation.output.isEligible) requests=\(presentation.output.requests.count) cards=\(model.stackSnapshot.visible.count) queued=\(model.stackSnapshot.queued.count) uptime=\(model.presentationUptime)"
                )
            }
            return predicate()
        }
        checks["initialMeasuredWindow"] = await waitFor {
            self.window.isVisible && self.presentation.output.requests.isEmpty
        }
        advance(0.5)
        becomeInteractive()
        checks["interactivePanelBecameKey"] = await waitFor { self.window.isKeyWindow }
        let before = model.stackSnapshot
        suspendGeometryForRegression()
        checks["programmaticHide"] = await waitFor { !self.window.isVisible }
        advance(10)
        checks["hiddenReadingPaused"] =
            model.stackSnapshot.pauseReasons.contains(.geometryUnavailable)
            && model.stackSnapshot.visible.map(\.readingTime.remaining)
                == before.visible.map(\.readingTime.remaining)
        checks["programmaticResignPreservedStack"] =
            model.stackSnapshot.visible.map(\.id) == before.visible.map(\.id)
            && !before.visible.isEmpty
        restoreGeometryForRegression()
        checks["hiddenHostMeasuredAndRestored"] = await waitFor {
            self.window.isVisible && self.presentation.output.requests.isEmpty
        }
        checks["restoreDidNotAcquireKey"] = !window.isKeyWindow
        checks["entranceNotReplayed"] =
            model.stackSnapshot.visible.map(\.entrance) == before.visible.map(\.entrance)
        becomeInteractive()
        _ = await waitFor { self.window.isKeyWindow }
        let other = EventNoticePanel(
            contentRect: NSRect(x: 40, y: 40, width: 160, height: 80),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.allowsKeyboardInteraction = true
        other.makeKeyAndOrderFront(nil)
        checks["genuineNativeKeyHandoffClosesStack"] = await waitFor {
            self.model.stackSnapshot.visible.isEmpty && self.model.stackSnapshot.queued.isEmpty
        }
        other.orderOut(nil); other.close()
        model.clearForPrivacy()
        return checks
    }

    func focusForRegression() { becomeInteractive() }
    /// Exercises the production output subscription, retained panel and keyboard gate together.
    func runStackReviewRegression(
        advance: @MainActor (TimeInterval) -> Void, withdrawOutput: Bool = false
    ) async -> [String: Bool] {
        func waitFor(_ predicate: @MainActor () -> Bool) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 4
            while !predicate() && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return predicate()
        }
        var checks: [String: Bool] = [:]
        checks["initialMeasuredWindow"] = await waitFor {
            // Mount the fixture for initial measurements, as the native stack harness does.
            // After setup, only the production subscription controls window visibility.
            self.window.orderFront(nil)
            self.window.contentView?.needsLayout = true
            self.window.contentView?.layoutSubtreeIfNeeded()
            return self.presentation.output.isEligible && self.presentation.output.requests.isEmpty
        }
        guard checks["initialMeasuredWindow"] == true else { return checks }
        if withdrawOutput {
            var armed = false, cleared = false, hiddenSynchronously = false, staleDelivery = false
            let observation = presentation.outputs.sink { [self] value in
                guard armed else { return }
                if cleared && value.isEligible { staleDelivery = true }
                if value.isEligible && !cleared {
                    cleared = true
                    model.clearForPrivacy()
                    hiddenSynchronously = !window.isVisible
                }
            }
            armed = true
            presentation.updateFontEnvironment("review-withdrawal")
            checks["reentrantWithdrawalTriggered"] = await waitFor { cleared }
            checks["privacyWithdrawsSynchronously"] = cleared && hiddenSynchronously
            checks["privacyWindowStaysHidden"] = await waitFor {
                !self.window.isVisible && !self.presentation.output.isEligible
                    && self.presentation.output.requests.isEmpty
            }
            checks["noStaleDelivery"] = !staleDelivery
            observation.cancel()
            return checks
        }
        advance(0.5)
        becomeInteractive()
        checks["interactivePanelBecameKey"] = await waitFor { self.window.isKeyWindow }
        let before = model.stackSnapshot.visible
        guard before.count == 3 else { checks["threeVisibleCards"] = false; return checks }
        var lostEligibility = false
        let observation = presentation.outputs.sink {
            if !$0.isEligible { lostEligibility = true }
        }
        closeBanner(id: before[1].id)
        checks["remainingCardsMeasured"] = await waitFor {
            self.presentation.output.requests.isEmpty
                && self.model.stackSnapshot.visible.prefix(2).map(\.id)
                    == [before[0].id, before[2].id]
        }
        checks["dismissalPreservesKeyboard"] =
            window.isKeyWindow && window.allowsKeyboardInteraction && isInteractive
        advance(0.2)
        checks["exitReclaimed"] = await waitFor {
            self.model.stackSnapshot.exiting.isEmpty && self.presentation.output.requests.isEmpty
        }
        checks["retirementPreservesKeyboard"] =
            window.isKeyWindow && window.allowsKeyboardInteraction && isInteractive
        checks["neverWithdrewRemainingWindow"] = !lostEligibility
        checks["focusStillPausesReading"] = model.stackSnapshot.pauseReasons.contains(.windowFocus)
        observation.cancel()
        window.cancelOperation(nil)
        checks["escapeStillDismissesStack"] =
            model.stackSnapshot.visible.isEmpty && model.stackSnapshot.queued.isEmpty
        clearForPrivacy()
        return checks
    }

    func suspendGeometryForRegression() {
        regressionViewport = (268, nil)
        updateViewport()
    }
    func restoreGeometryForRegression() {
        regressionViewport = nil
        updateViewport()
    }
    #endif

    private func becomeInteractive() {
        if !isInteractive { focusRestoration = onWillBecomeInteractive() }
        isInteractive = true
        window.allowsKeyboardInteraction = true
        updateViewport()
        guard presentation.output.isEligible else { return }
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
        hideWindow()
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
        guard !programmaticHide else { return }
        let generation = hideGeneration
        Task { @MainActor [weak self] in
            guard let self, !self.window.isKeyWindow, !self.programmaticHide,
                self.hideGeneration == generation, self.window.isVisible
            else { return }
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

    private func hideWindow() {
        // orderOut can deliver resign-key synchronously or on the next run-loop turn. Release
        // interaction first and retain a separate guard through that turn; never dismissStack.
        programmaticHide = true
        hideGeneration &+= 1
        focusRestoration = nil
        isInteractive = false
        window.allowsKeyboardInteraction = false
        window.orderOut(nil)
        animationVisibility.isVisible = false
        // Withdrawal can originate in the model's willSet publication. Only native hiding is
        // synchronous here; defer model pause projection until that transaction has committed.
        if !focusResetPending {
            focusResetPending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.focusResetPending = false
                guard !self.isInteractive else { return }
                self.model.setPauseReason(.windowFocus, active: false)
                self.model.setKeyboardFocused(false)
                self.model.setHovering(false)
            }
        }
    }

    private func render(_ value: EventNoticeStackPresentationOutput) {
        if renderedEpoch != value.epoch {
            renderedEpoch = value.epoch
            hideWindow()
        }
        guard value.isEligible, let screen = presentationScreen else {
            hideWindow()
            // An ordered-out host still lays out pending measurement copies. Its proposed
            // width must follow the request even while the visible geometry is suspended.
            window.setContentSize(NSSize(width: value.width, height: max(1, value.height)))
            if !hiddenLayoutPending {
                hiddenLayoutPending = true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.hiddenLayoutPending = false
                    self.window.contentView?.needsLayout = true
                    self.window.contentView?.layoutSubtreeIfNeeded()
                }
            }
            return
        }
        programmaticHide = false
        let frame = NSRect(
            x: EventNoticePlacement.clampedX(visibleFrame: screen.visibleFrame, width: value.width),
            y: EventNoticePlacement.topAnchorY(
                screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                safeAreaTop: screen.safeAreaInsets.top, height: value.height),
            width: value.width, height: value.height)
        if window.frame != frame { window.setFrame(frame, display: true) }
        window.alphaValue = 1
        if !window.isVisible { window.orderFront(nil) }
        animationVisibility.isVisible = window.occlusionState.contains(.visible)
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

    private func scheduleViewportRefresh() {
        guard !viewportRefreshPending else { return }
        viewportRefreshPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.viewportRefreshPending = false
            self.updateViewport()
        }
    }

    private func updateViewport() {
        guard model.stackSnapshot.hasPresentation else {
            presentationScreen = nil
            return
        }
        if let presentationScreen, !NSScreen.screens.contains(where: { $0 === presentationScreen })
        {
            self.presentationScreen = nil
        }
        guard let screen = presentationScreen ?? screenUnderPointer() ?? NSScreen.main else {
            presentation.updateViewport(width: presentation.output.width, availableHeight: nil)
            return
        }
        presentationScreen = screen
        model.setPauseReason(.modal, active: modalPauseObserver.isPaused)
        #if DEBUG && CLAUDIO_UI_REGRESSION
        if let regressionViewport {
            presentation.updateViewport(
                width: regressionViewport.width,
                availableHeight: regressionViewport.height)
            return
        }
        #endif
        presentation.updateViewport(
            width: Double(EventNoticePlacement.clampedWidth(visibleFrame: screen.visibleFrame)),
            availableHeight: Double(
                EventNoticePlacement.availableHeight(
                    screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                    safeAreaTop: screen.safeAreaInsets.top)))
        // A screen origin can change without changing available size.
        render(presentation.output)
    }

    private func screenUnderPointer() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
    }
}
