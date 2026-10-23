import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation

@MainActor
func runFivePageSettingsNativeSuites() async {
    await suite("Five-page settings native：About attaches to General and returns modal focus") {
        for language in ClaudioAppLanguage.allCases {
            for width: CGFloat in [960, 1240] {
                let fixture = SettingsPresentationFixtures.generalLogin(
                    language: language, route: .destination(.general))
                let probe = NativeSettingsShellProbe(
                    session: fixture.session, width: width, dark: width == 960)
                defer { probe.close() }
                await probe.presentAndSettle()
                fixture.session.send(.route(.destination(.about)))
                await probe.settle()
                for _ in 0..<32 where probe.window.attachedSheet == nil {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                guard let sheet = probe.window.attachedSheet, let content = sheet.contentView else {
                    expect(false, "关于必须挂为同一原生窗口的 sheet"); continue
                }
                expect(
                    fixture.session.state.routeResolution.destination == .general
                        && !fixture.session.state.chrome.navigationEnabled,
                    "关于表单期间正文通用与侧栏模态阻断保持一致")
                expect(
                    content.bounds.width <= width
                        && content.bounds.height <= probe.window.frame.height,
                    "关于表单实际几何必须容纳于最小窗口")
                sheet.makeKey()
                sheet.selectNextKeyView(nil)
                let first = sheet.firstResponder
                sheet.selectPreviousKeyView(nil)
                sheet.selectNextKeyView(nil)
                var visitedKeyViews = Set<ObjectIdentifier>()
                for _ in 0..<12 {
                    sheet.selectNextKeyView(nil)
                    if let responder = sheet.firstResponder {
                        visitedKeyViews.insert(ObjectIdentifier(responder))
                    }
                    expect((sheet.firstResponder as? NSView)?.window === sheet, "Tab 焦点圈定在关于表单")
                }
                expect(visitedKeyViews.count > 1, "关于表单 Tab 实际遍历多个控件")
                for _ in 0..<12 {
                    sheet.selectPreviousKeyView(nil)
                    expect(
                        (sheet.firstResponder as? NSView)?.window === sheet, "Shift+Tab 焦点圈定在关于表单")
                }
                expect(
                    sheet.firstResponder === first && sheet.firstResponder != nil,
                    "Tab / Shift+Tab 往返保持在原生 sheet key-view loop")
                if let directory = ProcessInfo.processInfo.environment[
                    "CLAUDIO_SETTINGS_NATIVE_CAPTURE_DIR"],
                    language == (width == 960 ? .english : .zhHans),
                    let frame = content.superview,
                    let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
                {
                    // Capture the native sheet frame, including its semantic window background.
                    // The hosting content alone is transparent and omits AppKit compositing.
                    frame.cacheDisplay(in: frame.bounds, to: bitmap)
                    let url = URL(fileURLWithPath: directory).appendingPathComponent(
                        "about-sheet-\(Int(width)).png")
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
                }
                if let scroll = aboutSheetDescendants(content).compactMap({ $0 as? NSScrollView })
                    .first(where: { ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height })
                {
                    let maximum =
                        (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    await probe.settle()
                    expect(scroll.contentView.bounds.minY > 0, "关于资源与诊断可以原生滚动到达")
                } else {
                    expect(false, "关于表单必须提供可滚动的资源与诊断正文")
                }
                // Dispatch Escape through the native sheet, exercising the cancelAction button.
                let escape = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: sheet.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53)!
                sheet.sendEvent(escape)
                await probe.settle()
                expect(fixture.session.aboutPresentation == nil, "Esc 关闭关于表单")
                for _ in 0..<32
                where (probe.window.firstResponder as? NSView)?.accessibilityIdentifier()
                    != "settings.general.about"
                {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                expect(
                    (probe.window.firstResponder as? NSView)?.accessibilityIdentifier()
                        == "settings.general.about",
                    "Esc 归还实际关于入口焦点，当前 \(String(describing: probe.window.firstResponder))")
                expect(
                    fixture.session.navigationHistory.current?.location.destination == .general,
                    "关闭关于不会新增历史目的页")
            }
        }
    }
    await suite("Five-page settings native：workspace profile detail geometry") {
        for width: CGFloat in [960, 1240] {
            let rule = WorkspaceSoundRule(
                id: UUID(),
                directory: WorkspaceDirectory(kind: .directory, path: "/fixture/Example"),
                surfaces: [.claudeCode, .codex],
                profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
            let fixture = SettingsPresentationFixtures.generalLogin(
                language: width == 960 ? .english : .zhHans,
                route: .events(scope: .workspace(rule.id), event: .stop), workspaceRules: [rule])
            let probe = NativeSettingsShellProbe(
                session: fixture.session, width: width, dark: width == 960,
                reduceMotion: width == 960)
            await probe.presentAndSettle()
            expect(probe.shell.view.bounds.width <= width + 1, "工作区完整详情不横向溢出")
            expect(probe.scrollReading(to: probe.maximumReadingOffset ?? 0), "完整详情可滚动到底")
            if let directory = ProcessInfo.processInfo.environment[
                "CLAUDIO_SETTINGS_NATIVE_CAPTURE_DIR"]
            {
                _ = probe.scrollReading(to: 0)
                await probe.settle()
                probe.capture(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(
                        "workspace-detail-\(Int(width)).png"))
            }
            probe.close()
        }
    }

}

@MainActor
private func aboutSheetDescendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(aboutSheetDescendants)
}
