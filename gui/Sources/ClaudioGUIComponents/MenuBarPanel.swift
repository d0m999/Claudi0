import AppKit
import ClaudioGUICore

/// A transient menu surface that borrows keyboard focus without activating its application.
/// Settings and other applications retain their window ordering throughout presentation.
@MainActor
package final class MenuBarPanel: NSPanel {
    package enum Dismissal {
        case explicit
        case outsideInteraction
        case keyResignation

        @MainActor
        package func preservesNoticeNavigation(
            _ navigation: SessionNavigationCoordinator, frontmostPID: Int32?
        ) -> Bool {
            self == .keyResignation && navigation.permitsFocusHandoff(to: frontmostPID)
        }
    }

    package var onEscape: (() -> Bool)?
    package var onShow: (() -> Void)?
    package var onClose: ((Dismissal) -> Void)?
    private weak var anchor: NSView?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var keyResignationObserver: NSObjectProtocol?
    private var closing = false

    package var isShown: Bool { isVisible }
    package var contentSize: NSSize {
        get { contentRect(forFrameRect: frame).size }
        set { setContentSize(newValue) }
    }

    package init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .statusBar
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        title = "claudi0"
    }

    package override var canBecomeKey: Bool { true }
    package override var canBecomeMain: Bool { false }

    package func show(relativeTo rect: NSRect, of view: NSView) {
        guard !isShown, let anchorWindow = view.window else { return }
        let screenRect = anchorWindow.convertToScreen(view.convert(rect, to: nil))
        let visible = anchorWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? screenRect
        let x = max(
            visible.minX + 8,
            min(
                screenRect.midX - frame.width / 2,
                visible.maxX - frame.width - 8))
        let y = max(
            visible.minY + 8,
            min(
                screenRect.minY - frame.height - 4,
                visible.maxY - frame.height - 4))
        setFrameOrigin(NSPoint(x: x, y: y))
        anchor = view
        (view as? NSStatusBarButton)?.highlight(true)
        installDismissalObservers()
        makeKeyAndOrderFront(nil)
        onShow?()
    }

    package override func close() {
        dismiss(.explicit)
    }

    package override func cancelOperation(_ sender: Any?) {
        if onEscape?() == true { return }
        dismiss(.explicit)
    }

    package override func accessibilityPerformCancel() -> Bool {
        guard isShown else { return false }
        if onEscape?() == true { return true }
        dismiss(.explicit)
        return true
    }

    package func dismiss(_ reason: Dismissal) {
        guard isShown, !closing else { return }
        closing = true
        removeDismissalObservers()
        // Close child popovers before ordering out their parent. The retained root remains alive.
        for child in childWindows ?? [] { child.close() }
        orderOut(nil)
        (anchor as? NSStatusBarButton)?.highlight(false)
        anchor = nil
        closing = false
        onClose?(reason)
    }

    private func containsWindow(_ candidate: NSWindow?) -> Bool {
        var current = candidate
        while let window = current {
            if window === self { return true }
            current = window.sheetParent ?? window.parent
        }
        return false
    }

    private func installDismissalObservers() {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.containsWindow(event.window) else { return }
                if let anchor = self.anchor, statusItemContainsMouseEvent(event, button: anchor) {
                    return
                }
                self.dismiss(.outsideInteraction)
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let anchor = self.anchor, statusItemContainsMouseEvent(event, button: anchor) {
                    return
                }
                self.dismiss(.outsideInteraction)
            }
        }
        keyResignationObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let resignedWindow = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, self.containsWindow(resignedWindow) else {
                    return
                }
                // A child popover can borrow key. Wait for the new key target before deciding
                // whether focus left this menu; app activation is independent of a nonactive panel.
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.containsWindow(NSApp.keyWindow) else { return }
                    self.dismiss(.keyResignation)
                }
            }
        }
    }

    private func removeDismissalObservers() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let keyResignationObserver {
            NotificationCenter.default.removeObserver(keyResignationObserver)
        }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        keyResignationObserver = nil
    }
}
