#if DEBUG
import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioPanelPresentation
import ClaudioSettingsPresentation
import ClaudioLocalization
import SoundPacksWindow
import SwiftUI

/// DEBUG gallery of the production panel, retained Settings, sound editor and banners.
/// All frames consume the shared PreviewFixtures catalog and isolated preview dependencies.
struct StateGalleryView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ProductionPanelGalleryView()
                EventNoticeGalleryView()
                SettingsWindowRouteGalleryView()
                SettingsExperienceGalleryView()
                EventSettingsLayoutGalleryView()
                ComplexAccessibilityEnvironmentGalleryView()
                AICueExperienceGalleryView()
                PanelPackSectionGalleryView()
                PanelQuitFooterGalleryView()
                MasterVolumeGalleryView()
                PackCardGalleryView()
                ForEach(ClaudioAppLanguage.allCases) { language in
                    ForEach([ClaudioCompactPreviewDensity.standard]) { textSize in
                        ForEach(SettingsGalleryAppearance.allCases) { appearance in
                            GallerySection(
                                title:
                                    "Sounds destination · \(language.selfName) · compact · \(appearance.rawValue) (12 production states × 2 widths)"
                            ) {
                                if textSize == .standard && appearance == .light {
                                    SoundPacksWindowStateGalleryView(language: language)
                                        .environment(\.colorScheme, appearance.colorScheme)
                                } else {
                                    SoundPacksWindowStateGalleryView(
                                        language: language,
                                        textSize: textSize
                                    )
                                    .environment(\.colorScheme, appearance.colorScheme)
                                }
                            }
                        }
                    }
                }
                HostIntegrationGalleryView()
            }
            .padding(20)
        }
        // The gallery's own chrome sits on a TOKENIZED surface too, never SwiftUI's
        // untokenized default window background — see ``GalleryFrame``'s note for why that
        // background was a correctness bug in a file DESIGN.md calls the 视觉真相源.
        .background(ClaudioColor.panel(colorScheme))
    }
}

// MARK: - Unified Settings route skeleton (DEBUG only)

struct SettingsWindowRouteGalleryView: View {
    var body: some View {
        GallerySection(title: "Unified Settings · 9 typed route slots") {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach(PreviewFixtures.settingsRouteScenarios) { scenario in
                    GalleryFrame(
                        caption: "\(language.selfName) · \(scenario.destination.rawValue)"
                    ) {
                        SettingsWindowRouteFrame(
                            route: scenario.route,
                            availability: PreviewFixtures.settingsRouteAvailability,
                            language: language)
                    }
                }
            }
        }
        GallerySection(title: "Unified Settings · 6 visible route failures") {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach(PreviewFixtures.settingsRouteFailureScenarios) { scenario in
                    GalleryFrame(caption: "\(language.selfName) · \(scenario.id)") {
                        SettingsWindowRouteFrame(
                            route: scenario.route,
                            availability: scenario.availability,
                            language: language)
                    }
                }
            }
        }
    }
}

struct SettingsExperienceGalleryView: View {
    var body: some View {
        GallerySection(
            title:
                "Unified Settings · 6 basic production destinations · 2 languages × compact density"
        ) {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach([ClaudioCompactPreviewDensity.standard]) { textSize in
                    ForEach(PreviewFixtures.settingsExperienceScenarios) { scenario in
                        GalleryFrame(
                            caption:
                                "\(language.selfName) · \(textSize.rawValue) · \(scenario.rawValue)"
                        ) {
                            SettingsWindowRouteFrame(
                                route: .destination(scenario.destination),
                                availability: PreviewFixtures.settingsRouteAvailability,
                                language: language,
                                textSize: textSize,
                                experienceScenario: scenario)
                        }
                    }
                }
            }
        }
    }
}

private enum EventSettingsGalleryWidth: String, CaseIterable, Identifiable {
    case minimum
    case standard

    var id: String { rawValue }
    var value: CGFloat {
        self == .minimum
            ? SettingsWindowGeometry.minimumWidth : SettingsWindowGeometry.defaultWidth
    }
}

private enum SettingsGalleryAppearance: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

struct EventSettingsLayoutGalleryView: View {
    var body: some View {
        GallerySection(
            title:
                "Events destination · production mount · 2 languages × compact density × 2 widths"
        ) {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach([ClaudioCompactPreviewDensity.standard]) { textSize in
                    ForEach(SettingsGalleryAppearance.allCases) { appearance in
                        ForEach(EventSettingsGalleryWidth.allCases) { width in
                            GalleryFrame(
                                caption:
                                    "\(language.selfName) · \(textSize.rawValue) · \(appearance.rawValue) · \(width.rawValue)"
                            ) {
                                SettingsWindowRouteFrame(
                                    route: .events(scope: .surface(.workBuddy), event: .stop),
                                    availability: PreviewFixtures.settingsRouteAvailability,
                                    language: language,
                                    textSize: textSize,
                                    width: width.value
                                )
                                .environment(\.colorScheme, appearance.colorScheme)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ComplexAccessibilityEnvironmentGalleryView: View {
    var body: some View {
        GallerySection(
            title: "Complex Settings · accessibility environment variants"
        ) {
            GalleryFrame(caption: "Increase Contrast") {
                AccessibilityHighContrastGalleryMount(
                    content: SettingsWindowRouteFrame(
                        route: .events(scope: .surface(.workBuddy), event: .stop),
                        availability: PreviewFixtures.settingsRouteAvailability,
                        language: .english,
                        textSize: .standard,
                        width: EventSettingsGalleryWidth.minimum.value
                    ))
            }
            GalleryFrame(caption: "Reduce Transparency") {
                SettingsWindowRouteFrame(
                    route: .events(scope: .surface(.workBuddy), event: .stop),
                    availability: PreviewFixtures.settingsRouteAvailability,
                    language: .zhHans,
                    textSize: .standard,
                    width: EventSettingsGalleryWidth.minimum.value
                )
                .environment(\.settingsReduceTransparencyOverride, true)
            }
            GalleryFrame(caption: "Reduce Motion") {
                SettingsWindowRouteFrame(
                    route: .events(scope: .surface(.workBuddy), event: .stop),
                    availability: PreviewFixtures.settingsRouteAvailability,
                    language: .english,
                    textSize: .standard,
                    width: EventSettingsGalleryWidth.minimum.value
                )
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
        }
    }
}

/// AppKit owns the macOS increased-contrast appearance fact. Hosting the unchanged production
/// subtree under that system appearance exercises SwiftUI's real `colorSchemeContrast` projection
/// without adding gallery-only branches to production views.
private struct AccessibilityHighContrastGalleryMount<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: content)
        hostingView.appearance = NSAppearance(named: .accessibilityHighContrastAqua)
        return hostingView
    }

    func updateNSView(_ hostingView: NSHostingView<Content>, context: Context) {
        hostingView.rootView = content
        hostingView.appearance = NSAppearance(named: .accessibilityHighContrastAqua)
    }
}

struct AICueExperienceGalleryView: View {
    var body: some View {
        GallerySection(
            title:
                "Events AI Cue · 5 profiles · isolated credential/composer/failure states · 2 languages × compact density"
        ) {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach([ClaudioCompactPreviewDensity.standard]) { textSize in
                    ForEach(SettingsGalleryAppearance.allCases) { appearance in
                        ForEach(PreviewFixtures.aiCueGalleryScenarios) { scenario in
                            GalleryFrame(
                                caption:
                                    "\(language.selfName) · \(textSize.rawValue) · \(appearance.rawValue) · \(scenario.rawValue)"
                            ) {
                                SettingsWindowRouteFrame(
                                    route: .events(scope: .global, event: .stop),
                                    availability: PreviewFixtures.settingsRouteAvailability,
                                    language: language,
                                    textSize: textSize,
                                    aiCueScenario: scenario
                                )
                                .environment(\.colorScheme, appearance.colorScheme)
                            }
                        }
                    }
                }
            }
        }
    }
}

@MainActor
private struct SettingsWindowRouteFrame: View {
    let route: SettingsRoute
    let availability: SettingsRouteAvailability
    let language: ClaudioAppLanguage
    let textSize: ClaudioCompactPreviewDensity
    let experienceProfile: PreviewFixtures.SettingsExperienceProfile?
    let width: CGFloat
    let aiCueScenario: PreviewFixtures.AICueGalleryScenario?
    let integrationScenario: PreviewFixtures.HostIntegrationScenario?
    let integrationInFlightAction: HostIntegrationUserAction?

    init(
        route: SettingsRoute,
        availability: SettingsRouteAvailability,
        language: ClaudioAppLanguage,
        textSize: ClaudioCompactPreviewDensity = .standard,
        experienceScenario: PreviewFixtures.SettingsExperienceScenario? = nil,
        width: CGFloat = SettingsWindowGeometry.minimumWidth,
        aiCueScenario: PreviewFixtures.AICueGalleryScenario? = nil,
        integrationScenario: PreviewFixtures.HostIntegrationScenario? = nil,
        integrationInFlightAction: HostIntegrationUserAction? = nil
    ) {
        self.route = route
        self.availability = availability
        self.language = language
        self.textSize = textSize
        experienceProfile = experienceScenario?.profile
        self.width = width
        self.aiCueScenario = aiCueScenario
        self.integrationScenario = integrationScenario
        self.integrationInFlightAction = integrationInFlightAction
    }

    var body: some View {
        SettingsStateGalleryView(
            route: route,
            availability: availability,
            language: language,
            textSize: textSize,
            experienceProfile: experienceProfile,
            aiCueScenario: aiCueScenario,
            integrationScenario: integrationScenario,
            integrationInFlightAction: integrationInFlightAction
        )
        .frame(
            width: width,
            height: SettingsWindowGeometry.minimumHeight)
    }

}

// MARK: - Production Agent panel (2 languages × compact density × critical states)

private enum ProductionPanelGalleryScenario: String, CaseIterable, Identifiable {
    case workBuddy = "WorkBuddy operational"
    case workBuddyAwaitingExpanded = "WorkBuddy awaiting · scope expanded"
    case needsPack = "needsPack recovery"
    case configFailure = "config failure"
    case libraryFailure = "sound library failure"
    case libraryRefreshFailed = "sound library refresh failed · stale events"
    case surfaceFailure = "WorkBuddy surface override failure"

    var id: String { rawValue }
}

struct ProductionPanelGalleryView: View {
    var body: some View {
        GallerySection(
            title: "Production Agent Panel · 2 languages × compact density × 7 critical states"
        ) {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach([ClaudioCompactPreviewDensity.standard]) { textSize in
                    ForEach(ProductionPanelGalleryScenario.allCases) { scenario in
                        GalleryFrame(
                            caption:
                                "\(language.selfName) · \(textSize.rawValue) · \(scenario.rawValue)"
                        ) {
                            ProductionPanelStateFrame(
                                language: language,
                                textSize: textSize,
                                scenario: scenario)
                        }
                    }
                }
            }
        }
    }
}

private enum EventNoticeGalleryScenario: String, CaseIterable, Identifiable {
    case single = "single"
    case burst = "three-event burst"
    case reread = "replay from recent"
    case unknown = "unknown source"

    var id: String { rawValue }
}

/// DEBUG-only interaction gallery for the C-direction surface. The buttons intentionally drive
/// the same public model inputs as the receiver, so one/three/replay and light/dark checks do not
/// grow a second preview-only presentation state machine.
struct EventNoticeGalleryView: View {
    var body: some View {
        GallerySection(
            title: "Event Source Notice C · 2 languages × 2 themes × 4 interaction states"
        ) {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach(SettingsGalleryAppearance.allCases) { appearance in
                    ForEach(EventNoticeGalleryScenario.allCases) { scenario in
                        GalleryFrame(
                            caption:
                                "\(language.selfName) · \(appearance.rawValue) · \(scenario.rawValue)"
                        ) {
                            EventNoticeGalleryFrame(
                                language: language,
                                scenario: scenario
                            )
                            .environment(\.colorScheme, appearance.colorScheme)
                        }
                    }
                }
            }
        }
    }
}

@MainActor
private struct EventNoticeGalleryFrame: View {
    let language: ClaudioAppLanguage
    let scenario: EventNoticeGalleryScenario

    /// Shared mutable flag so the DEBUG "Route OK / Route Fail" buttons decide what the next
    /// simulated navigation returns. Simulation never leaves this gallery (SPEC S8).
    private final class RouteSimulationBox {
        var succeeds = true
    }

    @StateObject private var model: EventNoticeModel
    @StateObject private var languageStore: ClaudioPreferences
    @StateObject private var navigationCoordinator: SessionNavigationCoordinator
    private let routeSimulation: RouteSimulationBox

    init(language: ClaudioAppLanguage, scenario: EventNoticeGalleryScenario) {
        self.language = language
        self.scenario = scenario
        let routeSimulation = RouteSimulationBox()
        self.routeSimulation = routeSimulation
        let model = EventNoticeModel(receiverEpoch: UUID())
        _model = StateObject(wrappedValue: model)
        _languageStore = StateObject(wrappedValue: ClaudioPreferences(previewLanguage: language))
        _navigationCoordinator = StateObject(
            wrappedValue: SessionNavigationCoordinator(model: model) { _, complete in
                EventNoticeScheduler.live.schedule(after: 0.15) {
                    complete(routeSimulation.succeeds ? .exactReturnConfirmed : .failed)
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EventNoticeView(
                model: model,
                languageStore: languageStore,
                onViewSource: { _ = model.viewSource($0) },
                onCopySessionID: { navigationCoordinator.copy($0) { _ in true } },
                onClose: { model.dismiss() }
            )
            .frame(width: 440, height: EventNoticeView.preferredHeight(for: model.snapshot))

            HStack(spacing: 6) {
                Button("One") { emit(count: 1) }
                Button("Three") { emit(count: 3) }
                Button("Replay") { model.openAttentionReminders() }
                Button("Clear") { model.clearForPrivacy() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            HStack(spacing: 6) {
                Button("Route OK") { simulateRoute(succeeds: true) }
                Button("Route Fail") { simulateRoute(succeeds: false) }
                Text("Route: \(String(describing: navigationCoordinator.result))")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("Synthetic · model-driven DEBUG controls · no real host navigation")
                .font(.system(size: 9, design: .rounded))
                .foregroundColor(.secondary)
        }
        .padding(8)
        .onAppear(perform: seed)
    }

    /// S8 route simulation: builds a verified target from the current notice's own safe source
    /// fields, so success/failure is exercised without promising any real host navigation.
    private func simulateRoute(succeeds: Bool) {
        routeSimulation.succeeds = succeeds
        guard
            let record = model.snapshot.current, let action = record.action,
            let notice = record.notice,
            let source = notice.source,
            let sessionID = source.sessionID
        else {
            navigationCoordinator.reset()
            return
        }
        let target = SessionNavigationTarget(
            surface: notice.surface,
            projectKey: source.projectKey,
            sessionID: sessionID)
        navigationCoordinator.openSession(
            sessionNavigationCapability(for: notice, verifiedTarget: target),
            action: action, generation: navigationCoordinator.capabilityGeneration)
    }

    private func seed() {
        guard model.snapshot.attentionReminders.isEmpty else { return }
        switch scenario {
        case .single:
            emit(count: 1)
        case .burst:
            emit(count: 3)
        case .reread:
            emit(count: 1)
            model.hideImmediately()
        case .unknown:
            emit(count: 1, unknownSource: true)
        }
    }

    private func emit(count: Int, unknownSource: Bool = false) {
        let bindings = HostCapabilityCatalog.bindings(for: .claudeCode)
        for index in 0..<count {
            let binding = bindings[index % bindings.count]
            guard let nativeEvent = binding.nativeEvent else { continue }
            _ = model.accept(
                makeEventNoticeGalleryNotice(
                    epoch: model.receiverEpoch,
                    binding: binding,
                    nativeEvent: nativeEvent,
                    language: language,
                    unknownSource: unknownSource))
        }
    }
}

private func makeEventNoticeGalleryNotice(
    epoch: UUID,
    binding: HostCapabilityBinding,
    nativeEvent: String,
    language: ClaudioAppLanguage,
    unknownSource: Bool
) -> HostEventNotice {
    HostEventNotice(
        receiverEpoch: epoch,
        surface: .claudeCode,
        bindingID: binding.id,
        installationID: UUID(),
        nativeEvent: nativeEvent,
        event: binding.event,
        occurredAt: Date(),
        source: unknownSource
            ? nil
            : HostEventSource(
                projectLabel: language == .english ? "Orbit Signals" : "Orbit 示例项目",
                projectKey: "debug-gallery-project",
                sessionID: "12345678-debug-gallery", mainSessionIsKnown: true),
        reason: binding.qualification == .questionIntentOnly ? .questionIntent : nil)
}

@MainActor
private struct ProductionPanelStateFrame: View {
    let language: ClaudioAppLanguage
    let textSize: ClaudioCompactPreviewDensity
    let scenario: ProductionPanelGalleryScenario

    @StateObject private var focusCoordinator: PanelFocusCoordinator
    @StateObject private var hostIntegrations: HostIntegrationPresentationStore
    @StateObject private var languageStore: ClaudioPreferences
    @StateObject private var eventNoticeModel: EventNoticeModel
    private let panelModel: PanelConfigController
    private let soundScopeExpanded: Bool

    init(
        language: ClaudioAppLanguage,
        textSize: ClaudioCompactPreviewDensity,
        scenario: ProductionPanelGalleryScenario
    ) {
        self.language = language
        self.textSize = textSize
        self.scenario = scenario

        let hostPhase: PreviewFixtures.WorkBuddyVisualPhase =
            scenario == .workBuddyAwaitingExpanded
            ? .awaitingActivation : .allImplementedBindingsCurrent
        let hostState = PreviewFixtures.workBuddyVisualScenarios.first {
            $0.phase == hostPhase
        }!.state
        soundScopeExpanded = scenario == .workBuddyAwaitingExpanded
        _focusCoordinator = StateObject(wrappedValue: PanelFocusCoordinator())
        _hostIntegrations = StateObject(
            wrappedValue: HostIntegrationPresentationStore(
                state: hostState,
                configurationSources: [:]))
        let languageStore = ClaudioPreferences(previewLanguage: language)
        languageStore.setCompactPreviewDensity(textSize)
        _languageStore = StateObject(wrappedValue: languageStore)
        _eventNoticeModel = StateObject(
            wrappedValue: EventNoticeModel(receiverEpoch: UUID()))

        let baseConfig = ClaudioConfig(
            selectedPack: "gallery-pack",
            masterVolume: 0.8,
            eventsEnabled: Dictionary(
                uniqueKeysWithValues: Event.allCases.map { ($0.cliName, true) }))
        let presentRows = Event.allCases.map {
            EventRow(
                event: $0,
                coverage: .present(fileName: "\($0.cliName).aiff"),
                enabled: true)
        }

        switch scenario {
        case .workBuddy, .workBuddyAwaitingExpanded:
            panelModel = PanelConfigController(
                previewConfigState: .operational(baseConfig),
                selectedSurface: .workBuddy,
                eventRows: presentRows,
                selectedPackMetadata: SelectedPackMetadata(
                    id: "gallery-pack",
                    name: "Orbit Signals"),
                environment: previewAudioImportEnvironment)
        case .needsPack:
            panelModel = PanelConfigController(
                previewConfigState: .needsPack,
                libraryPresentationState: .ready,
                environment: previewAudioImportEnvironment)
        case .configFailure:
            panelModel = PanelConfigController(
                previewConfigState: .malformed(
                    reason: language == .english
                        ? "config.json contains an invalid master_volume value."
                        : "config.json 的 master_volume 值无效。"),
                libraryPresentationState: .ready,
                environment: previewAudioImportEnvironment)
        case .libraryFailure:
            panelModel = PanelConfigController(
                previewConfigState: .operational(baseConfig),
                selectedPackMetadata: SelectedPackMetadata(
                    id: "gallery-pack",
                    name: "Orbit Signals"),
                libraryPresentationState: .loadFailed(
                    reason: language == .english
                        ? "The sound pack library could not be read."
                        : "无法读取声音包库。"),
                environment: previewAudioImportEnvironment)
        case .libraryRefreshFailed:
            panelModel = PanelConfigController(
                previewConfigState: .operational(baseConfig),
                eventRows: presentRows,
                selectedPackMetadata: SelectedPackMetadata(
                    id: "gallery-pack",
                    name: "Orbit Signals"),
                libraryPresentationState: .refreshFailed(
                    reason: "Gallery scan failure; this technical detail must stay hidden."),
                environment: previewAudioImportEnvironment)
        case .surfaceFailure:
            var invalidBase = baseConfig
            invalidBase.invalidSurfaceOverrideKeys = [HostSurfaceID.workBuddy.rawValue]
            let failedEffective = ClaudioConfig(
                selectedPack: "",
                masterVolume: baseConfig.masterVolume,
                eventsEnabled: Dictionary(
                    uniqueKeysWithValues: Event.allCases.map { ($0.cliName, false) }))
            panelModel = PanelConfigController(
                previewConfigState: .operational(invalidBase),
                effectiveConfig: failedEffective,
                selectedSurface: .workBuddy,
                surfaceSoundIssue: language == .english
                    ? "The WorkBuddy sound override is damaged; playback stopped without falling back to Global."
                    : "WorkBuddy 的声音覆盖已损坏；已停止播放，且未回退到 Global。",
                eventRows: Event.allCases.map {
                    EventRow(event: $0, coverage: .unmapped, enabled: false)
                },
                libraryPresentationState: .ready,
                environment: previewAudioImportEnvironment)
        }
    }

    var body: some View {
        PanelView(
            previewPanelModel: panelModel,
            previewSoundScopeExpanded: soundScopeExpanded,
            audioEnvironment: previewAudioImportEnvironment,
            focusCoordinator: focusCoordinator,
            hostIntegrations: hostIntegrations,
            languageStore: languageStore,
            eventNoticeModel: eventNoticeModel
        )
        .frame(height: 560)
    }
}

struct PanelPackSectionGalleryView: View {
    var body: some View {
        GallerySection(
            title: "PanelPackSectionState (\(PreviewFixtures.panelPackSectionStates.count))"
        ) {
            ForEach(
                Array(PreviewFixtures.panelPackSectionStates.enumerated()),
                id: \.offset
            ) { _, state in
                GalleryFrame(caption: panelPackSectionCaption(state)) {
                    PanelPackSectionStateFrame(state: state)
                }
            }
        }
    }
}

private struct PanelPackSectionStateFrame: View {
    let state: PanelPackSectionState
    @FocusState private var focusedTarget: PanelFocusTarget?

    var body: some View {
        PanelPackSectionView(
            state: state,
            typeScale: 1,
            focusedTarget: $focusedTarget,
            adaptation: panelLayoutAdaptation(),
            onSelect: { _ in }
        )
        .frame(width: CGFloat(standardPanelWidth))
    }
}

private func panelPackSectionCaption(_ state: PanelPackSectionState) -> String {
    switch state {
    case .loading: ".loading"
    case .pinned(let cards): ".pinned(\(cards.count))"
    case .noPinnedPacks(let count): ".noPinnedPacks(available: \(count))"
    case .noPacks: ".noPacks"
    case .readFailed: ".readFailed"
    }
}

// MARK: - Fixed panel quit footer (2 languages × compact density)

struct PanelQuitFooterGalleryView: View {
    var body: some View {
        GallerySection(title: "Panel quit footer (2 languages × compact density · 312pt)") {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach([ClaudioCompactPreviewDensity.standard]) { density in
                    GalleryFrame(
                        caption: "\(language.selfName) · \(density.rawValue)"
                    ) {
                        PanelQuitFooterStateFrame(
                            language: language,
                            density: density)
                    }
                }
            }
        }
    }
}

private struct PanelQuitFooterStateFrame: View {
    let language: ClaudioAppLanguage
    let density: ClaudioCompactPreviewDensity
    @FocusState private var focusedTarget: PanelFocusTarget?

    var body: some View {
        PanelQuitFooter(
            language: language,
            focusedTarget: $focusedTarget,
            onQuit: {}
        )
        .frame(width: CGFloat(standardPanelWidth))
    }
}

// MARK: - MasterVolumeState (6 fixtures, PLAN-MASTER-VOLUME.md D33/D38)

struct MasterVolumeGalleryView: View {
    var body: some View {
        GallerySection(
            title: "MasterVolumeState (\(PreviewFixtures.masterVolumeStates.count))"
        ) {
            ForEach(Array(PreviewFixtures.masterVolumeStates.enumerated()), id: \.offset) {
                _, state in
                GalleryFrame(caption: masterVolumeStateCaption(state)) {
                    MasterVolumeStateFrame(state: state)
                }
            }
        }
    }
}

/// One master-volume frame. The gallery never actually writes anything — every frame's state
/// is fully determined by ``PreviewFixtures/MasterVolumeState``, so ``onCommit`` is a no-op
/// that always reports failure (never invoked in practice, since nothing here drags the
/// slider) and ``focusCoordinator`` is a fresh, never-observed instance (mirrors this file's
/// other frames constructing throwaway view-models pinned to no particular state).
///
/// D39: `.writeFailed` is rendered by `PanelView`, not `MasterVolumeRow` itself — this frame
/// reproduces that exact split (row, then a SEPARATE error row) for the `.failed` case, rather
/// than inventing a shape `MasterVolumeRow` alone could never produce on its own.
private struct MasterVolumeStateFrame: View {
    let state: PreviewFixtures.MasterVolumeState
    @FocusState private var focusedTarget: PanelFocusTarget?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MasterVolumeRow(
                diskVolume: volume,
                onCommit: { _ in nil },
                focusCoordinator: PanelFocusCoordinator(),
                focusedTarget: $focusedTarget,
                adaptation: panelLayoutAdaptation(),
                language: .zhHans)
            if case .failed(_, let message) = state {
                FailureRow(message: message)
            }
        }
        .frame(width: CGFloat(standardPanelWidth))
    }

    private var volume: Double {
        switch state {
        case .value(let volume): volume
        case .failed(let volume, _): volume
        }
    }

    /// 直接渲染产品用的那一个 ``FailureRow``（`ClaudioGUIComponents/FailureRow.swift`）—— 展柜画的就是真身，不是它的仿品。
    ///
    /// 【这里原本是第七份手抄副本，而它的注释把整个病灶说穿了】原文：
    ///
    /// > Mirrors `PanelView.errorNotice`'s shape **verbatim** … this repo's established
    /// > 「拒绝行」 pattern is **duplicated per-view rather than shared** …, since each already
    /// > lives as a `private` method on a `View` with **no public surface for another file to call**.
    ///
    /// 那句话是**对当时事实的准确描述**，也正是复制粘贴自我繁殖的机制：前五份全是 `private`，于是
    /// 第六个想用它的人**只能再抄一份** —— 而每一份新副本，都被前面那些副本正当化了。抄到第七份时，
    /// 「大家都是抄的」本身成了继续抄下去的理由。
    ///
    /// 它还有一个副本独有的 bug：字号是裸 `size: 11`，**没有乘 `typeScale`** —— 展柜里这一行字
    /// 从来不跟随 Dynamic Type。换成 `FailureRow` 之后它**免费**获得了跟随（组件自带
    /// `@ScaledMetric`），这一条谁都没去修过，它是被这次合并顺手带走的。
    ///
    /// 现在那个「no public surface」不成立了：``FailureRow`` 就是那个 surface。
}

/// Exhaustive over every ``MasterVolumeState`` case, no `default:`.
private func masterVolumeStateCaption(_ state: PreviewFixtures.MasterVolumeState) -> String {
    switch state {
    case .value(let volume): ".value(\(volume))"
    case .failed(let volume, let message):
        ".failed(volume: \(volume), message: \"\(message.prefix(24))…\")"
    }
}

// MARK: - PackCard / PackCardState (6 fixtures)

struct PackCardGalleryView: View {
    var body: some View {
        GallerySection(title: "PackCard / PackCardState (\(PreviewFixtures.packCards.count))") {
            ForEach(Array(PreviewFixtures.packCards.enumerated()), id: \.offset) { _, card in
                GalleryFrame(caption: packCardCaption(card)) {
                    PackCardStateFrame(card: card)
                }
            }
        }
    }
}

private struct PackCardStateFrame: View {
    let card: PackCard
    @FocusState private var focusedTarget: PanelFocusTarget?

    var body: some View {
        // `PackCardView` itself is `private` to `PackGalleryView.swift` — a single-card
        // array is the only way to render exactly one card via the public
        // `PackGalleryView` API, never a second, parallel card-rendering path.
        PackGalleryView(cards: [card], focusedTarget: $focusedTarget, language: .zhHans)
    }
}

private func packCardCaption(_ card: PackCard) -> String {
    "\(card.id) · \(packCardStateCaption(card.state)) · isSelected=\(card.isSelected)"
}

/// Exhaustive over every ``PackCardState`` case, no `default:`.
private func packCardStateCaption(_ state: PackCardState) -> String {
    switch state {
    case .complete: ".complete"
    case .partial(let present, let total): ".partial(\(present)/\(total))"
    case .broken: ".broken"
    }
}

// MARK: - Host integrations (all-product + WorkBuddy pre-RC scenarios)

/// 全部产品宿主展柜直接渲染生产 ``IntegrationsSettingsDestinationView``；WorkBuddy 的七态
/// 继续进入同一份 production view，不在 gallery 复制第二套展示组件。
struct HostIntegrationGalleryView: View {
    var body: some View {
        let scenarioCount =
            PreviewFixtures.hostIntegrationScenarios.count
            + PreviewFixtures.workBuddyVisualScenarios.count + 1
        GallerySection(
            title: "Host integrations · 2 languages (\(scenarioCount))"
        ) {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach([ClaudioCompactPreviewDensity.standard]) { textSize in
                    ForEach(SettingsGalleryAppearance.allCases) { appearance in
                        ForEach(PreviewFixtures.hostIntegrationScenarios) { scenario in
                            GalleryFrame(
                                caption: hostIntegrationGalleryCaption(
                                    language: language,
                                    textSize: textSize,
                                    appearance: appearance,
                                    id: scenario.id,
                                    title: scenario.title)
                            ) {
                                HostIntegrationSettingsFrame(
                                    scenario: scenario,
                                    language: language,
                                    textSize: textSize
                                )
                                .environment(\.colorScheme, appearance.colorScheme)
                            }
                        }
                        ForEach(PreviewFixtures.workBuddyVisualScenarios) { scenario in
                            GalleryFrame(
                                caption: hostIntegrationGalleryCaption(
                                    language: language,
                                    textSize: textSize,
                                    appearance: appearance,
                                    id: scenario.id,
                                    title: scenario.title)
                            ) {
                                HostIntegrationSettingsFrame(
                                    scenario: PreviewFixtures.HostIntegrationScenario(
                                        id: scenario.id,
                                        title: scenario.title,
                                        state: scenario.state),
                                    language: language,
                                    textSize: textSize
                                )
                                .environment(\.colorScheme, appearance.colorScheme)
                            }
                        }
                        if let disconnectScenario = PreviewFixtures.workBuddyVisualScenarios.first(
                            where: { $0.phase == .taskStartCurrent })
                        {
                            GalleryFrame(
                                caption: hostIntegrationGalleryCaption(
                                    language: language,
                                    textSize: textSize,
                                    appearance: appearance,
                                    id: "workbuddy.disconnect-in-flight",
                                    title: "WorkBuddy 断开中")
                            ) {
                                HostIntegrationSettingsFrame(
                                    scenario: PreviewFixtures.HostIntegrationScenario(
                                        id: "workbuddy.disconnect-in-flight",
                                        title: "WorkBuddy 断开中",
                                        state: disconnectScenario.state),
                                    selectedSurface: .workBuddy,
                                    language: language,
                                    textSize: textSize,
                                    integrationInFlightAction: .disconnect(.workBuddy)
                                )
                                .environment(\.colorScheme, appearance.colorScheme)
                            }
                        }
                    }
                }
            }
        }
    }
}

private func hostIntegrationGalleryCaption(
    language: ClaudioAppLanguage,
    textSize: ClaudioCompactPreviewDensity,
    appearance: SettingsGalleryAppearance,
    id: String,
    title: String
) -> String {
    [language.selfName, textSize.rawValue, appearance.rawValue, id, title]
        .joined(separator: " · ")
}

@MainActor
private struct HostIntegrationSettingsFrame: View {
    let scenario: PreviewFixtures.HostIntegrationScenario
    let selectedSurface: HostSurfaceID?
    let language: ClaudioAppLanguage
    let textSize: ClaudioCompactPreviewDensity
    let integrationInFlightAction: HostIntegrationUserAction?

    init(
        scenario: PreviewFixtures.HostIntegrationScenario,
        selectedSurface: HostSurfaceID? = nil,
        language: ClaudioAppLanguage,
        textSize: ClaudioCompactPreviewDensity,
        integrationInFlightAction: HostIntegrationUserAction? = nil
    ) {
        self.scenario = scenario
        self.selectedSurface = selectedSurface
        self.language = language
        self.textSize = textSize
        self.integrationInFlightAction = integrationInFlightAction
    }

    var body: some View {
        SettingsWindowRouteFrame(
            route: selectedSurface.map { SettingsRoute.integrations(IntegrationsSettingsRoute(surface: $0)) }
                ?? .destination(.integrations),
            availability: PreviewFixtures.settingsRouteAvailability,
            language: language,
            textSize: textSize,
            integrationScenario: scenario,
            integrationInFlightAction: integrationInFlightAction)
    }
}

// MARK: - Shared gallery chrome

private struct GallerySection<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                // 既有 token，不是 SwiftUI 默认 `.primary`。
                .foregroundColor(ClaudioColor.text(colorScheme))
            content
        }
    }
}

private struct GalleryFrame<Content: View>: View {
    let caption: String
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(caption: String, @ViewBuilder content: () -> Content) {
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                // 既有 token（`text-2`），不是非 token 的 `.secondary`。
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            // LOAD-BEARING (`/ship` 评审): every framed view here — production components,
            // ``PackGalleryView``, Settings views — paints NO surface of its own; in
            // production ``PanelView`` (the composition root) supplies it. Without this
            // background, the gallery rendered all five event colors, every
            // glyph tile and every reject row on SwiftUI's **untokenized default window
            // background** — and that surface is precisely what every contrast assertion in
            // `ContrastSuite` is talking about. A 视觉真相源 (DESIGN.md line 134) that shows
            // the colors on the wrong surface is worse than no gallery: it makes a
            // contrast failure look fine (which is exactly how the glyph-tile ≥3:1 failure
            // this pass fixes survived review). `panel` in both schemes — the same token
            // `PanelView` uses.
            content
                .background(ClaudioColor.panel(colorScheme))
        }
        .padding(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                // 既有 token，不是非 token 的 `Color.gray.opacity(0.2)`。
                .strokeBorder(ClaudioColor.hairlineStrong(colorScheme))
        )
    }
}

// MARK: - Preview-only support environment (never touches user data)

/// A fixed-duration stub — the gallery never actually imports a file (every drop-zone
/// frame's state is pinned via `previewState:`, not produced by running the pipeline),
/// so this is only ever present to satisfy ``AudioImportEnvironment``'s required
/// `durationProbe` parameter.
private struct PreviewDurationProbe: AudioDurationProbing {
    func probeDuration(of fileURL: URL) -> TimeInterval? { 1.0 }
}

/// One isolated temporary root backs every DEBUG gallery dependency. Production initializers can
/// therefore exercise their normal scan/refresh contracts without reading Claudio's user data.
private let previewStateGalleryRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("claudio-state-gallery-\(UUID().uuidString)", isDirectory: true)

private let previewAudioImportEnvironment = AudioImportEnvironment(
    userPacksDirectory: previewStateGalleryRoot.appendingPathComponent(
        "packs",
        isDirectory: true),
    durationProbe: PreviewDurationProbe(),
    packsLockFile: previewStateGalleryRoot.appendingPathComponent("packs.lock")
)

@MainActor
private let previewStateGallerySoundPackLibrary = SoundPackLibrary(
    environment: previewAudioImportEnvironment)

@MainActor
private let previewStateGalleryRefreshCoordinator = SoundPacksRefreshCoordinator()

// MARK: - Preview providers (classic `PreviewProvider` ONLY — `#Preview` does not
// compile under CommandLineTools, see this file's header doc comment)

struct MasterVolumeGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            MasterVolumeGalleryView().preferredColorScheme(.light)
            MasterVolumeGalleryView().preferredColorScheme(.dark)
        }
    }
}

struct PanelQuitFooterGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            PanelQuitFooterGalleryView().preferredColorScheme(.light)
            PanelQuitFooterGalleryView().preferredColorScheme(.dark)
        }
    }
}

struct PackCardGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            PackCardGalleryView().preferredColorScheme(.light)
            PackCardGalleryView().preferredColorScheme(.dark)
        }
    }
}

struct HostIntegrationGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            HostIntegrationGalleryView().preferredColorScheme(.light)
            HostIntegrationGalleryView().preferredColorScheme(.dark)
        }
    }
}

/// The combined, one-screen gallery (T14 acceptance criterion 2: "browsable in one
/// Xcode Canvas screen").
struct StateGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            StateGalleryView().preferredColorScheme(.light)
            StateGalleryView().preferredColorScheme(.dark)
        }
    }
}
#endif
