import Foundation

@MainActor
func runEventNoticeFocusSuites() {
    suite("Event Notice：来源 App 打开失败先进入详情，原交互有效时才恢复焦点") {
        let path = guiTestRepositoryRoot().appendingPathComponent(
            "gui/Sources/ClaudioGUI/EventNoticeWindowController.swift")
        // The native controller belongs to the app executable, which this harness cannot import.
        // Check the delegate-to-callback handoff at its production call site.
        guard let source = try? String(contentsOf: path, encoding: .utf8) else {
            expect(false, "必须找到生产窗口控制器的来源 App 回调")
            return
        }
        let controller = strippingComments(source).codeWithoutStringLiterals
        guard
            let openStart = controller.range(of: "func openSourceApplication(_ action:"),
            let openEnd = controller.range(
                of: "func copySessionID(", range: openStart.upperBound..<controller.endIndex)
        else {
            expect(false, "必须找到生产窗口控制器的来源 App 回调边界")
            return
        }
        let callback = String(controller[openStart.lowerBound..<openEnd.lowerBound])
        guard
            let failed = callback.range(of: "else if outcome != .cancelled"),
            let action = callback.range(
                of: "self.model.viewSource(action)", range: failed.upperBound..<callback.endIndex),
            let reclaim = callback.range(
                of: "self.becomeInteractive()", range: action.upperBound..<callback.endIndex)
        else {
            expect(false, "失败回调必须保留明确的交互恢复路径")
            return
        }
        let failureBranch = callback[failed.lowerBound..<reclaim.lowerBound]
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        expect(
            failureBranch.contains(
                "else if outcome != .cancelled, self.model.viewSource(action) == .applied")
                && failureBranch.contains(
                    "if self.isInteractive, NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID"
                ),
            "自动非激活胶囊打开失败也须进入详情；只有原交互仍有效且前台未变化时才接管键盘")
        guard
            let resign = controller.range(of: "func windowDidResignKey("),
            let render = controller.range(
                of: "private func render(", range: resign.upperBound..<controller.endIndex)
        else {
            expect(false, "必须找到生产窗口控制器的失焦委托")
            return
        }
        let resignBody = controller[resign.lowerBound..<render.lowerBound]
        expect(
            resignBody.contains("navigation.applicationResult == .started")
                && resignBody.contains("isInteractive = false")
                && resignBody.contains("close()"),
            "来源 App 打开在途失焦要撤销交互资格，普通失焦要关闭面板")
    }
}
