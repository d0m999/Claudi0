import ClaudioCore
import ClaudioGUICore
import Foundation
import SoundPacksWindow

@MainActor
private final class RedesignPlayback: SoundPacksEditorNativeEffectsAdapter {
    var callbacks: [@MainActor @Sendable (Bool) -> Void] = []
    var volumes: [Double] = []
    var stops = 0
    func selectAudioFiles(allowsMultipleSelection: Bool) -> [URL] { [] }
    func playAudio(fileURL: URL, volume: Double) -> TimeInterval? { 1 }
    func playAudio(
        fileURL: URL, volume: Double, completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Bool {
        volumes.append(volume); callbacks.append(completion); return true
    }
    func stopAudio() { stops += 1 }
    func revealInFinder(fileURL: URL) {}
}

@MainActor
func runSoundsRedesignCompositionSuites() async {
    await suite("声音设置核心集成：持久草稿、本地预览字节、首次发布、改名与组选包隔离") {
        await withTempDirectory { root in
            writeFixture(
                #"{"selected_pack":"original","future":{"retained":true}}"#,
                to: root.appendingPathComponent("config.json"))
            let fixture = CompositionFixture(root: root)
            defer { fixture.cleanup() }
            do {
                let app = try fixture.build()
                let owner = app.soundPacksEditorOwner
                _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 1)))
                _ = await app.soundPackLibrary.refreshSnapshot(trigger: .initial)
                for _ in 0..<32 { await Task.yield() }
                let draft = try await owner.createNamedDraft(AICuePackName("我的声音"))
                let reconstructed = SoundPackDraftStore(
                    directory: owner.draftStore.directory, environment: app.audioEnvironment)
                await reconstructed.refresh()
                expect(reconstructed.snapshot.drafts == [draft], "新 owner 从磁盘恢复稳定草稿身份和名称")
                expect(
                    !FileManager.default.fileExists(
                        atPath: root.appendingPathComponent("packs/\(draft.packID)").path),
                    "命名草稿不发布为空安装包")
                do {
                    _ = try await reconstructed.create(name: AICuePackName("我的声音"));
                    expect(false, "重复名称必须拒绝")
                } catch {}
                let source = root.appendingPathComponent("original.mp3")
                writeFixture(validMP3ID3Data(), to: source)
                let preview = try await owner.prepareLocalSound(source)
                writeFixture("changed external source", to: source)
                guard let selection = owner.beginSoundSelection(event: .stop) else {
                    expect(false, "草稿目标必须可进入来源选择"); return
                }
                let result = await owner.useLocalSound(preview, selection: selection)
                await preview.discard()
                guard case .adopted(let adopted) = result else {
                    expect(false, "首音发布失败：\(result)"); return
                }
                expect(adopted.importedFile.packID == draft.packID, "首次发布保留草稿 ID")
                expect(
                    (try? Data(contentsOf: adopted.importedFile.destinationURL))
                        == validMP3ID3Data(), "采用预览验证字节，不能重新读取已变化的外部源")
                await owner.waitForMutationTransactionsToQuiesceForTesting()
                await owner.draftStore.refresh()
                expect(owner.draftStore.snapshot.drafts.isEmpty, "已发布身份不再重复投影为草稿")
                try await owner.renameInstalledPack(
                    packID: draft.packID, name: AICuePackName("正式声音"))
                let manifest = try Data(
                    contentsOf: root.appendingPathComponent("packs/\(draft.packID)/manifest.json"))
                let json = try JSONSerialization.jsonObject(with: manifest) as! [String: Any]
                expect(
                    json["name"] as? String == "正式声音" && json["id"] as? String == draft.packID,
                    "正式改名只改显示名，ID 不变")
                let config = try String(
                    contentsOf: root.appendingPathComponent("config.json"), encoding: .utf8)
                expect(
                    config.contains("original") && config.contains("future"), "新建、选用和改名不改变组选包或未知配置")
            } catch { expect(false, "核心组装流程失败：\(error)") }
        }
    }

    await suite("声音设置核心集成：目录包预览、发布、命名复制和未知元数据") {
        await withTempDirectory { root in
            let fixture = CompositionFixture(root: root)
            defer { fixture.cleanup() }
            do {
                let app = try fixture.build()
                let owner = app.soundPacksEditorOwner
                _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 1)))
                let source = root.appendingPathComponent("test.claudiopack")
                writeFixture(
                    #"{"id":"imported","name":"Imported","events":{"stop":"tone.mp3"},"license":"CC0","author":"Fixture","future":{"keep":1}}"#,
                    to: source.appendingPathComponent("manifest.json"))
                writeFixture(validMP3ID3Data(), to: source.appendingPathComponent("tone.mp3"))
                writeFixture("attribution", to: source.appendingPathComponent("ATTRIBUTION.txt"))
                let prepared = try await owner.preparePackImport(source)
                expect(
                    prepared.packID == "imported" && prepared.eventCount == 1
                        && prepared.fileCount == 2, "导入预览来自实际内容")
                expect(
                    !FileManager.default.fileExists(
                        atPath: root.appendingPathComponent("packs/imported").path), "预览不能发布安装包")
                try await owner.importPreparedPack(prepared)
                await owner.waitForMutationTransactionsToQuiesceForTesting()
                let copyID = try await owner.copyNamedPack(
                    packID: "imported", name: AICuePackName("Named Copy"))
                let data = try Data(
                    contentsOf: root.appendingPathComponent("packs/\(copyID)/manifest.json"))
                let copied = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                expect(copied["name"] as? String == "Named Copy", "复制遵循确认的名称")
                expect(
                    copied["license"] == nil && copied["author"] == nil && copied["future"] != nil,
                    "复制移除整包声明并保留未知元数据")
                expect(
                    FileManager.default.fileExists(
                        atPath: root.appendingPathComponent("packs/\(copyID)/ATTRIBUTION.txt").path),
                    "独立归属材料保留")
                let duplicate = try await owner.preparePackImport(source)
                do {
                    try await owner.importPreparedPack(duplicate); expect(false, "重复 ID 不得覆盖已安装包")
                } catch {}
                await duplicate.discard()
                let link = source.appendingPathComponent("escape.mp3")
                try FileManager.default.createSymbolicLink(
                    at: link, withDestinationURL: root.appendingPathComponent("outside"))
                do {
                    _ = try await owner.preparePackImport(source); expect(false, "目录包内链接必须拒绝")
                } catch {}
            } catch { expect(false, "目录包流程失败：\(error)") }
        }
    }

    await suite("声音设置核心集成：历史首音、删除独立副本、完整来源 CAS") {
        await withTempDirectory { root in
            let fixture = CompositionFixture(root: root)
            defer { fixture.cleanup() }
            do {
                let app = try fixture.build()
                let owner = app.soundPacksEditorOwner
                _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 1)))
                _ = await app.soundPackLibrary.refreshSnapshot(trigger: .initial)
                for _ in 0..<64 { await Task.yield() }
                let draft = try await owner.createNamedDraft(AICuePackName("历史采用"))
                let generated = historyGeneration(
                    root.appendingPathComponent("generated"), count: 2)
                let trash = root.appendingPathComponent("trash")
                let history = GenerationHistoryStore(
                    directory: root.appendingPathComponent("history"),
                    trash: { url in
                        try FileManager.default.createDirectory(
                            at: trash, withIntermediateDirectories: true)
                        try FileManager.default.moveItem(
                            at: url, to: trash.appendingPathComponent(UUID().uuidString))
                    })
                _ = try await history.archive(generated, soundDescription: "保留两条真实结果")
                guard let selection = owner.beginSoundSelection(event: .stop) else {
                    expect(false, "草稿可选历史"); return
                }
                let result = await owner.useHistorySound(
                    batchID: generated.id, audioID: generated.candidates[0].id,
                    history: history, selection: selection)
                guard case .adopted(let adopted) = result else {
                    expect(false, "历史采用应使用真实事务：\(result)"); return
                }
                expect(adopted.importedFile.packID == draft.packID, "历史首音保持草稿身份")
                try await history.trash(batchID: generated.id, expectedCount: 2)
                expect(
                    (try? Data(contentsOf: adopted.importedFile.destinationURL))
                        == validMP3ID3Data(), "整组历史删除不影响已采用副本")
                await owner.waitForMutationTransactionsToQuiesceForTesting()
                for _ in 0..<64 { await Task.yield() }
                guard let stale = owner.beginSoundSelection(event: .stop) else {
                    expect(false, "已发布事件可重新选择"); return
                }
                let file = root.appendingPathComponent("next.mp3")
                writeFixture(validMP3ID3Data(), to: file)
                let preview = try await owner.prepareLocalSound(file)
                let manifestURL = root.appendingPathComponent("packs/\(draft.packID)/manifest.json")
                var json =
                    try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                    as! [String: Any]
                json["events"] = [:]
                let changed = try JSONSerialization.data(
                    withJSONObject: json, options: [.sortedKeys])
                try changed.write(to: manifestURL)
                let rejected = await owner.useLocalSound(preview, selection: stale)
                if case .adopted = rejected { expect(false, "陈旧来源不能覆盖外部解绑") }
                expect((try Data(contentsOf: manifestURL)) == changed, "完整来源 CAS 保留新映射")
                await preview.discard()
            } catch { expect(false, "历史核心集成失败：\(error)") }
        }
    }

    await suite("声音包命名：跨存储竞争、宽度避重、历史同名和未改名无操作") {
        await withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let directory = root.appendingPathComponent("drafts")
            let first = SoundPackDraftStore(directory: directory, environment: environment)
            let second = SoundPackDraftStore(directory: directory, environment: environment)
            do {
                let name = try AICuePackName("  ＡＢＣ  ")
                async let one = try? first.create(name: name)
                async let two = try? second.create(name: AICuePackName("abc"))
                let results = await [one, two]
                expect(results.compactMap { $0 }.count == 1, "独立 store 同时确认只有一次命名成功")
                await first.refresh()
                expect(first.snapshot.drafts.count == 1, "磁盘只有一个保留名称")
                do {
                    _ = try await second.create(name: AICuePackName("AbC"));
                    expect(false, "大小写和字符宽度冲突必须拒绝")
                } catch { expect(error as? SoundAssetStorageError == .nameConflict, "冲突有专门的可恢复原因") }
                let unicode = String(repeating: "🇨🇳", count: 64)
                expect(
                    try AICuePackName(unicode).value == unicode, "使用 Swift Character 而非 UTF-16 长度")
                for bad in ["  ", unicode + "a", "有\n换行", "控制\u{0001}字符"] {
                    expect((try? AICuePackName(bad)) == nil, "空白、超长、换行及控制字符拒绝")
                }
                let original = #"{"id":"old-a","name":"Legacy","future":42,"events":{}}"#
                writeFixture(
                    original,
                    to: environment.userPacksDirectory.appendingPathComponent("old-a/manifest.json")
                )
                writeFixture(
                    #"{"id":"old-b","name":"Legacy","events":{}}"#,
                    to: environment.userPacksDirectory.appendingPathComponent("old-b/manifest.json")
                )
                try await SoundPackDirectoryTransfer.rename(
                    packID: "old-a", name: AICuePackName("Legacy"),
                    environment: environment, draftsDirectory: directory)
                expect(
                    try String(
                        contentsOf: environment.userPacksDirectory.appendingPathComponent(
                            "old-a/manifest.json"), encoding: .utf8) == original,
                    "旧同名不迁移，未改变名称不重写 JSON")
                do {
                    _ = try await first.create(name: AICuePackName("legacy"));
                    expect(false, "新建仍对旧同名集合避重")
                } catch {}
            } catch { expect(false, "命名回归失败：\(error)") }
        }
    }

    await suite("声音包命名：库中普通文件不阻断新建、复制或改名") {
        await withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let directory = root.appendingPathComponent("drafts")
            let store = SoundPackDraftStore(directory: directory, environment: environment)
            writeFixture(
                "unrelated file",
                to: environment.userPacksDirectory.appendingPathComponent("README.txt"))
            let source = environment.userPacksDirectory.appendingPathComponent("original")
            writeFixture(
                #"{"id":"original","name":"Original","events":{}}"#,
                to: source.appendingPathComponent("manifest.json"))
            do {
                let draft = try await store.create(name: AICuePackName("New Draft"))
                _ = try await store.rename(
                    packID: draft.packID, name: AICuePackName("Renamed Draft"))
                try await SoundPackDirectoryTransfer.rename(
                    packID: "original", name: AICuePackName("Renamed Pack"),
                    environment: environment, draftsDirectory: directory)
                let copy = try await SoundPackDirectoryTransfer.prepare(
                    source: source, environment: environment, copyName: AICuePackName("Named Copy"))
                defer { Task { await copy.discard() } }
                try await SoundPackDirectoryTransfer.publish(
                    copy, environment: environment, draftsDirectory: directory)
                expect(
                    FileManager.default.fileExists(
                        atPath: environment.userPacksDirectory.appendingPathComponent(copy.packID)
                            .path), "普通文件存在时仍可发布命名副本")
                do {
                    _ = try await store.create(name: AICuePackName("renamed pack"))
                    expect(false, "过滤普通文件不能绕过真实包名称冲突")
                } catch { expect(error as? SoundAssetStorageError == .nameConflict, "真实冲突仍在锁内拒绝") }
                expect(
                    try String(
                        contentsOf: environment.userPacksDirectory.appendingPathComponent(
                            "README.txt"), encoding: .utf8) == "unrelated file", "命名不修改无关文件")
            } catch { expect(false, "普通文件不得阻断命名操作：\(error)") }
        }
    }

    await suite("声音包导入：拒绝库无法发现的隐藏身份，并在发布边界复核") {
        await withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let source = root.appendingPathComponent("external")
            do {
                for id in [".invisible", ".another"] {
                    writeFixture(
                        "{\"id\":\"\(id)\",\"events\":{}}",
                        to: source.appendingPathComponent("manifest.json"))
                    do {
                        let hidden = try await SoundPackDirectoryTransfer.prepare(
                            source: source, environment: environment)
                        await hidden.discard()
                        expect(false, "隐藏 ID \(id) 必须在预览前拒绝")
                    } catch {
                        expect(error as? SoundAssetStorageError == .unsafeEntry, "隐藏 ID 显示安全校验原因")
                    }
                    expect(
                        !FileManager.default.fileExists(
                            atPath: environment.userPacksDirectory.appendingPathComponent(id).path),
                        "拒绝后不留下不可见安装包")
                }
                writeFixture(
                    #"{"id":"visible","events":{}}"#,
                    to: source.appendingPathComponent("manifest.json"))
                let prepared = try await SoundPackDirectoryTransfer.prepare(
                    source: source, environment: environment)
                let stage = try FileManager.default.contentsOfDirectory(
                    at: environment.userPacksDirectory, includingPropertiesForKeys: nil
                ).first { $0.lastPathComponent.hasPrefix(".pack-transfer-") }!
                writeFixture(
                    #"{"id":".invisible","events":{}}"#,
                    to: stage.appendingPathComponent("payload/manifest.json"))
                do {
                    try await SoundPackDirectoryTransfer.publish(
                        prepared, environment: environment,
                        draftsDirectory: root.appendingPathComponent("drafts"))
                    expect(false, "发布时仍须拒绝已变成隐藏 ID 的预览")
                } catch { expect(error as? SoundAssetStorageError == .unsafeEntry, "发布也执行同一身份校验") }
                await prepared.discard()
            } catch { expect(false, "导入身份回归失败：\(error)") }
        }
    }

    suite("声音试听：真实回调、旧播放隔离、互斥与系统输出相对增益") {
        let player = RedesignPlayback()
        let effects = SoundPacksEditorNativeEffectsDispatcher(adapter: player)
        let file = URL(fileURLWithPath: "/fixture/audio.mp3")
        effects.toggleSoundPreview(id: "one", fileURL: file)
        expect(effects.playingSoundID == "one" && player.volumes == [1.0], "不读取或修改组与系统音量")
        effects.toggleSoundPreview(id: "two", fileURL: file)
        expect(effects.playingSoundID == "two" && player.stops == 1, "新播放先停止上一条")
        player.callbacks[0](true)
        expect(effects.playingSoundID == "two", "迟到的结束回调不能清除新状态")
        player.callbacks[1](true)
        expect(effects.playingSoundID == nil && !effects.previewFailed, "自然结束清除播放状态")
        effects.toggleSoundPreview(id: "three", fileURL: file)
        player.callbacks[2](false)
        expect(effects.playingSoundID == nil && effects.previewFailed, "真实失败可见")
        effects.toggleSoundPreview(id: "four", fileURL: file)
        effects.toggleSoundPreview(id: "four", fileURL: file)
        expect(effects.playingSoundID == nil && player.stops == 2, "重复点击停止，再次播放从新请求开始")
    }

    suite("生成退出判定：合并请求、重读状态、不重新发起任务") {
        var gate = AICueTerminationGate()
        expect(gate.request(reason: .generating) == .ask(.generating), "生成中提示")
        expect(gate.request(reason: .generating) == .alreadyWaiting, "重复退出不叠窗")
        expect(
            gate.answer(quit: true, currentReason: .unsavedAudio) == .ask(.unsavedAudio),
            "生成完成但保存失败时改用真实风险提示")
        expect(gate.answer(quit: false, currentReason: .unsavedAudio) == .cancel, "留下不改变任务")
        expect(gate.request(reason: .unsavedAudio) == .ask(.unsavedAudio), "待处理仍需提示")
        expect(gate.answer(quit: true, currentReason: nil) == .allow, "保存已完成不再重复提示")
        expect(gate.request(reason: nil) == .allow, "无在途结果直接退出")
    }
}
