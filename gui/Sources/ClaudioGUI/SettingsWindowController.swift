import AppKit
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Combine
import SwiftUI

/// Thin AppKit adapter around the app-lifetime Settings presentation session. Destination route,
/// focus, lifecycle and announcement intent stay in the importable session; this owner retains
/// exactly one native window and the activation handback debt attached to it.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settingsPresentationSession: SettingsPresentationSession
    private let postAccessibilityAnnouncement: @MainActor (NSWindow, String, Int) -> Bool
    private var window: RetainedSettingsWindow?
    private let statusActivationGuard = StatusItemWindowOrderGuard()
    private var focusRestoration: (@MainActor (NSRunningApplication?) -> Void)?
    private var handbackTracker = RetainedWindowHandbackTracker<NSRunningApplication>()
    private var externalActivationCancellable: AnyCancellable?
    private var settingsPresentationCancellable: AnyCancellable?
    private var settingsPresentationAnnouncementDeliveryScheduled = false

    init(
        session: SettingsPresentationSession,
        postAccessibilityAnnouncement: @escaping @MainActor (NSWindow, String, Int) -> Bool =
            SettingsWindowController.postAccessibilityAnnouncement
    ) {
        settingsPresentationSession = session
        self.postAccessibilityAnnouncement = postAccessibilityAnnouncement
        super.init()

        externalActivationCancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard
                        let self,
                        let application =
                            notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication
                    else { return }
                    let isCurrentApplication =
                        application.processIdentifier
                        == ProcessInfo.processInfo.processIdentifier
                    self.handbackTracker.noteExternalActivation(
                        application,
                        isWindowVisible: self.window?.isVisible == true,
                        isCurrentApplication: isCurrentApplication)
                }
            }

        settingsPresentationCancellable = session.$state
            .sink { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateWindowTitle(language: state.language)
                    if state.pendingAnnouncement != nil {
                        self.scheduleSettingsPresentationAnnouncementDelivery()
                    }
                }
            }
    }

    func showWindow(
        request: SettingsPresentationRequest = .route(nil),
        returnFocusTo application: NSRunningApplication?,
        onClose restoration: @escaping @MainActor (NSRunningApplication?) -> Void
    ) {
        focusRestoration = restoration
        let wasVisible = window?.isVisible == true
        _ = settingsPresentationSession.send(.present(request))
        let presentedWindow = window ?? makeWindow()
        finishPanelPresentation()
        if !wasVisible {
            handbackTracker.beginPresentation(returnTo: application)
        }

        if !wasVisible || !presentedWindow.isKeyWindow {
            _ = settingsPresentationSession.send(.windowPhaseChanged(.visibleNonKey))
        }
        presentedWindow.presentForUserRequest()
        _ = settingsPresentationSession.send(
            .windowPhaseChanged(presentedWindow.isKeyWindow ? .key : .visibleNonKey))
        if !wasVisible {
            presentedWindow.makeFirstResponder(presentedWindow.contentViewController?.view)
        }
        scheduleSettingsPresentationAnnouncementDelivery()
    }

    /// A nonactivating Settings window or its active sheet can own key focus while another
    /// application remains frontmost. Visibility and remembered application activation cannot
    /// substitute for the current native key target.
    var ownsForegroundBeforePanel: Bool {
        guard let window else { return false }
        return statusActivationGuard.isProtecting(window)
            || settingsWindowOwnsKeyFocus(window, keyWindow: NSApp.keyWindow)
    }

    func restoreVisibleWindowAfterPanelClose() -> Bool {
        finishPanelPresentation()
        guard let window, window.isVisible, !window.isMiniaturized, window.isOnActiveSpace else {
            return false
        }
        let target = settingsWindowRestorationTarget(window)
        guard target.isVisible, !target.isMiniaturized, target.isOnActiveSpace else { return false }
        target.makeKey()
        return true
    }

    /// macOS can deactivate an accessory app before forwarding its status-item action.
    /// Capture this boundary while Settings still owns key; no remembered foreground cache.
    func protectSettingsDuringStatusActivation(button: NSView?) {
        guard let window,
            settingsWindowOwnsKeyFocus(window, keyWindow: NSApp.keyWindow),
            CGEventSource.buttonState(.combinedSessionState, button: .left),
            let button,
            statusItemContainsScreenPoint(NSEvent.mouseLocation, button: button)
        else { return }
        statusActivationGuard.begin(window: window)
    }

    func finishStatusActivation() {
        statusActivationGuard.finish(restoringOrder: true)
    }

    func prepareForPanelPresentation(settingsWasForeground: Bool) {
        window?.defersAutomaticFocusForPanel = !settingsWasForeground
    }

    func finishPanelPresentation() {
        window?.defersAutomaticFocusForPanel = false
    }

    /// Mutual exclusion with the top event-notice list (SPEC: 设置打开和顶部列表互斥显示).
    /// Transfer the complete restoration before close consumes it. The notice surface will run
    /// it only when its own interaction ends, preserving both the host and panel destination.
    func closeForMutualExclusion() -> (@MainActor () -> Void)? {
        guard let window, window.isVisible else { return nil }
        let restoration = takeFocusRestoration()
        window.close()
        return restoration
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard
            let keyWindow = notification.object as? NSWindow,
            keyWindow === window
        else { return }
        _ = settingsPresentationSession.send(.windowPhaseChanged(.key))
        scheduleSettingsPresentationAnnouncementDelivery()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard
            let changedWindow = notification.object as? NSWindow,
            changedWindow === window
        else { return }
        _ = settingsPresentationSession.send(.windowPhaseChanged(.visibleNonKey))
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let closingWindow = notification.object as? NSWindow,
            closingWindow === window
        else { return }

        statusActivationGuard.finish(restoringOrder: false)
        _ = settingsPresentationSession.send(.windowWillClose)
        let restoration = takeFocusRestoration()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                restoration?()
            }
        }
    }

    private func takeFocusRestoration() -> (@MainActor () -> Void)? {
        guard let restoration = focusRestoration else { return nil }
        focusRestoration = nil
        return handbackTracker.consumeOnClose(restoringWith: restoration)
    }

    #if DEBUG && CLAUDIO_UI_REGRESSION
    var regressionGeometry: [String: Any] {
        guard let window else { return [:] }
        return [
            "width": window.contentLayoutRect.width, "height": window.contentLayoutRect.height,
            "frameWidth": window.frame.width, "frameHeight": window.frame.height,
            "backingScale": window.backingScaleFactor,
            "appearance": window.effectiveAppearance.name.rawValue,
        ]
    }

    func applyRegressionGeometry(minimum: Bool, dark: Bool) {
        guard let window else { return }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: minimum ? 960 : 1240, height: minimum ? 640 : 820))
        window.center()
    }

    func focusForRegression() { window?.presentForUserRequest() }
    #endif

    private func makeWindow() -> RetainedSettingsWindow {
        let content = SettingsRootView(session: settingsPresentationSession)
        let window = RetainedSettingsWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsWindowGeometry.defaultWidth,
                height: SettingsWindowGeometry.defaultHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = ClaudioL10n(
            language: settingsPresentationSession.state.language
        ).text(.settingsWindowTitle)
        window.contentMinSize = NSSize(
            width: SettingsWindowGeometry.minimumWidth,
            height: SettingsWindowGeometry.minimumHeight)
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        window.delegate = self
        window.setFrameAutosaveName("Claudio.SettingsWindow")
        window.center()
        self.window = window
        return window
    }

    private func updateWindowTitle(language: ClaudioAppLanguage) {
        window?.title = ClaudioL10n(language: language).text(.settingsWindowTitle)
    }

    private func scheduleSettingsPresentationAnnouncementDelivery() {
        guard !settingsPresentationAnnouncementDeliveryScheduled else { return }
        settingsPresentationAnnouncementDeliveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settingsPresentationAnnouncementDeliveryScheduled = false
                self.deliverPendingSettingsPresentationAnnouncement()
            }
        }
    }

    private func deliverPendingSettingsPresentationAnnouncement() {
        guard
            settingsPresentationSession.state.windowPhase == .key,
            let announcement = settingsPresentationSession.state.pendingAnnouncement,
            let window,
            window.isVisible,
            window.isKeyWindow
        else { return }
        let sentence = announcement.meaning.localizedSentence(
            language: settingsPresentationSession.state.language)
        guard !sentence.isEmpty else { return }
        _ = SettingsAnnouncementDelivery.attempt(
            announcement,
            post: {
                postAccessibilityAnnouncement(
                    window,
                    sentence,
                    announcement.meaning.priority)
            },
            acknowledgeSuccess: { [settingsPresentationSession] id in
                _ = settingsPresentationSession.send(
                    .acknowledgeAnnouncement(id: id, didPost: true))
            })
    }

    private static func postAccessibilityAnnouncement(
        window: NSWindow,
        sentence: String,
        priority: Int
    ) -> Bool {
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: sentence,
                .priority: priority,
            ])
        return true
    }
}
