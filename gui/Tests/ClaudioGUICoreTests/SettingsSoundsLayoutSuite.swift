import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation
import SoundPacksWindow
import SwiftUI
import Vision

@MainActor
func runSettingsSoundsLayoutSuites() {
    suite("设置原生呈现：八页暖色底、三组留白与独立事件卡") {
        for size in [NSSize(width: 1_240, height: 820), NSSize(width: 960, height: 640)] {
            for dark in [false, true] {
                for destination in SettingsDestination.allCases {
                    let fixture = SettingsPresentationFixtures.generalLogin(
                        language: size.width == 960 ? .english : .zhHans,
                        route: .destination(destination),
                        availability: PreviewFixtures.settingsRouteAvailability)
                    let probe = SettingsSoundsNativeLayoutProbe(
                        session: fixture.session, size: size,
                        appearance: dark ? .darkAqua : .aqua)
                    defer { probe.close() }
                    let name = "\(destination.rawValue) \(size.width) \(dark ? "dark" : "light")"
                    let frames = SoundPacksLayoutRecorder.frames
                    guard let content = frames["settings.content"] else {
                        expect(false, "\(name) 内容区必须实际挂载")
                        continue
                    }
                    let expectedBackground = dark ? [26, 24, 21] : [250, 248, 244]
                    for y in [40.0, size.height / 2, size.height - 20] {
                        let observed = probe.rgb(at: CGPoint(x: content.minX + 8, y: y))
                        expect(
                            colorsMatch(observed, expectedBackground),
                            "\(name) 页头、滚动区和底部须连续使用设置底色：\(observed as Any)")
                    }
                    let sidebarRows = SettingsDestination.allCases.compactMap {
                        frames["settings.sidebar.item.\($0.rawValue)"]
                    }
                    expect(sidebarRows.count == 8, "\(name) 八页侧栏必须实际挂载")
                    if sidebarRows.count == 8 {
                        for index in 1..<8 {
                            let gap = sidebarRows[index].minY - sidebarRows[index - 1].maxY
                            expect(
                                abs(gap - ([4, 6].contains(index) ? 24 : 3)) < 1,
                                "\(name) 侧栏第 \(index) 处组间／组内留白：\(gap)")
                        }
                    }
                    if destination == .eventsAndSounds || destination == .sounds {
                        let prefix = destination == .sounds ? "sound-packs" : "workspace"
                        let cards = Event.allCases.compactMap {
                            frames["\(prefix).event-card.\($0.rawValue)"]
                        }
                        expect(cards.count == 5, "\(name) 五事件必须各自成卡：\(frames.keys.sorted())")
                        for pair in zip(cards, cards.dropFirst()) {
                            expect(
                                abs(pair.1.minY - pair.0.maxY - 12) < 1,
                                "\(name) 事件卡间距必须为 12 pt：\(pair)")
                        }
                        let selectorID =
                            destination == .sounds
                            ? "sound-packs.selector.card" : "workspace.scope-selector.card"
                        let infoID =
                            destination == .sounds
                            ? "sound-packs.information.card" : "workspace.configuration.card"
                        if let selector = frames[selectorID] {
                            expect(selector.height >= 70, "\(name) 选择器卡至少 70 pt")
                            let observed = probe.rgb(
                                at: CGPoint(x: selector.midX, y: selector.minY + 5))
                            expect(
                                colorsMatch(observed, dark ? [28, 26, 23] : [255, 255, 255]),
                                "\(name) 卡片必须使用设置专用表面：\(observed as Any)")
                            let border = probe.rgb(
                                at: CGPoint(x: selector.midX, y: selector.minY + 0.25))
                            expect(
                                colorsMatch(border, dark ? [63, 60, 55] : [228, 225, 224]),
                                "\(name) 卡片须显示真实 1 pt 描边：\(border as Any)")
                            if let info = frames["workspace.migration.card"] ?? frames[infoID] {
                                expect(
                                    abs(info.minY - selector.maxY - 36) < 1,
                                    "\(name) 选择器后留白须为 36 pt：\(selector), \(info)")
                            }
                        } else {
                            expect(false, "\(name) 选择器卡必须实际挂载")
                        }
                        if let info = frames[infoID], let first = cards.first {
                            expect(
                                abs(first.minY - info.maxY - 24) < 1,
                                "\(name) 配置／包信息卡至五事件留白须为 24 pt：\(info), \(first)")
                        }
                        let auxiliaryID =
                            destination == .sounds
                            ? "settings.sounds.ai-cue.service" : "workspace.auxiliary.card"
                        if let auxiliary = frames[auxiliaryID], let last = cards.last {
                            if size.width == 960 {
                                expect(
                                    auxiliary.minY > last.maxY,
                                    "\(name) 窄窗口辅助卡须放在五事件与主操作之后")
                            } else {
                                expect(
                                    abs(auxiliary.width - 260) < 1 && auxiliary.minX > last.maxX,
                                    "\(name) 宽窗口辅助卡须在右侧且宽 260 pt：\(auxiliary)")
                            }
                        } else {
                            expect(false, "\(name) 真实辅助卡必须挂载")
                        }
                    }
                }
            }
        }
    }

    suite("设置原生呈现：系统高对比度外观保留实色表面") {
        for dark in [false, true] {
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .events(scope: .global, event: nil),
                availability: PreviewFixtures.settingsRouteAvailability)
            let probe = SettingsSoundsNativeLayoutProbe(
                session: fixture.session, size: NSSize(width: 1_240, height: 820),
                appearance: dark
                    ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            defer { probe.close() }
            guard
                let selector = SoundPacksLayoutRecorder.frames["workspace.scope-selector.card"]
            else { expect(false, "辅助功能检查必须挂载选择器卡"); continue }
            let interior = probe.rgb(at: CGPoint(x: selector.midX, y: selector.minY + 5))
            expect(
                colorsMatch(interior, dark ? [28, 26, 23] : [255, 255, 255]),
                "高对比度外观不得改变卡片实色：\(interior as Any)")
        }
    }

    suite("声音设置原生挂载：两种窗口尺寸和语言保留包列表、滚动详情与固定操作栏") {
        for (size, language, appearance) in [
            (NSSize(width: 1_240, height: 820), ClaudioAppLanguage.zhHans, NSAppearance.Name.aqua),
            (NSSize(width: 960, height: 640), ClaudioAppLanguage.english, .darkAqua),
        ] {
            let fixture = SettingsPresentationFixtures.generalLogin(
                language: language,
                route: .sounds(.overview),
                availability: PreviewFixtures.settingsRouteAvailability)
            let probe = SettingsSoundsNativeLayoutProbe(
                session: fixture.session,
                size: size,
                appearance: appearance)
            let frames = SoundPacksLayoutRecorder.frames
            let name = "\(Int(size.width))×\(Int(size.height)) \(language.rawValue)"
            guard let sidebar = frames["settings.sidebar"],
                let title = frames["settings.title.sounds"],
                let list = frames["sound-packs.pack-list"],
                let scroll = frames["sound-packs.detail-scroll"],
                let action = frames["sound-packs.action-bar"],
                let editor = frames["sound-packs.editor"],
                let service = frames["settings.sounds.ai-cue.service"]
            else {
                expect(false, "\(name) 未挂载完整声音布局：\(frames.keys.sorted())")
                probe.close()
                continue
            }
            expect(
                sidebar.minY <= 2 && sidebar.maxY >= size.height - 2
                    && title.minY >= 0 && title.maxY <= editor.minY + 2,
                "\(name) 侧栏须贴顶且标题在包编辑器上方：\(frames)")
            expect(
                editor.minY >= title.maxY - 2 && editor.maxY <= size.height + 2
                    && list.width > 120 && list.height >= 64
                    && list.maxY <= size.height + 2,
                "\(name) 顶部完整库选择器须在窗口内可达：\(frames)")
            expect(
                scroll.width > 200 && scroll.height > 100
                    && list.maxY <= scroll.minY + 2
                    && service.minY >= scroll.minY - 2
                    && service.width <= scroll.width + 2,
                "\(name) 服务卡须复用同一个详情滚动区，窄窗口允许移到卡片后：\(frames)")
            expect(
                action.minY >= scroll.maxY - 3 && action.maxY <= size.height + 2,
                "\(name) 包操作栏须固定在详情滚动区下方且保持可见：\(frames)")
            let mappingRows = Event.allCases.compactMap {
                frames["sound-packs.event.\($0.rawValue)"]
            }
            let generationActions = Event.allCases.compactMap {
                frames["settings.sounds.ai-cue.event.\($0.rawValue)"]
            }
            expect(
                mappingRows.count == Event.allCases.count
                    && generationActions.count == Event.allCases.count
                    && zip(mappingRows, generationActions).allSatisfy { pair in
                        pair.0.maxY <= pair.1.minY + 2
                            && abs(pair.0.minX - pair.1.minX) < 30
                    },
                "\(name) 每个事件只能在包映射行下接一处描述生成动作：\(frames)")
            expect(
                Event.allCases.allSatisfy { event in
                    guard let card = frames["sound-packs.event-card.\(event.rawValue)"],
                        let action = frames["settings.sounds.ai-cue.event.\(event.rawValue)"]
                    else { return false }
                    return card.contains(action)
                },
                "\(name) 每个 AI 生成入口须属于自己的独立事件卡")
            let visibleText = probe.recognizedText()
            expect(
                visibleText.map {
                    $0.count >= 5 && !$0.contains(where: { $0.contains("%@") })
                } == true,
                "\(name) 可见声音页不得出现原样格式占位符：\(visibleText ?? [])")
            if let captureDirectory = ProcessInfo.processInfo.environment[
                "CLAUDIO_LAYOUT_CAPTURE_DIR"]
            {
                let file = URL(fileURLWithPath: captureDirectory).appendingPathComponent(
                    "sounds-\(Int(size.width))-\(language.rawValue).png")
                expect(probe.saveScreenshot(to: file), "\(name) 原生挂载截图必须能保存")
            }
            probe.close()
        }
    }

    suite("声音设置原生挂载：空组和只读深链仍在同一详情区") {
        let draftFixture = SettingsPresentationFixtures.generalLogin(
            route: .sounds(.overview),
            availability: PreviewFixtures.settingsRouteAvailability)
        let draftProbe = SettingsSoundsNativeLayoutProbe(
            session: draftFixture.session,
            size: NSSize(width: 960, height: 640))
        expect(
            draftFixture.soundPacksEditor.beginAICuePackDraft(language: .zhHans),
            "空组必须经现有 owner 创建")
        draftProbe.refresh()
        expect(
            Event.allCases.allSatisfy {
                SoundPacksLayoutRecorder.frames["settings.sounds.ai-cue.event.\($0.rawValue)"]
                    != nil
            },
            "未发布空组也必须保留唯一五事件生成入口")
        draftProbe.close()

        let readonlyFixture = SettingsPresentationFixtures.generalLogin(
            route: .sounds(.copyAndApply(packID: "gallery-pack", event: .stop)),
            availability: PreviewFixtures.settingsRouteAvailability,
            builtinPackIDs: ["gallery-pack"])
        let readonlyProbe = SettingsSoundsNativeLayoutProbe(
            session: readonlyFixture.session,
            size: NSSize(width: 1_240, height: 820))
        expect(readonlyFixture.aiCueViewModel.session == nil, "只读编辑深链不启动 AI 会话")
        if case .sounds(let presentation) = readonlyFixture.soundPacksEditor.presentation.mode {
            expect(presentation.route.editTarget?.event == .stop, "只读深链定位真实编辑事件")
        } else {
            expect(false, "必须进入同一声音编辑 owner")
        }
        expect(
            Event.allCases.allSatisfy {
                SoundPacksLayoutRecorder.frames["settings.sounds.ai-cue.event.\($0.rawValue)"]
                    == nil
            } && SoundPacksLayoutRecorder.frames["sound-packs.action-bar"] != nil,
            "只读包隐藏生成入口并保留复制操作栏")
        readonlyProbe.close()
    }

    suite("声音设置原生挂载：切换检查包清理旧事件会话") {
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
        if case .sounds(let sounds) = fixture.soundPacksEditor.presentation.mode,
            let action = sounds.packs.first(where: { $0.id == "settings-fixture-pack" })?
                .inspectAction
        {
            _ = fixture.soundPacksEditor.send(.invoke(action))
            probe.refresh()
            expect(
                fixture.aiCueViewModel.session == nil
                    && fixture.aiCueViewModel.generation == nil,
                "切换包后旧目标会话与候选必须失效")
            expect(
                SoundPacksLayoutRecorder.frames["sound-packs.pack-list"] != nil
                    && SoundPacksLayoutRecorder.frames["sound-packs.action-bar"] != nil,
                "切换包后仍保留包列表和固定操作栏")
        } else {
            expect(false, "测试包必须提供 owner 的检查动作")
        }
        probe.close()
    }
}

@MainActor
private final class SettingsSoundsNativeLayoutProbe {
    private let window: UnconstrainedProbeWindow
    private let hostingView: NSHostingView<SettingsRootView>
    private let requestedSize: NSSize

    init(
        session: SettingsPresentationSession,
        size: NSSize,
        appearance: NSAppearance.Name = .aqua
    ) {
        _ = NSApplication.shared
        SoundPacksLayoutRecorder.reset()
        requestedSize = size
        window = UnconstrainedProbeWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        hostingView = NSHostingView(rootView: SettingsRootView(session: session))
        hostingView.frame = NSRect(origin: .zero, size: size)
        window.contentView = hostingView
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
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

    func refresh() {
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
            hostingView.layoutSubtreeIfNeeded()
        }
    }

    func recognizedText() -> [String]? {
        guard let image = renderedBitmap()?.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        // Deterministic inspection must not wait on the system Neural Engine service.
        request.usesCPUOnly = true
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard
            (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil
        else { return nil }
        return request.results?.compactMap { $0.topCandidates(1).first?.string }
    }

    func saveScreenshot(to url: URL) -> Bool {
        guard let data = renderedBitmap()?.representation(using: .png, properties: [:])
        else { return false }
        return (try? data.write(to: url)) != nil
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

    private func renderedBitmap() -> NSBitmapImageRep? {
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        else { return nil }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}

private func colorsMatch(_ observed: [Int]?, _ expected: [Int]) -> Bool {
    guard let observed, observed.count == expected.count else { return false }
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
