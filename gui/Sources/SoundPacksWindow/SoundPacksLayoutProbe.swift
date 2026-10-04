import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    package func soundPacksLayoutProbe(_ identifier: String) -> some View {
        #if DEBUG
        background(SoundPacksLayoutReportingView(identifier: identifier))
        #else
        self
        #endif
    }
}

#if DEBUG
@MainActor
package enum SoundPacksLayoutRecorder {
    private static var cachedFrames: [String: CGRect] = [:]
    private static var sources: [String: NativeLayoutSource] = [:]

    /// Ancestors can move after a toolbar/safe-area or localized intrinsic-size update
    /// without invoking a reporting child's layout again. Read live window coordinates.
    package static var frames: [String: CGRect] {
        var result = cachedFrames
        for (identifier, source) in sources {
            guard let view = source.view, let content = view.window?.contentView else {
                result.removeValue(forKey: identifier)
                continue
            }
            result[identifier] = windowFrame(view, bounds: source.bounds, content: content)
        }
        return result
    }

    package static func reset() {
        cachedFrames.removeAll()
        sources.removeAll()
    }

    package static func record(_ identifier: String, frame: CGRect) {
        cachedFrames[identifier] = frame
    }

    fileprivate static func forget(_ identifier: String, view: NSView) {
        guard sources[identifier]?.identity == ObjectIdentifier(view) else { return }
        cachedFrames.removeValue(forKey: identifier)
        sources.removeValue(forKey: identifier)
    }

    package static func recordNative(_ identifier: String, view: NSView, bounds: CGRect? = nil) {
        guard let content = view.window?.contentView else { return }
        record(identifier, frame: windowFrame(view, bounds: bounds, content: content))
        sources[identifier] = NativeLayoutSource(view: view, bounds: bounds)
    }

    private static func windowFrame(_ view: NSView, bounds: CGRect?, content: NSView) -> CGRect {
        var frame = view.convert(bounds ?? view.bounds, to: content)
        if !content.isFlipped { frame.origin.y = content.bounds.maxY - frame.maxY }
        return frame
    }
}

@MainActor
private final class NativeLayoutSource {
    weak var view: NSView?
    let identity: ObjectIdentifier
    let bounds: CGRect?

    init(view: NSView, bounds: CGRect?) {
        self.view = view
        identity = ObjectIdentifier(view)
        self.bounds = bounds
    }
}

private struct SoundPacksLayoutReportingView: NSViewRepresentable {
    let identifier: String

    func makeNSView(context _: Context) -> SoundPacksLayoutReportingNSView {
        SoundPacksLayoutReportingNSView(identifier: identifier)
    }

    func updateNSView(_ view: SoundPacksLayoutReportingNSView, context _: Context) {
        if view.probeIdentifier != identifier {
            SoundPacksLayoutRecorder.forget(view.probeIdentifier, view: view)
        }
        view.probeIdentifier = identifier
        view.needsLayout = true
    }
}

private final class SoundPacksLayoutReportingNSView: NSView {
    var probeIdentifier: String

    init(identifier: String) {
        probeIdentifier = identifier
        super.init(frame: .zero)
        setAccessibilityElement(false)
        setAccessibilityIdentifier(identifier)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        SoundPacksLayoutRecorder.recordNative(probeIdentifier, view: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { SoundPacksLayoutRecorder.forget(probeIdentifier, view: self) }
        needsLayout = true
    }
}
#endif
