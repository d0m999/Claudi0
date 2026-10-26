import AppKit
import ApplicationServices
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
                guard await probe.presentAndSettle() else { return }
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
                settingsKeyboardPress(48, "\t", in: sheet)
                await probe.settle()
                let first = sheet.firstResponder
                settingsKeyboardPress(48, "\t", in: sheet, modifiers: .shift)
                await probe.settle()
                settingsKeyboardPress(48, "\t", in: sheet)
                await probe.settle()
                var visitedKeyViews = Set<ObjectIdentifier>()
                for _ in 0..<12 {
                    settingsKeyboardPress(48, "\t", in: sheet)
                    await probe.settle()
                    if let responder = sheet.firstResponder {
                        visitedKeyViews.insert(ObjectIdentifier(responder))
                    }
                    expect((sheet.firstResponder as? NSView)?.window === sheet, "Tab 焦点圈定在关于表单")
                }
                expect(visitedKeyViews.count > 1, "关于表单 Tab 实际遍历多个控件")
                for _ in 0..<12 {
                    settingsKeyboardPress(48, "\t", in: sheet, modifiers: .shift)
                    await probe.settle()
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
        for language in ClaudioAppLanguage.allCases {
            for dark in [false, true] {
                for width: CGFloat in [960, 1240] {
                    let rule = WorkspaceSoundRule(
                        id: UUID(),
                        directory: WorkspaceDirectory(kind: .directory, path: "/fixture/Example"),
                        surfaces: [],
                        profile: WorkspaceSoundProfile(
                            selectedPack: "settings-fixture-pack", volume: 0.7))
                    let fixture = SettingsPresentationFixtures.generalLogin(
                        language: language,
                        route: .events(scope: .workspace(rule.id), event: .stop),
                        workspaceRules: [rule])
                    let probe = NativeSettingsShellProbe(
                        session: fixture.session, width: width, dark: dark,
                        reduceMotion: width == 960)
                    defer { probe.close() }
                    guard await probe.presentAndSettle() else { return }
                    expect(probe.shell.view.bounds.width <= width + 1, "工作区完整详情不横向溢出")
                    expect(probe.scrollReading(to: probe.maximumReadingOffset ?? 0), "完整详情可滚动到底")
                    await probe.settle()
                    let l10n = ClaudioL10n(language: language)
                    expectWorkspaceSourceCopy(in: probe.shell.view, prefix: "workspace", l10n: l10n)
                    let elements = workspaceSourceAXElements(in: probe.shell.view)
                    expect(
                        elements.contains {
                            $0.accessibilityIdentifier?() == "workspace.sound-sources.empty"
                        },
                        "零来源工作区详情常驻未使用说明")
                    for surface in WorkspaceSurfaceEligibility.candidates {
                        let checkbox = elements.first {
                            $0.accessibilityIdentifier?()
                                == "workspace.sound-source.\(surface.rawValue)"
                        }
                        expectWorkspaceSourceCheckbox(checkbox, surface: surface, l10n: l10n)
                    }
                    expect(
                        elements.first {
                            $0.accessibilityIdentifier?() == "workspace.manage-connections"
                        }?
                        .accessibilityLabel?() == l10n.text(.workspaceManageConnections),
                        "仅工作区详情提供双语连接管理入口")
                    if let directory = ProcessInfo.processInfo.environment[
                        "CLAUDIO_SETTINGS_NATIVE_CAPTURE_DIR"]
                    {
                        probe.capture(
                            to: URL(fileURLWithPath: directory).appendingPathComponent(
                                "workspace-sources-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(width)).png"
                            ))
                    }
                }
            }
        }
    }

    await suite(
        "Five-page settings native：source connections link returns to workspace reading position"
    ) {
        let rule = WorkspaceSoundRule(
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/Example"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .events(scope: .workspace(rule.id), event: .stop), workspaceRules: [rule])
        let session = fixture.session
        let probe = NativeSettingsShellProbe(session: session, width: 960, dark: false)
        defer { probe.close() }
        guard await probe.presentAndSettle() else { return }
        _ = probe.scrollReading(to: probe.maximumReadingOffset ?? 0)
        await probe.settle()
        let offset = probe.readingOffset ?? -1
        let location = session.navigationHistory.current?.location
        let selectedScope = fixture.eventSettingsModel.selectedSoundScope
        let config = fixture.eventSettingsModel.configState
        // A stale host-detail visit must not turn the new entry into a host deep link.
        session.send(.route(.integrations(.init(surface: .codex, detailsHost: .codex))))
        session.send(.goBack)
        guard await probe.presentAndSettle() else { return }
        guard
            let link = workspaceSourceAXElements(in: probe.shell.view).first(where: {
                $0.accessibilityIdentifier?() == "workspace.manage-connections"
            })
        else {
            expect(false, "实际挂载工作区详情必须存在连接入口"); return
        }
        expect(link.accessibilityPerformPress?() == true, "从真实 SwiftUI 按钮进入连接")
        guard await probe.presentAndSettle() else { return }
        expect(
            session.state.routeResolution.route == .destination(.integrations),
            "入口使用既有 session 的连接首页路由")
        expect(
            probe.window.contentViewController === probe.shell && probe.window.attachedSheet == nil,
            "连接复用同一 retained window，不创建新窗口或表单")
        session.send(.goBack)
        guard await probe.presentAndSettle() else { return }
        expect(
            session.navigationHistory.current?.location == location
                && fixture.eventSettingsModel.selectedSoundScope == selectedScope
                && fixture.eventSettingsModel.configState == config,
            "返回恢复原工作区与事件浏览身份，导航不写声音配置")
        expect(
            abs((probe.readingOffset ?? -1) - offset) < 2,
            "返回恢复原工作区阅读位置：before=\(offset), after=\(probe.readingOffset ?? -1)")
    }

    await suite(
        "Five-page settings native：workspace creation explains sources and permits clearing all"
    ) {
        for language in ClaudioAppLanguage.allCases {
            for dark in [false, true] {
                for width: CGFloat in [960, 1240] {
                    let fixture = SettingsPresentationFixtures.generalLogin(
                        language: language, route: .destination(.eventsAndSounds))
                    let probe = NativeSettingsShellProbe(
                        session: fixture.session, width: width, dark: dark)
                    defer { probe.close() }
                    guard await probe.presentAndSettle() else { return }
                    let add = workspaceSourceAXElements(in: probe.shell.view).first {
                        $0.accessibilityIdentifier?() == "workspace.add"
                    }
                    expect(add?.accessibilityPerformPress?() == true, "通过实际添加按钮打开表单")
                    await probe.settle()
                    for _ in 0..<32 where probe.window.attachedSheet == nil {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                    guard let sheet = probe.window.attachedSheet, let content = sheet.contentView
                    else {
                        expect(false, "添加表单必须挂在当前设置窗口"); continue
                    }
                    let l10n = ClaudioL10n(language: language)
                    expectWorkspaceSourceCopy(in: content, prefix: "workspace.new", l10n: l10n)
                    expect(
                        content.bounds.width <= width
                            && content.bounds.height <= probe.window.frame.height,
                        "添加表单长说明适配最小窗口：\(content.bounds)")
                    for surface in WorkspaceSurfaceEligibility.candidates {
                        let checkbox = workspaceSourceAXElements(in: content).first {
                            $0.accessibilityIdentifier?()
                                == "workspace.new.sound-source.\(surface.rawValue)"
                        }
                        expectWorkspaceSourceCheckbox(checkbox, surface: surface, l10n: l10n)
                        if WorkspaceSurfaceEligibility.verified.contains(surface) {
                            expect(checkbox?.accessibilityPerformPress?() == true, "系统勾选动作允许取消来源")
                            await probe.settle()
                        }
                    }
                    let elements = workspaceSourceAXElements(in: content)
                    expect(
                        elements.contains {
                            $0.accessibilityIdentifier?() == "workspace.new.sound-sources.empty"
                        },
                        "全部取消后显示零来源说明")
                    expect(
                        !elements.contains {
                            $0.accessibilityIdentifier?() == "workspace.manage-connections"
                        },
                        "添加表单不提供跨页连接入口")
                    let route = fixture.session.state.routeResolution.route
                    fixture.session.send(.route(.destination(.integrations)))
                    expect(fixture.session.state.routeResolution.route == route, "添加表单沿用模态导航阻断")
                    if let directory = ProcessInfo.processInfo.environment[
                        "CLAUDIO_SETTINGS_NATIVE_CAPTURE_DIR"],
                        let frame = content.superview,
                        let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
                    {
                        frame.cacheDisplay(in: frame.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(
                            to: URL(fileURLWithPath: directory).appendingPathComponent(
                                "workspace-create-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(width)).png"
                            ))
                    }
                    let cancel = elements.first {
                        $0.accessibilityRole?() == .button
                            && $0.accessibilityLabel?() == l10n.text(.workspaceCancel)
                    }
                    expect(cancel?.accessibilityPerformPress?() == true, "取消表单且不写配置")
                    await probe.settle()
                }
            }
        }
    }

}

@MainActor
private var workspaceSourceAccessibilityPrepared = false

@MainActor
private func workspaceSourceAXElements(in root: NSView) -> [AnyObject] {
    if !workspaceSourceAccessibilityPrepared {
        workspaceSourceAccessibilityPrepared = true
        // As in the Sounds layout probe, initialize SwiftUI AX through this process's
        // public application element; the executable harness has no external AX client.
        NSApplication.shared.finishLaunching()
        let completed = DispatchSemaphore(value: 0)
        let processID = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.global().async {
            let application = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(application, 1)
            var children: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(
                application, kAXChildrenAttribute as CFString, &children)
            completed.signal()
        }
        let deadline = Date().addingTimeInterval(2)
        while completed.wait(timeout: .now()) != .success && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
        root.layoutSubtreeIfNeeded()
    }
    var result: [AnyObject] = []
    var visited = Set<ObjectIdentifier>()
    func visit(_ element: AnyObject) {
        guard visited.insert(ObjectIdentifier(element)).inserted else { return }
        result.append(element)
        for child in element.accessibilityChildren?() ?? [] { visit(child as AnyObject) }
    }
    visit(root)
    return result
}

@MainActor
private func expectWorkspaceSourceCopy(in root: NSView, prefix: String, l10n: ClaudioL10n) {
    let elements = workspaceSourceAXElements(in: root)
    for (suffix, key) in [
        ("title", ClaudioL10nKey.workspaceSoundSourcesTitle),
        ("description", ClaudioL10nKey.workspaceSoundSourcesDescription),
    ] {
        let text = elements.first {
            $0.accessibilityIdentifier?() == "\(prefix).sound-sources.\(suffix)"
        }
        let value: String? = text?.accessibilityValue?()
        expect(
            value == l10n.text(key) || text?.accessibilityLabel?() == l10n.text(key),
            "实际挂载双语标题与常驻说明完整可读：\(prefix).\(suffix)")
        if suffix == "description" {
            expect((text?.accessibilityFrame?().height ?? 0) > 12, "常驻说明具有可读高度")
        }
    }
}

@MainActor
private func expectWorkspaceSourceCheckbox(
    _ checkbox: AnyObject?, surface: HostSurfaceID, l10n: ClaudioL10n
) {
    let name =
        HostID.productVisibleCases.first { $0.surfaceID == surface }?.displayName
        ?? surface.rawValue
    expect(
        checkbox?.accessibilityRole?() == .checkBox
            && checkbox?.accessibilityLabel?() == name,
        "来源行使用系统 checkbox，只显示来源名：\(surface.rawValue)")
    expect(
        checkbox?.accessibilityHelp?() == l10n.text(.workspaceSoundSourcesHint),
        "每个勾选框的无障碍提示说明声音设置适用性")
    expect(
        checkbox?.isAccessibilityEnabled?()
            == WorkspaceSurfaceEligibility.verified.contains(surface),
        "原有来源资格门控保持有效")
}

@MainActor
private func aboutSheetDescendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(aboutSheetDescendants)
}
