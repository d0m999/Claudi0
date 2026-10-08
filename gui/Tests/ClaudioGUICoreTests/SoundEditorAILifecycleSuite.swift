import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation
import SoundPacksWindow

private actor SoundEditorLifecycleCredentials: AICueCredentialManaging {
    private var currentStatus: AICueCredentialStatus
    init(
        status: AICueCredentialStatus = .stored(
            verification: .verified, hasPendingReplacement: false)
    ) {
        currentStatus = status
    }
    func status(for profileID: AICueProviderProfileID) async -> AICueCredentialStatus {
        currentStatus
    }

    func save(
        _ credential: SensitiveCredentialInput,
        for profileID: AICueProviderProfileID
    ) async throws -> AICueCredentialStatus {
        currentStatus = .stored(verification: .verified, hasPendingReplacement: false)
        return currentStatus
    }

    func delete(for profileID: AICueProviderProfileID) async throws {}
    func cancelPendingReplacement(for profileID: AICueProviderProfileID) async throws {}
}

/// Completes only when the test releases it, including when the caller has been cancelled.
private actor SoundEditorLifecycleGenerator: AICueGenerating {
    private var continuation: CheckedContinuation<AICueGeneration, Never>?
    private(set) var cancellationCount = 0
    private(set) var discardedGenerationIDs: [UUID] = []

    var isSuspended: Bool { continuation != nil }

    func generate(
        description: String,
        locale: String,
        providerProfileID: AICueProviderProfileID,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueGeneration {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.noteCancellation() }
        }
    }

    func release(with generation: AICueGeneration) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: generation)
    }

    func discard(generationID: UUID) async {
        discardedGenerationIDs.append(generationID)
    }

    func discardAll() async {}

    private func noteCancellation() { cancellationCount += 1 }
}

@MainActor
func runSoundEditorAILifecycleSuites() async {
    #if DEBUG
    await suite("声音实际生成表单：百炼准入同时约束生成和凭据入口") {
        #if CLAUDIO_BAILIAN_ACCEPTANCE
        let admitted = true
        #else
        let admitted = false
        #endif
        for status in [
            AICueCredentialStatus.missing,
            .stored(verification: .verified, hasPendingReplacement: false),
        ] {
            let defaultsName = "BailianAdmission-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: defaultsName)!
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let generator = SoundEditorLifecycleGenerator()
            let model = AICueGenerationViewModel(
                credentialManager: SoundEditorLifecycleCredentials(status: status),
                generator: generator, providerProfileID: .bailianBeijing,
                providerPreferences: AICueProviderPreferences(defaults: defaults))
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .sounds(.overview),
                availability: PreviewFixtures.settingsRouteAvailability, aiCueViewModel: model)
            let probe = SettingsSoundsNativeLayoutProbe(
                session: fixture.session, size: NSSize(width: 960, height: 640))
            defer { model.endSession(); probe.close() }
            await probe.settle()
            expect(probe.pressControl("settings.sounds.pack.settings-fixture-pack"), "实际声音列表进入包详情")
            await probe.settle()
            expect(probe.chooseSource(event: .stop, index: 0), "实际事件菜单打开 AI 表单")
            await probe.settle()
            model.updateDescription("清晰地说“任务完成”")
            probe.refresh()
            expect(
                probe.menuIsEnabled(identifier: "settings.sounds.ai.generate") == admitted,
                "缺凭据配置及已有凭据生成均服从当前构建准入")
            expect(
                probe.menuIsEnabled(identifier: "event-settings.ai-cue.credential-manage")
                    == admitted,
                "共享服务卡服从同一准入")
            if status == .missing {
                let manage = probe.menuAccessibilityElement(
                    identifier: "settings.sounds.ai.credential-manage")
                if let manage {
                    expect(
                        manage.isAccessibilityEnabled?() == admitted,
                        "实际表单额外凭据入口服从准入")
                } else {
                    expect(false, "额外凭据入口必须可独立检查")
                }
            }
            if !admitted {
                expect(!probe.pressControl("settings.sounds.ai.generate"), "普通构建不能进入配置或生成")
                expect(
                    probe.menuAccessibilityElement(
                        identifier: "event-settings.ai-cue.credential-input") == nil,
                    "未获准服务不挂载凭据表单")
                expect(!(await generator.isSuspended), "未获准服务不调用生成器")
                try! model.selectProviderProfile(.elevenLabsGlobal)
                await model.refreshCredentialStatus()
                probe.refresh()
                expect(
                    probe.menuIsEnabled(identifier: "settings.sounds.ai.generate") == true,
                    "切换到已准入服务可恢复生成或配置入口")
            } else if status == .missing {
                expect(probe.pressControl("settings.sounds.ai.credential-manage"), "验收构建允许进入凭据管理")
                await probe.settle()
                expect(
                    probe.menuAccessibilityElement(
                        identifier: "event-settings.ai-cue.credential-input") != nil,
                    "验收构建挂载既有凭据表单")
                expect(!(await generator.isSuspended), "配置入口不自动生成")
            }
        }
    }

    await suite("声音原生流程：列表、五事件来源、附属表单与凭据返回") {
        for language in ClaudioAppLanguage.allCases {
            let generator = SoundEditorLifecycleGenerator()
            let viewModel = soundEditorLifecycleViewModel(
                generator: generator,
                credentials: SoundEditorLifecycleCredentials(status: .missing))
            let fixture = SettingsPresentationFixtures.generalLogin(
                language: language,
                route: .sounds(.overview), availability: PreviewFixtures.settingsRouteAvailability,
                aiCueViewModel: viewModel)
            let probe = SettingsSoundsNativeLayoutProbe(
                session: fixture.session,
                size: NSSize(width: 960, height: 640))
            defer { viewModel.endSession(); probe.close() }
            await probe.settle()
            expect(!probe.hasAttachedSheet && viewModel.session == nil, "开声音页只显示列表，不创建表单或请求")
            expect(
                probe.menuAccessibilityElement(identifier: "settings.sounds.management-scope")
                    == nil,
                "声音页不显示工作区作用域")
            expect(probe.pressControl("settings.sounds.pack.settings-fixture-pack"), "真实列表行进入详情")
            await probe.settle()
            expect(
                fixture.session.state.soundsDetail == .pack(packID: "settings-fixture-pack"),
                "列表进入同区域包详情")
            captureSoundLifecycle(probe, name: "detail-\(language.rawValue)")
            for event in Event.allCases {
                expect(
                    probe.menuIsEnabled(
                        identifier: "settings.sounds.event.\(event.rawValue).source") == true,
                    "五事件直接提供来源菜单")
            }
            expect(probe.chooseSource(event: .stop, index: 0), "选择 AI 来源")
            await probe.settle()
            expect(
                probe.hasAttachedSheet
                    && viewModel.session
                        == AICueComposerSession(packID: "settings-fixture-pack", event: .stop),
                "AI 使用同一窗口附属表单及固定目标")
            viewModel.updateDescription("短促木琴完成音效")
            probe.refresh()
            expect(
                probe.controlLabel("settings.sounds.ai.generate")
                    == ClaudioL10n(language: language).text(.aiCueConfigureKey), "缺少凭据明确引导配置")
            expect(probe.pressControl("settings.sounds.ai.generate"), "从生成表单进入共享服务管理")
            await probe.settle()
            expect(
                probe.menuAccessibilityElement(identifier: "event-settings.ai-cue.credential-input")
                    != nil, "服务管理实际挂载")
            await viewModel.saveCredential(try! SensitiveCredentialInput("fixture-only-key"))
            expect(!(await generator.isSuspended), "保存凭据不发生成请求")
            expect(probe.pressControl("event-settings.ai-cue.credential-cancel"), "服务管理返回原表单")
            await probe.settle()
            expect(
                viewModel.soundDescription == "短促木琴完成音效" && probe.hasAttachedSheet,
                "返回保留描述和原附属表单")
            captureSoundLifecycle(probe, name: "composer-\(language.rawValue)", sheet: true)
            expect(probe.pressControl("settings.sounds.sheet.close"), "关闭表单")
            await probe.settle()
            expect(!probe.hasAttachedSheet && viewModel.session == nil, "关闭撤销采用上下文")
            for source in 1...4 {
                expect(probe.chooseSource(event: .stop, index: source), "其他来源也从同一事件打开")
                await probe.settle()
                expect(probe.hasAttachedSheet, "来源选择使用附属表单")
                captureSoundLifecycle(
                    probe, name: "source-\(source)-\(language.rawValue)", sheet: true)
                expect(probe.pressControl("settings.sounds.sheet.close"), "取消来源不写入")
                await probe.settle()
            }
        }
    }
    await suite("声音原生生命周期：关闭表单继续生成，结果从记录入口恢复") {
        let generator = SoundEditorLifecycleGenerator()
        let viewModel = soundEditorLifecycleViewModel(generator: generator)
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .sounds(.overview),
            availability: PreviewFixtures.settingsRouteAvailability, aiCueViewModel: viewModel)
        let probe = SettingsSoundsNativeLayoutProbe(
            session: fixture.session, size: NSSize(width: 960, height: 640))
        defer { probe.close() }
        await probe.settle()
        expect(probe.pressControl("settings.sounds.pack.settings-fixture-pack"), "进入目标包")
        await probe.settle()
        expect(probe.chooseSource(event: .stop, index: 0), "打开 AI 表单")
        await probe.settle()
        viewModel.updateDescription("后台完成的木琴")
        probe.refresh()
        expect(probe.pressControl("settings.sounds.ai.generate"), "仅显式点击开始任务")
        expect(await soundEditorLifecycleWait { await generator.isSuspended }, "Provider 收到一组任务")
        expect(probe.pressControl("settings.sounds.sheet.close"), "生成中仍可关闭表单")
        await probe.settle()
        expect(
            await generator.cancellationCount == 0 && viewModel.session == nil,
            "关表单不取消任务，只撤销采用上下文")
        let generation = soundEditorLifecycleGeneration(root: fixture.temporaryRoot)
        await generator.release(with: generation)
        expect(
            await soundEditorLifecycleWait { viewModel.coordinator.state == .saved(generation.id) },
            "后台完成后归档成功")
        expect(viewModel.generation == nil && !probe.hasAttachedSheet, "后台完成不重新打开或授予旧上下文")
        expect(viewModel.coordinator.history.snapshot.batches.first?.audio.count == 3, "全部三条结果持久保存")
        expect(viewModel.coordinator.hasUnreadCompletion, "会话内记录入口显示未读完成状态")
        let routeResult = fixture.session.send(
            .route(.sounds(SoundPacksWindowRoute(scope: .global, destination: .history))))
        await probe.settle()
        captureSoundLifecycle(probe, name: "history")
        expect(
            !viewModel.coordinator.hasUnreadCompletion,
            "进入记录页消除完成提示：\(routeResult), \(fixture.session.state.routeResolution), \(fixture.session.state.soundsDetail)"
        )
    }
    await suite("声音原生生命周期：持久草稿的 AI 首音发布不会被页面切换撤销") {
        let generator = SoundEditorLifecycleGenerator()
        let viewModel = soundEditorLifecycleViewModel(generator: generator)
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .sounds(.overview),
            availability: PreviewFixtures.settingsRouteAvailability, aiCueViewModel: viewModel)
        let probe = SettingsSoundsNativeLayoutProbe(
            session: fixture.session, size: NSSize(width: 960, height: 640))
        defer { probe.close() }
        await probe.settle()
        let owner = fixture.soundPacksEditor
        do {
            let draft = try await owner.createNamedDraft(AICuePackName("AI 首音草稿"))
            _ = fixture.session.send(
                .route(
                    .sounds(
                        SoundPacksWindowRoute(
                            scope: .global, destination: .draft(packID: draft.packID)))))
            await probe.settle()
            expect(probe.chooseSource(event: .stop, index: 0), "草稿事件打开 AI 表单")
            await probe.settle()
            viewModel.updateDescription("第一次保存的木琴")
            viewModel.startGeneration(locale: "zh-Hans")
            expect(await soundEditorLifecycleWait { await generator.isSuspended }, "只发起本轮请求")
            let generation = soundEditorLifecycleGeneration(root: fixture.temporaryRoot)
            await generator.release(with: generation)
            expect(
                await soundEditorLifecycleWait { viewModel.phase == .candidatesReady },
                "归档成功才出现可采用候选")
            await probe.settle()
            captureSoundLifecycle(probe, name: "candidates", sheet: true)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let permit = sounds.eventRows.first(where: { $0.event == .stop })?
                    .aiCueAdoptionPermit
            else {
                expect(false, "持久草稿签发真实当前候选采用能力"); return
            }
            viewModel.adopt(candidateID: generation.candidates[0].id, permit: permit) {
                candidate, name, permit in
                await owner.perform(
                    .adoptAICue(candidate: candidate, displayName: name, permit: permit))
            }
            expect(
                await soundEditorLifecycleWait {
                    viewModel.phase == .applied || viewModel.session == nil
                }, "首次发布成功后结束表单")
            await probe.settle()
            let manifestURL = owner.soundImportEnvironment.userPacksDirectory
                .appendingPathComponent(draft.packID).appendingPathComponent("manifest.json")
            let manifest = try JSONDecoder().decode(
                PackManifest.self, from: Data(contentsOf: manifestURL))
            expect(
                manifest.id == draft.packID && manifest.eventSources[Event.stop.rawValue] != nil,
                "真实事务发布同一草稿 ID 和事件绑定")
            expect(
                fixture.session.state.soundsDetail == .pack(packID: draft.packID)
                    && !probe.hasAttachedSheet,
                "发布后进入正式包详情，不落入失效草稿页")
            expect(
                viewModel.coordinator.history.snapshot.batches.first?.audio.count == 3,
                "采用一条仍保留全部三条生成记录")
        } catch { expect(false, "AI 首音原生集成失败：\(error)") }
    }
    await suite("声音原生候选：部分成功显示实际数量与已有许可说明") {
        for count in [1, 2] {
            let generator = SoundEditorLifecycleGenerator()
            let viewModel = soundEditorLifecycleViewModel(generator: generator)
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .sounds(.overview), availability: PreviewFixtures.settingsRouteAvailability,
                aiCueViewModel: viewModel)
            let probe = SettingsSoundsNativeLayoutProbe(
                session: fixture.session, size: NSSize(width: 960, height: 640))
            defer { viewModel.endSession(); probe.close() }
            await probe.settle()
            expect(probe.pressControl("settings.sounds.pack.settings-fixture-pack"), "进入目标包")
            await probe.settle()
            expect(probe.chooseSource(event: .stop, index: 0), "打开生成表单")
            await probe.settle()
            viewModel.updateDescription("部分完成的木琴")
            viewModel.startGeneration(locale: "zh-Hans")
            expect(await soundEditorLifecycleWait { await generator.isSuspended }, "只发起一组请求")
            await generator.release(
                with: soundEditorLifecycleGeneration(root: fixture.temporaryRoot, count: count))
            expect(
                await soundEditorLifecycleWait { viewModel.phase == .candidatesReady },
                "部分有效集合归档后可选择")
            await probe.settle()
            expect(
                probe.menuAccessibilityElement(identifier: "settings.sounds.ai.partial") != nil,
                "部分成功显示明确的实际数量提示")
            expect(viewModel.generation?.candidates.count == count, "表单保留实际候选数量")
            captureSoundLifecycle(probe, name: "candidates-\(count)", sheet: true)
        }
    }
    #endif
}

@MainActor
private func captureSoundLifecycle(
    _ probe: SettingsSoundsNativeLayoutProbe, name: String, sheet: Bool = false
) {
    guard let directory = ProcessInfo.processInfo.environment["CLAUDIO_SOUND_CAPTURE_DIR"] else {
        return
    }
    let file = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
    expect(
        sheet ? probe.saveSheetScreenshot(to: file) : probe.saveScreenshot(to: file),
        "原生声音流程截图可保存：\(name)")
}

@MainActor
private func soundEditorLifecycleViewModel(
    generator: SoundEditorLifecycleGenerator,
    credentials: SoundEditorLifecycleCredentials = SoundEditorLifecycleCredentials()
) -> AICueGenerationViewModel {
    AICueGenerationViewModel(
        credentialManager: credentials,
        generator: generator, providerProfileID: .elevenLabsGlobal,
        providerPreferences: AICueProviderPreferences(defaults: UserDefaults()))
}

@MainActor
private func soundEditorLifecycleOpenLocalEvent(
    _ probe: SettingsRootNativeProbe, fixture: SettingsPresentationFixture
) async -> Bool {
    let opened = probe.clickRecordedControl("sound-packs.event-row.stop")
    expect(opened, "必须通过真实事件行鼠标点击进入本地详情")
    await Task.yield()
    let mounted = SoundPacksLayoutRecorder.frames["sound-packs.event-detail"] != nil
    expect(mounted, "点击事件行后必须实际挂载事件详情")
    expect(
        fixture.session.state.routeResolution.route
            == .sounds(.editEvent(packID: "settings-fixture-pack", event: .stop)),
        "本地事件详情通过统一位置进入历史")
    return opened && mounted
}

@MainActor
private func soundEditorLifecyclePermit(_ owner: SoundPacksEditorOwner) -> SoundPackAdoptionPermit?
{
    guard case .sounds(let sounds) = owner.presentation.mode else { return nil }
    return sounds.eventRows.first(where: { $0.event == .stop })?.aiCueAdoptionPermit
}

@MainActor
private func soundEditorLifecycleRoute(_ owner: SoundPacksEditorOwner) -> SoundPacksWindowRoute? {
    guard case .sounds(let sounds) = owner.presentation.mode else { return nil }
    return sounds.route
}

@MainActor
private func soundEditorLifecycleWait(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

@MainActor
private func soundEditorLifecycleExpectOverview() async {
    let mounted = await soundEditorLifecycleWait {
        SoundPacksLayoutRecorder.frames["sound-packs.events.group"] != nil
    }
    expect(
        mounted && SoundPacksLayoutRecorder.frames["sound-packs.event-detail"] == nil,
        "显式请求必须实际退出事件详情并重新挂载声音概览")
}

@MainActor
private func soundEditorLifecycleClickSoundsSidebar(_ probe: SettingsRootNativeProbe) async {
    await probe.settle()
    expect(probe.selectSidebar(.sounds, horizontalFraction: 0.5), "原生列表单选必须发布一次统一导航事务")
    await probe.settle()
    await soundEditorLifecycleExpectOverview()
}

@MainActor
private func soundEditorLifecycleGeneration(root: URL, count: Int = 3) -> AICueGeneration {
    let id = UUID()
    let plan = AICueSoundPlan(
        suggestedDisplayName: "木琴完成", modality: .soundEffect,
        soundDescription: "短促木琴完成音效", spokenContent: nil, languageTag: nil,
        styleDescription: "短促、清晰", targetDurationMilliseconds: 1_500,
        instructionVersion: AICueSoundPlanner.instructionVersion)
    let candidates = AICueVariant.allCases.prefix(count).map { variant in
        writeFixture(
            validMP3ID3Data(), to: root.appendingPathComponent("candidate-\(variant.ordinal).mp3"))
        return AICueCandidate(
            id: UUID(), variant: variant,
            asset: AICueTemporaryAudioAsset(
                fileURL: root.appendingPathComponent("candidate-\(variant.ordinal).mp3"),
                byteCount: validMP3ID3Data().count, sniffedFormat: .mp3),
            durationMilliseconds: 1_200, mediaType: "audio/mpeg",
            provenance: AICueCandidateProvenance(
                providerID: .elevenLabs, profileID: .elevenLabsGlobal,
                modelID: "eleven_text_to_sound_v2", generationID: id,
                requestOrdinal: variant.ordinal, providerRequestID: nil))
    }
    return AICueGeneration(
        id: id, profileID: .elevenLabsGlobal, plan: plan, candidates: candidates,
        completion: count == 3 ? .complete : .partial,
        generatedAt: Date(timeIntervalSince1970: 1))
}
