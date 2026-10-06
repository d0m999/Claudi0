import SwiftUI

// The harness locates mounted content by the same stable identities as accessibility.
// The marker observes geometry only: clicks still travel through the window and SwiftUI Button.
extension View {
    @MainActor
    func eventReaderActionIdentity(_ identifier: String) -> some View {
        accessibilityIdentifier(identifier).eventReaderTestProbe(identifier)
    }

    @MainActor
    func eventReaderTestProbe(_ identifier: String, value: String? = nil) -> some View {
        #if DEBUG
        background {
            if EventNoticeReaderTestProbe.isRecording {
                EventNoticeReaderTestMarker(identifier: identifier, value: value)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        #else
        self
        #endif
    }
}

#if DEBUG
import AppKit

@MainActor
package enum EventNoticeReaderTestProbe {
    private struct Marker {
        let view: NSView
        let identifier: String
        let value: String?
    }

    package private(set) static var isRecording = false
    private static var markers: [ObjectIdentifier: Marker] = [:]

    package static func start() {
        markers.removeAll()
        isRecording = true
    }

    package static func stop() {
        isRecording = false
        markers.removeAll()
    }

    package static func identifiers(in window: NSWindow) -> Set<String> {
        Set(markers.values.filter { $0.view.window === window }.map(\.identifier))
    }

    package static func view(_ identifier: String, in window: NSWindow) -> NSView? {
        matching(identifier, in: window)?.view
    }

    package static func value(_ identifier: String, in window: NSWindow) -> String? {
        matching(identifier, in: window)?.value
    }

    private static func matching(_ identifier: String, in window: NSWindow) -> Marker? {
        let matches = markers.values.filter {
            $0.identifier == identifier && $0.view.window === window
        }
        return matches.count == 1 ? matches.first : nil
    }

    fileprivate static func record(_ view: NSView, identifier: String, value: String?) {
        guard isRecording else { return }
        markers[ObjectIdentifier(view)] = Marker(view: view, identifier: identifier, value: value)
    }

    fileprivate static func remove(_ view: NSView) {
        markers.removeValue(forKey: ObjectIdentifier(view))
    }
}

private struct EventNoticeReaderTestMarker: NSViewRepresentable {
    let identifier: String
    let value: String?

    func makeNSView(context: Context) -> NSView {
        let view = EventNoticeReaderMarkerView()
        view.setAccessibilityElement(false)
        EventNoticeReaderTestProbe.record(view, identifier: identifier, value: value)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        EventNoticeReaderTestProbe.record(view, identifier: identifier, value: value)
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        EventNoticeReaderTestProbe.remove(view)
    }
}

private final class EventNoticeReaderMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
