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
    await suite("声音原生入口：直接生成、显式配置 Key、保存后仍需显式生成") {
        for language in ClaudioAppLanguage.allCases {
            let generator = SoundEditorLifecycleGenerator()
            let credentials = SoundEditorLifecycleCredentials(status: .missing)
            let viewModel = soundEditorLifecycleViewModel(
                generator: generator, credentials: credentials)
            let fixture = SettingsPresentationFixtures.generalLogin(
                language: language, route: .sounds(.overview),
                availability: PreviewFixtures.settingsRouteAvailability, aiCueViewModel: viewModel)
            let probe = SettingsSoundsNativeLayoutProbe(
                session: fixture.session, size: NSSize(width: 960, height: 640))
            defer { viewModel.endSession(); probe.close() }
            await probe.settle()
            let l10n = ClaudioL10n(language: language)
            expect(!probe.hasAttachedSheet, "首次声音页不自动弹 Key sheet")
            for event in Event.allCases {
                if let frame = SoundPacksLayoutRecorder.frames[
                    "settings.sounds.ai-cue.event.\(event.rawValue)"]
                {
                    _ = probe.scrollToVisible(frame)
                }
                expect(
                    probe.menuAccessibilityElement(
                        identifier: "settings.sounds.ai-cue.event.\(event.rawValue)") != nil,
                    "五事件的生成入口必须在主页面直接可达")
            }
            expect(
                SoundPacksLayoutRecorder.frames["sound-packs.deletion.card"] != nil,
                "声音包删除必须成为主页面独立区域")
            expect(
                probe.menuIsEnabled(identifier: "sound-packs.delete-selected-pack") == false,
                "使用中的声音包仍受删除保护")
            if let frame = SoundPacksLayoutRecorder.frames["settings.sounds.ai-cue.event.stop"] {
                _ = probe.scrollToVisible(frame)
            }
            expect(probe.pressControl("settings.sounds.ai-cue.event.stop"), "点击主页面生成入口")
            await probe.settle()
            expect(
                viewModel.session
                    == AICueComposerSession(packID: "settings-fixture-pack", event: .stop),
                "直接入口跨路由保留同包同事件创作会话")
            expect(
                probe.menuAccessibilityElement(identifier: "event-settings.ai-cue.description")
                    != nil,
                "一步进入描述表单")
            viewModel.updateDescription("短促木琴完成音效")
            probe.refresh()
            if let frame = SoundPacksLayoutRecorder.frames["event-settings.ai-cue.generate.control"]
            {
                _ = probe.scrollToVisible(frame)
            }
            expect(
                probe.controlLabel("event-settings.ai-cue.generate")
                    == l10n.text(.aiCueConfigureKey),
                "缺少 Key 时主按钮明确引导配置")
            expect(probe.pressControl("event-settings.ai-cue.generate"), "显式配置 Key")
            await probe.settle()
            expect(probe.hasAttachedSheet, "点击后挂载原生 Key sheet")
            expect(!(await generator.isSuspended), "配置 Key 不触发生成")
            // Use the injected credential manager; this checks the save seam without a real API request.
            await viewModel.saveCredential(try! SensitiveCredentialInput("fixture-only-key"))
            fixture.eventSettingsSelection.dismissCredentialSheet()
            await probe.settle()
            expect(
                !probe.hasAttachedSheet && viewModel.soundDescription == "短促木琴完成音效",
                "保存后返回同表单并保留描述")
            let generatedAfterSaving = await generator.isSuspended
            expect(viewModel.phase == .editing && !generatedAfterSaving, "保存不自动生成")
            expect(
                probe.controlLabel("event-settings.ai-cue.generate")
                    == l10n.text(.aiCueGenerateCue),
                "主按钮切换为生成提示音")
            expect(probe.pressControl("event-settings.ai-cue.generate"), "显式生成提示音")
            let generating = await soundEditorLifecycleWait { await generator.isSuspended }
            expect(generating, "主按钮进入真实生成任务")
            guard generating else { continue }
            await generator.release(
                with: soundEditorLifecycleGeneration(root: fixture.temporaryRoot))
            _ = await soundEditorLifecycleWait { viewModel.phase == .candidatesReady }
            await probe.settle()
            expect(
                probe.controlLabel("event-settings.ai-cue.candidate.clear.use")?.contains(
                    l10n.format(.aiCueUseNamedEvent, localizedEventName(.stop, language: language)))
                    == true,
                "候选采用按钮明确具体事件")
        }
    }
    await suite("声音事件详情：点击当前声音侧栏立即取消生成并拒绝迟到候选") {
        let generator = SoundEditorLifecycleGenerator()
        let viewModel = soundEditorLifecycleViewModel(generator: generator)
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .sounds(.overview),
            availability: PreviewFixtures.settingsRouteAvailability,
            aiCueViewModel: viewModel)
        let probe = SettingsRootNativeProbe(session: fixture.session)
        defer {
            viewModel.endSession()
            probe.close()
        }
        guard await soundEditorLifecycleOpenLocalEvent(probe, fixture: fixture) else { return }
        viewModel.begin(packID: "settings-fixture-pack", event: .stop)
        viewModel.updateDescription("短促木琴完成音效")
        viewModel.startGeneration(locale: "zh-Hans")
        let suspended = await soundEditorLifecycleWait { await generator.isSuspended }
        expect(suspended && viewModel.phase == .generating, "真实 generation task 必须已挂起")

        // Publishing the current context again is not a new user navigation request.
        if case .sounds(let sounds) = fixture.soundPacksEditor.presentation.mode {
            _ = fixture.soundPacksEditor.send(
                .activate(.sounds(route: .overview, requestRevision: sounds.requestRevision)))
        }
        await Task.yield()
        expect(
            viewModel.session != nil && viewModel.phase == .generating,
            "相同 requestRevision 的投影重放不得退出本地详情或取消生成")

        await soundEditorLifecycleClickSoundsSidebar(probe)
        _ = await soundEditorLifecycleWait { viewModel.session == nil }
        expect(
            fixture.session.state.routeResolution.destination == .sounds
                && soundEditorLifecycleRoute(fixture.soundPacksEditor) == .overview,
            "外层声音编辑器 route 始终为概览")
        expect(
            viewModel.session == nil && viewModel.phase == .editing,
            "详情退出必须立即结束 session 并恢复 editing")
        let cancelled = await soundEditorLifecycleWait { await generator.cancellationCount == 1 }
        expect(cancelled, "详情退出必须取消正在运行的 generation task")

        let generation = soundEditorLifecycleGeneration(root: fixture.temporaryRoot)
        await generator.release(with: generation)
        _ = await soundEditorLifecycleWait {
            await generator.discardedGenerationIDs.contains(generation.id)
                || viewModel.generation != nil
        }
        expect(
            viewModel.session == nil && viewModel.generation == nil && viewModel.phase == .editing,
            "已退出详情的迟到成功不得重新发布候选")
        let discarded = await generator.discardedGenerationIDs
        expect(discarded == [generation.id], "迟到成功必须交还同一 generation 清理")
    }

    await suite("声音事件详情：点击当前声音侧栏清候选并撤销 owner 采用资格") {
        let generator = SoundEditorLifecycleGenerator()
        let viewModel = soundEditorLifecycleViewModel(generator: generator)
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .sounds(.overview),
            availability: PreviewFixtures.settingsRouteAvailability,
            aiCueViewModel: viewModel)
        let probe = SettingsRootNativeProbe(session: fixture.session)
        defer {
            viewModel.endSession()
            probe.close()
        }
        guard await soundEditorLifecycleOpenLocalEvent(probe, fixture: fixture) else { return }
        viewModel.begin(packID: "settings-fixture-pack", event: .stop)
        viewModel.updateDescription("短促木琴完成音效")
        viewModel.startGeneration(locale: "zh-Hans")
        _ = await soundEditorLifecycleWait { await generator.isSuspended }
        let generation = soundEditorLifecycleGeneration(root: fixture.temporaryRoot)
        await generator.release(with: generation)
        let ready = await soundEditorLifecycleWait {
            soundEditorLifecyclePermit(fixture.soundPacksEditor) != nil
        }
        expect(ready && viewModel.phase == .candidatesReady, "正常生成必须发布候选及 owner 采用 permit")
        guard let permit = soundEditorLifecyclePermit(fixture.soundPacksEditor) else { return }

        await soundEditorLifecycleClickSoundsSidebar(probe)
        _ = await soundEditorLifecycleWait { viewModel.session == nil }
        expect(
            viewModel.session == nil && viewModel.generation == nil && viewModel.phase == .editing,
            "同 route 的显式退出必须使全部未采用候选失效")
        expect(
            soundEditorLifecyclePermit(fixture.soundPacksEditor) == nil,
            "owner 不得为已退出的候选继续签发 permit")
        _ = await soundEditorLifecycleWait {
            await generator.discardedGenerationIDs.contains(generation.id)
        }
        let discarded = await generator.discardedGenerationIDs
        expect(discarded == [generation.id], "退出必须清理已发布的 generation")
        let result = await fixture.soundPacksEditor.perform(
            .adoptAICue(
                candidate: generation.candidates[0],
                displayName: try! AICueDisplayName("木琴完成"), permit: permit))
        expect(result == .rejected(.stalePermit), "退出前捕获的 permit 必须在写入前拒绝")
    }

    await suite("声音事件详情：点击当前声音侧栏丢弃未发布空草稿") {
        let generator = SoundEditorLifecycleGenerator()
        let viewModel = soundEditorLifecycleViewModel(generator: generator)
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .sounds(.overview),
            availability: PreviewFixtures.settingsRouteAvailability,
            aiCueViewModel: viewModel)
        let probe = SettingsRootNativeProbe(session: fixture.session)
        defer { probe.close() }
        guard case .sounds(let initial) = fixture.soundPacksEditor.presentation.mode else {
            expect(false, "草稿入口必须处于声音概览")
            return
        }
        expect(
            fixture.soundPacksEditor.beginAICuePackDraft(language: .zhHans),
            "必须通过正常 owner 方法创建未发布空草稿")
        guard case .sounds(let created) = fixture.soundPacksEditor.presentation.mode,
            let draft = created.draft
        else {
            expect(false, "创建成功必须投影草稿身份")
            return
        }
        let mounted = await soundEditorLifecycleWait {
            SoundPacksLayoutRecorder.frames["sound-packs.event-detail"] != nil
        }
        expect(mounted, "草稿创建必须通过真实 onChange 进入本地事件详情")
        await soundEditorLifecycleClickSoundsSidebar(probe)
        if case .sounds(let exited) = fixture.soundPacksEditor.presentation.mode {
            expect(exited.draft == nil, "退出本地详情必须取消空草稿")
            expect(
                exited.packs.map(\.id) == initial.packs.map(\.id),
                "取消空草稿不得向已安装声音包列表发布新包")
        } else {
            expect(false, "点击声音侧栏必须保留声音概览")
        }
        let packDirectory = fixture.temporaryRoot.appendingPathComponent("packs")
            .appendingPathComponent(draft.packID)
        expect(
            !FileManager.default.fileExists(atPath: packDirectory.path),
            "未采用声音的空草稿不得发布磁盘包目录")
    }

    await suite("声音事件详情：初始深链挂载保留正常开始的同目标生成") {
        let generator = SoundEditorLifecycleGenerator()
        let viewModel = soundEditorLifecycleViewModel(generator: generator)
        viewModel.begin(packID: "settings-fixture-pack", event: .stop)
        viewModel.updateDescription("短促木琴完成音效")
        viewModel.startGeneration(locale: "zh-Hans")
        _ = await soundEditorLifecycleWait { await generator.isSuspended }
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .sounds(.editEvent(packID: "settings-fixture-pack", event: .stop)),
            availability: PreviewFixtures.settingsRouteAvailability,
            aiCueViewModel: viewModel)
        let probe = SettingsRootNativeProbe(session: fixture.session)
        await Task.yield()
        expect(
            viewModel.session == AICueComposerSession(packID: "settings-fixture-pack", event: .stop)
                && viewModel.phase == .generating,
            "首次路由投影必须保留同目标 session 与 generation task")
        let cancellations = await generator.cancellationCount
        expect(cancellations == 0, "首次深链挂载不得误取消原始请求")
        viewModel.endSession()
        await generator.release(with: soundEditorLifecycleGeneration(root: fixture.temporaryRoot))
        probe.close()
    }
    #endif
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

private func soundEditorLifecycleGeneration(root: URL) -> AICueGeneration {
    let id = UUID()
    let plan = AICueSoundPlan(
        suggestedDisplayName: "木琴完成", modality: .soundEffect,
        soundDescription: "短促木琴完成音效", spokenContent: nil, languageTag: nil,
        styleDescription: "短促、清晰", targetDurationMilliseconds: 1_500,
        instructionVersion: AICueSoundPlanner.instructionVersion)
    let candidates = AICueVariant.allCases.map { variant in
        AICueCandidate(
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
        generatedAt: Date(timeIntervalSince1970: 1))
}
