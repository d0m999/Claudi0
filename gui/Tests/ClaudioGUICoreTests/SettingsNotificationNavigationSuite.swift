import AppKit
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation
import SoundPacksWindow

@MainActor
func runSettingsNotificationNavigationSuites() async {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let resources = EventAnimationResources(
        directory: repository.appendingPathComponent(
            "gui/Sources/ClaudioGUI/Resources/EventAnimations"))
    for style in EventAnimationStyle.allCases {
        await resources.load(style, dark: false)
        await resources.load(style, dark: true)
    }
    await suite("通知详情导航：全窗口原生工具栏，动作复用设置会话") {
        for language in ClaudioAppLanguage.allCases {
            for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
                for width: CGFloat in [960, 1_240] {
                    let fixture = SettingsPresentationFixtures.generalLogin(
                        language: language, route: .destination(.notifications),
                        eventAnimations: resources)
                    let session = fixture.session
                    session.captureReadingPosition = {
                        SettingsReadingBookmark(
                            focusIdentifier: "settings.notifications.event-animation")
                    }
                    session.send(.route(.notifications(.eventAnimation)))
                    let probe = SettingsSoundsNativeLayoutProbe(
                        session: session,
                        size: NSSize(width: width, height: width == 960 ? 640 : 820),
                        appearance: appearance)
                    defer { probe.close() }
                    await probe.settle()
                    guard let control = probe.notificationNavigationControl else {
                        expect(false, "通知详情必须挂载原生 NSSegmentedControl 前后导航")
                        continue
                    }
                    expect(
                        control.segmentCount == 2 && control.trackingMode == .momentary,
                        "导航必须是两个瞬时操作，不保留分段选择态")
                    expect(
                        control.isEnabled(forSegment: 0) && !control.isEnabled(forSegment: 1),
                        "详情只能返回，前进必须禁用")
                    expect(
                        control.image(forSegment: 0)?.accessibilityDescription
                            == ClaudioL10n(language: language).text(.settingsNavigationBack),
                        "图标保留本地化无障碍名称")
                    let frames = SoundPacksLayoutRecorder.frames
                    if let navigation = frames["settings.navigation"],
                        let title = frames["settings.title.notifications"],
                        let reading = frames["settings.reading.notifications"]
                    {
                        expect(
                            navigation.maxX < title.minX
                                && abs(navigation.midY - title.midY) < 2
                                && navigation.maxY < reading.minY,
                            "前后控件必须在工具栏标题左侧，不能占用正文行")
                        expect(navigation.width < 100, "原生导航保持紧凑，不再是长条文字按钮")
                    } else {
                        expect(false, "页头、标题与正文布局均须可测量")
                    }
                    captureSettingsNavigation(probe, language, appearance, width, "detail")

                    expect(pressNavigationSegment(control, index: 0), "原生返回动作可投递")
                    await probe.settle()
                    expect(
                        session.state.routeResolution.route == .destination(.notifications)
                            && !session.animationPreview.isActive,
                        "返回通知总览并停止预览")
                    expect(
                        session.state.navigationRestoration?.focus == .restore
                            && session.navigationHistory.current?.location.route
                                == .destination(.notifications),
                        "返回从统一历史恢复总览与阅读位置")
                    expect(
                        !control.isEnabled(forSegment: 0) && control.isEnabled(forSegment: 1),
                        "返回后只能前进到刚离开的详情")
                    captureSettingsNavigation(probe, language, appearance, width, "overview")

                    expect(pressNavigationSegment(control, index: 1), "原生前进动作可投递")
                    await probe.settle()
                    expect(
                        session.state.routeResolution.route == .notifications(.eventAnimation)
                            && session.animationPreview.isActive,
                        "前进重开同一个详情并恢复独立预览")
                    expect(fixture.actionRecorder.actions.isEmpty, "导航不触发系统或宿主操作")
                }
            }
        }
    }
    suite("通知详情导航：重复位置保留前进，跨页统一历史，关闭清空") {
        let fixture = SettingsPresentationFixtures.generalLogin(route: .destination(.notifications))
        let session = fixture.session
        expect(
            !session.state.canGoBackFromEventAnimation
                && !session.state.canGoForwardToEventAnimation,
            "首次进入总览时两个方向均禁用")
        let initial = session.state
        expect(session.send(.goBackFromEventAnimation) == .unchanged, "禁用返回拒绝动作")
        expect(session.send(.goForwardToEventAnimation) == .unchanged, "禁用前进拒绝动作")
        expect(session.state == initial, "禁用动作不改路由、焦点或呈现代次")
        session.send(.route(.notifications(.eventAnimation)))
        session.send(.goBackFromEventAnimation)
        expect(session.state.canGoForwardToEventAnimation, "返回记住可前进详情")
        session.send(.route(.destination(.notifications)))
        expect(session.state.canGoForwardToEventAnimation, "重复当前路由保留前进记录")
        session.send(.route(.destination(.general)))
        session.send(.route(.destination(.notifications)))
        expect(!session.state.chrome.canGoForward, "返回后打开新位置截断前进分支")
        session.send(.goBack)
        expect(session.state.routeResolution.destination == .general, "返回覆盖其他目的页")
        session.send(.goForward)
        session.send(.route(.notifications(.eventAnimation)))
        session.send(.goBackFromEventAnimation)
        session.send(.windowWillClose)
        session.send(.present(.route(nil)))
        expect(
            session.state.routeResolution.route == .destination(.notifications)
                && !session.state.canGoForwardToEventAnimation,
            "重新打开窗口恢复顶层目的页，不恢复局部前进记录")
    }
    if CommandLine.arguments.contains("--settings-notification-navigation") {
        await suite("通知详情导航：返回后实际 first responder 为事件动画入口") {
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .destination(.notifications), eventAnimations: resources)
            let probe = SettingsSoundsNativeLayoutProbe(
                session: fixture.session, size: NSSize(width: 960, height: 640))
            defer { probe.close() }
            fixture.session.captureReadingPosition = {
                SettingsReadingBookmark(focusIdentifier: "settings.notifications.event-animation")
            }
            fixture.session.send(.route(.notifications(.eventAnimation)))
            await probe.settle()
            probe.activate()
            for _ in 0..<200 where !probe.isKeyWindow {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            expect(probe.isKeyWindow, "原生焦点回归必须有实际 key window")
            fixture.session.send(.windowPhaseChanged(.key))
            for _ in 0..<100 where fixture.session.state.focusDebt != nil {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            guard let control = probe.notificationNavigationControl else {
                expect(false, "实际窗口挂载原生导航")
                return
            }
            expect(pressNavigationSegment(control, index: 0), "从页头原生返回")
            for _ in 0..<100
            where probe.focusedControlIdentifier != "settings.notifications.event-animation" {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            expect(
                probe.focusedControlIdentifier == "settings.notifications.event-animation",
                "原生入口取得实际焦点，标题不可抢回；当前：\(probe.focusedControlIdentifier ?? "nil")")
        }
    }
}

@MainActor
private func pressNavigationSegment(_ control: NSSegmentedControl, index: Int) -> Bool {
    func buttons(in element: AnyObject) -> [AnyObject] {
        if element.accessibilityRole?() == .button { return [element] }
        return (element.accessibilityChildren?() ?? []).flatMap { buttons(in: $0 as AnyObject) }
    }
    let segments = buttons(in: control)
    guard segments.indices.contains(index),
        segments[index].responds(to: #selector(NSAccessibilityButton.accessibilityPerformPress))
    else { return false }
    // AppKit can return false after dispatching a momentary segment's action. The caller
    // checks the actual session route, preview lifecycle and enabled state after each press.
    _ = segments[index].accessibilityPerformPress?()
    return true
}

@MainActor
private func captureSettingsNavigation(
    _ probe: SettingsSoundsNativeLayoutProbe,
    _ language: ClaudioAppLanguage,
    _ appearance: NSAppearance.Name,
    _ width: CGFloat,
    _ page: String
) {
    guard let output = ProcessInfo.processInfo.environment["CLAUDIO_LAYOUT_CAPTURE_DIR"] else {
        return
    }
    let file = URL(fileURLWithPath: output).appendingPathComponent(
        "navigation-\(page)-\(language.rawValue)-\(appearance.rawValue)-\(Int(width)).png")
    expect(probe.saveScreenshot(to: file), "保存原生导航截图")
}
