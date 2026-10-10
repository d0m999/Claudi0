import AppKit
import Darwin

/// Request-local input observation; native dispatches carry the request's marker.
@MainActor
final class ZedNavigationInputMonitor {
    private let marker: Int64
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var stopped = false
    private(set) var interfered = false

    init?(marker: Int64) {
        self.marker = marker
        let events: NSEvent.EventTypeMask = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: events
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
        }
        guard globalMonitor != nil else { return nil }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
        guard localMonitor != nil else { stop(); return nil }
    }

    func observe(_ event: NSEvent) {
        guard !stopped else { return }
        if let cg = event.cgEvent, cg.getIntegerValueField(.eventSourceUserData) == marker,
            cg.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
        {
            return
        }
        interfered = true
    }

    func stop() {
        stopped = true
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
