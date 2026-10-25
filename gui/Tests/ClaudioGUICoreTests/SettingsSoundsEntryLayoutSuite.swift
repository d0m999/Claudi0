import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation
import SoundPacksWindow

@MainActor
func runSettingsSoundsEntryLayoutSuites() async {
    await suite("声音包入口离屏布局：合法长名称换行，收藏按钮完整显示，缩放后重新排版") {
        await withTempDirectory { root in
            let longName = String(repeating: "声音包名称", count: 10) + "测试"
            expect(
                longName.count == 52 && (try? AICuePackName(longName)) != nil,
                "回归夹具使用合法的 52 字符包名")
            for language in [ClaudioAppLanguage.zhHans, .english] {
                for starred in [false, true] {
                    let owner = SoundPacksEditorOwner.stateGalleryFixture(
                        previewConfig: ClaudioConfig(selectedPack: "long"),
                        packCards: [("long", longName), ("short", "短包名")].map { id, name in
                            PackCard(
                                id: id, name: name, isCC0: true,
                                presentEvents: Set(Event.allCases), state: .complete,
                                isSelected: id == "long")
                        },
                        selectedPackID: "long", selectedEventRows: [],
                        starredPackIDs: starred ? ["long"] : [],
                        environment: makeAudioImportEnvironment(
                            userPacksDirectory: root.appendingPathComponent("packs")))
                    let fixture = SettingsPresentationFixtures.generalLogin(
                        temporaryParent: root, language: language, route: .sounds(.overview),
                        soundPacksEditor: owner)
                    SoundPacksLayoutRecorder.reset()
                    let shell = SettingsNativeShellController(session: fixture.session)
                    let window = NSPanel(
                        contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                        styleMask: [
                            .titled, .nonactivatingPanel, .fullSizeContentView, .resizable,
                        ],
                        backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentViewController = shell
                    shell.install(in: window)
                    defer {
                        fixture.session.send(.windowWillClose)
                        window.contentViewController = nil
                        window.close()
                    }
                    var narrowTextHeight: CGFloat?
                    var originalEntry: NSView?
                    for width: CGFloat in [960, 1240, 960] {
                        window.setContentSize(NSSize(width: width, height: 640))
                        for _ in 0..<6 {
                            await Task.yield()
                            shell.view.layoutSubtreeIfNeeded()
                            pumpSoundsEntryLayoutRunLoop()
                        }
                        let name = "\(language.rawValue)/starred=\(starred)/\(Int(width))"
                        let frames = SoundPacksLayoutRecorder.frames
                        guard let reading = frames["settings.reading.sounds"],
                            let detail = frames["settings.sounds.pack.long.detail"],
                            let text = frames["settings.sounds.pack.long.name"],
                            let shortText = frames["settings.sounds.pack.short.name"],
                            let favorite = frames["settings.sounds.pack.long.panel"]
                        else {
                            expect(false, "\(name) 必须挂载生产列表的名称、入口与收藏按钮几何")
                            continue
                        }
                        expect(!window.isVisible, "布局回归不得展示窗口或获取前台焦点")
                        expect(
                            abs((window.contentView?.bounds.width ?? 0) - width) < 1,
                            "\(name) 必须保持要求的窗口宽度")
                        expect(
                            reading.maxX <= width && detail.minX >= reading.minX,
                            "\(name) 阅读列和入口保留在窗口内：\(reading), \(detail)")
                        expect(
                            detail.maxX <= favorite.minX && favorite.maxX <= reading.maxX,
                            "\(name) 收藏按钮完整留在阅读列内且不覆盖入口：\(detail), \(favorite)")
                        expect(
                            detail.insetBy(dx: -1, dy: -1).contains(text),
                            "\(name) 完整包名留在可点击的详情入口内：\(text), \(detail)")
                        if let entry = soundsEntryView(in: shell.view) {
                            expect(
                                entry.acceptsFirstResponder && entry.accessibilityRole() == .button
                                    && entry.accessibilityLabel() == longName,
                                "\(name) 入口保留原生焦点资格、按钮语义和完整名称")
                            expect(
                                abs(entry.bounds.width - detail.width) < 1
                                    && abs(entry.bounds.height - detail.height) < 1,
                                "\(name) 原生交互区域覆盖整个换行后的入口")
                            let point = entry.convert(
                                NSPoint(x: entry.bounds.midX, y: entry.bounds.midY),
                                to: shell.view.superview)
                            expect(
                                shell.view.hitTest(point) === entry,
                                "\(name) 真实命中测试到达原生按钮")
                            if let originalEntry {
                                expect(originalEntry === entry, "缩放保留原生焦点控件身份")
                            } else {
                                originalEntry = entry
                            }
                        } else {
                            expect(false, "\(name) 必须挂载原生包详情入口")
                        }
                        if width == 960 {
                            expect(
                                text.height > shortText.height * 1.5,
                                "\(name) 长包名必须换行：长名称 \(text)，短名称 \(shortText)")
                            if let narrowTextHeight {
                                expect(
                                    abs(text.height - narrowTextHeight) < 1,
                                    "缩窄后必须恢复原换行高度")
                            } else {
                                narrowTextHeight = text.height
                            }
                        } else if let narrowTextHeight {
                            expect(
                                text.height <= narrowTextHeight,
                                "加宽后按新的可用宽度排版")
                        }
                        print("  \(name): name=\(text), favorite=\(favorite)")
                    }
                    let navigationVersion = fixture.session.navigationHistory.version
                    expect(
                        originalEntry?.accessibilityPerformPress() == true,
                        "原生按钮可独立激活详情导航")
                    expect(
                        fixture.session.state.soundsDetail == .pack(packID: "long")
                            && fixture.session.navigationHistory.version == navigationVersion + 1,
                        "一次激活只导航一次")
                    if case .sounds(let sounds) = owner.presentation.mode {
                        expect(
                            sounds.packs.first(where: { $0.id == "long" })?.isStarred == starred,
                            "详情导航不改变收藏状态")
                    } else {
                        expect(false, "详情导航保留声音包 owner")
                    }
                }
            }
        }
    }
}

@MainActor
private func soundsEntryView(in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == "settings.sounds.pack.long",
        view.accessibilityRole() == .button
    {
        return view
    }
    return view.subviews.lazy.compactMap { soundsEntryView(in: $0) }.first
}

@MainActor
private func pumpSoundsEntryLayoutRunLoop() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
}
