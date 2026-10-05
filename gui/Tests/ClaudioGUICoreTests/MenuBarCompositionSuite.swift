import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

actor CompositionVault: AICueCredentialVault {
    private var accesses = 0
    func containsCredential(in slotID: AICueCredentialSlotID) -> Bool {
        accesses += 1; return false
    }
    func credential(in slotID: AICueCredentialSlotID) -> SensitiveCredentialInput? {
        accesses += 1; return nil
    }
    func replaceCredential(_ credential: SensitiveCredentialInput, in slotID: AICueCredentialSlotID)
    {
        accesses += 1
    }
    func deleteCredential(in slotID: AICueCredentialSlotID) { accesses += 1 }
    func count() -> Int { accesses }
}

actor CompositionProvider: AICueCandidateSetProvider {
    nonisolated let profile: AICueProviderProfile
    private var accesses = 0
    init(profile: AICueProviderProfile) { self.profile = profile }
    func validateCredential(_ credential: SensitiveCredentialInput) { accesses += 1 }
    func generateCandidateSet(
        plan: AICueSoundPlan, credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) throws -> [AICueProviderCandidateResponse] {
        accesses += 1
        throw AICueTransportError.transportFailure
    }
    func count() -> Int { accesses }
}

actor CompositionMetadata: AICueCredentialMetadataStoring {
    func verification(for profileID: AICueProviderProfileID) -> AICueCredentialVerification? { nil }
    func setVerification(
        _ verification: AICueCredentialVerification?, for profileID: AICueProviderProfileID
    ) {}
}

actor CompositionHosts {
    private var refreshes = 0
    private var bootstraps = 0
    private var actions: [HostIntegrationUserAction] = []
    let replacement: HostIntegrationPresentationState
    init(replacement: HostIntegrationPresentationState) { self.replacement = replacement }
    func refresh() -> HostIntegrationPresentationState { refreshes += 1; return replacement }
    func bootstrap() -> HostIntegrationPresentationState { bootstraps += 1; return replacement }
    func perform(_ action: HostIntegrationUserAction) -> HostIntegrationMutationOutcome {
        actions.append(action)
        return HostIntegrationMutationOutcome(
            state: replacement, feedbackKind: .information, feedbackMessage: "fixture outcome")
    }
    func counts() -> (Int, Int, [HostIntegrationUserAction]) { (refreshes, bootstraps, actions) }
}

@MainActor
final class CompositionFixture {
    let root: URL
    let defaultsName = "MenuBarCompositionSuite.\(UUID().uuidString)"
    let defaults: UserDefaults
    private let ownsNamedDefaults: Bool
    let vault = CompositionVault()
    let registry = AICueProviderRegistry(evidenceGatedSenseAudioAssetPolicy: nil)
    let providers: [CompositionProvider]
    let initial = PreviewFixtures.hostIntegrationScenarios.first!.state
    let hosts: CompositionHosts
    var registrations: [GlobalShortcut] = []
    var delivered: [GlobalShortcutAction] = []
    var hotKeyHandler: (@MainActor (GlobalShortcutAction) -> Void)?
    var copied: [String] = []
    var audibilityChanges = 0
    var publishes = 0
    var routerBound = false
    var viewModelFactories = 0
    var activityFactories = 0
    var aboutFactories = 0
    var modelRoot: URL?
    var factoryModel: AICueGenerationViewModel?
    var aboutFacts: [AboutSurfaceFact] = []
    var composition: PanelAppComposition!

    init(root: URL, defaults injectedDefaults: UserDefaults? = nil) {
        self.root = root
        ownsNamedDefaults = injectedDefaults == nil
        defaults = injectedDefaults ?? UserDefaults(suiteName: defaultsName)!
        if injectedDefaults == nil { defaults.removePersistentDomain(forName: defaultsName) }
        providers = registry.profiles().map { CompositionProvider(profile: $0) }
        hosts = CompositionHosts(replacement: PreviewFixtures.hostIntegrationScenarios.last!.state)
    }

    func cleanup() {
        if ownsNamedDefaults { defaults.removePersistentDomain(forName: defaultsName) }
    }

    func build(
        throwModelError: Bool = false,
        integrationRefreshFeedback: IntegrationsFeedbackText = .localized(
            key: .feedbackRedetectedSources, arguments: [])
    ) throws -> PanelAppComposition {
        let environment = makeAudioImportEnvironment(
            userPacksDirectory: root.appendingPathComponent("packs"))
        let hostProvider = hosts
        let preferences = ClaudioPreferences(
            defaults: defaults, notificationCenter: NotificationCenter(),
            preferredLanguageIdentifiers: { ["en"] })
        let result = try PanelAppComposition(
            environment: PanelAppComposition.Environment(
                configFile: root.appendingPathComponent("config.json"),
                configLockFile: root.appendingPathComponent("config.lock"),
                audioEnvironment: environment, preferences: preferences,
                soundScopeDefaults: defaults,
                aiCueTemporaryRoot: root.appendingPathComponent("ai-temporary"),
                hostIntegrationState: initial,
                configurationSources: [
                    .claudeCode: root.appendingPathComponent("settings.json").path
                ],
                integrationMatrixProvider: HostIntegrationMatrixProvider(
                    refresh: { await hostProvider.refresh() },
                    bootstrap: { await hostProvider.bootstrap() }),
                integrationActionProvider: HostIntegrationActionProvider {
                    await hostProvider.perform($0)
                },
                integrationRefreshFeedback: integrationRefreshFeedback),
            adapters: PanelAppComposition.Adapters(
                globalHotKeys: GlobalHotKeyAdapter(
                    register: { [weak self] in self?.registrations.append($0) },
                    unregister: { _ in },
                    setActionHandler: { [weak self] in self?.hotKeyHandler = $0 }),
                shortcutPersistence: .userDefaults(defaults),
                clipboardWriter: IntegrationDestinationClipboardWriter { [weak self] in
                    self?.copied.append($0); return true
                },
                makeAICueViewModel: { [unowned self] temporaryRoot, durationProbe in
                    viewModelFactories += 1
                    modelRoot = temporaryRoot
                    if throwModelError { throw AICueRuntimeError.invalidProviderBindings }
                    let runtime = try AICueRuntime(
                        registry: registry, vault: vault, temporaryRoot: temporaryRoot,
                        durationProbe: durationProbe, providerBindings: providers,
                        credentialMetadata: CompositionMetadata(), providerDefaults: defaults)
                    let model = AICueGenerationViewModel(
                        credentialManager: runtime.credentialManager, generator: runtime.dispatcher,
                        registry: runtime.registry, providerPreferences: runtime.providerPreferences
                    )
                    factoryModel = model
                    return model
                },
                makeActivityDiagnostics: { [unowned self] in
                    activityFactories += 1
                    return ActivityDiagnosticsModel(previewPresentation: .empty())
                },
                makeAboutSettings: { [unowned self] facts in
                    aboutFactories += 1; aboutFacts = facts
                    return AboutSettingsModel(
                        bundleFacts: projectAboutBundleFacts(
                            AboutBundleFactsInput(
                                brandName: nil, productName: nil, version: nil, build: nil,
                                architecture: nil, minimumSystemVersion: nil,
                                operatingSystemVersion: nil)),
                        resources: [], pathFacts: [], surfaceFacts: facts,
                        actions: AboutSettingsActions(copy: { _ in true }, open: { _ in false }))
                }),
            actions: PanelAppComposition.Actions(
                audibilityInputsChanged: { [weak self] in self?.audibilityChanges += 1 },
                performGlobalShortcut: { [weak self] in self?.delivered.append($0) },
                publishHostIntegrationState: { [weak self] state in
                    guard let self, routerBound else { return nil }
                    publishes += 1
                    return composition.hostIntegrations.replace(state: state)
                }))
        composition = result
        return result
    }
}

@MainActor
func runMenuBarCompositionSuites() async {
    await suite("Panel composition：隔离构造、类型化工厂与外部副作用边界") {
        await withTempDirectory { root in
            let fixture = CompositionFixture(root: root)
            defer { fixture.cleanup() }
            let composition = try! fixture.build()
            let counts = await fixture.hosts.counts()
            expect(
                counts.0 == 0 && counts.1 == 0 && counts.2.isEmpty,
                "构造不得 bootstrap、检测或自动连接宿主")
            expect(await fixture.vault.count() == 0, "构造不得读取或查询凭据")
            for provider in fixture.providers {
                expect(await provider.count() == 0, "构造不得 probe 或发生成请求")
            }
            expect(
                fixture.viewModelFactories == 1 && fixture.activityFactories == 1
                    && fixture.aboutFactories == 1,
                "每个注入工厂恰好构造一次")
            expect(
                fixture.modelRoot == root.appendingPathComponent("ai-temporary"),
                "AI 根必须来自 environment")
            expect(!FileManager.default.fileExists(atPath: fixture.modelRoot!.path), "构造不创建候选目录")
            expect(
                composition.aiCueViewModel === fixture.factoryModel,
                "组合根必须保留工厂返回的模型，不能重新构造第二份")
            expect(
                fixture.aboutFacts == composition.hostIntegrations.safeSurfaceFacts,
                "About 工厂消费同一 presentation store 的安全事实")
            expect(
                composition.preferences.language == .english
                    && composition.aiCueViewModel.availableProviderProfiles
                        == fixture.registry.profiles(),
                "偏好与 AI view model 使用注入的 owner")
        }
    }

    await suite("Panel composition：未绑定 router 时 refresh/action 仍发布到同一个 store") {
        await withTempDirectory { root in
            let fixture = CompositionFixture(root: root)
            defer { fixture.cleanup() }
            let composition = try! fixture.build()
            await composition.integrationsModel.perform(.redetect)
            let replacement = fixture.hosts.replacement
            expect(
                composition.hostIntegrations.content
                    == integrationDestinationContent(
                        state: replacement,
                        configurationSources: [
                            .claudeCode: root.appendingPathComponent("settings.json").path
                        ]),
                "未绑定 router 仍必须更新同一事实与配置来源")
            await composition.integrationsModel.perform(.connect(.claudeCode))
            expect(
                composition.integrationsModel.content == composition.hostIntegrations.content,
                "动作与面板保持同一 content")
            fixture.routerBound = true
            await composition.integrationsModel.perform(.redetect)
            await composition.integrationsModel.perform(.repair(.codex))
            expect(fixture.publishes == 2, "绑定后 refresh 与 action 均经 native 发布回调")
            expect(
                composition.integrationsModel.content == composition.hostIntegrations.content,
                "绑定后保持同一事实")
            expect(
                composition.integrationsModel.copyConfigurationSource(for: .claudeCode),
                "剪贴板必须由 adapter 执行")
            expect(
                fixture.copied == [root.appendingPathComponent("settings.json").path], "复制注入的配置来源")
            let counts = await fixture.hosts.counts()
            expect(
                counts.0 == 2 && counts.1 == 0
                    && counts.2 == [.connect(.claudeCode), .repair(.codex)],
                "refresh 与显式动作分别调用各自 provider，不调用 bootstrap")
        }
    }

    await suite("Panel composition：共享库刷新、作用域拒写、快捷键与可听性回调") {
        await withTempDirectory { root in
            let packs = root.appendingPathComponent("packs")
            writeFixture(
                #"{"id":"pack-a","name":"Before","events":{"stop":"stop.mp3"}}"#,
                to: packs.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("audio", to: packs.appendingPathComponent("pack-a/stop.mp3"))
            writeFixture(
                #"{"selected_pack":"pack-a"}"#, to: root.appendingPathComponent("config.json"))
            let fixture = CompositionFixture(root: root)
            defer { fixture.cleanup() }
            let composition = try! fixture.build()
            _ = composition.soundPacksEditorOwner.send(
                .activate(
                    .sounds(route: .editEvent(packID: "pack-a", event: .stop), requestRevision: 1)))
            _ = await composition.soundPackLibrary.refreshSnapshot(trigger: .initial)
            await composition.soundPacksEditorOwner.waitForMutationTransactionsToQuiesceForTesting()
            for _ in 0..<32 { await Task.yield() }
            expect(
                composition.eventSettingsModel.selectedPackMetadata.displayName == "Before",
                "面板消费共享库初次结果")
            writeFixture(
                #"{"id":"pack-a","name":"After","events":{"stop":"stop.mp3"}}"#,
                to: packs.appendingPathComponent("pack-a/manifest.json"))
            composition.soundPackLibrary.invalidate(packIDs: ["pack-a"])
            _ = await composition.soundPackLibrary.refreshSnapshot(trigger: .retry)
            await composition.soundPacksEditorOwner.waitForMutationTransactionsToQuiesceForTesting()
            for _ in 0..<32 { await Task.yield() }
            expect(
                composition.eventSettingsModel.selectedPackMetadata.displayName == "After",
                "面板消费同一刷新")
            if case .sounds(let sounds) = composition.soundPacksEditorOwner.presentation.mode {
                expect(
                    sounds.packs.first(where: { $0.id == "pack-a" })?.name == "After", "编辑器消费同一刷新")
            } else {
                expect(false, "编辑器保持 sounds context")
            }
            let unknown = UUID()
            composition.soundScopeSelection.select(.workspace(unknown))
            _ = composition.soundPacksEditorOwner.send(
                .activate(
                    .events(
                        route: EventSettingsWindowRoute(
                            scope: composition.soundScopeSelection.projection.scope),
                        requestRevision: 2))
            )
            if case .events(let events) = composition.soundPacksEditorOwner.presentation.mode,
                case .unavailable(let scope, _) = events.scope
            {
                expect(scope == .workspace(unknown), "编辑器借用同一作用域身份并呈现不可用")
                expect(
                    events.packs.allSatisfy { $0.useAction == nil } && events.adoptionPermit == nil,
                    "失效工作区不能向编辑器签发应用声音包或采纳写入能力")
            } else {
                expect(false, "编辑器不得回落可写默认组")
            }
            let before = try! Data(contentsOf: root.appendingPathComponent("config.json"))
            expect(
                composition.eventSettingsModel.selectedSoundScope == .workspace(unknown),
                "controller 订阅同一个选择 owner")
            expect(composition.eventSettingsModel.setMasterVolume(0.2) == nil, "失效工作区必须拒写")
            expect(
                try! Data(contentsOf: root.appendingPathComponent("config.json")) == before,
                "拒写不得回落默认组")
            composition.soundScopeSelection.select(.global)
            composition.eventSettingsModel.reloadConfigOnly()
            expect(fixture.audibilityChanges == 0, "轻量 config 刷新保持既有无回调合同")
            composition.eventSettingsModel.reload()
            expect(fixture.audibilityChanges == 1, "全量刷新调用注入的可听性回调")
            composition.globalShortcutSettings.replace(
                .togglePanel, keyCode: 40, modifiers: [.command, .option])
            fixture.hotKeyHandler?(.togglePanel)
            expect(
                fixture.registrations.count == 1 && fixture.delivered == [.togglePanel],
                "注册与触发使用注入 adapter/actions")
            expect(
                fixture.defaults.data(forKey: globalShortcutDefaultsKey(.togglePanel)) != nil,
                "快捷键持久化使用隔离 defaults")
        }
    }

    await suite("Panel composition：刷新反馈由环境注入，模型强持工厂依赖") {
        await withTempDirectory { root in
            let fixture = CompositionFixture(root: root)
            defer { fixture.cleanup() }
            let feedback: IntegrationsFeedbackText = .localized(
                key: .feedbackHostStateUpdated, arguments: [])
            let composition = try! fixture.build(integrationRefreshFeedback: feedback)
            await composition.integrationsModel.perform(.redetect)
            // 回执首次变化有独立反馈；无新回执的重新检测应使用注入文案。
            await composition.integrationsModel.perform(.redetect)
            expect(
                composition.integrationsModel.feedback?.text == feedback,
                "fixture 刷新必须保留自己的类型化状态更新文案")
            await composition.aiCueViewModel.refreshCredentialStatus()
            expect(await fixture.vault.count() > 0, "runtime 离开工厂后模型仍持有所需凭据依赖")
            expect(fixture.viewModelFactories == 1, "使用模型不得重新调用工厂")
        }
    }

    suite("Panel composition：模型工厂失败向调用方传播") {
        withTempDirectory { root in
            let fixture = CompositionFixture(root: root)
            defer { fixture.cleanup() }
            do { _ = try fixture.build(throwModelError: true); expect(false, "工厂失败必须抛出") } catch {
                expect(error as? AICueRuntimeError == .invalidProviderBindings, "保留类型化错误")
                expect(
                    fixture.viewModelFactories == 1 && fixture.activityFactories == 0
                        && fixture.aboutFactories == 0,
                    "工厂错误传播时不得继续构造后续 owner")
            }
        }
    }
}
