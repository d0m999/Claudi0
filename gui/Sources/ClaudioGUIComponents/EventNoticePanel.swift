import AppKit

/// Borderless panels cannot become key by default. Only the explicit interaction path grants
/// that capability; automatic arrival stays nonactivating and cannot interrupt an input method.
@MainActor
public final class EventNoticePanel: NSPanel {
    public var allowsKeyboardInteraction = false
    public var onEscape: (@MainActor () -> Void)?
    public override var canBecomeKey: Bool { allowsKeyboardInteraction }
    public override var canBecomeMain: Bool { false }

    public override func cancelOperation(_ sender: Any?) {
        guard allowsKeyboardInteraction else { return }
        onEscape?()
    }
}
