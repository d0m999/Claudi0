import AppKit
import ClaudioGUICore
import Combine
import Foundation

/// Only sheets owned by the notice window pause its reading budget. Settings has an
/// independent modal lifetime; the notice model remains the only reading-budget owner.
@MainActor
package final class EventNoticeModalPauseObserver {
    private let model: EventNoticeModel
    private weak var owner: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var modalDepth: [String: Int] = [:]

    package var isPaused: Bool { modalDepth.values.contains { $0 > 0 } }

    package init(model: EventNoticeModel, owner: NSWindow) {
        self.model = model
        self.owner = owner
        for (name, active, kind) in [
            (NSWindow.willBeginSheetNotification, true, "sheet"),
            (NSWindow.didEndSheetNotification, false, "sheet"),
        ] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] notification in
                    guard let self, let window = notification.object as? NSWindow else { return }
                    let key = kind + String(window.windowNumber)
                    guard active ? self.owns(window) : self.modalDepth[key] != nil else { return }
                    let depth = max(0, (self.modalDepth[key] ?? 0) + (active ? 1 : -1))
                    self.modalDepth[key] = depth > 0 ? depth : nil
                    self.model.setPauseReason(.modal, active: self.isPaused)
                }
                .store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] notification in
                guard let self, let window = notification.object as? NSWindow else { return }
                self.releaseSheetPauses(attachedTo: window)
                self.model.setPauseReason(.modal, active: self.isPaused)
            }
            .store(in: &subscriptions)
    }

    private func owns(_ window: NSWindow) -> Bool {
        var ancestor: NSWindow? = window
        while let current = ancestor {
            if current === owner { return true }
            ancestor = current.sheetParent
        }
        return false
    }

    private func releaseSheetPauses(attachedTo window: NSWindow) {
        // AppKit hides attached sheets with their closing parent without necessarily sending
        // didEndSheet. Drop only this tracked tree; hover and focus remain model-owned.
        modalDepth["sheet" + String(window.windowNumber)] = nil
        for sheet in window.sheets { releaseSheetPauses(attachedTo: sheet) }
    }
}
