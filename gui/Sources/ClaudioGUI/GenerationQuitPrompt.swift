import AppKit
import ClaudioGUICore
import ClaudioLocalization

/// Retained native alert, without a blocking runModal loop. Generation completion continues on
/// MainActor while the user decides. A settings window uses a sheet; otherwise only the alert's
/// own dialog is shown, never a second settings window.
@MainActor
final class GenerationQuitPrompt: NSObject, NSWindowDelegate {
    private let alert = NSAlert()
    private var completion: ((Bool) -> Void)?
    private var isSheet = false

    init(reason: AICueTerminationReason, language: ClaudioAppLanguage) {
        let l10n = ClaudioL10n(language: language)
        super.init()
        alert.alertStyle = .warning
        alert.messageText = l10n.text(
            reason == .generating ? .soundsQuitGenerating : .soundsQuitUnsaved)
        alert.addButton(withTitle: l10n.text(.soundsKeepWaiting))
        alert.addButton(
            withTitle: l10n.text(reason == .generating ? .soundsQuit : .soundsQuitAnyway))
    }

    func show(attachedTo parent: NSWindow?, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        if let parent, parent.isVisible {
            isSheet = true
            alert.beginSheetModal(for: parent.attachedSheet ?? parent) { [weak self] response in
                self?.finish(response == .alertSecondButtonReturn)
            }
        } else {
            alert.layout()
            alert.window.delegate = self
            alert.buttons[0].target = self
            alert.buttons[0].action = #selector(stay)
            alert.buttons[0].keyEquivalent = "\r"
            alert.buttons[1].target = self
            alert.buttons[1].action = #selector(quit)
            alert.window.center()
            alert.window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func stay() { finish(false) }
    @objc private func quit() { finish(true) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(false); return true }

    private func finish(_ quit: Bool) {
        guard let completion else { return }
        self.completion = nil
        if !isSheet { alert.window.orderOut(nil) }
        completion(quit)
    }
}
