import AppKit
import ApplicationServices
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation
import SoundPacksWindow
import SwiftUI
import Vision

@MainActor
func runSettingsSoundsLayoutSuites() async {
    await suite("设置原生呈现：八页、两语言、两外观、两尺寸的 64 个组合") {
        for language in [ClaudioAppLanguage.zhHans, .english] {
            for size in [NSSize(width: 1_240, height: 820), NSSize(width: 960, height: 640)] {
                for dark in [false, true] {
                    for destination in SettingsDestination.allCases {
                        let fixture = SettingsPresentationFixtures.generalLogin(
                            language: language, route: .destination(destination),
                            availability: PreviewFixtures.settingsRouteAvailability)
                        let probe = SettingsSoundsNativeLayoutProbe(
                            session: fixture.session, size: size,
                            appearance: dark ? .darkAqua : .aqua)
                        defer { probe.close() }
                        await probe.settle()
                        let name =
                            "\(destination.rawValue) \(Int(size.width)) \(language.rawValue) \(dark)"
                        let frames = SoundPacksLayoutRecorder.frames
                        guard let content = frames["settings.content"],
                            let sidebar = frames["settings.sidebar"],
                            let reading = frames["settings.reading.\(destination.rawValue)"]
                        else {
                            expect(false, "\(name) 必须挂载真实页面与单列内容：\(frames.keys.sorted())")
                            continue
                        }
                        expect(
                            abs(sidebar.width - (size.width <= 1_100 ? 210 : 252)) < 1,
                            "\(name) 侧栏宽度必须匹配窗口：\(sidebar)")
                        let padding: CGFloat = size.width <= 1_100 ? 26 : 32
                        expect(
                            reading.width <= 780 - padding * 2 + 1
                                && reading.minX >= content.minX + padding - 1
                                && reading.maxX <= content.maxX - padding + 1,
                            "\(name) 单列包含内边距且无横向溢出：\(reading), \(content)")
                        for y in [content.minY + 8, size.height / 2, size.height - 20] {
                            expect(
                                colorsMatch(
                                    probe.rgb(at: CGPoint(x: content.minX + 8, y: y)),
                                    probe.semanticRGB(.windowBackgroundColor)),
                                "\(name) 页首、滚动区、页尾必须保持设置底色")
                        }
                        let rows = SettingsDestination.allCases.compactMap {
                            frames["settings.sidebar.item.\($0.rawValue)"]
                        }
                        expect(rows.count == 8, "\(name) 八页侧栏必须实际挂载")
                        for index in 1..<rows.count {
                            let gap = rows[index].minY - rows[index - 1].maxY
                            expect(
                                ([4, 6].contains(index) ? gap >= 16 : abs(gap) < 1),
                                "\(name) 三组侧栏间距：\(gap)")
                        }
                        let menuRows: [(identifier: String, minimumHeight: CGFloat)]
                        switch destination {
                        case .general:
                            menuRows = [("settings.general.language", 38)]
                        case .eventsAndSounds:
                            menuRows = [
                                ("workspace.scope-selector", 38),
                                ("event-settings.sound-pack-picker", 38),
                            ]
                        case .sounds:
                            menuRows = [
                                ("settings.sounds.management-scope", 51),
                                ("sound-packs.pack-list", 38),
                            ]
                        default:
                            menuRows = []
                        }
                        for menuRow in menuRows {
                            expectSettingsMenuLayout(
                                probe: probe, identifier: menuRow.identifier, name: name,
                                minimumHeight: menuRow.minimumHeight,
                                exactHeight: menuRow.minimumHeight == 38 ? 38 : nil)
                        }
                        if destination == .eventsAndSounds || destination == .sounds {
                            let prefix = destination == .sounds ? "sound-packs" : "workspace"
                            let events = Event.allCases.compactMap {
                                frames["\(prefix).event-row.\($0.rawValue)"]
                            }
                            expect(events.count == 5, "\(name) 五事件须在同一功能组内")
                            if let group = frames["\(prefix).events.group"] {
                                expect(
                                    events.allSatisfy {
                                        group.insetBy(dx: -1, dy: -1).contains($0)
                                    },
                                    "\(name) 五事件不得成为独立卡片或横向溢出")
                                for pair in zip(events, events.dropFirst()) {
                                    expect(
                                        abs(pair.1.minY - pair.0.maxY) <= 2,
                                        "\(name) 事件行只由分隔线分开：\(pair)")
                                }
                            } else {
                                expect(false, "\(name) 必须挂载事件功能组")
                            }
                            if let selector = frames[
                                "\(prefix).\(prefix == "workspace" ? "scope-selector" : "selector").card"
                            ] {
                                expect(
                                    colorsMatch(
                                        probe.rgb(
                                            at: CGPoint(x: selector.midX, y: selector.minY + 5)),
                                        probe.semanticRGB(.underPageBackgroundColor)),
                                    "\(name) 功能组使用系统语义色：actual=\(probe.rgb(at: CGPoint(x: selector.midX, y: selector.minY + 5)) as Any), expected=\(probe.semanticRGB(.underPageBackgroundColor) as Any)"
                                )
                            } else {
                                expect(false, "\(name) 必须挂载选择器")
                            }
                        }
                        if destination == .sounds {
                            for event in Event.allCases {
                                expect(
                                    probe.menuAccessibilityElement(
                                        identifier: "settings.sounds.ai-cue.event.\(event.rawValue)"
                                    ) != nil,
                                    "\(name) 用户包五事件行必须直接挂载生成入口")
                            }
                            if let deletion = frames["sound-packs.deletion.card"],
                                let eventGroup = frames["sound-packs.events.group"]
                            {
                                expect(
                                    deletion.minY > eventGroup.maxY,
                                    "\(name) 删除声音包位于主页面底部独立区域")
                            } else {
                                expect(false, "\(name) 必须挂载声音包删除区域")
                            }
                        }
                        if let captureDirectory = ProcessInfo.processInfo.environment[
                            "CLAUDIO_LAYOUT_CAPTURE_DIR"]
                        {
                            let file = URL(fileURLWithPath: captureDirectory)
                                .appendingPathComponent(
                                    "\(destination.rawValue)-\(Int(size.width))-\(language.rawValue)-\(dark ? "dark" : "light").png"
                                )
                            expect(probe.saveScreenshot(to: file), "\(name) 原生截图须可保存")
                            expect(probe.scrollToEnd(), "\(name) 末尾必须通过原生滚动可达")
                            let bottom = file.deletingPathExtension()
                                .appendingPathExtension("bottom.png")
                            expect(probe.saveScreenshot(to: bottom), "\(name) 滚动末尾原生截图须可保存")
                        }
                    }
                }
            }
        }
    }

    await suite("设置原生呈现：高对比度仍使用实色功能组") {
        for dark in [false, true] {
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .events(scope: .global, event: nil),
                availability: PreviewFixtures.settingsRouteAvailability)
            let probe = SettingsSoundsNativeLayoutProbe(
                session: fixture.session, size: NSSize(width: 1_240, height: 820),
                appearance: dark
                    ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            defer { probe.close() }
            await probe.settle()
            guard let selector = SoundPacksLayoutRecorder.frames["workspace.scope-selector.card"]
            else { expect(false, "高对比度检查须挂载实际选择器"); continue }
            expect(
                colorsMatch(
                    probe.rgb(at: CGPoint(x: selector.midX, y: selector.minY + 5)),
                    probe.semanticRGB(.underPageBackgroundColor)),
                "增强对比度系统功能组：actual=\(probe.rgb(at: CGPoint(x: selector.midX, y: selector.minY + 5)) as Any), expected=\(probe.semanticRGB(.underPageBackgroundColor) as Any)"
            )
        }
    }

    await runSettingsMenuLayoutSuites()

    await suite("声音详情：未发布草稿与只读深链保持真实可编辑边界") {
        let draftFixture = SettingsPresentationFixtures.generalLogin(
            route: .sounds(.overview), availability: PreviewFixtures.settingsRouteAvailability)
        let draftProbe = SettingsSoundsNativeLayoutProbe(
            session: draftFixture.session,
            size: NSSize(width: 960, height: 640))
        await draftProbe.settle()
        expect(
            draftFixture.soundPacksEditor.beginAICuePackDraft(language: .zhHans), "草稿须由既有 owner 创建")
        draftProbe.refresh()
        expect(
            SoundPacksLayoutRecorder.frames["sound-packs.event-detail"] != nil,
            "新草稿直接进入事件详情且未发布")
        expect(
            {
                if case .sounds(let sounds) = draftFixture.soundPacksEditor.presentation.mode {
                    return sounds.draft != nil
                }; return false
            }(),
            "呈现详情不得发布空草稿")
        draftProbe.close()

        let readonlyFixture = SettingsPresentationFixtures.generalLogin(
            route: .sounds(.copyAndApply(packID: "gallery-pack", event: .stop)),
            availability: PreviewFixtures.settingsRouteAvailability,
            builtinPackIDs: ["gallery-pack"])
        let readonlyProbe = SettingsSoundsNativeLayoutProbe(
            session: readonlyFixture.session,
            size: NSSize(width: 1_240, height: 820))
        await readonlyProbe.settle()
        expect(readonlyFixture.aiCueViewModel.session == nil, "只读包详情不得启动 AI 会话")
        expect(
            SoundPacksLayoutRecorder.frames["sound-packs.event-detail"] != nil,
            "只读深链仍进入对应事件详情")
        readonlyProbe.close()
    }

    await suite("声音设置原生挂载：切换检查包清理旧事件会话") {
        let generationID = UUID()
        let profileID = AICueProviderProfileID.elevenLabsGlobal
        let candidates = AICueVariant.allCases.enumerated().map { index, variant in
            AICueCandidate(
                id: UUID(),
                variant: variant,
                asset: AICueTemporaryAudioAsset(
                    fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                        "claudio-layout-candidate-\(generationID)-\(index).mp3"),
                    byteCount: 1,
                    sniffedFormat: .mp3),
                durationMilliseconds: 500,
                mediaType: "audio/mpeg",
                provenance: AICueCandidateProvenance(
                    providerID: .elevenLabs,
                    profileID: profileID,
                    modelID: "layout-fixture",
                    generationID: generationID,
                    requestOrdinal: index + 1,
                    providerRequestID: nil))
        }
        let generation = AICueGeneration(
            id: generationID,
            profileID: profileID,
            plan: AICueSoundPlan(
                suggestedDisplayName: "Cue",
                modality: .soundEffect,
                soundDescription: "Short cue",
                spokenContent: nil,
                languageTag: nil,
                styleDescription: "Soft",
                targetDurationMilliseconds: 500,
                instructionVersion: "layout-fixture"),
            candidates: candidates,
            generatedAt: Date())
        let viewModel = AICueGenerationViewModel(
            previewState: AICueGenerationPreviewState(
                providerProfileID: profileID,
                credentialStatus: .stored(
                    verification: .verified,
                    hasPendingReplacement: false),
                phase: .candidatesReady,
                soundDescription: "Short cue",
                displayName: "Cue",
                session: AICueComposerSession(packID: "gallery-pack", event: .stop),
                generation: generation),
            registry: PreviewFixtures.aiCueEvidenceRegistry)
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .sounds(.editEvent(packID: "gallery-pack", event: .stop)),
            availability: PreviewFixtures.settingsRouteAvailability,
            aiCueViewModel: viewModel)
        let probe = SettingsSoundsNativeLayoutProbe(
            session: fixture.session,
            size: NSSize(width: 960, height: 640))
        expect(
            fixture.aiCueViewModel.session
                == AICueComposerSession(packID: "gallery-pack", event: .stop)
                && fixture.aiCueViewModel.generation?.candidates.count == 3,
            "用户包深链必须打开对应事件的行内生成表单")
        expect(
            SoundPacksLayoutRecorder.frames["settings.sounds.ai-cue.composer.stop"] != nil,
            "行内表单必须位于同一映射列表")
        if fixture.session.send(.inspectSoundPack("settings-fixture-pack")) == .routed {
            await probe.settle()
            expect(
                fixture.aiCueViewModel.session == nil
                    && fixture.aiCueViewModel.generation == nil,
                "切换包后旧目标会话与候选必须失效")
            expect(
                fixture.session.state.soundsDetail == .overview
                    && fixture.session.navigationHistory.current?.location.viewedPackID
                        == "settings-fixture-pack"
                    && SoundPacksLayoutRecorder.frames["sound-packs.events.group"] != nil,
                "显式检查新包进入其概览，历史保存新查看身份，旧候选不可操作")
        } else {
            expect(false, "测试包必须提供 owner 的检查动作")
        }
        probe.close()
    }
}

@MainActor
func runSettingsMenuLayoutSuites() async {
    await suite("设置原生菜单：长包名仍在紧凑行右侧且不挤出内容") {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claudio-long-menu-layout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        for language in [ClaudioAppLanguage.zhHans, .english] {
            for dark in [false, true] {
                let packName =
                    language == .zhHans
                    ? "这是一个用于确认声音包名称很长时仍然保持紧凑且不会挤出设置内容区域的名称"
                    : "A deliberately long sound pack name that stays within its compact settings row"
                let owner = SoundPacksEditorOwner.stateGalleryFixture(
                    previewConfig: ClaudioConfig(selectedPack: "long-pack"),
                    packCards: [
                        PackCard(
                            id: "long-pack", name: packName, isCC0: true,
                            presentEvents: Set(Event.allCases), state: .complete,
                            isSelected: true)
                    ],
                    selectedPackID: "long-pack",
                    selectedEventRows: Event.allCases.map {
                        EventRow(
                            event: $0, coverage: .present(fileName: "\($0.cliName).mp3"),
                            enabled: true)
                    },
                    environment: makeAudioImportEnvironment(
                        userPacksDirectory: temporaryRoot.appendingPathComponent("packs")))
                let fixture = SettingsPresentationFixtures.generalLogin(
                    language: language, route: .sounds(.overview), soundPacksEditor: owner)
                let probe = SettingsSoundsNativeLayoutProbe(
                    session: fixture.session, size: NSSize(width: 960, height: 640),
                    appearance: dark ? .darkAqua : .aqua)
                defer { probe.close() }
                await probe.settle()
                expectSettingsMenuLayout(
                    probe: probe, identifier: "sound-packs.pack-list",
                    name: "长包名 \(language.rawValue) \(dark)", minimumHeight: 38,
                    exactHeight: 38)
                expect(
                    probe.menuIsEnabled(identifier: "sound-packs.pack-list") == true,
                    "实际挂载的长名称菜单必须仍可操作")
                if language == .zhHans && !dark {
                    expect(
                        probe.menuAccessibilityValue(identifier: "missing.menu") == nil,
                        "不存在的菜单身份不能匹配其他控件的名称")
                    expect(
                        probe.menuIsEnabled(identifier: "missing.menu") == nil,
                        "不存在的菜单身份不能被误报为禁用")
                }
                let selectedValue = probe.menuAccessibilityValue(
                    identifier: "sound-packs.pack-list")
                // Backends may expose the selected title or its richer accessibility label.
                let expectedLabel = localizedSoundPacksPackAccessibilityLabel(
                    displayName: packName, isActivePack: true, state: .complete,
                    license: .cc0, language: language)
                expect(
                    selectedValue == packName || selectedValue == expectedLabel,
                    "长包名可视觉截断，但挂载菜单的无障碍当前值仍保留完整名称，\(language.rawValue) \(dark)：\(String(describing: selectedValue))"
                )
            }
        }
    }

    await suite("设置原生菜单：不可用服务选择仍保留中性紧凑呈现") {
        for dark in [false, true] {
            let fixture = SettingsPresentationFixtures.generalLogin(aiCueScenario: .adopting)
            let probe = SettingsSoundsNativeLayoutProbe(
                session: fixture.session, size: NSSize(width: 960, height: 640),
                appearance: dark ? .darkAqua : .aqua)
            defer { probe.close() }
            await probe.settle()
            expect(fixture.aiCueViewModel.phase == .adopting, "fixture 必须处于禁止更换服务的采用阶段")
            expectSettingsMenuLayout(
                probe: probe, identifier: "event-settings.ai-cue.provider-profile",
                name: "不可用服务选择 \(dark)", minimumHeight: 38, exactHeight: 38,
                scrollIntoView: true)
            expect(
                probe.menuIsEnabled(identifier: "event-settings.ai-cue.provider-profile") == false,
                "采用期间实际挂载的服务下拉控件必须不可操作")
        }
    }
}

@MainActor
private func expectSettingsMenuLayout(
    probe: SettingsSoundsNativeLayoutProbe,
    identifier: String,
    name: String,
    minimumHeight: CGFloat,
    exactHeight: CGFloat? = nil,
    scrollIntoView: Bool = false
) {
    let rowID = "\(identifier).row"
    let controlID = "\(identifier).control"
    if scrollIntoView, let control = SoundPacksLayoutRecorder.frames[controlID] {
        expect(probe.scrollToVisible(control), "\(name) 下拉控件必须可通过原生滚动到达")
    }
    guard let row = SoundPacksLayoutRecorder.frames[rowID],
        let control = SoundPacksLayoutRecorder.frames[controlID]
    else {
        expect(false, "\(name) 必须挂载设置行与下拉控件：\(identifier)")
        return
    }
    expect(
        row.height >= minimumHeight - 1
            && (exactHeight.map { abs(row.height - $0) < 1 } ?? true),
        "\(name) \(identifier) 紧凑行高度必须匹配文字层级：\(row)")
    expect(
        row.insetBy(dx: -1, dy: -1).contains(control),
        "\(name) \(identifier) 下拉控件不得溢出设置行：\(row), \(control)")
    expect(
        abs(row.maxX - control.maxX) < 1,
        "\(name) \(identifier) 下拉控件必须靠设置行右侧：\(row), \(control)")
    expect(
        control.width < row.width * 0.65,
        "\(name) \(identifier) 下拉控件不得伸展占满标签后的剩余空间：\(control)")
    guard let colors = probe.controlColorFractions(in: control) else {
        expect(false, "\(name) \(identifier) 收起控件必须能采集实际绘制像素")
        return
    }
    expect(
        colors.neutral >= 0.9 && colors.accentBlue < 0.002,
        "\(name) \(identifier) 控件底、文字与箭头必须使用中性色，灰像素 \(colors.neutral)，蓝像素 \(colors.accentBlue)")
}

@MainActor
final class SettingsSoundsNativeLayoutProbe {
    private static var hasPreparedMenuAccessibility = false
    private let window: RetainedSettingsWindow
    private let hostingView: NSView
    private let shell: SettingsNativeShellController
    private let session: SettingsPresentationSession
    private let requestedSize: NSSize

    var notificationNavigationControl: NSSegmentedControl? {
        refresh()
        return shell.navigationControl
    }

    var focusedControlIdentifier: String? {
        (window.firstResponder as? NSView)?.accessibilityIdentifier()
    }

    var isKeyWindow: Bool { window.isKeyWindow }

    func activate() {
        window.presentForUserRequest()
        refresh()
    }

    init(
        session: SettingsPresentationSession,
        size: NSSize,
        appearance: NSAppearance.Name = .aqua
    ) {
        _ = NSApplication.shared
        SoundPacksLayoutRecorder.reset()
        self.session = session
        shell = SettingsNativeShellController(session: session)
        requestedSize = size
        window = RetainedSettingsWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        hostingView = shell.view
        window.contentViewController = shell
        shell.install(in: window)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.presentForUserRequest()
        refresh()
        enforceRequestedContentSize()
    }

    /// DESIGN.md 合同：窗口默认 1240×820、最小 960×640，断言都以请求尺寸为前提。
    /// 无显示器的 runner 若按可见区压缩窗口，GeometryReader 会随之变矮，后续几何
    /// 断言就会报神秘数字。这里下令恢复请求尺寸后再布局一次；若环境连这都拒绝，
    /// 前提断言会直说，而不是让侧栏断言背锅。这是前提加固，不是放宽断言。
    private func enforceRequestedContentSize() {
        guard window.contentView?.bounds.size != requestedSize else { return }
        window.setContentSize(requestedSize)
        hostingView.frame.size = requestedSize
        refresh()
        expect(
            window.contentView?.bounds.size == requestedSize,
            "布局探针窗口必须达到请求尺寸 \(requestedSize)，实得 \(window.contentView?.bounds.size as Any)"
        )
    }

    func settle() async {
        for _ in 0..<4 { await Task.yield(); refresh() }
    }

    func refresh() {
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
            hostingView.layoutSubtreeIfNeeded()
            shell.synchronizeLayout()
        }
    }

    func saveScreenshot(to url: URL) -> Bool {
        guard let frame = window.contentView?.superview,
            let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
        else { return false }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil
    }

    var hasAttachedSheet: Bool { window.attachedSheet != nil }

    func menuIsEnabled(identifier: String) -> Bool? {
        menuAccessibilityElement(identifier: identifier)?.isAccessibilityEnabled?()
    }

    func menuAccessibilityValue(identifier: String) -> String? {
        guard let menu = menuAccessibilityElement(identifier: identifier) else { return nil }
        let value: String? = menu.accessibilityValue?()
        return value
    }

    func pressControl(_ identifier: String) -> Bool {
        guard let control = menuAccessibilityElement(identifier: identifier),
            control.isAccessibilityEnabled?() != false
        else { return false }
        let pressed = control.accessibilityPerformPress?() == true
        refresh()
        return pressed
    }

    func controlLabel(_ identifier: String) -> String? {
        menuAccessibilityElement(identifier: identifier)?.accessibilityLabel?()
    }

    func menuAccessibilityElement(identifier: String) -> AnyObject? {
        prepareMenuAccessibility()
        var matches: [AnyObject] = []
        var visited: Set<ObjectIdentifier> = []
        // SwiftUI can draw menus without an NSControl. Its AX proxies implement the public
        // Objective-C getters without declaring NSAccessibilityProtocol conformance.
        func visit(_ element: AnyObject) {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return }
            if element.accessibilityIdentifier?() == identifier { matches.append(element) }
            for child in element.accessibilityChildren?() ?? [] {
                visit(child as AnyObject)
            }
        }
        visit(hostingView)
        return matches.count == 1 ? matches[0] : nil
    }

    private func prepareMenuAccessibility() {
        guard !Self.hasPreparedMenuAccessibility else { return }
        Self.hasPreparedMenuAccessibility = true
        // A CLI harness has no external AX client. Query only this process to initialize
        // AppKit/SwiftUI accessibility; pump the main run loop while AppKit serves the request.
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
        refresh()
    }

    func scrollToVisible(_ frame: CGRect) -> Bool {
        func findReadingScroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.bounds.width > 400 { return scroll }
            return view.subviews.lazy.compactMap { findReadingScroll(in: $0) }.first
        }
        guard let scroll = findReadingScroll(in: hostingView),
            let document = scroll.documentView
        else { return false }
        var nativeFrame = frame
        if !hostingView.isFlipped { nativeFrame.origin.y = hostingView.bounds.maxY - frame.maxY }
        let target = document.convert(nativeFrame, from: hostingView)
        _ = document.scrollToVisible(target)
        refresh()
        return scroll.documentVisibleRect.insetBy(dx: -1, dy: -1).contains(target)
    }

    func scrollToEnd() -> Bool {
        var scrolls: [NSScrollView] = []
        func visit(_ view: NSView, insideReadingScroll: Bool = false) {
            let isReadingScroll = view is NSScrollView && view.bounds.width > 400
            if let scroll = view as? NSScrollView, isReadingScroll, !insideReadingScroll {
                scrolls.append(scroll)
            }
            for child in view.subviews {
                visit(child, insideReadingScroll: insideReadingScroll || isReadingScroll)
            }
        }
        visit(hostingView)
        guard scrolls.count == 1, let scroll = scrolls.first,
            let document = scroll.documentView
        else { return false }
        let clip = scroll.contentView
        let y =
            document.isFlipped
            ? max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
            : document.bounds.minY
        clip.scroll(to: NSPoint(x: document.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
        refresh()
        let visible = scroll.documentVisibleRect
        return document.bounds.height <= visible.height + 1
            || (document.isFlipped
                ? abs(visible.maxY - document.bounds.maxY) < 1
                : abs(visible.minY - document.bounds.minY) < 1)
    }

    func saveSheetScreenshot(to url: URL) -> Bool {
        guard let view = window.attachedSheet?.contentView,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    func renderedSheetText() -> String? {
        guard let view = window.attachedSheet?.contentView,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return recognizedText(in: bitmap)
    }

    func renderedButtonText(title: String) -> String? {
        guard let button = findButton(title: title, in: hostingView),
            let bitmap = renderedBitmap(), let image = bitmap.cgImage
        else { return nil }
        let frame = hostingView.convert(button.bounds, from: button)
        let scaleX = CGFloat(image.width) / hostingView.bounds.width
        let scaleY = CGFloat(image.height) / hostingView.bounds.height
        let y = hostingView.isFlipped ? frame.minY : hostingView.bounds.height - frame.maxY
        let crop = CGRect(
            x: frame.minX * scaleX, y: y * scaleY,
            width: frame.width * scaleX, height: frame.height * scaleY)
        guard let cropped = image.cropping(to: crop) else { return nil }
        return recognizedText(in: NSBitmapImageRep(cgImage: cropped))
    }

    func buttonLayout(title: String) -> [String: CGFloat]? {
        guard let button = findButton(title: title, in: hostingView) else { return nil }
        return [
            "width": button.bounds.width,
            "intrinsicWidth": button.intrinsicContentSize.width,
            "cellWidth": button.cell?.cellSize.width ?? -1,
            "wrapperWidth": button.superview?.bounds.width ?? -1,
            "wrapperIntrinsicWidth": button.superview?.intrinsicContentSize.width ?? -1,
        ]
    }

    private func findButton(title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { self.findButton(title: title, in: $0) }.first
    }

    private func recognizedText(in bitmap: NSBitmapImageRep) -> String? {
        guard let image = bitmap.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.usesCPUOnly = true
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else {
            return nil
        }
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(
            separator: "\n")
    }

    func semanticRGB(_ color: NSColor) -> [Int]? {
        var result: [Int]?
        func groupSurface(in view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == "settings.semantic-surface.group" { return view }
            return view.subviews.lazy.compactMap { groupSurface(in: $0) }.first
        }
        let appearance =
            color == .underPageBackgroundColor
            ? (groupSurface(in: hostingView)?.effectiveAppearance ?? window.effectiveAppearance)
            : window.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            if let rgb = color.usingColorSpace(.sRGB),
                let background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
            {
                // Compare the rendered system color, including its system-provided alpha,
                // over the page surface. Comparing only the RGB ignores native compositing.
                let alpha: CGFloat = rgb.alphaComponent
                let foreground: [CGFloat] = [
                    rgb.redComponent, rgb.greenComponent, rgb.blueComponent,
                ]
                let behind: [CGFloat] = [
                    background.redComponent, background.greenComponent, background.blueComponent,
                ]
                result = zip(foreground, behind).map { channel, backgroundChannel -> Int in
                    let blended: CGFloat = channel * alpha + backgroundChannel * (1 - alpha)
                    return Int((blended * 255).rounded())
                }
            }
        }
        return result
    }

    func rgb(at point: CGPoint) -> [Int]? {
        // Convert the bitmap itself: colorAt() returns a calibrated NSColor and does not
        // carry the source display's ICC profile through an NSColor-space conversion.
        guard let bitmap = renderedBitmap()?.converting(to: .sRGB, renderingIntent: .default)
        else { return nil }
        let x = Int(point.x * CGFloat(bitmap.pixelsWide) / hostingView.bounds.width)
        let y = Int(point.y * CGFloat(bitmap.pixelsHigh) / hostingView.bounds.height)
        guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
            let color = bitmap.colorAt(x: x, y: y)
        else { return nil }
        return [color.redComponent, color.greenComponent, color.blueComponent].map {
            Int(($0 * 255).rounded())
        }
    }

    /// Inspect the resting text, arrow and body. The system focus ring may use the accent color
    /// and can extend inside a popup's AX frame on newer macOS; sample without that ring, then
    /// restore the exact responder. Thresholds still reject an accent-colored control body.
    func controlColorFractions(in frame: CGRect) -> (neutral: Double, accentBlue: Double)? {
        let responder = window.firstResponder
        window.makeFirstResponder(nil)
        refresh()
        defer {
            window.makeFirstResponder(responder)
            refresh()
        }
        guard let bitmap = renderedBitmap()?.converting(to: .sRGB, renderingIntent: .default)
        else { return nil }
        let scaleX = CGFloat(bitmap.pixelsWide) / hostingView.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / hostingView.bounds.height
        let interior = frame.insetBy(dx: 3, dy: 3)
        guard hostingView.bounds.contains(interior), !interior.isEmpty else { return nil }
        let minX = Int(ceil(interior.minX * scaleX))
        let maxX = Int(floor(interior.maxX * scaleX))
        let minY = Int(ceil(interior.minY * scaleY))
        let maxY = Int(floor(interior.maxY * scaleY))
        guard minX < maxX, minY < maxY else { return nil }
        var total = 0
        var neutral = 0
        var accentBlue = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let r = color.redComponent * 255
                let g = color.greenComponent * 255
                let b = color.blueComponent * 255
                total += 1
                if max(r, max(g, b)) - min(r, min(g, b)) <= 18 { neutral += 1 }
                if b - r > 35 && b - g > 10 { accentBlue += 1 }
            }
        }
        guard total > 0 else { return nil }
        return (Double(neutral) / Double(total), Double(accentBlue) / Double(total))
    }

    private func renderedBitmap() -> NSBitmapImageRep? {
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        else { return nil }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap
    }

    func close() {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        session.send(.windowWillClose)
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }
}

private func colorsMatch(_ observed: [Int]?, _ expected: [Int]?) -> Bool {
    guard let observed, let expected, observed.count == expected.count else { return false }
    return zip(observed, expected).allSatisfy { abs($0 - $1) <= 3 }
}

/// 探针窗口只做离屏布局与位图采集，从不需要真正可见。CI runner 的虚拟屏幕不足
/// 820pt 高时，AppKit 会在 order front／setFrame 路径按可见区压缩窗口（同树在
/// runner 舰队上已实测 653／668 两种高度），1240×820 的设计合同前提即被破坏。
/// 因此拒绝屏幕适配，保证请求尺寸；纯测试桩，不进产品。
@MainActor
private final class UnconstrainedProbeWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }
}
