import ClaudioCore
import ClaudioGUICore
import Foundation

private actor SelectionCredentials: AICueCredentialManaging {
    func status(for profileID: AICueProviderProfileID) -> AICueCredentialStatus {
        .stored(verification: .verified, hasPendingReplacement: false)
    }
    func save(_ credential: SensitiveCredentialInput, for profileID: AICueProviderProfileID)
        -> AICueCredentialStatus
    { status(for: profileID) }
    func delete(for profileID: AICueProviderProfileID) {}
    func cancelPendingReplacement(for profileID: AICueProviderProfileID) {}
}

private actor SelectionGenerator: AICueGenerating {
    private var continuation: CheckedContinuation<AICueGeneration, Never>?
    private(set) var requests = 0
    func generate(
        description: String, locale: String, providerProfileID: AICueProviderProfileID,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueGeneration {
        requests += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ generation: AICueGeneration) {
        continuation?.resume(returning: generation)
        continuation = nil
    }
    func discard(generationID: UUID) {}
    func discardAll() {}
}

/// Blocks the existing disk/probe adapters, rather than simulating lifecycle results.
private final class SelectionIOGate: AudioDurationProbing, @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var entered = false
    private var file: URL?
    private var succeeds = true
    func arm(succeeds: Bool = true) {
        condition.lock(); defer { condition.unlock() }
        blocked = true; entered = false; file = nil; self.succeeds = succeeds
    }
    var hasEntered: Bool {
        condition.lock(); defer { condition.unlock() }
        return entered
    }
    var preparedFile: URL? {
        condition.lock(); defer { condition.unlock() }
        return file
    }
    func wait(file: URL? = nil) {
        condition.lock(); defer { condition.unlock() }
        entered = true; self.file = file
        while blocked { condition.wait() }
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        blocked = false; condition.broadcast()
    }
    func probeDuration(of fileURL: URL) -> TimeInterval? {
        guard fileURL.deletingLastPathComponent().lastPathComponent.hasPrefix("claudio-preview-")
        else { return 1 }
        wait(file: fileURL)
        condition.lock(); defer { condition.unlock() }
        return succeeds ? 1 : nil
    }
}

@MainActor
private final class SelectionPlayer: AudioPreviewPlaying {
    var files: [URL] = []
    var stops = 0
    func play(fileAt url: URL, volume: Float) -> Bool { files.append(url); return true }
    func play(
        fileAt url: URL, volume: Float,
        onCompletion: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Bool { play(fileAt: url, volume: volume) }
    func stop() { stops += 1 }
}

@MainActor
private func selectionComposer(root: URL, generator: SelectionGenerator = SelectionGenerator())
    -> AICueGenerationViewModel
{
    AICueGenerationViewModel(
        credentialManager: SelectionCredentials(), generator: generator,
        providerProfileID: .elevenLabsGlobal,
        generationHistoryDirectory: root.appendingPathComponent("history"))
}

@MainActor
private func waitForSelection(_ predicate: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if predicate() { return true }
        // The executable harness shares the app's macOS 12 deployment floor.
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return predicate()
}

@MainActor
func runSoundEventSelectionLifecycleSuites() async {
    await suite("声音选用：首次匹配的兼容投影可接入，新选用不继承已关闭上下文") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["gallery-pack"])
            let generator = SelectionGenerator()
            let model = selectionComposer(root: root, generator: generator)
            model.begin(packID: "gallery-pack", event: .stop)
            await model.refreshCredentialStatus()
            model.updateDescription("由其他呈现持有的生成投影")
            model.startGeneration(locale: "zh-Hans")
            while await generator.requests == 0 { await Task.yield() }
            await generator.finish(historyGeneration(root.appendingPathComponent("input")))
            guard
                await waitForSelection({
                    if case .saved = model.coordinator.state { return true }; return false
                })
            else { expect(false, "实际生成与归档必须先成功"); return }
            let session = fixture.owner.soundSelection
            let original = model.generation
            expect(original != nil, "compatibility fixture 先提供生成投影")
            session.configure(
                composer: model, playback: ManualAudioPreviewSession(player: SelectionPlayer()))
            session.end()
            _ = fixture.owner.send(
                .activate(
                    .sounds(
                        route: .editEvent(packID: "gallery-pack", event: .stop), requestRevision: 1)
                ))
            expect(model.generation == original, "冷接线和 owner 激活不能清除其他呈现持有的投影")
            _ = await fixture.library.refreshSnapshot(trigger: .initial)
            guard await waitForSoundEditorReady(fixture.owner, library: fixture.library) else {
                return
            }
            expect(session.begin(event: .stop, mode: .ai) != nil, "显式新选用取得独立上下文")
            expect(model.generation == original, "首次显式表单保留同目标兼容会话的现有投影")
            session.end()
            expect(session.begin(event: .stop, mode: .ai) != nil, "关闭后能签发新的选择上下文")
            expect(model.generation == nil, "重开不能复活已关闭会话的候选或资格")
            session.end()
        }
    }

    await suite("声音选用：五类入口共享一次性上下文，刷新保留、离页永不复活") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["a", "b"])
            let owner = fixture.owner
            let route = SoundPacksWindowRoute(surface: nil, destination: .pack(packID: "a"))
            _ = owner.send(.activate(.sounds(route: route, requestRevision: 1)))
            _ = await fixture.library.refreshSnapshot(trigger: .initial)
            guard await waitForSoundEditorReady(owner, library: fixture.library) else { return }
            let session = owner.soundSelection
            let composer = selectionComposer(root: root)
            session.configure(
                composer: composer, playback: ManualAudioPreviewSession(player: SelectionPlayer()))
            let manifest = root.appendingPathComponent("packs/a/manifest.json")
            let original = try? Data(contentsOf: manifest)
            for mode in SoundEventSelectionSession.Mode.allCases {
                guard let old = session.begin(event: .stop, mode: mode) else {
                    expect(false, "五种来源均可开始：\(mode)"); continue
                }
                let oldOrigin = session.origin
                _ = owner.send(.activate(.sounds(route: route, requestRevision: 2)))
                expect(session.context == old, "同路由刷新不撤销表单")
                session.end(origin: oldOrigin)
                expect(session.context == nil && composer.session == nil, "关闭撤销选用与候选上下文")
                expect(!owner.useExistingSound(.file("stop.mp3"), selection: old), "关闭后的原凭证拒写")
                guard let next = session.begin(event: .notification, mode: mode) else {
                    expect(false, "关闭后可重新选择"); continue
                }
                session.end(origin: oldOrigin)
                expect(session.context == next && next.id != old.id, "迟到关闭不终止新表单")
                expect(
                    session.closeForm(origin: oldOrigin) == nil && session.context == next,
                    "整个迟到 onDismiss 不得通过重启页面绕过身份检查")
                _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 3)))
                _ = owner.send(.activate(.sounds(route: route, requestRevision: 4)))
                expect(session.context == nil, "A → B → A 不恢复选用上下文")
                expect(!owner.useExistingSound(.file("stop.mp3"), selection: next), "返回原包不能复活旧凭证")
            }
            expect((try? Data(contentsOf: manifest)) == original, "开始、浏览、取消从未改写原映射")
            let managementOrigin = session.activateForm(route: route)
            session.invalidateTarget(viewedPackID: "a")
            session.invalidateTarget(viewedPackID: "a")
            expect(session.context == nil, "管理表单不签发采用资格")
            guard let pageOrigin = session.closeForm(origin: managementOrigin) else {
                expect(false, "重复目标失效仍允许管理表单结束呈现"); return
            }
            expect(pageOrigin != managementOrigin, "结束管理表单产生新的页面身份")
            expect(session.closeForm(origin: pageOrigin) == nil, "页面身份不能被当作表单重复关闭")
            guard let direct = owner.beginSoundSelection(event: .stop) else {
                expect(false, "低层入口仍可签发"); return
            }
            _ = owner.beginSoundSelection(event: .notification)
            expect(
                !owner.useExistingSound(.file("stop.mp3"), selection: direct), "新选择也撤销低层旧 ledger")
            _ = owner.send(.activate(.inactive))
        }
    }

    await suite("声音选用：本机暂存迟到成功与失败均隔离，源文件保留") {
        for succeeds in [true, false] {
            await withTempDirectory { root in
                let gate = SelectionIOGate()
                defer { gate.release() }
                let fixture = makeSoundEditorFixture(
                    root: root, packIDs: ["a"], durationProbe: gate)
                let owner = fixture.owner
                _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 1)))
                _ = await fixture.library.refreshSnapshot(trigger: .initial)
                guard await waitForSoundEditorReady(owner, library: fixture.library) else { return }
                let session = owner.soundSelection
                _ = session.begin(event: .stop, mode: .local)
                let source = root.appendingPathComponent("external.mp3")
                writeFixture(validMP3ID3Data(), to: source)
                let original = try? Data(contentsOf: source)
                gate.arm(succeeds: succeeds)
                let preparation = Task { await session.prepareLocalSound { source } }
                guard await waitForSelection({ gate.hasEntered }), let staged = gate.preparedFile
                else {
                    gate.release(); _ = await preparation.value
                    expect(false, "真实验证字节已写入暂存后阻塞"); return
                }
                expect(session.isPreparingLocalSound, "当前请求呈现准备中")
                session.end()
                let next = session.begin(event: .notification, mode: .system)
                gate.release()
                expect(await preparation.value == .superseded, "旧成功或失败均不成为新表单反馈")
                expect(session.context == next && session.localPreview == nil, "旧资源不能进入新选择")
                expect(!session.isPreparingLocalSound, "旧完成不改写新请求忙状态")
                expect(!FileManager.default.fileExists(atPath: staged.path), "迟到资源被释放")
                expect((try? Data(contentsOf: source)) == original, "取消不删除或改写外部源文件")
                session.end()
            }
        }
    }

    await suite("声音选用：关闭先停止自身试听、释放暂存，重复旧关闭不停止接管者") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 1)))
            _ = await fixture.library.refreshSnapshot(trigger: .initial)
            guard await waitForSoundEditorReady(owner, library: fixture.library) else { return }
            let player = SelectionPlayer()
            let playback = ManualAudioPreviewSession(player: player)
            let session = owner.soundSelection
            let composer = selectionComposer(root: root)
            session.configure(composer: composer, playback: playback)
            _ = session.begin(event: .stop, mode: .local)
            let source = root.appendingPathComponent("external.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            expect(await session.prepareLocalSound { source } == .ready, "当前预览已验证")
            guard let preview = session.localPreview,
                let token = playback.prepare(origin: session.origin, target: "local")
            else { expect(false, "可开始当前预览"); return }
            _ = playback.start(token, fileURL: preview.fileURL, volume: 1)
            let oldOrigin = session.origin
            session.end(origin: oldOrigin)
            expect(player.stops == 1 && playback.playing == nil, "关闭同步停止试听")
            await session.waitForResourceCleanupForTesting()
            expect(!FileManager.default.fileExists(atPath: preview.fileURL.path), "关闭释放暂存")
            composer.begin(scope: .global, event: .notification)
            let panelOrigin = ManualPreviewOrigin(.panel)
            guard let panel = playback.prepare(origin: panelOrigin, target: "panel") else { return }
            _ = playback.start(panel, fileURL: source, volume: 0.5)
            session.end(origin: oldOrigin)
            expect(playback.playing == panel && player.stops == 1, "重复旧关闭不能停面板接管的声音")
            session.preview(id: "late", fileURL: source, origin: oldOrigin)
            expect(
                playback.playing == panel && player.files.count == 2,
                "旧按钮回调不能重新取得试听资格或停止接管者")
            expect(
                composer.session?.packID == nil && composer.session?.event == .notification,
                "重复旧关闭不能结束 Events 接管的 composer")
            expect(
                session.closeForm(origin: oldOrigin) == nil && playback.playing == panel,
                "结束后的旧 onDismiss 无权重启 Sounds 来源")
            playback.stop(origin: panelOrigin)
            let pageOrigin = session.activate()
            session.preview(id: "page.before", fileURL: source, origin: pageOrigin)
            session.invalidateTarget(viewedPackID: "a")
            session.invalidateTarget(viewedPackID: "a")
            expect(playback.playing == nil, "目标失效同步撤销页内旧试听")
            session.preview(id: "page.recovered", fileURL: source, origin: pageOrigin)
            expect(
                playback.isPlaying("page.recovered", origin: pageOrigin),
                "仍挂载页面在同路由恢复后允许新的显式试听")
            session.end(origin: pageOrigin)
        }
    }

    await suite("声音选用：UI 意图在创建异步 Task 前捕获来源身份") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 1)))
            _ = await fixture.library.refreshSnapshot(trigger: .initial)
            guard await waitForSoundEditorReady(owner, library: fixture.library) else { return }
            let session = owner.soundSelection
            _ = session.begin(event: .stop, mode: .local)
            let oldOrigin = session.origin
            _ = session.begin(event: .notification, mode: .local)
            let next = session.context
            var openedPicker = false
            let result = await session.prepareLocalSound(origin: oldOrigin) {
                openedPicker = true; return root.appendingPathComponent("external.mp3")
            }
            expect(result == .superseded && !openedPicker, "迟到 Task 不能替新目标打开旧文件选择器")
            if case .superseded = await session.use(.local, origin: oldOrigin) {
            } else {
                expect(false, "迟到的选用 Task 不能改写新目标")
            }
            expect(
                session.context == next && !session.isUsingSound && !session.isPreparingLocalSound,
                "迟到意图不改写新目标或忙状态")
            session.end()
        }
    }

    await suite("声音选用：生产 interface 采用冻结字节，离页后在途事务仍结算且不覆盖新目标") {
        for closesDuringUse in [false, true] {
            await withTempDirectory { root in
                let gate = SelectionIOGate()
                defer { gate.release() }
                let fixture = makeSoundEditorFixture(
                    root: root, packIDs: ["a"],
                    afterFinalImportCancellationSampleForTesting: { gate.wait() })
                let owner = fixture.owner
                _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 1)))
                _ = await fixture.library.refreshSnapshot(trigger: .initial)
                guard await waitForSoundEditorReady(owner, library: fixture.library) else { return }
                let session = owner.soundSelection
                _ = session.begin(event: .stop, mode: .local)
                let source = root.appendingPathComponent("external.mp3")
                let manifest = root.appendingPathComponent("packs/a/manifest.json")
                let originalManifest = try? Data(contentsOf: manifest)
                let originalConfig = try? Data(contentsOf: fixture.configFile)
                writeFixture(validMP3ID3Data(), to: source)
                expect(await session.prepareLocalSound { source } == .ready, "选用前只准备，不改绑定")
                guard let preview = session.localPreview else { return }
                expect((try? Data(contentsOf: manifest)) == originalManifest, "准备字节未修改事件")
                writeFixture("external bytes changed", to: source)
                gate.arm()
                let use = Task { await session.use(.local) }
                guard await waitForSelection({ gate.hasEntered }) else {
                    gate.release(); _ = await use.value
                    expect(false, "已接受事务停在真实导入 adapter"); return
                }
                if closesDuringUse {
                    session.end()
                    _ = session.begin(event: .notification, mode: .system)
                }
                let current = session.context
                gate.release()
                let result = await use.value
                if closesDuringUse {
                    if case .superseded = result {} else { expect(false, "旧事务结果不交给新表单") }
                    expect(session.context == current, "迟到事务没有撤销新目标")
                    expect((try? Data(contentsOf: manifest)) == originalManifest, "离页撤销旧绑定资格")
                } else {
                    if case .completed(let completion) = result,
                        case .adopted(let adopted) = completion.result
                    {
                        expect(
                            (try? Data(contentsOf: adopted.importedFile.destinationURL))
                                == validMP3ID3Data(),
                            "显式选用使用预览验证字节而不是变动后的外部源")
                    } else {
                        expect(false, "当前表单实际完成采用事务")
                    }
                    if case .completed(let completion) = await session.use(.local),
                        case .rejected = completion.result
                    {
                    } else {
                        expect(false, "已消费凭证不能再次写入")
                    }
                }
                session.end()
                await session.waitForResourceCleanupForTesting()
                await owner.waitForMutationTransactionsToQuiesceForTesting()
                expect(owner.soundAdoptionCount == 0, "关闭不遗留未结算采用操作")
                expect(!FileManager.default.fileExists(atPath: preview.fileURL.path), "结束释放选用暂存")
                expect((try? Data(contentsOf: fixture.configFile)) == originalConfig, "选用不改组选包或配置")
                expect(
                    (try? String(contentsOf: source, encoding: .utf8)) == "external bytes changed",
                    "源文件保持用户在预览后写入的内容")
            }
        }
    }

    await suite("声音选用：历史管理借用相同暂存 seam，迟到读取不抢新试听") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["a"])
            let session = fixture.owner.soundSelection
            let player = SelectionPlayer()
            let playback = ManualAudioPreviewSession(player: player)
            let gate = SelectionIOGate()
            defer { gate.release() }
            let history = GenerationHistoryStore(
                directory: root.appendingPathComponent("history"), beforePublish: { gate.wait() })
            let generation = historyGeneration(root.appendingPathComponent("input"), count: 1)
            do {
                _ = try await history.archive(generation, soundDescription: "历史声音")
                session.configure(composer: selectionComposer(root: root), playback: playback)
                session.activate()
                let batchID = generation.id, audioID = generation.candidates[0].id
                expect(
                    await session.previewHistory(
                        batchID: batchID, audioID: audioID, history: history) == .ready,
                    "管理页可试听而不签发采用上下文")
                expect(session.context == nil && player.files.count == 1, "管理试听不产生选用资格")
                guard let staged = player.files.last else { return }
                session.end()
                await session.waitForResourceCleanupForTesting()
                expect(!FileManager.default.fileExists(atPath: staged.path), "管理试听关闭也释放暂存")
                session.activate()
                gate.arm()
                let second = historyGeneration(root.appendingPathComponent("second"), count: 1)
                let archive = Task { try await history.archive(second, soundDescription: "阻塞队列") }
                guard await waitForSelection({ gate.hasEntered }) else {
                    gate.release(); _ = try await archive.value
                    expect(false, "真实历史 disk actor 已阻塞"); return
                }
                let preview = Task {
                    await session.previewHistory(
                        batchID: batchID, audioID: audioID, history: history)
                }
                guard await waitForSelection({ playback.request?.target == audioID.uuidString })
                else {
                    gate.release(); _ = try await archive.value; _ = await preview.value
                    expect(false, "在途历史读取持有当前 token"); return
                }
                let panelOrigin = ManualPreviewOrigin(.panel)
                guard let panel = playback.prepare(origin: panelOrigin, target: "new") else {
                    return
                }
                _ = playback.start(
                    panel, fileURL: generation.candidates[0].asset.fileURL, volume: 0.5)
                gate.release()
                _ = try await archive.value
                expect(await preview.value == .superseded, "历史迟到读取不重新取得播放资格")
                expect(playback.playing == panel && player.files.count == 2, "接管者保持真实播放状态")
                session.end()
                expect(playback.playing == panel, "历史来源关闭不停止其他来源")
                playback.stop(origin: panelOrigin)
            } catch { expect(false, "历史生命周期失败：\(error)") }
        }
    }

    await suite("声音选用：关闭生成表单继续归档，重开不继承旧候选或采用资格") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 1)))
            _ = await fixture.library.refreshSnapshot(trigger: .initial)
            guard await waitForSoundEditorReady(owner, library: fixture.library) else { return }
            let generator = SelectionGenerator()
            let composer = selectionComposer(root: root, generator: generator)
            let session = owner.soundSelection
            session.configure(
                composer: composer, playback: ManualAudioPreviewSession(player: SelectionPlayer()))
            _ = session.begin(event: .stop, mode: .ai)
            await composer.refreshCredentialStatus()
            composer.updateDescription("关闭后仍归档")
            composer.startGeneration(locale: "zh-Hans")
            while await generator.requests == 0 { await Task.yield() }
            session.end()
            _ = session.begin(event: .notification, mode: .ai)
            let reopened = session.context
            await generator.finish(historyGeneration(root.appendingPathComponent("input")))
            expect(
                await waitForSelection {
                    if case .saved = composer.coordinator.state { return true }; return false
                }, "原任务实际归档成功")
            expect(await generator.requests == 1, "关闭与重开不重复生成")
            expect(
                composer.coordinator.history.snapshot.batches.first?.soundDescription == "关闭后仍归档",
                "记录仍使用点击时描述")
            expect(session.context == reopened && composer.generation == nil, "重开仅查看后台任务，不继承候选")
            if case .sounds(let sounds) = owner.presentation.mode {
                expect(
                    sounds.eventRows.allSatisfy { $0.aiCueAdoptionPermit == nil }, "归档不复活已关闭的采用资格")
            } else {
                expect(false, "仍在当前声音页")
            }
            session.end()
        }
    }
}
