import AppKit
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Combine
import SoundPacksWindow
import SwiftUI

/// The native shell renders the session's projection; it never interprets domain routes.
@MainActor
package final class SettingsNativeShellController: NSSplitViewController, NSToolbarDelegate {
    package let sidebarController: SettingsNativeSidebarController
    package let navigationControl = NSSegmentedControl()
    package let pageTitle = NSTextField(labelWithString: "")
    private let session: SettingsPresentationSession
    private let contentController: NSHostingController<AnyView>
    private var presentationSubscription: AnyCancellable?
    private var windowObservers: [NSObjectProtocol] = []
    private weak var installedWindow: NSWindow?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var compactLayout: Bool?
    private var lastContentFocusIdentifier: String?
    private var restorationScheduled = false
    private var isSynchronizingLayout = false

    package init(session: SettingsPresentationSession) {
        self.session = session
        sidebarController = SettingsNativeSidebarController(session: session)
        contentController = NSHostingController(
            rootView: AnyView(SettingsDestinationContentView(session: session)))
        super.init(nibName: nil, bundle: nil)
        if #available(macOS 13, *) { contentController.sizingOptions = [] }
        contentController.view.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)
        session.captureReadingPosition = { [weak self] in self?.captureReadingPosition() }
        // Mount readiness can advance without changing the visible projection.
        presentationSubscription = session.$state
            .combineLatest(session.$renderedNavigationStamp)
            .sink { [weak self] state, _ in
                MainActor.assumeIsolated { self?.update(state) }
            }
    }

    required init?(coder: NSCoder) { nil }

    package override func cancelOperation(_ sender: Any?) {
        guard view.window?.isKeyWindow == true, view.window?.attachedSheet == nil,
            session.state.chrome.navigationEnabled
        else { return }
        sidebarController.focusSelection()
    }

    package override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebar.canCollapse = false
        sidebar.minimumThickness = SettingsWindowGeometry.compactSidebarWidth
        sidebar.maximumThickness = SettingsWindowGeometry.standardSidebarWidth
        addSplitViewItem(sidebar)
        // Native safe area, including the toolbar, determines the content's top boundary.
        let container = SettingsSafeAreaContentController(content: contentController)
        addSplitViewItem(NSSplitViewItem(viewController: container))
        sidebarWidthConstraint = sidebarController.view.widthAnchor.constraint(equalToConstant: 252)
        sidebarWidthConstraint?.priority = .defaultHigh
        sidebarWidthConstraint?.isActive = true
        view.setAccessibilityIdentifier(SettingsPresentationAccessibilityID.root)
        update(session.state)
    }

    package override func viewDidAppear() {
        super.viewDidAppear()
        if let window = view.window { install(in: window) }
    }

    package override func viewDidLayout() {
        super.viewDidLayout()
        synchronizeLayout()
    }

    package func synchronizeLayout() {
        guard !isSynchronizingLayout else { return }
        isSynchronizingLayout = true
        defer { isSynchronizingLayout = false }
        let compact = view.bounds.width <= SettingsWindowGeometry.compactSidebarWindowThreshold
        let sidebarWidth = CGFloat(settingsSidebarWidth(windowWidth: view.bounds.width))
        sidebarWidthConstraint?.constant = sidebarWidth
        if let sidebar = splitViewItems.first {
            sidebar.minimumThickness = sidebarWidth
            sidebar.maximumThickness = sidebarWidth
        }
        if compactLayout != compact {
            compactLayout = compact
            contentController.rootView = AnyView(
                SettingsDestinationContentView(session: session)
                    .environment(\.settingsUsesCompactLayout, compact))
        }
        if let window = view.window, installedWindow !== window { install(in: window) }
        view.layoutSubtreeIfNeeded()
        #if DEBUG
        SoundPacksLayoutRecorder.recordNative("settings.sidebar", view: sidebarController.view)
        for destination in SettingsDestination.allCases {
            if let frame = sidebarController.frame(for: destination) {
                SoundPacksLayoutRecorder.recordNative(
                    "settings.sidebar.item.\(destination.rawValue)",
                    view: sidebarController.table, bounds: frame)
            }
        }
        SoundPacksLayoutRecorder.recordNative(
            "settings.title.\(session.state.chrome.destination.rawValue)", view: pageTitle)
        SoundPacksLayoutRecorder.recordNative("settings.navigation", view: navigationControl)
        #endif
    }

    package func install(in window: NSWindow) {
        guard installedWindow !== window else { return }
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        installedWindow = window
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.styleMask.insert(.fullSizeContentView)
        let toolbar = NSToolbar(identifier: "Claudio.Settings.Toolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        for notification in [NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification] {
            windowObservers.append(
                NotificationCenter.default.addObserver(
                    forName: notification, object: window, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRestoration() } })
        }
        windowObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willBeginSheetNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    _ = self?.session.send(.setNavigationBlocked(id: "native-sheet", blocked: true))
                }
            })
        windowObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didEndSheetNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    _ = self?.session.send(
                        .setNavigationBlocked(id: "native-sheet", blocked: false))
                }
            })
        windowObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.synchronizeLayout() } })
        windowObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.uninstall() } })
        windowObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.rememberContentFocus() } })
        for (name, blocked) in [
            (Notification.Name.claudioSettingsModalWillBegin, true),
            (.claudioSettingsModalDidEnd, false),
        ] {
            windowObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated {
                        _ = self?.session.send(
                            .setNavigationBlocked(id: "file-picker", blocked: blocked))
                    }
                })
        }
        update(session.state)
        DispatchQueue.main.async { [weak self] in self?.synchronizeLayout() }
    }

    package func uninstall() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        installedWindow = nil
        lastContentFocusIdentifier = nil
    }

    package func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .sidebarTrackingSeparator, .init("settings.navigation"), .space,
            .init("settings.page-title"), .flexibleSpace,
        ]
    }
    package func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    package func toolbar(
        _: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        if identifier == .sidebarTrackingSeparator {
            return NSTrackingSeparatorToolbarItem(
                identifier: identifier, splitView: splitView, dividerIndex: 0)
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier.rawValue == "settings.navigation" {
            navigationControl.segmentCount = 2
            navigationControl.trackingMode = .momentary
            navigationControl.segmentStyle = .automatic
            navigationControl.controlSize = .regular
            navigationControl.setWidth(32, forSegment: 0)
            navigationControl.setWidth(32, forSegment: 1)
            navigationControl.target = self
            navigationControl.action = #selector(navigate(_:))
            navigationControl.setAccessibilityIdentifier("settings.navigation")
            item.view = navigationControl
        } else if identifier.rawValue == "settings.page-title" {
            pageTitle.font = .systemFont(ofSize: 17, weight: .semibold)
            pageTitle.lineBreakMode = .byTruncatingTail
            pageTitle.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
            item.view = pageTitle
        } else {
            return nil
        }
        update(session.state)
        return item
    }

    @objc private func navigate(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard (0..<2).contains(index), sender.isEnabled(forSegment: index) else { return }
        _ = session.send(index == 0 ? .goBack : .goForward)
    }

    private func update(_ state: SettingsPresentationState) {
        pageTitle.stringValue = state.chrome.title
        pageTitle.setAccessibilityIdentifier("settings.title.\(state.chrome.destination.rawValue)")
        pageTitle.setAccessibilityValue(state.chrome.title)
        pageTitle.sizeToFit()
        guard isViewLoaded else { return }
        sidebarController.update(state)
        if navigationControl.segmentCount == 2 {
            let l10n = ClaudioL10n(language: state.language)
            for (index, item) in [
                ("chevron.backward", l10n.text(.settingsNavigationBack), state.chrome.canGoBack),
                (
                    "chevron.forward", l10n.text(.settingsNavigationForward),
                    state.chrome.canGoForward
                ),
            ].enumerated() {
                navigationControl.setImage(
                    NSImage(systemSymbolName: item.0, accessibilityDescription: item.1),
                    forSegment: index)
                navigationControl.setToolTip(item.1, forSegment: index)
                navigationControl.setEnabled(item.2, forSegment: index)
            }
        }
        scheduleRestoration()
    }

    private func scheduleRestoration() {
        guard !restorationScheduled else { return }
        restorationScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.restorationScheduled = false
                self.applyRestoration()
            }
        }
    }

    private func applyRestoration() {
        guard let request = session.state.navigationRestoration,
            request.stamp == session.navigationHistory.stamp,
            request.stamp == session.renderedNavigationStamp,
            let window = view.window, window.isKeyWindow, window.attachedSheet == nil,
            session.state.chrome.navigationEnabled
        else { return }
        contentController.view.layoutSubtreeIfNeeded()
        if request.focus == .sidebar {
            sidebarController.focusSelection()
        } else if session.state.routeResolution.failure != nil {
            _ = session.send(.restoreFailureFocus(request.stamp))
        } else if request.focus == .restore {
            restoreScroll(request.bookmark)
            if request.bookmark.focusIdentifier?.hasPrefix("settings.sidebar.") == true {
                sidebarController.focusSelection()
            } else if let identifier = request.bookmark.focusIdentifier,
                let target = contentController.view.settingsDescendants.first(where: {
                    $0.accessibilityIdentifier() == identifier && $0.acceptsFirstResponder
                })
            {
                window.makeFirstResponder(target)
            } else {
                focusFirstContentTarget(window: window)
            }
        } else if window.firstResponder === navigationControl || window.firstResponder === window
            || window.firstResponder === sidebarController.table
        {
            focusFirstContentTarget(window: window)
        }
        _ = session.send(.acknowledgeRestoration(request.stamp))
    }

    private func focusFirstContentTarget(window: NSWindow) {
        if let control = contentController.view.settingsDescendants.first(where: {
            $0.acceptsFirstResponder && !$0.isHiddenOrHasHiddenAncestor
                && (($0 as? NSControl)?.isEnabled == true || $0.accessibilityRole() == .radioButton)
        }) {
            window.makeFirstResponder(control)
        }
    }

    private var readingScrollView: NSScrollView? {
        contentController.view.settingsDescendants.compactMap { $0 as? NSScrollView }
            .max { $0.bounds.height < $1.bounds.height }
    }

    private func rememberContentFocus() {
        guard let responder = view.window?.firstResponder as? NSView,
            responder.isDescendant(of: contentController.view)
        else { return }
        var candidate: NSView? = responder
        while let current = candidate, current !== contentController.view {
            let identifier = current.accessibilityIdentifier()
            if !identifier.isEmpty {
                lastContentFocusIdentifier = identifier
                break
            }
            candidate = current.superview
        }
    }

    private func captureReadingPosition() -> SettingsReadingBookmark {
        rememberContentFocus()
        let sidebarFocus = "settings.sidebar.\(session.state.chrome.destination.rawValue)"
        let focus =
            view.window?.firstResponder === sidebarController.table
            ? sidebarFocus : (lastContentFocusIdentifier ?? sidebarFocus)
        guard let scroll = readingScrollView, let document = scroll.documentView else {
            return .init(focusIdentifier: focus)
        }
        let offset = scroll.contentView.bounds.minY
        let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
        let anchor = document.settingsReadingAnchors.first { candidate in
            let frame = document.convert(candidate.bounds, from: candidate)
            return frame.minY >= offset && frame.minY <= offset + scroll.contentView.bounds.height
        }
        return .init(
            focusIdentifier: focus, scrollAnchorIdentifier: anchor?.accessibilityIdentifier(),
            anchorOffset: anchor.map { Double(offset - document.convert($0.bounds, from: $0).minY) }
                ?? 0,
            relativeScrollPosition: maximum > 0 ? Double(offset / maximum) : 0)
    }

    private func restoreScroll(_ bookmark: SettingsReadingBookmark) {
        guard let scroll = readingScrollView, let document = scroll.documentView else { return }
        let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
        var offset = CGFloat(bookmark.relativeScrollPosition) * maximum
        if let identifier = bookmark.scrollAnchorIdentifier,
            let anchor = document.settingsReadingAnchors.first(where: {
                $0.accessibilityIdentifier() == identifier
            })
        {
            offset =
                document.convert(anchor.bounds, from: anchor).minY + CGFloat(bookmark.anchorOffset)
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, offset))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

@MainActor
private final class SettingsSafeAreaContentController: NSViewController {
    private let content: NSViewController
    init(content: NSViewController) {
        self.content = content; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = NSView()
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

extension NSView {
    fileprivate var settingsDescendants: [NSView] {
        [self] + subviews.flatMap(\.settingsDescendants)
    }

    fileprivate var settingsReadingAnchors: [NSView] {
        let candidates = settingsDescendants.filter {
            let identifier = $0.accessibilityIdentifier()
            return !identifier.isEmpty && !identifier.hasPrefix("settings.semantic-surface.")
        }
        let identifiers = Dictionary(grouping: candidates) { $0.accessibilityIdentifier() }
        // Decoration names describe roles, and repeated identifiers cannot identify one anchor.
        // Both capture and restore use the normalized fallback when no unique semantic view exists.
        return candidates.filter { identifiers[$0.accessibilityIdentifier()]?.count == 1 }
    }
}
