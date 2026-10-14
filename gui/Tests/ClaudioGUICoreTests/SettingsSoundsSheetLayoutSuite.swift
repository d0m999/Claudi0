import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation
import SoundPacksWindow
import SwiftUI

/// 声音设置 sheet 的弹性列表合同。系统提示音、本包音频、音频管理、生成记录四个「列表型」
/// sheet 的主体必须铺满弹性区：列表与底部按钮之间不得留下死区——历史缺陷是 620pt 的
/// sheet 里列表被压在顶部、只剩三成高度，下半张表单纯白（用户反馈：滚动框只用了界面一半）。
/// 表单型 sheet（命名、AI、本机导入）继续走外层 `ScrollView`，一并守住不回归。
@MainActor
func runSettingsSoundsSheetLayoutSuites() async {
    await suite("声音设置 sheet 布局：四个列表型 sheet 铺满弹性区且滚动可达") {
        await withTempDirectory { root in
            let sounds = root.appendingPathComponent("system", isDirectory: true)
            try! FileManager.default.createDirectory(
                at: sounds, withIntermediateDirectories: true)
            // 与真机 /System/Library/Sounds 同量级（14 条），保证任何受测窗口尺寸下
            // 列表内容都高于可视区，弹性高度与原生滚动都必须真实存在。
            let soundNames = [
                "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse",
                "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
            ]
            for name in soundNames {
                writeFixture(validAIFFData(), to: sounds.appendingPathComponent("\(name).aiff"))
            }
            var checkedFormSheets = false
            for language in [ClaudioAppLanguage.zhHans, .english] {
                for size in [NSSize(width: 1_240, height: 820), NSSize(width: 960, height: 640)] {
                    let name = "\(language.rawValue) \(Int(size.width))"
                    let fixture = makeSheetLayoutEditorFixture(root: root, language: language)
                    let settings = SettingsPresentationFixtures.generalLogin(
                        language: language,
                        route: .sounds(
                            SoundPacksWindowRoute(
                                surface: nil, destination: .pack(packID: "target"))),
                        soundPacksEditor: fixture.owner)
                    let probe = SettingsSoundsNativeLayoutProbe(
                        session: settings.session, size: size)
                    defer { probe.close() }
                    guard await waitForSoundEditorReady(fixture.owner, library: fixture.library)
                    else {
                        expect(false, "\(name) fixture 必须到达 ready")
                        continue
                    }
                    await probe.settle()

                    // 系统提示音（来源菜单第 5 项）：死区缺陷的原始现场。
                    expect(
                        probe.chooseSource(event: .stop, index: 4),
                        "\(name) 生产来源菜单打开系统提示音 sheet")
                    await probe.settle()
                    expectListSheetFills(
                        probe: probe, listIdentifier: "settings.sounds.sheet.system.list",
                        name: "\(name) 系统提示音")
                    expect(
                        sheetListRowCount(probe.sheetContentView) == soundNames.count,
                        "\(name) 系统提示音列表必须真实呈现全部 \(soundNames.count) 条")
                    expect(
                        scrollSheetListToBottom(probe.sheetContentView),
                        "\(name) \(soundNames.count) 条系统提示音必须原生滚动到底全部可达")
                    expect(
                        probe.pressControl("settings.sounds.sheet.close"),
                        "\(name) 关闭系统提示音 sheet")
                    await probe.settle()

                    // 从生成记录选择：内层滚动区同样必须铺满。
                    expect(
                        probe.chooseSource(event: .stop, index: 1),
                        "\(name) 生产来源菜单打开生成记录 sheet")
                    await probe.settle()
                    expectListSheetFills(
                        probe: probe, listIdentifier: "settings.sounds.sheet.history.list",
                        name: "\(name) 生成记录")
                    expect(
                        probe.pressControl("settings.sounds.sheet.close"),
                        "\(name) 关闭生成记录 sheet")
                    await probe.settle()

                    // 从本包选择：清单列表同样必须铺满。
                    expect(
                        probe.chooseSource(event: .stop, index: 2),
                        "\(name) 生产来源菜单打开本包音频 sheet")
                    await probe.settle()
                    expectListSheetFills(
                        probe: probe, listIdentifier: "settings.sounds.sheet.files.list",
                        name: "\(name) 本包音频")
                    expect(
                        sheetListRowCount(probe.sheetContentView) == 1,
                        "\(name) 本包音频列表必须真实呈现包内文件，弹性高度不得由空列表伪装")
                    expect(
                        probe.pressControl("settings.sounds.sheet.close"),
                        "\(name) 关闭本包音频 sheet")
                    await probe.settle()

                    // 管理包内音频…：同一 inventory 列表，管理态无主按钮。
                    expect(
                        probe.pressControl("settings.sounds.manage-files"),
                        "\(name) 包详情打开音频管理 sheet")
                    await probe.settle()
                    expectListSheetFills(
                        probe: probe, listIdentifier: "settings.sounds.sheet.files.list",
                        name: "\(name) 音频管理")
                    expect(
                        probe.pressControl("settings.sounds.sheet.close"),
                        "\(name) 关闭音频管理 sheet")
                    await probe.settle()

                    if !checkedFormSheets {
                        checkedFormSheets = true
                        // 表单型 sheet 不得因分流丢失外层滚动与主按钮。
                        expect(
                            probe.chooseSource(event: .stop, index: 0),
                            "\(name) AI 生成表单仍是生产入口")
                        await probe.settle()
                        expect(
                            probe.hasAttachedSheet
                                && probe.menuAccessibilityElement(
                                    identifier: "settings.sounds.sheet.use") != nil,
                            "\(name) AI 表单型 sheet 仍挂载且保留选用按钮")
                        expect(
                            probe.pressControl("settings.sounds.sheet.close"),
                            "\(name) AI 表单可关闭")
                        await probe.settle()
                        expect(
                            probe.chooseSource(event: .stop, index: 3),
                            "\(name) 本机导入表单仍是生产入口")
                        await probe.settle()
                        expect(probe.hasAttachedSheet, "\(name) 本机导入表单型 sheet 仍挂载")
                        expect(
                            probe.pressControl("settings.sounds.sheet.close"),
                            "\(name) 本机导入表单可关闭")
                        await probe.settle()
                    }

                    if let captureDirectory = ProcessInfo.processInfo.environment[
                        "CLAUDIO_LAYOUT_CAPTURE_DIR"]
                    {
                        try? FileManager.default.createDirectory(
                            atPath: captureDirectory, withIntermediateDirectories: true)
                        expect(
                            probe.chooseSource(event: .stop, index: 4),
                            "\(name) 重新打开系统提示音 sheet")
                        await probe.settle()
                        expect(
                            probe.saveSheetScreenshot(
                                to: URL(fileURLWithPath: captureDirectory)
                                    .appendingPathComponent(
                                        "sheet-system-\(Int(size.width))"
                                            + "-\(language.rawValue).png")),
                            "\(name) 系统提示音 sheet 截图可保存")
                        expect(
                            probe.pressControl("settings.sounds.sheet.close"),
                            "\(name) 关闭截图用 sheet")
                        await probe.settle()
                    }
                }
            }
        }
    }
}

/// 列表型 sheet 的几何合同：列表铺满 620−2×24 的内容宽度，底部与 sheet 之间只剩
/// 页脚（内边距 + 间距 + 按钮行，共约 68pt；阈值 112 留余量）。旧实现（无条件外包
/// ScrollView + 内部 340/380pt 上限）实测死区 241–400pt，四个 sheet × 双语 × 两窗口
/// 全部违规；本断言即该缺陷的回归守卫。
@MainActor
private func expectListSheetFills(
    probe: SettingsSoundsNativeLayoutProbe,
    listIdentifier: String,
    name: String
) {
    probe.refresh()
    guard probe.hasAttachedSheet else {
        expect(false, "\(name) 列表型 sheet 必须实际挂载")
        return
    }
    guard let sheet = probe.sheetContentView,
        let listFrame = SoundPacksLayoutRecorder.frames[listIdentifier]
    else {
        expect(false, "\(name) 必须记录列表几何：\(listIdentifier)")
        return
    }
    expect(
        listFrame.minX >= 24 - 1 && listFrame.maxX <= sheet.bounds.maxX - 24 + 1
            && listFrame.width >= 620 - 24 * 2 - 1,
        "\(name) 列表必须铺满 sheet 内容宽度：\(listFrame), sheet=\(sheet.bounds)")
    expect(
        sheet.bounds.height - listFrame.maxY <= 112,
        "\(name) 列表与底部按钮之间不得留下死区：gap=\(sheet.bounds.height - listFrame.maxY)")
}

/// sheet 内列表的真实行数：直接读 AppKit 底层（NSTableView／NSCollectionView）。
/// List 行内容在本 harness 里无法经 AX 标识触达，但几何断言可能被空列表伪装满足，
/// 行数让「内容真实在场」成为合同的一部分。
@MainActor
private func sheetListRowCount(_ contentView: NSView?) -> Int? {
    guard let contentView else { return nil }
    func find(in view: NSView) -> Int? {
        if let table = view as? NSTableView { return table.numberOfRows }
        if let collection = view as? NSCollectionView {
            guard collection.numberOfSections > 0 else { return 0 }
            return (0..<collection.numberOfSections).reduce(0) {
                $0 + collection.numberOfItems(inSection: $1)
            }
        }
        return view.subviews.lazy.compactMap { find(in: $0) }.first
    }
    return find(in: contentView)
}

/// 把 sheet 内的主滚动容器滚到底，返回是否到达文档底部。
@MainActor
private func scrollSheetListToBottom(_ contentView: NSView?) -> Bool {
    guard let contentView else { return false }
    func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.bounds.width > 400 { return scroll }
        return view.subviews.lazy.compactMap { findScroll(in: $0) }.first
    }
    guard let scroll = findScroll(in: contentView), let document = scroll.documentView else {
        return false
    }
    let clip = scroll.contentView
    let bottom = max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
    clip.scroll(to: NSPoint(x: document.bounds.minX, y: bottom))
    scroll.reflectScrolledClipView(clip)
    return scroll.documentVisibleRect.maxY >= document.bounds.maxY - 1
}

@MainActor
private func makeSheetLayoutEditorFixture(root: URL, language: ClaudioAppLanguage)
    -> (owner: SoundPacksEditorOwner, library: SoundPackLibrary)
{
    let packs = root.appendingPathComponent("packs-\(language.rawValue)", isDirectory: true)
    writeFixture(
        #"{"id":"target","name":"hi test","events":{"stop":"stop.mp3"},"future":{"keep":true}}"#,
        to: packs.appendingPathComponent("target/manifest.json"))
    writeFixture(validAIFFData(), to: packs.appendingPathComponent("target/stop.mp3"))
    var environment = makeAudioImportEnvironment(userPacksDirectory: packs)
    // 注入 14 条临时系统提示音，替换真机 /System/Library/Sounds，保证断言确定性。
    environment.systemSoundCatalog = SystemSoundCatalog(
        directory: root.appendingPathComponent("system"))
    let configFile = root.appendingPathComponent("config-\(language.rawValue).json")
    writeFixture(#"{"selected_pack":"target","events":{"stop":true}}"#, to: configFile)
    let library = SoundPackLibrary(environment: environment)
    let owner = SoundPacksEditorOwner(
        configFile: configFile,
        lockFile: root.appendingPathComponent("config-\(language.rawValue).lock"),
        environment: environment,
        soundPackLibrary: library,
        refreshCoordinator: SoundPacksRefreshCoordinator())
    return (owner, library)
}
