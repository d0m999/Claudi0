import Foundation

@MainActor
func runEventNoticeFocusSuites() {
    suite("Event Notice：来源 App 失败就地反馈，成功不抢回焦点") {
        let path = guiTestRepositoryRoot().appendingPathComponent(
            "gui/Sources/ClaudioGUI/EventNoticeWindowController.swift")
        // The native controller belongs to the app executable, which this harness cannot import.
        // Check the delegate-to-callback handoff at its production call site.
        guard let source = try? String(contentsOf: path, encoding: .utf8) else {
            expect(false, "必须找到生产窗口控制器的来源 App 回调")
            return
        }
        let controller = strippingComments(source).codeWithoutStringLiterals
        expect(
            controller.contains("window.onEscape = { [weak self] in self?.close() }"),
            "原生取消命令调用同一个关闭和取消所属请求入口")
        guard
            let openStart = controller.range(of: "func openSourceApplication(_ action:"),
            let openEnd = controller.range(
                of: "func copySessionID(", range: openStart.upperBound..<controller.endIndex)
        else {
            expect(false, "必须找到生产窗口控制器的来源 App 回调边界")
            return
        }
        let callback = String(controller[openStart.lowerBound..<openEnd.lowerBound])
        expect(
            !callback.contains("self.model.viewSource(action)")
                && !callback.contains("self.becomeInteractive()"), "失败在横幅就地反馈，不抢回键盘或进入详情")
        expect(
            callback.contains("navigation.navigateSource(")
                && callback.contains("self.releaseInteraction()")
                && callback.contains(
                    "[.exactReturnConfirmed, .applicationFallback, .requestSent].contains(outcome)"),
            "三类成功均消费焦点归还责任，只有协调器精确确认收起横幅")
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
            resignBody.contains("navigation.permitsFocusHandoff(")
                && resignBody.contains("Task { @MainActor")
                && resignBody.contains("navigation.isNavigating")
                && resignBody.contains("releaseInteraction()")
                && resignBody.contains("close()"),
            "预期交接释放焦点；在途主动切走取消，普通失焦关闭")
    }
}
