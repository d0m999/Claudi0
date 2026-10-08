import ClaudioCore
import ClaudioGUICore
import Combine
import Foundation

private actor HistoryGeneratorFixture: AICueGenerating {
    var continuation: CheckedContinuation<AICueGeneration, Never>?
    private(set) var requests = 0
    private(set) var discarded: [UUID] = []
    func generate(
        description: String, locale: String, providerProfileID: AICueProviderProfileID,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueGeneration {
        requests += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func complete(_ generation: AICueGeneration) {
        continuation?.resume(returning: generation); continuation = nil
    }
    func discard(generationID: UUID) { discarded.append(generationID) }
    func discardAll() {}
}

@MainActor
func waitForHistoryState(
    _ coordinator: AICueGenerationCoordinator,
    matching predicate: @escaping (AICueGenerationTaskState) -> Bool
) async {
    if predicate(coordinator.state) { return }
    var subscription: AnyCancellable?
    await withCheckedContinuation { continuation in
        subscription = coordinator.$state.sink { state in
            if predicate(state) { continuation.resume() }
        }
    }
    subscription?.cancel()
}

@MainActor
func historyGeneration(_ root: URL, count: Int = 3) -> AICueGeneration {
    let id = UUID()
    let candidates = Array(AICueVariant.allCases.prefix(count)).map { variant in
        let file = root.appendingPathComponent("candidate-\(variant.ordinal).mp3")
        writeFixture(validMP3ID3Data(), to: file)
        return AICueCandidate(
            id: UUID(), variant: variant,
            asset: AICueTemporaryAudioAsset(
                fileURL: file, byteCount: validMP3ID3Data().count, sniffedFormat: .mp3),
            durationMilliseconds: 1_200, mediaType: "audio/mpeg",
            provenance: AICueCandidateProvenance(
                providerID: .elevenLabs, profileID: .elevenLabsGlobal,
                modelID: "private-model", generationID: id, requestOrdinal: variant.ordinal,
                providerRequestID: "private-request-id"))
    }
    return AICueGeneration(
        id: id, profileID: .elevenLabsGlobal,
        plan: AICueSoundPlan(
            suggestedDisplayName: "木琴", modality: .soundEffect,
            soundDescription: "INTERNAL-PLAN", spokenContent: nil, languageTag: nil,
            styleDescription: "PRIVATE-STYLE", targetDurationMilliseconds: 1_500,
            instructionVersion: AICueSoundPlanner.instructionVersion),
        candidates: candidates, completion: count == 3 ? .complete : .partial,
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
}

@MainActor
func runGenerationHistorySuites() async {
    await suite("生成记录：整批保存、幂等、重建、改名与独立 Trash") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("history")
        let trashDirectory = root.appendingPathComponent("trash")
        let trash: @Sendable (URL) throws -> Void = { source in
            try FileManager.default.createDirectory(
                at: trashDirectory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(
                at: source, to: trashDirectory.appendingPathComponent(UUID().uuidString))
        }
        let store = GenerationHistoryStore(directory: directory, trash: trash)
        let generation = historyGeneration(root)
        do {
            let batch = try await store.archive(generation, soundDescription: "原始描述")
            expect(batch.audio.count == 3, "真实有效三条必须整批可见")
            _ = try await store.archive(generation, soundDescription: "原始描述")
            expect(store.snapshot.batches.count == 1, "同一记录重试不能重复归档")
            let recreated = GenerationHistoryStore(directory: directory, trash: trash)
            await recreated.refresh()
            expect(recreated.snapshot.batches == store.snapshot.batches, "重新组装后保留描述、时间、服务、时长和稳定身份")
            let metadata = try String(
                contentsOf: directory.appendingPathComponent(generation.id.uuidString.lowercased())
                    .appendingPathComponent("batch.json"), encoding: .utf8)
            expect(
                batch.modelID == generation.candidates[0].provenance.modelID,
                "新记录持久保存实际模型 ID")
            let batchFile = directory.appendingPathComponent(generation.id.uuidString.lowercased())
                .appendingPathComponent("batch.json")
            var legacy =
                try JSONSerialization.jsonObject(with: Data(contentsOf: batchFile))
                as! [String: Any]
            legacy.removeValue(forKey: "modelID")
            try JSONSerialization.data(withJSONObject: legacy).write(to: batchFile)
            await recreated.refresh()
            expect(
                recreated.snapshot.batches[0].modelID == nil
                    && recreated.snapshot.batches[0].audio.count == 3, "旧记录缺模型字段仍可读")
            let audioID = generation.candidates[0].id
            try await recreated.rename(batchID: generation.id, audioID: audioID, name: "新的名称")
            let proof = try await recreated.audio(batchID: generation.id, audioID: audioID)
            expect(proof.name.value == "新的名称" && proof.data == validMP3ID3Data(), "改名保持音频字节")
            let adopted = root.appendingPathComponent("pack-copy.mp3")
            try proof.data.write(to: adopted)
            try await recreated.trash(batchID: generation.id, audioID: audioID)
            expect(recreated.snapshot.batches[0].audio.count == 2, "单条删除更新实际数量")
            expect((try? Data(contentsOf: adopted)) == validMP3ID3Data(), "历史删除不影响独立包副本")
            try await recreated.trash(batchID: generation.id, expectedCount: 2)
            expect(recreated.snapshot.batches.isEmpty, "整组删除不得留下空记录")
            expect(
                !metadata.contains("INTERNAL-PLAN") && !metadata.contains("private-request-id")
                    && !metadata.contains("PRIVATE-STYLE"), "持久元数据不能包含内部方案或 Provider 请求信息")
        } catch { expect(false, "持久记录流程失败：\(error)") }
    }

    await suite("生成记录：单条最后删除、损坏隔离和 Trash 失败恢复") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("history")
        let store = GenerationHistoryStore(
            directory: directory, trash: { _ in throw SoundAssetStorageError.trashFailed })
        let generation = historyGeneration(root, count: 1)
        do {
            _ = try await store.archive(generation, soundDescription: "一条")
            do {
                try await store.trash(batchID: generation.id, audioID: generation.candidates[0].id)
                expect(false, "Trash 失败不得报告成功")
            } catch {}
            expect(store.snapshot.batches.first?.audio.count == 1, "Trash 失败恢复原记录")
            let proof = try await store.audio(
                batchID: generation.id, audioID: generation.candidates[0].id)
            expect(proof.data == validMP3ID3Data(), "恢复后仍可安全读取")
            let corrupt = directory.appendingPathComponent(UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
            await store.refresh()
            expect(
                store.snapshot.batches.count == 2
                    && store.snapshot.batches.filter { $0.failure != nil }.count == 1,
                "坏组必须隔离，不隐藏健康记录")
            let removing = GenerationHistoryStore(
                directory: directory,
                trash: { source in
                    try FileManager.default.moveItem(
                        at: source, to: root.appendingPathComponent("recoverable"))
                })
            try await removing.trash(batchID: generation.id, audioID: generation.candidates[0].id)
            expect(!removing.snapshot.batches.contains { $0.id == generation.id }, "删除最后一条须移走整个组")
        } catch { expect(false, "恢复流程失败：\(error)") }
    }

    await suite("生成记录：发布结果不确定的幂等恢复、Trash 回滚失败与链接拒绝") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("history")
        let generation = historyGeneration(root.appendingPathComponent("input"), count: 1)
        let store = GenerationHistoryStore(
            directory: directory, afterPublish: { throw SoundAssetStorageError.unavailable })
        do {
            do {
                _ = try await store.archive(generation, soundDescription: "保持原始记录");
                expect(false, "发布后确认故障不得报告调用成功")
            } catch {}
            expect(store.snapshot.batches.isEmpty, "未知结果不投影假成功")
            _ = try await store.archive(generation, soundDescription: "保持原始记录")
            expect(store.snapshot.batches.count == 1, "按稳定 ID 读回同一批次，不重复创建或覆盖")
            let failingTrash = GenerationHistoryStore(
                directory: directory,
                trash: { isolated in
                    let original = isolated.deletingLastPathComponent().deletingLastPathComponent()
                        .appendingPathComponent(isolated.lastPathComponent)
                    try FileManager.default.createDirectory(
                        at: original, withIntermediateDirectories: false)
                    throw SoundAssetStorageError.trashFailed
                })
            do {
                try await failingTrash.trash(batchID: generation.id, expectedCount: 1)
                expect(false, "Trash 与恢复都失败必须报告可找回位置")
            } catch SoundAssetStorageError.recoveryRequired(let location) {
                expect(
                    FileManager.default.fileExists(
                        atPath: location.appendingPathComponent("batch.json").path), "原整组仍保留在精确恢复位置"
                )
            }
            let second = historyGeneration(root.appendingPathComponent("other"), count: 1)
            let healthy = GenerationHistoryStore(directory: root.appendingPathComponent("safe"))
            _ = try await healthy.archive(second, soundDescription: "健康组")
            let item = root.appendingPathComponent(
                "safe/" + second.id.uuidString.lowercased() + "/"
                    + second.candidates[0].id.uuidString.lowercased())
            let audio = item.appendingPathComponent("audio.mp3")
            try FileManager.default.removeItem(at: audio)
            try FileManager.default.createSymbolicLink(
                at: audio, withDestinationURL: second.candidates[0].asset.fileURL)
            await healthy.refresh()
            expect(healthy.snapshot.batches[0].audio[0].failure != nil, "链接音频在元数据列表标记不可用")
            do {
                _ = try await healthy.audio(batchID: second.id, audioID: second.candidates[0].id);
                expect(false, "试听和采用均拒绝链接")
            } catch {}
        } catch { expect(false, "持久恢复边界失败：\(error)") }
    }

    await suite("生成协调器：关表单继续同一任务、全局拒绝并发、保存后才恢复资格") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let generator = HistoryGeneratorFixture()
        let history = GenerationHistoryStore(directory: root.appendingPathComponent("history"))
        let coordinator = AICueGenerationCoordinator(generator: generator, history: history)
        expect(
            coordinator.start(
                description: "冻结的描述", locale: "zh-Hans", profileID: .elevenLabsGlobal), "首请求接受")
        expect(
            !coordinator.start(description: "第二次", locale: "en", profileID: .elevenLabsGlobal),
            "并发请求拒绝且不排队")
        coordinator.detachComposer()
        while await generator.requests == 0 { await Task.yield() }
        let generation = historyGeneration(root)
        await generator.complete(generation)
        await waitForHistoryState(coordinator) { if case .saved = $0 { true } else { false } }
        expect(history.snapshot.batches.first?.soundDescription == "冻结的描述", "关闭后仍归档冻结的描述")
        expect(coordinator.generation == nil, "关闭的表单不得恢复候选采用上下文")
        expect(
            coordinator.generationBlock == nil && coordinator.hasUnreadCompletion, "保存后恢复资格并只标记未读完成"
        )
        expect(await generator.requests == 1, "生命周期变化不能重复网络请求")
    }

    await suite("生成协调器：部分 Trash 失败保留剩余资产，仍阻止下一轮") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = historyGeneration(root)
        let history = GenerationHistoryStore(
            directory: root.appendingPathComponent("history"),
            beforePublish: {
                throw SoundAssetStorageError.unavailable
            })
        let generator = HistoryGeneratorFixture()
        let failedName = generation.candidates[1].asset.fileURL.lastPathComponent
        let trashRoot = root.appendingPathComponent("trash")
        let coordinator = AICueGenerationCoordinator(
            generator: generator, history: history,
            trash: { url in
                if url.lastPathComponent == failedName { throw SoundAssetStorageError.trashFailed }
                try FileManager.default.createDirectory(
                    at: trashRoot, withIntermediateDirectories: true)
                try FileManager.default.moveItem(
                    at: url, to: trashRoot.appendingPathComponent(url.lastPathComponent))
            })
        _ = coordinator.start(description: "原描述", locale: "zh-Hans", profileID: .elevenLabsGlobal)
        while await generator.requests == 0 { await Task.yield() }
        await generator.complete(generation)
        await waitForHistoryState(coordinator) { if case .pending = $0 { true } else { false } }
        await coordinator.abandonPending(expectedCount: 3)
        expect(
            coordinator.generation?.candidates.map(\.id) == [generation.candidates[1].id],
            "按实际 Trash 结果移除成功项，保留失败项")
        expect(
            coordinator.generationBlock == .pendingResults
                && coordinator.terminationReason == .unsavedAudio,
            "部分失败继续保持全局生成与退出门禁")
        expect(
            (try? Data(contentsOf: generation.candidates[1].asset.fileURL)) == validMP3ID3Data(),
            "失败项恢复原处，仍可试听与保存")
        expect(await generator.requests == 1 && history.snapshot.batches.isEmpty, "放弃不是生成或假归档")
    }

    await suite("生成协调器：归档失败保留音频、门禁不能绕过、重试不访问 Provider") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("blocked")
        let generation = historyGeneration(root, count: 2)
        try? Data().write(to: blocker)
        let history = GenerationHistoryStore(directory: blocker.appendingPathComponent("history"))
        let generator = HistoryGeneratorFixture()
        let coordinator = AICueGenerationCoordinator(generator: generator, history: history)
        _ = coordinator.start(description: "两条", locale: "zh-Hans", profileID: .elevenLabsGlobal)
        while await generator.requests == 0 { await Task.yield() }
        await generator.complete(generation)
        await waitForHistoryState(coordinator) { if case .pending = $0 { true } else { false } }
        coordinator.detachComposer()
        expect(coordinator.generation?.candidates.count == 2, "保存失败关表单保留有效集合")
        expect(coordinator.terminationReason == .unsavedAudio, "常规退出必须提示未保存音频")
        expect(
            !coordinator.start(description: "不能发起", locale: "en", profileID: .elevenLabsGlobal),
            "待处理全局禁止再次生成")
        try? FileManager.default.removeItem(at: blocker)
        coordinator.retrySave()
        await waitForHistoryState(coordinator) { if case .saved = $0 { true } else { false } }
        expect(await generator.requests == 1, "重试只保存现有资产，不重发生成")
        expect(history.snapshot.batches.first?.audio.count == 2, "partial 成功保存实际有效数量")
    }
    await suite("生成协调器：取消隔离迟到成功，采用事务持有资产直到返回") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let generator = HistoryGeneratorFixture()
        let history = GenerationHistoryStore(directory: root.appendingPathComponent("history"))
        let coordinator = AICueGenerationCoordinator(generator: generator, history: history)
        _ = coordinator.start(description: "保留输入", locale: "zh-Hans", profileID: .elevenLabsGlobal)
        while await generator.requests == 0 { await Task.yield() }
        coordinator.cancel()
        let late = historyGeneration(root.appendingPathComponent("late"))
        await generator.complete(late)
        for _ in 0..<1_000 {
            if await generator.discarded.contains(late.id) { break }
            await Task.yield()
        }
        expect(
            coordinator.state == .idle && coordinator.soundDescription == "保留输入", "取消保留描述且迟到结果不恢复状态"
        )
        let discarded = await generator.discarded
        expect(
            history.snapshot.batches.isEmpty && discarded.contains(late.id), "取消后迟到成功只释放临时资产，不归档或采用"
        )
        _ = coordinator.start(description: "下一轮", locale: "en", profileID: .elevenLabsGlobal)
        while await generator.requests < 2 { await Task.yield() }
        let generation = historyGeneration(root.appendingPathComponent("next"))
        await generator.complete(generation)
        await waitForHistoryState(coordinator) { $0 == .saved(generation.id) }
        guard let lease = coordinator.beginAdoption(generationID: generation.id) else {
            expect(false, "已归档候选可以开始采用事务"); return
        }
        coordinator.detachComposer()
        expect(
            coordinator.generation != nil && coordinator.generationBlock == .adopting,
            "关闭后继续保留采用事务正在读取的资产，并解释生成门禁")
        expect(
            !coordinator.start(description: "不能覆盖", locale: "en", profileID: .elevenLabsGlobal),
            "采用结束前不释放或覆盖有效资产")
        await coordinator.finishAdoption(lease, adopted: true)
        expect(
            coordinator.generation == nil && coordinator.generationBlock == nil, "事务结束后释放临时资产和门禁")
        expect(await generator.discarded.contains(generation.id), "已采用临时结果在事务返回后清理")
    }

}
