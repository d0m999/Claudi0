/// Application identity carried through the panel↔settings handback as a plain value, so the
/// ADR 0022 choreography never touches `NSRunningApplication`. The AppKit edge resolves it
/// back to the same live application instance at activation time. The launch timestamp
/// distinguishes a reused PID, including a later launch of the same bundle.
public struct PanelHandbackApplication: Equatable, Sendable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let launchTimestamp: Double?

    public init(
        processIdentifier: Int32,
        bundleIdentifier: String? = nil,
        launchTimestamp: Double? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.launchTimestamp = launchTimestamp
    }
}

/// ADR 0022 close-before-show / handback decisions for the transient panel and the retained
/// Settings window, kept free of AppKit/Foundation so the harness can drive every transition
/// with plain values. `MenuBarController` and `SettingsWindowController` own the native edges
/// (NSWindow, NSWorkspace) and drive this machine; `Request` is the queued settings intent.
///
/// Owned facts: the external application captured before the panel borrowed focus, the
/// presentation queued behind the panel's close, the one-shot panel focus target restored by
/// the Settings close callback, and the Settings key-ownership debt (via
/// ``PanelSettingsHandback``). Window-order mechanics stay in `MenuBarPanel`,
/// `RetainedSettingsWindow` and `StatusItemWindowOrderGuard`.
public struct PanelSettingsChoreography<Request> {
    /// A settings presentation and the exact handback context captured at request time.
    public struct PendingPresentation {
        public let request: Request
        public let panelFocusTarget: PanelFocusTarget?
        public let handbackApplication: PanelHandbackApplication?

        public init(
            request: Request,
            panelFocusTarget: PanelFocusTarget?,
            handbackApplication: PanelHandbackApplication?
        ) {
            self.request = request
            self.panelFocusTarget = panelFocusTarget
            self.handbackApplication = handbackApplication
        }
    }

    /// External app captured when the panel last opened; consumed by the next explicit
    /// settings presentation or discarded by an ordinary panel close.
    public private(set) var previousApplication: PanelHandbackApplication?
    /// Presentation waiting for the panel's close-before-show handoff.
    public private(set) var pendingPresentation: PendingPresentation?
    /// One-shot panel focus target delivered to the next real panel show.
    public private(set) var pendingRestoredPanelFocusTarget: PanelFocusTarget?
    private var settingsHandback = PanelSettingsHandback()

    public init() {}

    /// The panel is about to show. Records whether Settings owned key focus (explicit-close
    /// restoration debt) and captures the frontmost external application. The caller passes
    /// only non-self applications; re-showing overwrites the previous capture, matching the
    /// panel's ordinary open semantics.
    public mutating func notePanelWillShow(
        settingsWasForeground: Bool,
        frontmostApplication: PanelHandbackApplication?
    ) {
        settingsHandback.begin(settingsWasForeground: settingsWasForeground)
        if let frontmostApplication {
            previousApplication = frontmostApplication
        }
    }

    /// Close-before-show entry. An explicit handback wins over the captured previous
    /// application; the capture is consumed either way. When the panel is already closed the
    /// presentation runs immediately (returned); while the panel is shown it is queued and
    /// the caller closes the panel so ``panelDidClose(explicitDismissal:)`` delivers it.
    @discardableResult
    public mutating func requestSettingsPresentation(
        request: Request,
        returnFocusTo target: PanelFocusTarget?,
        handbackApplication explicitHandback: PanelHandbackApplication?,
        panelIsShown: Bool
    ) -> PendingPresentation? {
        let presentation = PendingPresentation(
            request: request,
            panelFocusTarget: target,
            handbackApplication: explicitHandback ?? previousApplication)
        previousApplication = nil
        guard panelIsShown else { return presentation }
        pendingPresentation = presentation
        return nil
    }

    /// What the panel's close must do next, after the caller's own hide/keyboard edges.
    public enum PanelCloseFollowUp {
        /// A queued presentation takes over: present Settings with it.
        case presentSettings(PendingPresentation)
        /// Explicit dismissal while Settings owned key focus before the panel: restore it.
        case restoreSettingsKeyFocus
        /// Outside interaction or app switch: the recipient keeps the user's new focus.
        case none
    }

    /// Sequences one panel close. A queued presentation always wins and consumes the Settings
    /// restoration debt with it; an ordinary close discards the captured application, and only
    /// an explicit dismissal may restore Settings' prior key target.
    public mutating func panelDidClose(explicitDismissal: Bool) -> PanelCloseFollowUp {
        let restoreSettings = settingsHandback.takeSettingsRestoration()
        if let presentation = pendingPresentation {
            pendingPresentation = nil
            return .presentSettings(presentation)
        }
        previousApplication = nil
        return explicitDismissal && restoreSettings ? .restoreSettingsKeyFocus : .none
    }

    /// What the retained Settings window's close callback must do with its handback debt.
    public enum SettingsCloseHandback {
        /// Reopen the panel at the exact trigger that opened Settings. As a side effect the
        /// resolved handback application becomes the new captured previous application and the
        /// target waits for the next real panel show.
        case restorePanelFocus(PanelFocusTarget)
        /// No panel destination: return activation to the resolved application, if any.
        case activateApplication(PanelHandbackApplication?)
    }

    /// Resolves the Settings close callback. The latest activation observed while Settings was
    /// visible wins over the application captured when the presentation was requested.
    public mutating func resolveSettingsCloseHandback(
        panelFocusTarget: PanelFocusTarget?,
        presentationHandback: PanelHandbackApplication?,
        latestHandbackApplication: PanelHandbackApplication?
    ) -> SettingsCloseHandback {
        let handback = latestHandbackApplication ?? presentationHandback
        guard let target = panelFocusTarget else {
            return .activateApplication(handback)
        }
        if let handback {
            previousApplication = handback
        }
        pendingRestoredPanelFocusTarget = target
        return .restorePanelFocus(target)
    }

    /// Consumes the restored panel focus target exactly once, at the next real panel show.
    public mutating func consumeRestoredPanelFocusTarget() -> PanelFocusTarget? {
        defer { pendingRestoredPanelFocusTarget = nil }
        return pendingRestoredPanelFocusTarget
    }
}

/// Resolves a handback identity to the same live application instance at activation time.
/// Unknown launch identity, reused PIDs and the current process all fail closed.
public func resolvePanelHandbackApplication<Application>(
    _ identity: PanelHandbackApplication?,
    currentProcessIdentifier: Int32,
    lookup: (Int32) -> Application?,
    identityOf: (Application) -> PanelHandbackApplication
) -> Application? {
    guard let identity, identity.processIdentifier > 0,
        identity.processIdentifier != currentProcessIdentifier,
        let launchTimestamp = identity.launchTimestamp, launchTimestamp.isFinite,
        let application = lookup(identity.processIdentifier),
        identityOf(application) == identity
    else {
        return nil
    }
    return application
}

/// ADR 0022 status-item protection starts only when all three current facts hold: Settings
/// (or its sheet) still owns native key, the primary mouse button is down, and the press hit
/// this app's status button. Background Settings never enters the guard.
public func panelSettingsShouldProtectDuringStatusActivation(
    settingsOwnsKeyFocus: Bool,
    primaryMouseButtonDown: Bool,
    statusItemHit: Bool
) -> Bool {
    settingsOwnsKeyFocus && primaryMouseButtonDown && statusItemHit
}
