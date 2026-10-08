import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation
import SoundPacksWindow

private actor RecoveryCredentialManager: AICueCredentialManaging {
    func status(for profileID: AICueProviderProfileID) async -> AICueCredentialStatus {
        .stored(verification: .verified, hasPendingReplacement: false)
    }
    func save(_ credential: SensitiveCredentialInput, for profileID: AICueProviderProfileID)
        async throws -> AICueCredentialStatus
    {
        await status(for: profileID)
    }
    func delete(for profileID: AICueProviderProfileID) async throws {}
    func cancelPendingReplacement(for profileID: AICueProviderProfileID) async throws {}
}

private actor RecoveryGenerator: AICueGenerating {
    let result: AICueGeneration
    private(set) var requests = 0
    init(_ result: AICueGeneration) { self.result = result }
    func generate(
        description: String, locale: String, providerProfileID: AICueProviderProfileID,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueGeneration {
        requests += 1
        return result
    }
    func discard(generationID: UUID) {}
    func discardAll() {}
}

private final class RecoveryIOGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = true
    private var entered = false
    init(blocked: Bool = true) { self.blocked = blocked }
    func arm() {
        condition.lock(); defer { condition.unlock() }
        blocked = true; entered = false
    }
    var hasEntered: Bool {
        condition.lock(); defer { condition.unlock() }
        return entered
    }
    func wait() {
        condition.lock(); defer { condition.unlock() }
        entered = true
        while blocked { condition.wait() }
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        blocked = false; condition.broadcast()
    }
}

@MainActor
private final class RecoveryPlayback: SoundPacksEditorNativeEffectsAdapter {
    private(set) var plays = 0
    func selectAudioFiles(allowsMultipleSelection: Bool) -> [URL] { [] }
    func playAudio(fileURL: URL, volume: Double) -> TimeInterval? { 1 }
    func playAudio(
        fileURL: URL, volume: Double, completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Bool {
        plays += 1; return true
    }
    func stopAudio() {}
    func revealInFinder(fileURL: URL) {}
}

private final class RecoveryInventorySource: @unchecked Sendable {
    private let lock = NSLock()
    private var inventory: SoundPackAudioInventory
    init(_ inventory: SoundPackAudioInventory) { self.inventory = inventory }
    func set(_ inventory: SoundPackAudioInventory) {
        lock.lock(); defer { lock.unlock() }
        self.inventory = inventory
    }
    func facts() -> [SoundPackFacts] {
        lock.lock(); defer { lock.unlock() }
        return [
            SoundPackFacts(
                id: "target", name: "Target", isCC0: false, factoryIntegrity: nil,
                eventCoverage: [:], cardState: .partial(present: 0, total: 5),
                audioInventory: inventory)
        ]
    }
}

@MainActor
func runSoundsReviewRecoverySuites() async {
    await suite("声音列表恢复：首次加载、失败、陈旧快照和重试均可见") {
        await withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let states: [(SoundPackLibraryPresentationState, String, Bool)] = [
                (.loading, "settings.sounds.library.loading", false),
                (.loadFailed(reason: "fixture"), "settings.sounds.library.failure", true),
                (.refreshing, "settings.sounds.library.refreshing", false),
                (.refreshFailed(reason: "fixture"), "settings.sounds.library.failure", true),
                (.ready, "settings.sounds.library.empty", false),
            ]
            for language in [ClaudioAppLanguage.zhHans, .english] {
                for (state, identifier, retry) in states {
                    let hasPrevious = state.hasUsableSnapshot && state != .ready
                    let cards =
                        hasPrevious
                        ? [
                            PackCard(
                                id: "previous", name: "Previous", isCC0: false, presentEvents: [],
                                state: .partial(present: 0, total: 5), isSelected: false)
                        ] : []
                    let owner = SoundPacksEditorOwner.stateGalleryFixture(
                        previewConfig: ClaudioConfig(selectedPack: ""), packCards: cards,
                        selectedPackID: nil, selectedEventRows: [],
                        libraryPresentationState: state, environment: environment)
                    let fixture = SettingsPresentationFixtures.generalLogin(
                        language: language, route: .sounds(.overview), soundPacksEditor: owner)
                    let probe = SettingsSoundsNativeLayoutProbe(
                        session: fixture.session, size: NSSize(width: 960, height: 640))
                    await probe.settle()
                    expect(
                        probe.menuAccessibilityElement(identifier: identifier) != nil,
                        "\(language) \(state) 呈现实际状态")
                    if state != .ready {
                        expect(
                            probe.menuAccessibilityElement(
                                identifier: "settings.sounds.library.empty") == nil, "加载或失败不能伪装成功空库"
                        )
                    }
                    if hasPrevious {
                        expect(
                            probe.menuAccessibilityElement(
                                identifier: "settings.sounds.pack.previous") != nil, "陈旧快照仍显示已有声音包")
                    }
                    if retry {
                        expect(
                            probe.menuIsEnabled(identifier: "settings.sounds.library.retry")
                                == true, "库失败提供可执行重试")
                        expect(
                            probe.pressControl("settings.sounds.library.retry"),
                            "真实按钮调用 owner 重试 capability")
                    }
                    probe.close()
                }
            }
        }
    }

    await suite("生成保存恢复：当前表单重获选用资格，关闭表单不复活旧资格") {
        for closeBeforeRetry in [false, true] {
            await withTempDirectory { root in
                do {
                    let environment = makeAudioImportEnvironment(
                        userPacksDirectory: root.appendingPathComponent("packs"))
                    writeFixture(
                        #"{"id":"target","name":"Target","events":{}}"#,
                        to: environment.userPacksDirectory.appendingPathComponent(
                            "target/manifest.json"))
                    let config = root.appendingPathComponent("config.json")
                    writeFixture(#"{"selected_pack":"target"}"#, to: config)
                    let library = SoundPackLibrary(environment: environment)
                    let owner = SoundPacksEditorOwner(
                        configFile: config, lockFile: root.appendingPathComponent("config.lock"),
                        environment: environment, soundPackLibrary: library,
                        refreshCoordinator: SoundPacksRefreshCoordinator())
                    _ = await library.refreshSnapshot(trigger: .initial)
                    let generation = historyGeneration(
                        root.appendingPathComponent("generated"), count: 1)
                    let generator = RecoveryGenerator(generation)
                    let blocker = root.appendingPathComponent("blocked")
                    writeFixture("not a directory", to: blocker)
                    let history = GenerationHistoryStore(
                        directory: blocker.appendingPathComponent("history"))
                    let defaultsName = UUID().uuidString
                    let defaults = UserDefaults(suiteName: defaultsName)!
                    defer { defaults.removePersistentDomain(forName: defaultsName) }
                    let model = AICueGenerationViewModel(
                        credentialManager: RecoveryCredentialManager(), generator: generator,
                        providerProfileID: .elevenLabsGlobal,
                        providerPreferences: AICueProviderPreferences(defaults: defaults))
                    model.installGenerationHistory(history)
                    let fixture = SettingsPresentationFixtures.generalLogin(
                        route: .sounds(
                            SoundPacksWindowRoute(
                                surface: nil, destination: .pack(packID: "target"))),
                        soundPacksEditor: owner, aiCueViewModel: model)
                    let probe = SettingsSoundsNativeLayoutProbe(
                        session: fixture.session, size: NSSize(width: 960, height: 640))
                    defer { probe.close() }
                    await probe.settle()
                    expect(probe.chooseSource(event: .stop, index: 0), "由目标事件打开生成表单")
                    await probe.settle()
                    let session = model.session
                    model.updateDescription("保存恢复测试")
                    model.startGeneration(locale: "zh-Hans")
                    guard
                        await waitForRecovery({
                            if case .pending = model.coordinator.state { return true }; return false
                        })
                    else { expect(false, "生成必须进入保存失败状态"); return }
                    await probe.settle()
                    expect(adoptionPermit(owner) == nil, "保存失败时禁用候选采用")
                    if closeBeforeRetry {
                        expect(probe.pressControl("settings.sounds.sheet.close"), "关闭当前采用上下文")
                        await probe.settle()
                    }
                    try FileManager.default.removeItem(at: blocker)
                    model.coordinator.retrySave()
                    guard
                        await waitForRecovery({
                            if case .saved = model.coordinator.state { return true }; return false
                        })
                    else { expect(false, "归档重试必须成功"); return }
                    await probe.settle()
                    expect(await generator.requests == 1, "重试仅归档，不重新生成")
                    if closeBeforeRetry {
                        expect(
                            model.session == nil && adoptionPermit(owner) == nil,
                            "归档成功不恢复已关闭会话的采用资格")
                    } else {
                        expect(
                            model.session == session && model.generation == generation,
                            "归档重试不改变有效会话或候选集合")
                        guard let permit = adoptionPermit(owner) else {
                            expect(false, "保存恢复后当前表单必须可显式选用"); return
                        }
                        let name = try AICueDisplayName("Recovered")
                        let result = await owner.perform(
                            .adoptAICue(
                                candidate: generation.candidates[0], displayName: name,
                                permit: permit))
                        if case .adopted = result {
                        } else {
                            expect(false, "恢复资格实际进入采用事务：\(result)")
                        }
                    }
                } catch { expect(false, "生成采用恢复失败：\(error)") }
            }
        }
    }

    await suite("包内音频恢复：加载和读取失败保留独立状态，重试成功空清单才显示空态") {
        for previousAvailable in [false, true] {
            await withTempDirectory { root in
                let gate = RecoveryIOGate()
                defer { gate.release() }
                let environment = makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("packs"))
                let oldAudio = environment.userPacksDirectory.appendingPathComponent(
                    "target/old.mp3")
                writeFixture(
                    #"{"id":"target","events":{}}"#,
                    to: environment.userPacksDirectory.appendingPathComponent(
                        "target/manifest.json"))
                writeFixture(validMP3ID3Data(), to: oldAudio)
                let oldFiles = [
                    PackAudioFile(fileName: "old.mp3", isOrphan: true, nativeTargetURL: oldAudio)
                ]
                let source = RecoveryInventorySource(
                    previousAvailable ? .available(oldFiles) : .deferred)
                let library = SoundPackLibrary(
                    scanner: SoundPackLibraryScanner { _ in .success(source.facts()) },
                    inventoryOperation: { _ in
                        gate.wait()
                        return .unavailable(
                            previousAvailable
                                ? .manifestUnreadable(reason: "fixture")
                                : .directoryUnreadable(reason: "fixture"))
                    })
                let config = root.appendingPathComponent("config.json")
                writeFixture(#"{"selected_pack":"target"}"#, to: config)
                let owner = SoundPacksEditorOwner(
                    configFile: config, lockFile: root.appendingPathComponent("config.lock"),
                    environment: environment, soundPackLibrary: library,
                    refreshCoordinator: SoundPacksRefreshCoordinator())
                _ = await library.refreshSnapshot(trigger: .initial)
                let fixture = SettingsPresentationFixtures.generalLogin(
                    route: .sounds(
                        SoundPacksWindowRoute(surface: nil, destination: .pack(packID: "target"))),
                    soundPacksEditor: owner)
                let probe = SettingsSoundsNativeLayoutProbe(
                    session: fixture.session, size: NSSize(width: 960, height: 640))
                defer { probe.close() }
                await probe.settle()
                expect(probe.chooseSource(event: .stop, index: 2), "事件入口打开本包音频表单")
                await probe.settle()
                if previousAvailable {
                    source.set(.deferred)
                    _ = await library.refreshSnapshot(trigger: .retry)
                }
                expect(await waitForRecovery { gate.hasEntered }, "清单 I/O 已阻塞，加载状态可稳定检查")
                await probe.settle()
                expect(
                    probe.menuAccessibilityElement(identifier: "settings.sounds.inventory.loading")
                        != nil, "清单加载不能被空数组或旧清单掩盖")
                expect(
                    probe.menuAccessibilityElement(identifier: "settings.sounds.inventory.empty")
                        == nil, "加载中不显示成功空态")
                gate.release()
                expect(
                    await waitForRecovery {
                        if case .sounds(let sounds) = owner.presentation.mode,
                            case .failed = sounds.inventory
                        {
                            return true
                        }; return false
                    }, "实际失败已到达 owner")
                await probe.settle()
                expect(
                    probe.menuAccessibilityElement(identifier: "settings.sounds.inventory.failure")
                        != nil, "清单失败原因可见")
                expect(
                    probe.menuIsEnabled(identifier: "settings.sounds.inventory.retry") == true,
                    "清单失败提供可执行重试")
                if previousAvailable {
                    if case .sounds(let sounds) = owner.presentation.mode,
                        case .failed(let previous, _) = sounds.inventory
                    {
                        expect(previous?.map(\.fileName) == ["old.mp3"], "读取失败保留上次清单，界面同时呈现失败状态")
                    } else {
                        expect(false, "失败清单必须保留之前读取的文件")
                    }
                }
                source.set(.available([]))
                expect(probe.pressControl("settings.sounds.inventory.retry"), "真实重试调用共享库读取")
                expect(
                    await waitForRecovery {
                        if case .sounds(let sounds) = owner.presentation.mode,
                            case .ready(let files) = sounds.inventory
                        {
                            return files.isEmpty
                        }; return false
                    }, "重试成功读取空清单")
                await probe.settle()
                expect(
                    probe.menuAccessibilityElement(identifier: "settings.sounds.inventory.empty")
                        != nil, "只有成功空清单显示空态")
                expect(
                    probe.menuAccessibilityElement(identifier: "settings.sounds.inventory.failure")
                        == nil, "成功重试清除失败提示")
            }
        }
    }

    await suite("历史试听恢复：路由切换撤销在途读取，新的显式试听仍可播放") {
        await withTempDirectory { root in
            let gate = RecoveryIOGate(blocked: false)
            defer { gate.release() }
            do {
                let generation = historyGeneration(root.appendingPathComponent("first"), count: 1)
                let history = GenerationHistoryStore(
                    directory: root.appendingPathComponent("history"),
                    beforePublish: { gate.wait() })
                _ = try await history.archive(generation, soundDescription: "历史试听")
                let generator = RecoveryGenerator(generation)
                let defaultsName = UUID().uuidString
                let defaults = UserDefaults(suiteName: defaultsName)!
                defer { defaults.removePersistentDomain(forName: defaultsName) }
                let model = AICueGenerationViewModel(
                    credentialManager: RecoveryCredentialManager(), generator: generator,
                    providerPreferences: AICueProviderPreferences(defaults: defaults))
                model.installGenerationHistory(history)
                let player = RecoveryPlayback()
                let effects = SoundPacksEditorNativeEffectsDispatcher(adapter: player)
                let historyRoute = SoundPacksWindowRoute(surface: nil, destination: .history)
                let fixture = SettingsPresentationFixtures.generalLogin(
                    route: .sounds(historyRoute), aiCueViewModel: model, nativeEffects: effects)
                let probe = SettingsSoundsNativeLayoutProbe(
                    session: fixture.session, size: NSSize(width: 960, height: 640))
                defer { probe.close() }
                await probe.settle()
                gate.arm()
                let other = historyGeneration(root.appendingPathComponent("second"), count: 1)
                let archive = Task { try await history.archive(other, soundDescription: "阻塞磁盘队列") }
                guard await waitForRecovery({ gate.hasEntered }) else {
                    gate.release(); _ = try await archive.value
                    expect(false, "归档门必须阻塞历史读取"); return
                }
                let previewID = "settings.sounds.preview.\(generation.candidates[0].id.uuidString)"
                expect(probe.pressControl(previewID), "真实历史按钮发起在途读取")
                await probe.settle()
                expect(player.plays == 0, "读取完成前不启动播放器")
                _ = fixture.session.send(.route(.sounds(.overview)))
                await probe.settle()
                expect(
                    fixture.session.state.routeResolution.route == .sounds(.overview),
                    "返回声音列表后仍使用同一挂载视图")
                gate.release()
                _ = try await archive.value
                let latePlayback = await waitForRecovery { player.plays > 0 }
                expect(!latePlayback && effects.playingSoundID == nil, "迟到的历史读取不能在新页面启动旧试听")
                _ = fixture.session.send(.route(.sounds(historyRoute)))
                await probe.settle()
                let previousPlayCount = player.plays
                expect(probe.pressControl(previewID), "返回历史后可显式发起新试听")
                expect(await waitForRecovery { player.plays > previousPlayCount }, "撤销旧请求不影响新请求播放")
            } catch { expect(false, "历史试听恢复失败：\(error)") }
        }
    }
}

@MainActor
private func adoptionPermit(_ owner: SoundPacksEditorOwner) -> SoundPackAdoptionPermit? {
    guard case .sounds(let sounds) = owner.presentation.mode else { return nil }
    return sounds.eventRows.first { $0.event == .stop }?.aiCueAdoptionPermit
}

@MainActor
private func waitForRecovery(_ predicate: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return predicate()
}
