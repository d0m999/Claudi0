import AppKit
import ClaudioGUICore
import Combine
import Foundation

/// Observes native modal lifetimes; the notice model remains the only reading-budget owner.
@MainActor
package final class EventNoticeModalPauseObserver {
    private let model: EventNoticeModel
    private var subscriptions: Set<AnyCancellable> = []
    private var modalDepth: [String: Int] = [:]

    package var isPaused: Bool { modalDepth.values.contains { $0 > 0 } }

    package init(model: EventNoticeModel) {
        self.model = model
        for (name, active, kind) in [
            (Notification.Name.claudioSettingsModalWillBegin, true, "file-picker"),
            (.claudioSettingsModalDidEnd, false, "file-picker"),
            (NSWindow.willBeginSheetNotification, true, "sheet"),
            (NSWindow.didEndSheetNotification, false, "sheet"),
        ] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] notification in
                    guard let self else { return }
                    let key = kind + String((notification.object as? NSWindow)?.windowNumber ?? 0)
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

    private func releaseSheetPauses(attachedTo window: NSWindow) {
        // AppKit hides attached sheets with their closing parent without necessarily sending
        // didEndSheet. Drop only this closing tree; other sheets and modal pickers still pause.
        modalDepth["sheet" + String(window.windowNumber)] = nil
        for sheet in window.sheets { releaseSheetPauses(attachedTo: sheet) }
    }
}
