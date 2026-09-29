import AppKit
import ClaudioGUIComponents

@MainActor
func runStatusItemWindowOrderGuardSuites() async {
    await suite("状态项激活保护在菜单显示后恢复普通层级") {
        _ = NSApplication.shared
        let settings = statusGuardWindow()
        let other = statusGuardWindow()
        let protection = StatusItemWindowOrderGuard(maximumDuration: 0.15)
        defer { protection.finish(restoringOrder: false); settings.close(); other.close() }
        expect(!protection.begin(window: settings), "隐藏窗口不能进入保护")
        other.presentForUserRequest()
        settings.presentForUserRequest()
        expect(protection.begin(window: settings), "可见普通窗口可以进入调用者已验证的状态项交接")
        expect(protection.isProtecting(settings), "保护保留原 key owner 身份")
        expect(!protection.isProtecting(other), "其他窗口不能共享保护身份")
        expect(settings.level.rawValue == NSWindow.Level.normal.rawValue + 1, "交接期间仅临时提升一层")
        expect(!protection.begin(window: other), "不能覆盖尚未结束的窗口交接")
        protection.finish(restoringOrder: true)
        expect(settings.level == .normal, "菜单显示后立即恢复普通层级")
        expect(!protection.isProtecting(settings), "显示完成立即消费保护状态")
        try? await Task.sleep(nanoseconds: 30_000_000)
        expect(statusGuardIsBefore(settings, other), "解除保护和原位置恢复必须在同一个显示事务提交")
        other.presentForUserRequest()
        protection.finish(restoringOrder: true)
        try? await Task.sleep(nanoseconds: 180_000_000)
        expect(statusGuardIsBefore(other, settings), "重复结束和旧超时都不能再次前置设置")
    }

    await suite("状态项回调缺失时解除保护并保留较新的窗口选择") {
        let settings = statusGuardWindow()
        let other = statusGuardWindow()
        let protection = StatusItemWindowOrderGuard(maximumDuration: 0.04)
        defer { protection.finish(restoringOrder: false); settings.close(); other.close() }
        settings.presentForUserRequest()
        expect(protection.begin(window: settings), "建立超时夹具")
        other.presentForUserRequest()
        try? await Task.sleep(nanoseconds: 100_000_000)
        expect(settings.level == .normal, "未收到菜单回调也不能遗留置顶层级")
        expect(!protection.isProtecting(settings), "超时清除原 key owner 身份")
        expect(statusGuardIsBefore(other, settings), "超时不得夺回用户已经交给另一窗口的位置")
        expect(protection.begin(window: settings), "超时后下一次交接可以重新开始")
        settings.close()
        protection.finish(restoringOrder: true)
        expect(!settings.isVisible, "保护结束不能重新显示已关闭窗口")
        expect(settings.level == .normal, "关闭窗口仍清理临时层级")
    }

    suite("状态项屏幕命中和迟到事件使用同一个坐标转换") {
        let anchorWindow = NSWindow(
            contentRect: NSRect(x: 200, y: 600, width: 100, height: 24),
            styleMask: .borderless, backing: .buffered, defer: false)
        anchorWindow.isReleasedWhenClosed = false
        let button = NSView(frame: NSRect(x: 10, y: 0, width: 22, height: 22))
        anchorWindow.contentView?.addSubview(button)
        defer { anchorWindow.close() }
        expect(
            statusItemContainsScreenPoint(NSPoint(x: 220, y: 610), button: button),
            "当前按下位置位于自己的状态按钮内")
        expect(
            !statusItemContainsScreenPoint(NSPoint(x: 280, y: 610), button: button),
            "其他状态项或桌面位置不能触发设置保护")
        button.removeFromSuperview()
        expect(
            !statusItemContainsScreenPoint(NSPoint(x: 220, y: 610), button: button),
            "没有原生锚定窗口时拒绝保护")
    }
}

@MainActor
private func statusGuardWindow() -> RetainedSettingsWindow {
    let window = RetainedSettingsWindow(
        contentRect: NSRect(x: 240, y: 240, width: 320, height: 240),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
}

@MainActor
private func statusGuardIsBefore(_ first: NSWindow, _ second: NSWindow) -> Bool {
    let order =
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? Int }
    guard let firstIndex = order.firstIndex(of: first.windowNumber),
        let secondIndex = order.firstIndex(of: second.windowNumber)
    else { return false }
    return firstIndex < secondIndex
}
