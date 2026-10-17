import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

/// 事件行「更换声音」入口与声音页拖放导入（plan/PLAN-EVENT-ROW-SOUND-ENTRY-AND-DROP.md）。
/// 只测投影与会话的外部事实：入口可用性、路由动词、焦点顺序、drop 预览态与包可编辑性。
@MainActor
func runEventRowSoundEntrySuites() async {
    suite("面板事件行声音入口：按包性质暴露路由与动词键，缺上下文不暴露入口") {
        let rows = Event.allCases.map {
            EventRow(event: $0, coverage: .present(fileName: "tone.aiff"), enabled: true)
        }
        let userPack = panelEventPresentations(
            rows: rows, scope: .global, masterVolume: 1, language: .zhHans,
            soundEntryContext: PanelSoundEntryContext(isBuiltinReadOnly: false))
        expect(
            userPack.count == Event.allCases.count
                && userPack.allSatisfy { $0.soundEntry?.route == .editEvent },
            "用户包：五个事件行都暴露定向编辑入口")
        expect(
            userPack.first?.soundEntry?.tooltipKey == .panelEventSoundEntryChange
                && userPack.first?.soundEntry?.accessibilityLabelKey
                    == .panelEventSoundEntryChangeLabel,
            "用户包入口的 tooltip 与无障碍标签都使用「更换」动词")
        let builtin = panelEventPresentations(
            rows: rows, scope: .global, masterVolume: 1, language: .zhHans,
            soundEntryContext: PanelSoundEntryContext(isBuiltinReadOnly: true))
        expect(
            builtin.allSatisfy { $0.soundEntry?.route == .copyAndApply },
            "出厂包：五个事件行都暴露复制并编辑入口")
        expect(
            builtin.first?.soundEntry?.tooltipKey == .panelEventSoundEntryView
                && builtin.first?.soundEntry?.accessibilityLabelKey
                    == .panelEventSoundEntryViewLabel,
            "出厂包入口的 tooltip 与无障碍标签都使用「查看」动词")
        let noContext = panelEventPresentations(
            rows: rows, scope: .global, masterVolume: 1, language: .zhHans)
        expect(
            noContext.allSatisfy { $0.soundEntry == nil },
            "缺省上下文（工作区页等调用点）不暴露入口")
        let degraded = Event.allCases.map {
            EventRow(event: $0, coverage: .broken(fileName: "gone.mp3"), enabled: false)
        }
        let degradedEntries = panelEventPresentations(
            rows: degraded, scope: .global, masterVolume: 1, language: .zhHans,
            soundEntryContext: PanelSoundEntryContext(isBuiltinReadOnly: false))
        expect(
            degradedEntries.allSatisfy { $0.soundEntry?.route == .editEvent },
            "断链/静音事件行同样保留入口（深链落点是同一事件行）")
    }

    suite("面板焦点顺序：声音入口排在试听之前，缺省不制造 Tab stop") {
        let rows = Event.allCases.map {
            EventRow(event: $0, coverage: .present(fileName: "tone.aiff"), enabled: true)
        }
        let withEntry = panelEventPresentations(
            rows: rows, scope: .global, masterVolume: 1, language: .english,
            soundEntryContext: PanelSoundEntryContext(isBuiltinReadOnly: false))
        let order = panelFocusOrder(
            .activityOperational(
                events: withEntry, hasActivityOverview: false, hasMasterVolume: false))
        for event in Event.allCases {
            guard
                let entryIndex = order.firstIndex(of: .eventSoundEntry(event)),
                let previewIndex = order.firstIndex(of: .eventPreview(event))
            else {
                expect(false, "健康事件行必须同时提供声音入口与试听焦点：\(event)")
                continue
            }
            expect(
                entryIndex < previewIndex,
                "声音入口的视觉位置在试听左侧，Tab 顺序必须一致：\(event)")
        }
        let withoutEntry = panelEventPresentations(
            rows: rows, scope: .global, masterVolume: 1, language: .english)
        let plainOrder = panelFocusOrder(
            .activityOperational(
                events: withoutEntry, hasActivityOverview: false, hasMasterVolume: false))
        expect(
            !plainOrder.contains(.eventSoundEntry(.stop)),
            "无入口上下文不得制造幽灵 Tab stop")
        expect(
            panelFirstFocusTarget(
                .activityOperational(
                    events: withEntry, hasActivityOverview: false, hasMasterVolume: false),
                requestedTarget: .eventSoundEntry(.notification)) == .eventSoundEntry(.notification),
            "设置归还的显式焦点目标仍可落在声音入口上")
    }

    await suite("声音页拖放：文件 URL 直接进入与选择面板一致的预览态，取消保留旧绑定") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["a"])
            let owner = fixture.owner
            let route = SoundPacksWindowRoute(surface: nil, destination: .pack(packID: "a"))
            _ = owner.send(.activate(.sounds(route: route, requestRevision: 1)))
            _ = await fixture.library.refreshSnapshot(trigger: .initial)
            guard await waitForSoundEditorReady(owner, library: fixture.library) else { return }
            let session = owner.soundSelection
            guard session.begin(event: .stop, mode: .local) != nil else {
                expect(false, "用户包事件可开始本机导入表单")
                return
            }
            let source = root.appendingPathComponent("dropped.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let originalSource = try? Data(contentsOf: source)
            expect(
                await session.prepareLocalSound(fromDrop: source) == .ready,
                "drop 与「导入音频 → 选文件」进入同一预览态")
            guard let preview = session.localPreview else {
                expect(false, "预览态必须持有已验证的暂存文件")
                return
            }
            let manifest = root.appendingPathComponent("packs/a/manifest.json")
            let originalManifest = try? Data(contentsOf: manifest)
            session.end()
            expect(
                session.localPreview == nil && session.context == nil,
                "取消/关闭清空预览，不绑定事件")
            await session.waitForResourceCleanupForTesting()
            expect(
                !FileManager.default.fileExists(atPath: preview.fileURL.path),
                "取消释放暂存文件")
            expect(
                (try? Data(contentsOf: manifest)) == originalManifest,
                "取消保留旧绑定（manifest 不被改写）")
            expect(
                (try? Data(contentsOf: source)) == originalSource,
                "取消不删除或改写外部源文件")
        }
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["a"])
            let owner = fixture.owner
            let route = SoundPacksWindowRoute(surface: nil, destination: .pack(packID: "a"))
            _ = owner.send(.activate(.sounds(route: route, requestRevision: 1)))
            _ = await fixture.library.refreshSnapshot(trigger: .initial)
            guard await waitForSoundEditorReady(owner, library: fixture.library) else { return }
            let session = owner.soundSelection
            guard session.begin(event: .stop, mode: .local) != nil else {
                expect(false, "用户包事件可开始本机导入表单")
                return
            }
            let invalid = root.appendingPathComponent("notes.txt")
            writeFixture("not audio", to: invalid)
            let result = await session.prepareLocalSound(fromDrop: invalid)
            guard case .failed = result else {
                expect(false, "不合规文件必须被拒绝，实得 \(result)")
                return
            }
            expect(session.localPreview == nil, "被拒绝的文件不进入预览态")
            session.end()
        }
    }

    await suite("声音页投影：按包可编辑性暴露事件行拖放可用性") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["a"])
            let owner = fixture.owner
            let route = SoundPacksWindowRoute(surface: nil, destination: .pack(packID: "a"))
            _ = owner.send(.activate(.sounds(route: route, requestRevision: 1)))
            _ = await fixture.library.refreshSnapshot(trigger: .initial)
            guard await waitForSoundEditorReady(owner, library: fixture.library) else { return }
            guard case .sounds(let sounds) = owner.presentation.mode else {
                expect(false, "包详情页必须发布 Sounds 投影")
                return
            }
            expect(
                sounds.acceptsEventSoundDrop && sounds.selectedPack?.isBuiltinReadOnly == false,
                "用户包详情页：事件行接受拖放（导向说明行同源可见）")
        }
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root, packIDs: ["factory-a"], builtinPackIDs: ["factory-a"])
            let owner = fixture.owner
            let route = SoundPacksWindowRoute(
                surface: nil, destination: .pack(packID: "factory-a"))
            _ = owner.send(.activate(.sounds(route: route, requestRevision: 1)))
            _ = await fixture.library.refreshSnapshot(trigger: .initial)
            guard await waitForSoundEditorReady(owner, library: fixture.library) else { return }
            guard case .sounds(let sounds) = owner.presentation.mode else {
                expect(false, "出厂包详情页必须发布 Sounds 投影")
                return
            }
            expect(
                !sounds.acceptsEventSoundDrop
                    && sounds.selectedPack?.isBuiltinReadOnly == true,
                "出厂包详情页：事件行不接受拖放、不出现导向说明行")
        }
    }
}
