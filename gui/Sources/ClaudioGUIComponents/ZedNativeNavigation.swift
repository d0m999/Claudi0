import AppKit
import ApplicationServices
import Carbon
import ClaudioCore
import ClaudioGUICore
import Darwin
import Foundation
import Security

/// Request-local native handles. Never guesses a window from its title or project directory.
@MainActor
final class ZedNativeNavigation {
    private let application: SourceApplicationTarget
    private let ax: AXUIElement
    private let current: @MainActor () -> Bool
    private let deadline: TimeInterval
    private var handles: [(UUID, AXUIElement)] = []
    private var selected: AXUIElement?
    private var inputMonitor: ZedNavigationInputMonitor?
    private let marker = Int64.random(in: 1...Int64.max)
    private(set) var failureReason: String?

    init?(
        application: SourceApplicationTarget, deadline: TimeInterval,
        current: @escaping @MainActor () -> Bool,
        onFailure: (String) -> Void
    ) {
        guard current() else { onFailure("initial_request_invalid"); return nil }
        if let reason = Self.blockingReason(application) { onFailure(reason); return nil }
        self.application = application; self.deadline = deadline; self.current = current
        ax = AXUIElementCreateApplication(application.process.pid)
        guard prepareMessaging(ax) else { onFailure("native_deadline"); return nil }
        var windowValue: CFTypeRef?
        let windowError = AXUIElementCopyAttributeValue(
            ax, kAXWindowsAttribute as CFString, &windowValue)
        guard windowError == .success, let windows = windowValue as? [AXUIElement] else {
            onFailure("ax_windows_error_\(windowError.rawValue)"); return nil
        }
        guard !windows.isEmpty, windows.count <= 4 else {
            onFailure(windows.isEmpty ? "ax_windows_empty" : "ax_window_limit"); return nil
        }
        for window in windows {
            guard attribute(window, kAXRoleAttribute) as? String == kAXWindowRole,
                attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
            else { continue }
            if !handles.contains(where: { CFEqual($0.1, window) }) {
                handles.append((UUID(), window))
            }
        }
        guard isCurrent, !handles.isEmpty else {
            onFailure(stopReason ?? "standard_windows_missing"); return nil
        }
        inputMonitor = ZedNavigationInputMonitor(marker: marker)
        guard inputMonitor != nil else { onFailure("input_monitor_unavailable"); return nil }
    }

    var isCurrent: Bool {
        inputMonitor?.interfered != true && !Task.isCancelled && current()
            && ProcessInfo.processInfo.systemUptime < deadline
    }
    var stopReason: String? {
        if inputMonitor?.interfered == true { return "native_input_interference" }
        if Task.isCancelled { return "native_task_cancelled" }
        if !current() { return "native_request_superseded" }
        if ProcessInfo.processInfo.systemUptime >= deadline { return "native_deadline" }
        return nil
    }
    var windows: [UUID] { handles.map(\.0) }
    var supportsDirections: Bool { Self.managedDirections() }
    func stop() {
        inputMonitor?.stop()
        inputMonitor = nil; handles.removeAll(); selected = nil
    }

    func isWindowCurrent(_ id: UUID) -> Bool {
        guard isCurrent else { failureReason = stopReason; return false }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.process.pid
        else { failureReason = "source_not_frontmost"; return false }
        guard let window = handles.first(where: { $0.0 == id })?.1 else {
            failureReason = "window_handle_unavailable"; return false
        }
        var focused: CFTypeRef?
        guard prepareMessaging(ax) else { failureReason = stopReason; return false }
        let error = AXUIElementCopyAttributeValue(
            ax, kAXFocusedWindowAttribute as CFString, &focused)
        guard error == .success, let focused else {
            failureReason = "focused_window_error_\(error.rawValue)"; return false
        }
        guard isCurrent else { failureReason = stopReason; return false }
        if !CFEqual(focused, window) { failureReason = "different_window_focused"; return false }
        failureReason = nil
        return true
    }

    func selectWindow(_ id: UUID) async -> Bool {
        failureReason = "window_selection_precondition"
        guard isCurrent, Self.defaultBindings(application.process.pid),
            let window = handles.first(where: { $0.0 == id })?.1,
            let app = NSRunningApplication(processIdentifier: application.process.pid)
        else { return false }
        selected = window
        if attribute(window, kAXMinimizedAttribute) as? Bool == true {
            failureReason = "window_unminimize_failed"
            guard prepareMessaging(window),
                AXUIElementSetAttributeValue(
                    window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
            else { return false }
        }
        return await ZedWindowSelection.select(
            deadline: deadline,
            environment: ZedWindowSelection.Environment(
                now: { ProcessInfo.processInfo.systemUptime }, isCurrent: { self.isCurrent },
                activate: {
                    self.failureReason = "application_activation_failed"
                    return app.activate(options: [])
                },
                raise: {
                    guard self.prepareMessaging(window) else { return .unavailable }
                    _ = AXUIElementSetAttributeValue(
                        window, kAXMainAttribute as CFString, kCFBooleanTrue)
                    guard self.prepareMessaging(window) else { return .unavailable }
                    let error = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    self.failureReason = "window_raise_error_\(error.rawValue)"
                    switch error {
                    case .success: return .dispatched
                    case .cannotComplete: return .indeterminate
                    default: return .unavailable
                    }
                },
                isSelected: { self.isWindowCurrent(id) },
                pause: { interval in
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }))
    }

    func step(_ action: ZedNavigationSearch.Step) async -> Bool {
        failureReason = "step_precondition"
        guard isCurrent, AXIsProcessTrusted(), CGPreflightPostEventAccess(),
            Self.defaultBindings(application.process.pid), let selected,
            let focused = attribute(ax, kAXFocusedWindowAttribute), CFEqual(focused, selected),
            NSWorkspace.shared.frontmostApplication?.processIdentifier == application.process.pid
        else { return false }
        failureReason = "event_preparation_failed"
        if action == .nextTab { return post([124], flags: [.maskCommand, .maskAlternate]) }
        failureReason = "pane_bindings_unavailable"
        guard Self.managedDirections(), let key = ZedNavigationBindings.directionKey(action) else {
            return false
        }
        return post([key], flags: [.maskControl, .maskAlternate, .maskCommand, .maskShift])
    }

    private func post(_ keys: [CGKeyCode], flags: CGEventFlags) -> Bool {
        guard isCurrent, let source = CGEventSource(stateID: .privateState) else { return false }
        var events: [CGEvent] = []
        for key in keys {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            else { return false }
            events.append(contentsOf: [down, up])
        }
        // Prepare the entire fixed chord and check its budget before enqueueing. No
        // fallible preparation, file read or suspension occurs between its two keys.
        guard isCurrent else { return false }
        for event in events {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.postToPid(application.process.pid)
        }
        failureReason = nil
        return true
    }

    /// AX IPC can need more than 40 ms even for a read. Every call remains bounded by the
    /// original request deadline, and callers revalidate after its synchronous completion.
    private func prepareMessaging(_ element: AXUIElement) -> Bool {
        guard isCurrent else { return false }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        return AXUIElementSetMessagingTimeout(element, Float(min(0.25, remaining))) == .success
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard prepareMessaging(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            isCurrent
        else {
            return nil
        }
        return value
    }

    static func blockingReason(_ application: SourceApplicationTarget) -> String? {
        if !AXIsProcessTrusted() { return "accessibility_not_granted" }
        if !CGPreflightPostEventAccess() { return "event_posting_not_granted" }
        if !officialSupportedBuild(application) { return "unsupported_zed_build" }
        if !defaultBindings(application.process.pid) { return "unsupported_bindings" }
        return nil
    }

    private static func officialSupportedBuild(_ application: SourceApplicationTarget) -> Bool {
        guard application.bundleIdentifier == "dev.zed.Zed",
            let bundle = Bundle(url: application.applicationURL),
            bundle.infoDictionary?["CFBundleShortVersionString"] as? String == "1.23.2"
        else { return false }
        var code: SecStaticCode?, requirement: SecRequirement?
        let rule =
            "anchor apple generic and identifier \"dev.zed.Zed\" and certificate leaf[subject.OU] = \"MQ55VZLNZQ\""
        guard
            SecStaticCodeCreateWithPath(application.applicationURL as CFURL, [], &code)
                == errSecSuccess,
            SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
            let code, let requirement
        else { return false }
        return SecStaticCodeCheckValidity(
            code, SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate)),
            requirement) == errSecSuccess
    }

    /// v1.23.2 inherits tab-next in all bundled base maps except None. Its Terminal cmd-k
    /// clears the screen, so directions require the exact explicit experiment keymap.
    /// Other custom keymaps/directories, unreadable settings or unknown layouts are unsupported.
    private static func defaultBindings(_ pid: Int32) -> Bool {
        guard standardConfiguration(pid),
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return false }
        let layout = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        guard ["com.apple.keylayout.ABC", "com.apple.keylayout.US"].contains(layout) else {
            return false
        }
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".config/zed")
        var info = stat()
        if lstat(config.appendingPathComponent("keymap.json").path, &info) == 0 {
            guard managedDirections() else { return false }
        } else if errno != ENOENT {
            return false
        }
        for name in ["settings.json", "global_settings.json"] {
            let url = config.appendingPathComponent(name)
            if lstat(url.path, &info) != 0 { if errno == ENOENT { continue }; return false }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                case .success(let data) = readRegularFileBounded(
                    at: url, maxBytes: 131072, followSymlink: false),
                let settings = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed)
                    as? [String: Any]
            else { return false }
            if let base = settings["base_keymap"] {
                guard let value = base as? String,
                    [
                        "Zed", "VSCode", "JetBrains", "SublimeText", "Atom", "TextMate", "Emacs",
                        "Cursor",
                    ].contains(value)
                else { return false }
            }
        }
        return true
    }

    private static func managedDirections() -> Bool {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".config/zed/keymap.json")
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == getuid(),
            case .success(let data) = readRegularFileBounded(
                at: file, maxBytes: 8192, followSymlink: false)
        else { return false }
        return ZedNavigationBindings.hasManagedDirections(data)
    }

    /// Bounded, transient read: only detects the config override and HOME. Never retains/logs argv
    /// or any other environment value; the process identity is separately revalidated by the adapter.
    private static func standardConfiguration(_ pid: Int32) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4, size <= 262144
        else { return false }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &bytes, &size, nil, 0) == 0 else { return false }
        bytes = Array(bytes.prefix(size))
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 256 else { return false }
        var position = 4
        func next() -> ArraySlice<UInt8>? {
            guard position < bytes.count,
                let end = bytes[position...].firstIndex(of: 0)
            else { return nil }
            let value = bytes[position..<end]; position = end + 1; return value
        }
        guard next() != nil else { return false }
        while position < bytes.count && bytes[position] == 0 { position += 1 }
        for _ in 0..<argc {
            guard let argument = next(), !argument.starts(with: Array("--user-data-dir".utf8))
            else { return false }
        }
        let expected = Array(("HOME=" + FileManager.default.homeDirectoryForCurrentUser.path).utf8)
        var matchesHome = false
        while let entry = next(), !entry.isEmpty {
            if entry.starts(with: Array("HOME=".utf8)) {
                matchesHome = entry.elementsEqual(expected)
            }
        }
        return matchesHome
    }
}
