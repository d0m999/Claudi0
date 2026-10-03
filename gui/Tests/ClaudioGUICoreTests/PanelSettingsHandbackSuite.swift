import AppKit
import ClaudioGUIComponents
import ClaudioGUICore
import Foundation

@MainActor
func runPanelSettingsHandbackSuites() async {
    suite("菜单与 Settings 从创建起就是非激活窗口") {
        _ = NSApplication.shared
        let settings = focusTestSettingsWindow()
        let panel = MenuBarPanel()
        defer { settings.close(); panel.close() }
        expect(settings.styleMask.contains(.nonactivatingPanel), "Settings 必须从初始化就具有非激活样式")
        expect(panel.styleMask.contains(.nonactivatingPanel), "菜单必须从初始化就具有非激活样式")
        expect(settings.canBecomeKey && panel.canBecomeKey, "两个窗口都必须能独立接收键盘")
        expect(!settings.canBecomeMain && !panel.canBecomeMain, "窗口不能被应用 main-window 激活联动")
        expect(!settings.hidesOnDeactivate && !panel.hidesOnDeactivate, "应用退激活不能隐式隐藏设置或菜单")
        expect(settings.level == .normal, "设置维持普通窗口层级，不能变成置顶窗口")
        settings.defersAutomaticFocusForPanel = true
        expect(!settings.canBecomeKey, "后台设置不参与菜单关闭后的自动 key 选择")
        settings.defersAutomaticFocusForPanel = false
        expect(settings.canBecomeKey, "菜单交互结束后恢复设置的键盘资格")
    }

    await suite("真实 NSPanel 打开和取消保持普通窗口顺序") {
        _ = NSApplication.shared
        let settings = focusTestSettingsWindow()
        let other = focusTestSettingsWindow()
        let anchorWindow = NSWindow(
            contentRect: NSRect(x: 200, y: 700, width: 28, height: 24),
            styleMask: .borderless, backing: .buffered, defer: false)
        anchorWindow.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        anchorWindow.contentView = anchor
        let panel = MenuBarPanel()
        panel.contentSize = NSSize(width: 120, height: 100)
        var shows = 0
        var closes: [MenuBarPanel.Dismissal] = []
        panel.onShow = { shows += 1 }
        panel.onClose = { closes.append($0) }
        defer {
            panel.onClose = nil
            panel.close()
            settings.close()
            other.close()
            anchorWindow.close()
        }

        for settingsIsFront in [true, false] {
            other.presentForUserRequest()
            settings.presentForUserRequest()
            if !settingsIsFront { other.presentForUserRequest() }
            try? await Task.sleep(nanoseconds: 50_000_000)
            let ownedKey = settingsWindowOwnsKeyFocus(settings, keyWindow: NSApp.keyWindow)
            expect(ownedKey == settingsIsFront, "夹具必须分别建立前台和后台设置")
            settings.defersAutomaticFocusForPanel = !ownedKey
            var handback = PanelSettingsHandback()
            handback.begin(settingsWasForeground: ownedKey)
            let before = focusTestNormalWindowOrder()
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            panel.show(relativeTo: anchor.bounds, of: anchor)
            try? await Task.sleep(nanoseconds: 50_000_000)
            expect(panel.isShown && panel.isKeyWindow, "真实非激活菜单必须可见且持有 key")
            NotificationCenter.default.post(
                name: NSApplication.didResignActiveNotification, object: NSApp)
            expect(panel.isShown, "应用退激活不等于非激活菜单失去键盘")
            expect(
                NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost,
                "菜单取得键盘不能切换前台应用")
            expect(
                focusTestSameWindowOrder(before, focusTestNormalWindowOrder()),
                "菜单打开后普通窗口必须保留原顺序")
            panel.cancelOperation(nil)
            try? await Task.sleep(nanoseconds: 50_000_000)
            expect(!panel.isShown, "Esc responder 路径必须收起菜单")
            expect(
                focusTestSameWindowOrder(before, focusTestNormalWindowOrder()),
                "菜单关闭后普通窗口顺序必须保持不变")
            settings.defersAutomaticFocusForPanel = false
            if handback.takeSettingsRestoration() { settings.makeKey() }
            expect(
                focusTestSameWindowOrder(before, focusTestNormalWindowOrder()),
                "设置的键盘归还不能改变窗口顺序")
            expect(
                NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost,
                "收起菜单后不能激活其他应用")
        }
        expect(shows == 2 && closes == [.explicit, .explicit], "每次展示和关闭只发出一次生命周期信号")
        panel.close()
        expect(closes.count == 2, "重复关闭不能重复归还焦点")
        panel.show(relativeTo: anchor.bounds, of: anchor)
        expect(panel.accessibilityPerformCancel(), "菜单必须暴露可访问性取消动作")
        expect(closes.last == .explicit, "可访问性取消与 Esc 使用同一关闭路径")
        panel.show(relativeTo: anchor.bounds, of: anchor)
        panel.dismiss(.outsideInteraction)
        expect(closes.last == .outsideInteraction, "主动点击外部窗口必须与 Esc 区分")
        panel.show(relativeTo: anchor.bounds, of: anchor)
        let child = focusTestSettingsWindow()
        panel.addChildWindow(child, ordered: .above)
        child.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 20_000_000)
        expect(panel.isShown, "菜单子窗口借用 key 不得关闭菜单")
        panel.makeKey()
        panel.removeChildWindow(child)
        child.close()
        other.makeKey()
        let focusDeadline = Date().addingTimeInterval(0.5)
        while panel.isShown && Date() < focusDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(!panel.isShown && closes.last == .outsideInteraction, "键盘真正离开菜单树时收起菜单")
        settings.presentForUserRequest()
        let beforeOutsideClick = focusTestNormalWindowOrder()
        panel.show(relativeTo: anchor.bounds, of: anchor)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 50, y: 50), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: settings.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
            NSApp.sendEvent(event)
        }
        expect(!panel.isShown && closes.last == .outsideInteraction, "真实点外鼠标事件必须经本地监视器收起菜单")
        expect(
            focusTestSameWindowOrder(beforeOutsideClick, focusTestNormalWindowOrder()),
            "点击前台设置的空白处收起菜单时保持原有普通窗口顺序")
        expect(settings.accessibilityPerformRaise(), "显式辅助功能 Raise 必须前置设置")
        expect(settings.isKeyWindow, "主动前置设置后必须拥有键盘焦点")
    }

    await suite("菜单打开期间显式 Settings 请求解除自动焦点抑制") {
        for performRaise in [true, false] {
            let settings = focusTestSettingsWindow()
            let other = focusTestSettingsWindow()
            let anchorWindow = NSWindow(
                contentRect: NSRect(x: 200, y: 700, width: 28, height: 24),
                styleMask: .borderless, backing: .buffered, defer: false)
            anchorWindow.isReleasedWhenClosed = false
            let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
            anchorWindow.contentView = anchor
            let panel = MenuBarPanel()
            panel.contentSize = NSSize(width: 120, height: 100)
            defer {
                panel.close()
                settings.close()
                other.close()
                anchorWindow.close()
            }

            settings.presentForUserRequest()
            other.presentForUserRequest()
            expect(!settings.isKeyWindow, "夹具必须先让 Settings 位于后台")
            settings.defersAutomaticFocusForPanel = true
            panel.show(relativeTo: anchor.bounds, of: anchor)
            expect(panel.isKeyWindow, "显式请求前菜单必须持有键盘焦点")
            settings.makeKey()
            expect(panel.isKeyWindow && !settings.isKeyWindow, "自动 key 交接仍须受菜单焦点抑制")
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier

            if performRaise {
                expect(settings.accessibilityPerformRaise(), "菜单打开时显式 AX Raise 必须成功")
            } else {
                settings.presentForUserRequest()
            }
            expect(!settings.defersAutomaticFocusForPanel, "显式请求必须自行解除抑制，不依赖控制器关闭回调")
            expect(settings.isVisible && settings.isKeyWindow, "显式请求必须同时前置设置并取得键盘焦点")
            expect(NSApp.keyWindow === settings, "原生 key owner 必须从菜单转移到 Settings")
            try? await Task.sleep(nanoseconds: 50_000_000)
            expect(!panel.isShown, "显式 Settings 请求取得焦点后菜单按失去 key 路径收起")
            expect(settings.isKeyWindow, "菜单收起后键盘焦点必须仍属于 Settings")
            expect(
                NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost,
                "显式非激活呈现不能改变前台应用")
        }
    }

    suite("菜单关闭只消费一次原来的 Settings key 所有权") {
        var handback = PanelSettingsHandback()
        handback.begin(settingsWasForeground: true)
        expect(handback.takeSettingsRestoration(), "前台设置在显式关闭菜单后取回 key")
        expect(!handback.takeSettingsRestoration(), "同一次关闭只消费一次 Settings 焦点")
        handback.begin(settingsWasForeground: false)
        expect(!handback.takeSettingsRestoration(), "后台设置不能借菜单关闭抢键盘")
        handback.begin(settingsWasForeground: true)
        handback.begin(settingsWasForeground: false)
        expect(!handback.takeSettingsRestoration(), "新一次打开必须覆盖旧决策")
    }

    suite("Settings 与真实活动 sheet 仍是同一个 key owner") {
        let settings = focusTestSettingsWindow()
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 120),
            styleMask: .titled, backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { settings.endSheet(sheet); sheet.close(); settings.close() }
        settings.orderFront(nil)
        settings.beginSheet(sheet)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        expect(sheet.sheetParent === settings, "测试必须使用真实附属 sheet")
        expect(settingsWindowOwnsKeyFocus(settings, keyWindow: sheet), "sheet key 仍属于 Settings")
        expect(settingsWindowRestorationTarget(settings) === sheet, "键盘归还必须指向当前 sheet")
        expect(!settingsWindowOwnsKeyFocus(settings, keyWindow: nil), "没有 key 不等于 Settings 在前台")
    }

    suite("菜单栏命中使用原始事件坐标") {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 200, height: 80),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = NSView(frame: NSRect(x: 20, y: 20, width: 24, height: 24))
        window.contentView?.addSubview(button)
        defer { window.close() }
        for (location, expected) in [(NSPoint(x: 30, y: 30), true), (NSPoint(x: 90, y: 30), false)]
        {
            let local = NSEvent.mouseEvent(
                with: .leftMouseDown, location: location,
                modifierFlags: [], timestamp: 10, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            expect(statusItemContainsMouseEvent(local, button: button) == expected, "本地事件按所属窗口坐标命中")
            let screen = window.convertPoint(toScreen: location)
            let quartz = CGPoint(x: screen.x, y: NSScreen.screens[0].frame.maxY - screen.y)
            let global = NSEvent(
                cgEvent: CGEvent(
                    mouseEventSource: nil, mouseType: .leftMouseDown,
                    mouseCursorPosition: quartz, mouseButton: .left)!)!
            expect(
                statusItemContainsMouseEvent(global, button: button) == expected, "全局事件按发生时的屏幕坐标命中")
        }
    }

    suite("生产窗口 owner 接入非激活呈现与状态项激活保护") {
        let root = guiTestRepositoryRoot()
        let menu = try! String(
            contentsOf: root.appendingPathComponent(
                "gui/Sources/ClaudioGUI/MenuBarController.swift"), encoding: .utf8)
        let settings = try! String(
            contentsOf: root.appendingPathComponent(
                "gui/Sources/ClaudioGUI/SettingsWindowController.swift"), encoding: .utf8)
        let choreography = try! String(
            contentsOf: root.appendingPathComponent(
                "gui/Sources/ClaudioGUICore/PanelSettingsChoreography.swift"), encoding: .utf8)
        let menuCode = strippingComments(menu).codeWithoutStringLiterals
        let settingsCode = strippingComments(settings).codeWithoutStringLiterals
        let settingsFlat = collapsingWhitespace(settingsCode)
        let choreographyCode = strippingComments(choreography).codeWithoutStringLiterals
        expect(menuCode.contains("let panelWindow = MenuBarPanel()"), "真实菜单必须使用非激活窗口组件")
        expect(
            menuCode.contains("panelWindow.onShow =") && menuCode.contains("panelWindow.onClose ="),
            "真实 owner 必须收到可靠的显示和关闭事件")
        expect(
            !menuCode.contains("NSApp.activate(") && !settingsCode.contains("NSApp.activate("),
            "菜单与设置的显示不能通过激活整个应用获得键盘")
        expect(!settingsCode.contains("orderFrontRegardless"), "设置 owner 不直接执行排序补偿，瞬时交接由独立原生组件提交")
        expect(
            menuCode.contains("NSApplication.willResignActiveNotification")
                && menuCode.contains("protectSettingsDuringStatusActivation("),
            "必须在系统转发状态项回调之前保护当前设置")
        expect(
            menuCode.range(of: "panelWindow.show(relativeTo:")!.lowerBound
                < menuCode.range(of: "settingsWindowController.finishStatusActivation()")!
                .lowerBound,
            "菜单取得焦点后才提交原层级恢复")
        expect(
            settingsFlat.contains("CGEventSource.buttonState( .combinedSessionState, button: .left)")
                && settingsFlat.contains(
                    "statusItemContainsScreenPoint( NSEvent.mouseLocation, button: button)")
                && settingsCode.contains("panelSettingsShouldProtectDuringStatusActivation("),
            "普通切换应用和其他状态项不能进入保护路径，三项事实判定下沉到可测的编排层"
                + "（两条 AppKit 边缘调用在生产侧按 100 列折行，故对折叠空白后的文本断言）")
        expect(
            settingsCode.contains("statusActivationGuard.finish(restoringOrder: false)"),
            "关闭设置必须取消保护而不重新前置")
        expect(
            settingsCode.contains("presentedWindow.presentForUserRequest()"),
            "只有主动请求 Settings 的路径可以前置设置")
        expect(settingsCode.contains("let window = RetainedSettingsWindow("), "设置保留单一非激活窗口")
        expect(
            settingsCode.contains("settingsWindowOwnsKeyFocus(window, keyWindow: NSApp.keyWindow)"),
            "原生 key window 与 sheet 决定当前所有权")
        expect(settingsCode.contains("target.makeKey()"), "设置恢复只取回键盘，不重新排序")
        expect(
            menuCode.contains("explicitDismissal: reason == .explicit")
                && choreographyCode.contains("explicitDismissal && restoreSettings"),
            "外部点击或应用切换不得归还旧 Settings 焦点；判定归 ADR 0022 编排层，MenuBarController 只转发关闭原因")
        expect(
            menuCode.contains("defer { settingsWindowController.finishPanelPresentation() }"),
            "所有关闭路径都必须恢复正常键盘资格")
        expect(
            choreographyCode.contains("pendingPresentation = presentation")
                && menuCode.contains("presentSettings(presentation)"),
            "保留统一 Settings 路由与关闭后展示；排队事实归编排层，呈现调用留在窗口 owner")
        expect(
            menuCode.contains("panelSettingsChoreography")
                && !menuCode.contains("NSRunningApplication?"),
            "close-before-show 决策与 handback 身份归编排层值类型，窗口 owner 只接触原生边缘")
    }
}

@MainActor
private func focusTestSettingsWindow() -> RetainedSettingsWindow {
    let window = RetainedSettingsWindow(
        contentRect: NSRect(x: 200, y: 200, width: 320, height: 240),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
}

private func focusTestNormalWindowOrder() -> [Int] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        .compactMap { $0[kCGWindowNumber as String] as? Int }
}

private func focusTestSameWindowOrder(_ before: [Int], _ after: [Int]) -> Bool {
    let common = Set(before).intersection(after)
    return before.filter { common.contains($0) } == after.filter { common.contains($0) }
}
