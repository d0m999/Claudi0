import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

private let panelScrollViewportCoordinateSpace = "panel.scroll-viewport"

/// 菜单栏 Agent 集成面板。生产树只呈现一个当前作用域的五行事件与两行播放设置；
/// 连接/诊断、事件设置和完整声音编辑继续由 retained window 负责。
@MainActor
public struct PanelView: View {
    @StateObject private var announcer: PanelAnnouncer
    @StateObject private var panelModel: PanelConfigController
    @State private var isSoundScopeMenuExpanded = false
    @State private var activityRange: LocalActivityRange = .today
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var soundScopePickerBottom: CGFloat = 0
    @State private var previousTopContent: PanelTopContent?
    @State private var previewAttemptFailures: [Event: EventPreviewAttemptFailure] = [:]
    @FocusState private var focusedTarget: PanelFocusTarget?

    /// C1：app 生命周期声音作用域选择的唯一事实，与设置窗口共享同一个 owner。视图只呈现它的
    /// 投影，不再持有 `@AppStorage` 副本。
    @ObservedObject private var soundScopeSelection: SoundScopeSelection
    @ObservedObject private var focusCoordinator: PanelFocusCoordinator
    @ObservedObject private var hostIntegrations: HostIntegrationPresentationStore
    @ObservedObject private var languageStore: ClaudioPreferences
    @ObservedObject private var activityDiagnostics: ActivityDiagnosticsModel
    @ObservedObject private var noticeNavigation: SessionNavigationCoordinator
    @ObservedObject private var eventNoticeModel: EventNoticeModel

    @Environment(\.colorScheme) private var colorScheme

    private let audioEnvironment: AudioImportEnvironment
    private let configFile: URL
    private let previewPlayer: AudioPreviewPlaying
    private let refreshesActivityOnLifecycle: Bool
    private let onAudibilityInputsChanged: @MainActor () -> Void
    private let onOpenSettings: @MainActor () -> Void
    private let onEditSoundScope: @MainActor (EventSettingsWindowRoute) -> Void
    private let onConfigureSound: @MainActor (SoundPacksWindowRoute) -> Void
    private let onOpenRecentNotices: @MainActor () -> Void
    private let onOpenIntegration: @MainActor (HostID) -> Void
    private let onQuit: @MainActor () -> Void
    private let onRevealConfig: @MainActor (URL) -> Void
    private let onAnnounce: @MainActor (String) -> Void

    /// C1：`panelModel` 与 `soundScopeSelection` 都由 app 组合层（`MenuBarController`）注入 ——
    /// 面板与设置窗口共享同一个 controller 与选择 owner，这里不再自构第二份。
    public init(
        audioEnvironment: AudioImportEnvironment,
        configFile: URL = ClaudioPaths.configFile,
        panelModel: PanelConfigController,
        soundScopeSelection: SoundScopeSelection,
        focusCoordinator: PanelFocusCoordinator = PanelFocusCoordinator(),
        hostIntegrations: HostIntegrationPresentationStore,
        languageStore: ClaudioPreferences,
        activityDiagnostics: ActivityDiagnosticsModel,
        eventNoticeModel: EventNoticeModel,
        noticeNavigation: SessionNavigationCoordinator? = nil,
        onAudibilityInputsChanged: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void,
        onEditSoundScope: @escaping @MainActor (EventSettingsWindowRoute) -> Void = { _ in },
        onConfigureSound: @escaping @MainActor (SoundPacksWindowRoute) -> Void = { _ in },
        onOpenRecentNotices: @escaping @MainActor () -> Void,
        onOpenIntegration: @escaping @MainActor (HostID) -> Void,
        onQuit: @escaping @MainActor () -> Void,
        onRevealConfig: @escaping @MainActor (URL) -> Void,
        onAnnounce: @escaping @MainActor (String) -> Void,
    ) {
        self.audioEnvironment = audioEnvironment
        self.configFile = configFile
        self.focusCoordinator = focusCoordinator
        self.hostIntegrations = hostIntegrations
        self.languageStore = languageStore
        self.activityDiagnostics = activityDiagnostics
        self.eventNoticeModel = eventNoticeModel
        self.noticeNavigation =
            noticeNavigation ?? SessionNavigationCoordinator(model: eventNoticeModel)
        self.onAudibilityInputsChanged = onAudibilityInputsChanged
        self.onOpenSettings = onOpenSettings
        self.onEditSoundScope = onEditSoundScope
        self.onConfigureSound = onConfigureSound
        self.onOpenRecentNotices = onOpenRecentNotices
        self.onOpenIntegration = onOpenIntegration
        self.onQuit = onQuit
        self.onRevealConfig = onRevealConfig
        self.onAnnounce = onAnnounce
        previewPlayer = NSSoundAudioPreviewPlayer()
        refreshesActivityOnLifecycle = true

        _announcer = StateObject(wrappedValue: PanelAnnouncer())
        _panelModel = StateObject(wrappedValue: panelModel)
        _soundScopeSelection = ObservedObject(wrappedValue: soundScopeSelection)
    }

    #if DEBUG
    /// Deterministic production-composition initializer used only by the state gallery. The
    /// injected model owns every visible state —— 包括 C1 之后的选择投影（Surface 播种已在
    /// preview controller 的 init 里完成）；callbacks are inert and the injected typed preferences
    /// are isolated so frames cannot change the user's real panel preferences.
    public init(
        previewPanelModel: PanelConfigController,
        previewSoundScopeExpanded: Bool = false,
        previewActivityPresentation: ActivityDiagnosticsPresentation = .empty(),
        previewActivityRange: LocalActivityRange = .today,
        audioEnvironment: AudioImportEnvironment,
        focusCoordinator: PanelFocusCoordinator,
        hostIntegrations: HostIntegrationPresentationStore,
        languageStore: ClaudioPreferences,
        eventNoticeModel: EventNoticeModel = EventNoticeModel(receiverEpoch: UUID()),
        previewPlayer: AudioPreviewPlaying? = nil,
        onAnnounce: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        _announcer = StateObject(wrappedValue: PanelAnnouncer())
        _panelModel = StateObject(wrappedValue: previewPanelModel)
        _soundScopeSelection = ObservedObject(wrappedValue: previewPanelModel.soundScopeSelection)
        _isSoundScopeMenuExpanded = State(initialValue: previewSoundScopeExpanded)
        _activityRange = State(initialValue: previewActivityRange)
        self.audioEnvironment = audioEnvironment
        self.configFile = URL(fileURLWithPath: "/dev/null/claudio-panel-preview-config.json")
        self.focusCoordinator = focusCoordinator
        self.hostIntegrations = hostIntegrations
        self.languageStore = languageStore
        self.eventNoticeModel = eventNoticeModel
        self.noticeNavigation = SessionNavigationCoordinator(model: eventNoticeModel)
        self.activityDiagnostics = ActivityDiagnosticsModel(
            previewPresentation: previewActivityPresentation)
        self.previewPlayer = previewPlayer ?? NSSoundAudioPreviewPlayer()
        self.refreshesActivityOnLifecycle = false
        self.onAudibilityInputsChanged = {}
        self.onOpenSettings = {}
        self.onEditSoundScope = { _ in }
        self.onConfigureSound = { _ in }
        self.onOpenRecentNotices = {}
        self.onOpenIntegration = { _ in }
        self.onQuit = {}
        self.onRevealConfig = { _ in }
        self.onAnnounce = onAnnounce
    }
    #endif

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(13)
            Rectangle()
                .fill(ClaudioTheme.hairline(colorScheme))
                .frame(height: ClaudioTheme.Metrics.hairline)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    noticeSection
                    soundScopePicker(
                        availableMenuHeight: max(
                            0,
                            scrollViewportHeight - soundScopePickerBottom - 5)
                    )
                    .background(
                        GeometryReader { pickerGeometry in
                            Color.clear.preference(
                                key: PanelSoundScopePickerBottomPreferenceKey.self,
                                value: pickerGeometry.frame(
                                    in: .named(panelScrollViewportCoordinateSpace)
                                ).maxY)
                        }
                    )
                    if showsRefreshFailedNotice {
                        refreshFailedNotice
                    }
                    mainContent
                    writeFailures
                    activityOverview
                }
                .padding(13)
            }
            .coordinateSpace(name: panelScrollViewportCoordinateSpace)
            .background(
                GeometryReader { scrollViewport in
                    Color.clear.preference(
                        key: PanelScrollViewportHeightPreferenceKey.self,
                        value: scrollViewport.size.height)
                }
            )
            .onPreferenceChange(PanelScrollViewportHeightPreferenceKey.self) {
                scrollViewportHeight = $0
            }
            .onPreferenceChange(PanelSoundScopePickerBottomPreferenceKey.self) {
                soundScopePickerBottom = $0
            }
            PanelQuitFooter(
                language: languageStore.language,
                focusedTarget: $focusedTarget,
                onQuit: onQuit)
        }
        .frame(width: standardPanelWidth)
        .background(ClaudioTheme.panelGradient(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel)
                .strokeBorder(ClaudioTheme.hairline(colorScheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel))
        .onAppear {
            announcer.observeLibraryTransitions(
                from: panelModel.$libraryPresentationState,
                facts: {
                    [
                        model = panelModel, coordinator = focusCoordinator,
                        preferences = languageStore
                    ] in
                    Self.libraryAnnouncementFacts(
                        model: model, coordinator: coordinator, preferences: preferences)
                },
                onAnnounce: onAnnounce)
            applyFirstFocus()
            if refreshesActivityOnLifecycle {
                activityDiagnostics.refresh()
            }
        }
        .onChange(of: focusCoordinator.showCount) { _ in
            isSoundScopeMenuExpanded = false
            previewAttemptFailures = [:]
            panelModel.reload()
            if refreshesActivityOnLifecycle {
                activityDiagnostics.refresh()
            }
            applyFirstFocus()
            announcePanelSummary()
        }
        .onChange(of: hostIntegrations.content.sourceRows) { _ in
            applyFirstFocus()
        }
        .onChange(of: panelModel.libraryPresentationState) { _ in
            if isEventFocusTarget(focusedTarget) || focusedTarget == .libraryRefreshRetry {
                applyFocusAfterContentChange()
            }
            announcePanelSummary(opening: false)
        }
        .onChange(of: panelModel.config.selectedPack) { _ in
            previewAttemptFailures = [:]
        }
        .onChange(of: soundScopeSelection.projection.scope) { _ in
            previewAttemptFailures = [:]
        }
        .onChange(of: panelModel.configState.topContent) { content in
            focusedTarget = panelFocusAfterTopContentChange(
                previous: previousTopContent,
                current: content,
                focusedTarget: focusedTarget,
                nextOrder: focusOrder(for: content))
            previousTopContent = content
            announcePanelSummary(opening: false)
        }
        .onChange(of: writeFailureRecoveryFocusTargets) { _ in
            if isWriteFailureRecoveryTarget(focusedTarget) {
                applyFocusAfterContentChange()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headerAccessibilityLabel)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            ClaudioOrbitWordmark(height: 22)
            Spacer(minLength: 8)
            Button(action: onOpenSettings) {
                Label(l10n.text(.panelOpenSettings), systemImage: "gearshape")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
                    .contentShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
            }
            .buttonStyle(ClaudioIconButtonStyle())
            .focused($focusedTarget, equals: .headerSettings)
            .accessibilityLabel(l10n.text(.panelOpenSettings))
            .accessibilityIdentifier("panel.settings")

        }
        .accessibilityElement(children: .contain)
    }

    private var noticeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                focusCoordinator.noticeIsExpanded.toggle()
                if focusCoordinator.noticeIsExpanded {
                    eventNoticeModel.openReading(.panel)
                } else {
                    eventNoticeModel.closeReading(.panel)
                }
            } label: {
                HStack {
                    Text(l10n.text(.eventNoticeRecent)).font(.headline)
                    Text(String(eventNoticeModel.badgeCount)).monospacedDigit()
                    Spacer()
                    Image(
                        systemName: focusCoordinator.noticeIsExpanded
                            ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(.plain)
            .focused($focusedTarget, equals: .recentNotices)
            .accessibilityIdentifier("panel.recent-notices")
            if focusCoordinator.noticeIsExpanded {
                EventNoticeReadingView(
                    model: eventNoticeModel, preferences: languageStore,
                    navigation: noticeNavigation, selected: $focusCoordinator.noticeSelection,
                    openSource: { action in
                        noticeNavigation.openSourceApplication(
                            action, generation: noticeNavigation.capabilityGeneration)
                    },
                    copySession: { action in
                        noticeNavigation.copy(action) { session in
                            NSPasteboard.general.clearContents()
                            return NSPasteboard.general.setString(session, forType: .string)
                        }
                    })
            } else if let latest = eventNoticeModel.readingSnapshot.latest {
                Text(
                    EventNoticeProjection.primaryLine(for: latest, language: languageStore.language)
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: focusCoordinator.noticeIsExpanded) { expanded in
            if expanded {
                eventNoticeModel.openReading(.panel)
            } else {
                eventNoticeModel.closeReading(.panel)
            }
        }
        .onChange(of: focusCoordinator.hideCount) { _ in eventNoticeModel.closeReading(.panel) }
    }

    private var headerAccessibilityLabel: String {
        Self.headerAccessibilityLabel(language: languageStore.language)
    }

    private static func headerAccessibilityLabel(language: ClaudioAppLanguage) -> String {
        let l10n = ClaudioL10n(language: language)
        let separator = language == .english ? ", " : "，"
        return l10n.text(.panelTitle) + separator + l10n.text(.panelOpenSettings)
            + separator + l10n.text(.eventNoticeRecent)
    }

    private static func libraryAnnouncementFacts(
        model: PanelConfigController,
        coordinator: PanelFocusCoordinator,
        preferences: ClaudioPreferences
    ) -> PanelLibraryAnnouncementFacts {
        PanelLibraryAnnouncementFacts(
            header: headerAccessibilityLabel(language: preferences.language),
            refreshFailedNotice: ClaudioL10n(language: preferences.language)
                .text(.panelLibraryRefreshFailed),
            topContent: model.configState.topContent,
            libraryState: model.libraryPresentationState,
            panelIsVisible: coordinator.isPanelVisible,
            openCount: coordinator.showCount)
    }

    private func announcePanelSummary(opening: Bool = true) {
        let announcer = self.announcer
        let coordinator = focusCoordinator
        let model = panelModel
        announcer.scheduleLibraryUpdate(
            opening: opening,
            facts: {
                Self.libraryAnnouncementFacts(
                    model: model, coordinator: coordinator, preferences: languageStore)
            },
            onAnnounce: onAnnounce)
    }

    // MARK: - Sound scope

    private var soundScopePresentations: [PanelSoundScopePresentation] {
        var scopeConfig = panelModel.config
        scopeConfig.workspaceRules = panelModel.workspaceRules
        return panelSoundScopePresentations(
            sourceRows: hostIntegrations.content.sourceRows,
            config: scopeConfig,
            language: languageStore.language)
    }

    private var selectedScope: PanelSoundScopePresentation {
        panelSoundScopeSelectionPresentation(
            selection: soundScopeSelection.projection.scope,
            scopes: soundScopePresentations,
            language: languageStore.language)
    }

    private func soundScopePicker(availableMenuHeight: CGFloat) -> some View {
        PanelSoundScopePicker(
            scopes: soundScopePresentations,
            selectedScope: selectedScope,
            language: languageStore.language,
            availableMenuHeight: availableMenuHeight,
            isExpanded: $isSoundScopeMenuExpanded,
            focusedTarget: $focusedTarget,
            onSelect: selectSoundScope,
            onOpenIntegration: onOpenIntegration)
    }

    /// C1：持久化、重钉与投影发布全部委托给 owner（经 `panelModel.selectSoundScope`）。
    /// 失效目标（菜单展开期间规则被删）不再回写任何持久字节 —— owner 的投影本来就是事实。
    private func selectSoundScope(_ requestedScope: PanelSoundScopeID) {
        guard
            let scope = validatedPanelSoundScopeSelection(
                requestedScope,
                availableScopes: soundScopePresentations.map(\.scope))
        else { return }
        panelModel.selectSoundScope(
            scope,
            rebindSelectedWorkspace: panelModel.selectedSoundScope == scope
                && soundScopeSelection.projection.staleness == .staleRule)
        previewAttemptFailures = [:]
        applyFirstFocus()
    }

    // MARK: - Activity overview

    private var activityPresentation: ActivityOverviewPresentation {
        activityDiagnostics.presentation.projection.presentation(for: .global)
    }

    private var activityOverview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.text(.workspaceAllSources)).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(l10n.text(.settingsActivityRangeToday))
                Text(activityCountText(activityPresentation.todayEventTotal)).monospacedDigit()
                Spacer()
                Text(l10n.text(.settingsActivityRangeSevenDays))
                Text(activityCountText(activityPresentation.sevenDayEventTotal)).monospacedDigit()
            }
            .font(.caption)
            Text(activityStatusText(activityPresentation.sevenDayStatus)).font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("panel.activity.totals")
    }

    private func activityMetric(title: String, value: UInt64?, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(value.map { String($0) } ?? "—")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(ClaudioTheme.text(colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func activitySegment(
        _ segment: ActivityOverviewSegmentLayout
    ) -> some View {
        let color = ClaudioTheme.event(segment.event, colorScheme)
        let isSupported = segment.availability == .supported
        return Button {
            focusedTarget = .activityMetric(segment.event)
        } label: {
            ZStack {
                Color.clear
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSupported && (segment.count ?? 0) > 0 ? color : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(
                                isSupported ? color : ClaudioTheme.secondaryText(colorScheme),
                                style: StrokeStyle(
                                    lineWidth: 1.5,
                                    dash: isSupported ? [] : [3, 2]))
                    }
                    .overlay {
                        if !isSupported {
                            Image(systemName: "slash.circle")
                                .font(.caption2)
                                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                        }
                    }
                    .frame(height: ActivityOverviewBarLayout.visibleBarHeight)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(
            PanelActivitySegmentButtonStyle(
                cornerRadius: ClaudioTheme.Radius.control)
        )
        .focused($focusedTarget, equals: .activityMetric(segment.event))
        .accessibilityLabel(localizedEventName(segment.event, language: languageStore.language))
        .accessibilityValue(activityTooltipText(segment))
        .accessibilityHint(
            l10n.format(
                .settingsActivityCoverage,
                Int64(activityPresentation.event(segment.event)?.coverage.supportedCount ?? 0),
                Int64(activityPresentation.event(segment.event)?.coverage.totalCount ?? 0))
        )
        .help(activityTooltipText(segment))
        .accessibilityIdentifier("panel.activity.segment.\(segment.event.cliName)")
    }

    private func activityTooltipText(_ segment: ActivityOverviewSegmentLayout) -> String {
        let event = activityPresentation.event(segment.event)
        let today = activityCountText(event?.todayCount)
        let sevenDays = activityCountText(event?.sevenDayCount)
        let coverage = l10n.format(
            .settingsActivityCoverage,
            Int64(event?.coverage.supportedCount ?? 0),
            Int64(event?.coverage.totalCount ?? 0))
        let label = localizedEventName(segment.event, language: languageStore.language)
        return "\(label) · \(l10n.text(.settingsActivityRangeToday)) \(today) · "
            + "\(l10n.text(.settingsActivityRangeSevenDays)) \(sevenDays) · \(coverage)"
    }

    private func activityStatusText(_ status: ActivityOverviewStatus) -> String {
        switch status {
        case .ready: return l10n.text(.settingsActivityStatusReady)
        case .empty: return l10n.text(.settingsActivityStatusEmpty)
        case .unobserved: return l10n.text(.settingsActivityStatusUnobserved)
        case .unavailable: return l10n.text(.settingsActivityStatusUnavailable)
        case .stale(let date):
            return l10n.format(
                .settingsActivityStatusStale,
                date.formatted(date: .abbreviated, time: .shortened) as NSString)
        case .partial(let date):
            return l10n.format(
                .settingsActivityStatusPartial,
                date.formatted(date: .abbreviated, time: .shortened) as NSString)
        }
    }

    private func activityCountText(_ count: UInt64?) -> String {
        count.map { String($0) } ?? "—"
    }

    // MARK: - Main content

    private var showsRefreshFailedNotice: Bool {
        panelShowsRefreshFailedNotice(
            topContent: panelModel.configState.topContent,
            libraryState: panelModel.libraryPresentationState)
    }

    private var refreshFailedNotice: some View {
        HStack(alignment: .center, spacing: 7) {
            FailureRow(message: l10n.text(.panelLibraryRefreshFailed))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("panel.library.refreshFailed")
            Button(l10n.text(.panelRetry)) {
                panelModel.retrySoundPackLibraryRefresh()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
            .focused($focusedTarget, equals: .libraryRefreshRetry)
            .accessibilityLabel(l10n.text(.panelRetry))
            .accessibilityHint(l10n.text(.panelRetryHint))
            .accessibilityIdentifier("panel.library.refresh-retry")
            .help(l10n.text(.panelRetryHint))
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch panelModel.configState.topContent {
        case .events:
            if panelModel.libraryPresentationState.hasUsableSnapshot {
                eventSection
            } else {
                libraryUnavailableSection
            }
            playbackSettings(
                masterVolumeEnabled: panelModel.libraryPresentationState.hasUsableSnapshot)
        case .needsPack:
            needsPackNotice
            playbackSettings(masterVolumeEnabled: false)
        case .configFailure:
            configFailureNotice()
        }
    }

    private var eventPresentations: [PanelEventPresentation] {
        panelEventPresentations(
            rows: panelModel.eventRows,
            scope: selectedScope.scope,
            masterVolume: panelModel.config.masterVolume,
            language: languageStore.language,
            configWritesAllowed: panelModel.soundControlsEnabled,
            safetyFailures: panelModel.previewSafetyFailures)
    }

    private var eventSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(l10n.format(.panelEventsTitle, selectedScope.name))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                Spacer(minLength: 4)
                Text(eventCoverageSummary)
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            }
            .padding(.bottom, 4)
            VStack(spacing: 0) {
                ForEach(Array(eventPresentations.enumerated()), id: \.element.id) { index, event in
                    PanelAgentEventRow(
                        presentation: event,
                        adaptation: layoutAdaptation,
                        language: languageStore.language,
                        hostIndicators: localizedPanelEventHostIndicators(
                            event: event.event, content: hostIntegrations.content,
                            language: languageStore.language),
                        attemptFailure: previewAttemptFailures[event.event],
                        focusedTarget: $focusedTarget,
                        onPreview: {
                            let outcome = panelModel.attemptPreview(
                                event.event, using: previewPlayer)
                            switch outcome {
                            case .started:
                                previewAttemptFailures[event.event] = nil
                                return true
                            case .failed(let failure):
                                previewAttemptFailures[event.event] = failure
                                onAnnounce(
                                    localizedEventPreviewAttemptFailure(
                                        failure, language: languageStore.language))
                                return false
                            }
                        },
                        onRecovery: { action in
                            switch action {
                            case .adjustGroupVolume:
                                focusedTarget = .masterVolume
                            case .editSound, .repairSound:
                                guard !panelModel.config.selectedPack.isEmpty else { return }
                                let target = soundScopeSelection.projection.writeTarget
                                let targetMatchesScope =
                                    selectedScope.scope.workspaceID == nil
                                    || target?.id == selectedScope.scope.workspaceID
                                guard targetMatchesScope else {
                                    onAnnounce(
                                        localizedWorkspaceError(
                                            .staleRule, language: languageStore.language))
                                    return
                                }
                                if panelModel.selectedPackIsBuiltinReadOnly {
                                    onConfigureSound(
                                        .copyAndApply(
                                            scope: selectedScope.scope,
                                            packID: panelModel.config.selectedPack,
                                            event: event.event,
                                            workspaceTarget: target))
                                } else {
                                    onConfigureSound(
                                        .editEvent(
                                            scope: selectedScope.scope,
                                            packID: panelModel.config.selectedPack,
                                            event: event.event,
                                            workspaceTarget: target))
                                }
                            }
                        },
                        onToggleMute: {
                            panelModel.toggleMute(event.event)
                            onAudibilityInputsChanged()
                        })
                    if index < eventPresentations.count - 1 {
                        Rectangle()
                            .fill(ClaudioTheme.hairline(colorScheme))
                            .frame(height: ClaudioTheme.Metrics.hairline)
                    }
                }
            }
            .padding(.horizontal, 8)
            .background(ClaudioTheme.surface(colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                    .strokeBorder(
                        ClaudioTheme.hairline(colorScheme),
                        lineWidth: ClaudioTheme.Metrics.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.events.single-scope")
    }

    private var eventCoverageSummary: String {
        if selectedScope.scope.surface == nil { return selectedScope.coverageText }
        return l10n.format(
            .panelEventsMappable,
            Int64(selectedScope.supportedCount),
            Int64(selectedScope.totalCount))
    }

    @ViewBuilder
    private var libraryUnavailableSection: some View {
        switch panelModel.libraryPresentationState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(l10n.text(.panelLoadingEvents))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            }
            .accessibilityIdentifier("panel.events.loading")
        case .loadFailed(let reason):
            VStack(alignment: .leading, spacing: 7) {
                FailureRow(message: reason)
                Button(l10n.text(.panelRetry)) {
                    panelModel.retrySoundPackLibraryRefresh()
                }
                .focused($focusedTarget, equals: .bootstrapReportRetry(id: "library"))
                .accessibilityLabel(l10n.text(.panelRetry))
                .accessibilityIdentifier("panel.library.retry")
            }
        case .ready, .refreshing, .refreshFailed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var needsPackNotice: some View {
        if panelModel.workspaceError == nil {
            VStack(alignment: .leading, spacing: 5) {
                Label(l10n.text(.panelSelectPack), systemImage: "speaker.slash")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(ClaudioTheme.text(colorScheme))
                Text(l10n.text(.panelNeedsPackSettingsMessage))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(9)
            .background(ClaudioTheme.elevated(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row))
            .accessibilityIdentifier("panel.needs-pack")
        }
    }

    private func configFailureNotice() -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let category = panelModel.configState.errorCopyCategory {
                FailureRow(message: l10n.text(category.key))
            }
            if panelConfigRecoveryTarget(configFile: configFile) != nil {
                Button {
                    guard let current = panelConfigRecoveryTarget(configFile: configFile) else {
                        return
                    }
                    onRevealConfig(current)
                } label: {
                    Label(l10n.text(.panelRevealConfig), systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .focused($focusedTarget, equals: .configReveal)
                .accessibilityLabel(l10n.text(.panelRevealConfig))
                .accessibilityHint(l10n.text(.panelRevealConfigHint))
                .accessibilityIdentifier("panel.reveal-config")
            }
        }
        .accessibilityIdentifier("panel.config-failure")
    }

    // MARK: - Playback settings

    private func playbackSettings(masterVolumeEnabled: Bool) -> some View {
        let scope = selectedScope.scope
        let workspaceTarget = soundScopeSelection.projection.writeTarget
        return VStack(alignment: .leading, spacing: 5) {
            Text(l10n.text(.panelPlaybackSettings))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(l10n.text(.panelSoundPackLabel))
                        .accessibilityHidden(true)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Picker(
                        l10n.text(.panelSoundPackLabel),
                        selection: Binding(
                            get: { panelModel.config.selectedPack },
                            set: {
                                _ = panelModel.switchPack(to: $0); onAudibilityInputsChanged()
                            })
                    ) {
                        if !panelModel.allSoundPacks.contains(where: {
                            $0.id == panelModel.config.selectedPack
                        }) {
                            Text(panelModel.config.selectedPack).tag(panelModel.config.selectedPack)
                        }
                        ForEach(panelModel.allSoundPacks, id: \.id) { pack in
                            Text(SelectedPackMetadata(id: pack.id, name: pack.name).displayName)
                                .tag(
                                    pack.id)
                        }
                    }
                    .labelsHidden()
                    .nativeMenuControl()
                    .frame(maxWidth: 176, alignment: .trailing)
                    .disabled(!panelModel.soundControlsEnabled)
                    .accessibilityLabel(l10n.text(.panelSoundPackLabel))
                    .accessibilityIdentifier("panel.workspace.pack-picker")
                    .focused($focusedTarget, equals: .soundPackPicker)
                }
                .padding(.horizontal, 9).padding(.top, 7)
                MasterVolumeRow(
                    diskVolume: panelModel.config.masterVolume,
                    isEnabled: masterVolumeEnabled && panelModel.soundControlsEnabled,
                    onCommit: { volume in
                        let landed = panelModel.setVolume(
                            volume, for: scope, workspaceTarget: workspaceTarget)
                        onAudibilityInputsChanged()
                        return landed
                    },
                    focusCoordinator: focusCoordinator,
                    focusedTarget: $focusedTarget,
                    adaptation: layoutAdaptation,
                    language: languageStore.language
                )
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .id(selectedScope.scope)
                if let id = selectedScope.scope.workspaceID,
                    let rule = panelModel.workspaceRules.first(where: { $0.id == id })
                {
                    Text(
                        l10n.text(.workspaceSurfaces) + ": "
                            + rule.surfaces.map { surface in
                                HostID.productVisibleCases.first { $0.surfaceID == surface }?
                                    .displayName ?? surface.rawValue
                            }.joined(separator: ", ")
                    )
                    .font(.caption).foregroundColor(.secondary)
                    Button(l10n.text(.workspaceEdit)) {
                        guard let target = soundScopeSelection.projection.writeTarget,
                            target.id == id
                        else {
                            onAnnounce(
                                localizedWorkspaceError(
                                    .staleRule, language: languageStore.language))
                            return
                        }
                        onEditSoundScope(
                            EventSettingsWindowRoute(
                                scope: .workspace(id), workspaceTarget: target))
                    }
                    .accessibilityLabel(l10n.text(.workspaceEdit))
                    .accessibilityIdentifier("panel.workspace.edit")
                    .focused($focusedTarget, equals: .workspaceDetails)
                }
                Text(l10n.text(.workspacePreviewNote)).font(.caption).foregroundColor(.secondary)
                    .padding(9)
                if panelModel.workspaceRulesMalformed {
                    FailureRow(message: l10n.text(.workspaceInvalidRule))
                }
                if let error = panelModel.workspaceError {
                    FailureRow(
                        message: localizedWorkspaceError(error, language: languageStore.language))
                    if error == .configFailure || error.isPublishedConflict,
                        panelConfigRecoveryTarget(configFile: configFile) != nil
                    {
                        Button(l10n.text(.panelRevealConfig)) {
                            guard let current = panelConfigRecoveryTarget(configFile: configFile)
                            else { return }
                            onRevealConfig(current)
                        }
                        .accessibilityLabel(l10n.text(.panelRevealConfig))
                        .accessibilityIdentifier("panel.workspace.reveal-config")
                    }
                    if let recoveryFile = panelModel.workspaceRecoveryFile {
                        Button(l10n.text(.panelRevealRecoveryFile)) {
                            guard let target = panelExistingRecoveryFileTarget(recoveryFile)
                            else { return }
                            onRevealConfig(target)
                        }
                        .accessibilityLabel(l10n.text(.panelRevealRecoveryFile))
                        .accessibilityIdentifier("panel.workspace.reveal-recovery")
                    }
                    if error.isPublishedConflict {
                        Button(l10n.text(.workspaceDeleteReload)) {
                            panelModel.reload()
                        }
                        .accessibilityLabel(l10n.text(.workspaceDeleteReload))
                        .accessibilityIdentifier("panel.workspace.reload-after-conflict")
                    }
                }
            }
            .background(ClaudioTheme.surface(colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                    .strokeBorder(
                        ClaudioTheme.hairline(colorScheme),
                        lineWidth: ClaudioTheme.Metrics.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.playback-settings")
    }

    private var writeFailures: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(panelWriteFailureRows(items: writeFailureItems, l10n: l10n)) { row in
                FailureRow(message: row.message)
            }
            if let category = panelModel.surfaceSoundIssueCopyCategory {
                FailureRow(message: l10n.text(category.key))
            }
            ForEach(Array(writeFailureRecoveryFiles.enumerated()), id: \.element) { index, file in
                if panelExistingRecoveryFileTarget(file) != nil {
                    Button {
                        guard let current = panelExistingRecoveryFileTarget(file) else { return }
                        onRevealConfig(current)
                    } label: {
                        Label(
                            writeFailureRecoveryFiles.count == 1
                                ? l10n.text(.panelRevealRecoveryFile)
                                : l10n.format(.panelRevealRecoveryFileNumber, Int64(index + 1)),
                            systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedTarget, equals: .writeFailureRecoveryFile(path: file.path))
                    .accessibilityLabel(
                        writeFailureRecoveryFiles.count == 1
                            ? l10n.text(.panelRevealRecoveryFile)
                            : l10n.format(.panelRevealRecoveryFileNumber, Int64(index + 1))
                    )
                    .accessibilityHint(l10n.text(.panelRevealRecoveryFileHint))
                    .accessibilityIdentifier("panel.write-failure.reveal-recovery.\(index + 1)")
                }
            }
            if showsWriteFailureConfigRecovery,
                panelConfigRecoveryTarget(configFile: configFile) != nil
            {
                Button {
                    guard let current = panelConfigRecoveryTarget(configFile: configFile) else {
                        return
                    }
                    onRevealConfig(current)
                } label: {
                    Label(l10n.text(.panelRevealConfig), systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .focused($focusedTarget, equals: .writeFailureConfigReveal)
                .accessibilityLabel(l10n.text(.panelRevealConfig))
                .accessibilityHint(l10n.text(.panelRevealConfigHint))
                .accessibilityIdentifier("panel.write-failure.reveal-config")
            }
        }
    }

    private var writeFailureItems: [PanelWriteFailure] {
        panelWriteFailureItems(
            muteError: panelModel.muteError,
            packSwitchError: panelModel.packSwitchError,
            masterVolumeError: panelModel.masterVolumeError,
            configFailureReason: currentConfigFailureReason)
    }

    private var showsWriteFailureConfigRecovery: Bool {
        guard !panelModel.configState.topContent.hasConfigFailureNotice else { return false }
        guard panelConfigRecoveryTarget(configFile: configFile) != nil else { return false }
        return writeFailureItems.contains(where: { $0.reason.copyCategory.offersConfigRecovery })
            || panelModel.surfaceSoundIssueCopyCategory?.offersConfigRecovery == true
    }

    private var writeFailureRecoveryFiles: [URL] {
        panelWriteFailureRecoveryFiles(
            items: writeFailureItems,
            surfaceRecoveryFile: panelModel.surfaceSoundIssueRecoveryFile)
    }

    private var writeFailureRecoveryFocusTargets: [PanelFocusTarget] {
        writeFailureRecoveryFiles.map { .writeFailureRecoveryFile(path: $0.path) }
            + (showsWriteFailureConfigRecovery ? [.writeFailureConfigReveal] : [])
    }

    private var currentConfigFailureReason: String? {
        switch panelModel.configState {
        case .malformed(let reason), .unwritable(let reason): return reason
        case .operational, .needsPack: return nil
        }
    }

    // MARK: - Focus and playback

    private func applyFirstFocus() {
        let content = panelModel.configState.topContent
        // The live opening policy IS the tested one (`panelFirstFocusTarget`): a still-rendered
        // handback target wins, otherwise the sound scope, otherwise the first rendered control.
        focusedTarget = panelFirstFocusTarget(
            focusScope(for: content),
            requestedTarget: focusCoordinator.requestedTarget)
        previousTopContent = content
    }

    private func applyFocusAfterContentChange() {
        let content = panelModel.configState.topContent
        focusedTarget = panelFocusAfterTopContentChange(
            previous: previousTopContent,
            current: content,
            focusedTarget: focusedTarget,
            nextOrder: focusOrder(for: content))
        previousTopContent = content
    }

    private func focusOrder(for content: PanelTopContent) -> [PanelFocusTarget] {
        panelFocusOrder(focusScope(for: content))
    }

    private func focusScope(for content: PanelTopContent) -> PanelFocusScope {
        let visibleEvents =
            content.showsEventContent
                && panelModel.libraryPresentationState.hasUsableSnapshot
            ? eventPresentations : []
        return .activityOperational(
            events: visibleEvents,
            hasActivityOverview: true,
            hasMasterVolume: content.showsEventContent
                && panelModel.libraryPresentationState.hasUsableSnapshot,
            hasConfigFailureNotice: content.hasConfigFailureNotice
                && panelConfigRecoveryTarget(configFile: configFile) != nil,
            hasRefreshFailedNotice: showsRefreshFailedNotice,
            writeFailureRecoveryPaths: writeFailureRecoveryFiles.map(\.path),
            hasWriteFailureConfigRecovery: showsWriteFailureConfigRecovery,
            hasSoundPackPicker: !content.hasConfigFailureNotice,
            hasWorkspaceDetails: !content.hasConfigFailureNotice
                && panelModel.workspaceRules.contains {
                    $0.id == selectedScope.scope.workspaceID
                })
    }

    private func isEventFocusTarget(_ target: PanelFocusTarget?) -> Bool {
        switch target {
        case .eventPreview, .eventMute: true
        default: false
        }
    }

    private func isWriteFailureRecoveryTarget(_ target: PanelFocusTarget?) -> Bool {
        switch target {
        case .writeFailureConfigReveal, .writeFailureRecoveryFile: true
        default: false
        }
    }

    // MARK: - Shared projections

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }
    private var layoutAdaptation: PanelLayoutAdaptation {
        PanelLayoutAdaptation(
            hidesWaveform: false,
            rowWrapsToTwoLines: false,
            eventActionsMoveBelow: false,
            panelWidth: standardPanelWidth)
    }
}

private struct PanelSoundScopePickerBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PanelScrollViewportHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 单一来源事件行：标题/原生事件/能力/文件是只读事实，右侧只有试听与静音。
@MainActor
private struct PanelAgentEventRow: View {
    let presentation: PanelEventPresentation
    let adaptation: PanelLayoutAdaptation
    let language: ClaudioAppLanguage
    let hostIndicators: [EventHostIndicatorPresentation]
    let attemptFailure: EventPreviewAttemptFailure?
    let onPreview: () -> Bool
    let onRecovery: (EventPreviewRecoveryAction) -> Void
    let onToggleMute: () -> Void
    private let focusedTarget: FocusState<PanelFocusTarget?>.Binding

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewPulseTrigger = 0
    @State private var previewSuccessToken: UUID?

    init(
        presentation: PanelEventPresentation,
        adaptation: PanelLayoutAdaptation,
        language: ClaudioAppLanguage,
        hostIndicators: [EventHostIndicatorPresentation],
        attemptFailure: EventPreviewAttemptFailure?,
        focusedTarget: FocusState<PanelFocusTarget?>.Binding,
        onPreview: @escaping () -> Bool,
        onRecovery: @escaping (EventPreviewRecoveryAction) -> Void,
        onToggleMute: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.adaptation = adaptation
        self.language = language
        self.hostIndicators = hostIndicators
        self.attemptFailure = attemptFailure
        self.focusedTarget = focusedTarget
        self.onPreview = onPreview
        self.onRecovery = onRecovery
        self.onToggleMute = onToggleMute
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if adaptation.eventActionsMoveBelow {
                    VStack(alignment: .leading, spacing: 6) {
                        identity
                        actions.padding(.leading, 30)
                    }
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        identity
                        Spacer(minLength: 4)
                        actions
                    }
                }
            }
            if let reason = previewUnavailableReason {
                Text(reason)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(
                        "panel.event.\(presentation.event.rawValue).preview-reason")
                if let recoveryAction {
                    Button(recoveryTitle(for: recoveryAction)) {
                        onRecovery(recoveryAction)
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel(recoveryTitle(for: recoveryAction))
                    .accessibilityIdentifier(
                        "panel.event.\(presentation.event.rawValue).preview-recovery")
                }
            }
            if let attemptFailure {
                Text(localizedEventPreviewAttemptFailure(attemptFailure, language: language))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(
                        "panel.event.\(presentation.event.rawValue).preview-failure"
                    )
                    .modifier(
                        PanelPreviewFailureMount(
                            event: presentation.event,
                            text: localizedEventPreviewAttemptFailure(
                                attemptFailure, language: language)))
            }
            if reduceMotion && previewSuccessToken != nil {
                Label(
                    ClaudioL10n(language: language).text(.eventPreviewStarted),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundColor(ClaudioTheme.clay(colorScheme))
                .accessibilityIdentifier(
                    "panel.event.\(presentation.event.rawValue).preview-started")
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.event.\(presentation.event.rawValue).row")
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 7) {
            ClaudioEventGlyph(event: presentation.event, size: 23)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundColor(
                        controlsUnavailable
                            ? ClaudioTheme.secondaryText(colorScheme)
                            : ClaudioTheme.text(colorScheme))

            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(identityAccessibilityLabel)
    }

    private var previewUnavailableReason: String? {
        guard !presentation.controls.previewAvailability.isAvailable else { return nil }
        return localizedEventPreviewHint(
            presentation.controls.previewAvailability, language: language)
    }

    private var recoveryAction: EventPreviewRecoveryAction? {
        return eventPreviewRecoveryAction(for: presentation.controls.previewAvailability)
    }

    private func recoveryTitle(for action: EventPreviewRecoveryAction) -> String {
        let l10n = ClaudioL10n(language: language)
        switch action {
        case .adjustGroupVolume: return l10n.text(.eventPreviewAdjustGroupVolume)
        case .editSound: return l10n.text(.actionConfigureSound)
        case .repairSound: return l10n.text(.eventPreviewRepairSound)
        }
    }

    private var identityAccessibilityLabel: String {
        let separator = language == .english ? ", " : "，"
        let parts = [
            presentation.title,
            previewUnavailableReason,
            attemptFailure.map { localizedEventPreviewAttemptFailure($0, language: language) },
        ].compactMap { $0 }
        return parts.joined(separator: separator)
    }

    private var hostBindingDetails: [EventHostIndicatorPresentation] {
        hostIndicators.filter { $0.detailText != nil }
    }

    private func hostBindingDetailLabel(_ indicator: EventHostIndicatorPresentation) -> String {
        [
            localizedHostName(indicator.host, language: language),
            localizedEventHostIndicatorStatus(indicator.state, language: language),
            indicator.detailText,
        ]
        .compactMap { $0 }
        .joined(separator: language == .english ? ", " : "，")
    }

    private var controlsUnavailable: Bool {
        presentation.implementation == .notImplemented || presentation.support == .unsupported
    }

    private var capabilityBadge: some View {
        Text(presentation.capabilityText)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(ClaudioTheme.elevated(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var soundFileText: some View {
        Text(presentation.soundFileText)
            .font(.system(size: 9.5, design: .rounded))
            .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            .lineLimit(adaptation.rowWrapsToTwoLines ? 2 : 1)
    }

    private var actions: some View {
        HStack(spacing: 5) {
            Button(action: performPreview) {
                Image(systemName: "play.fill")
                    .claudioPreviewPulse(trigger: previewPulseTrigger)
            }
            .buttonStyle(ClaudioIconButtonStyle())
            .disabled(!presentation.controls.previewEnabled)
            .focused(focusedTarget, equals: .eventPreview(presentation.event))
            .help(
                localizedEventPreviewHint(
                    presentation.controls.previewAvailability, language: language)
            )
            .accessibilityHint(
                localizedEventPreviewHint(
                    presentation.controls.previewAvailability, language: language)
            )
            .accessibilityLabel(
                ClaudioL10n(language: language).format(
                    .eventPreviewLabel,
                    presentation.title)
            )
            .accessibilityIdentifier("panel.event.\(presentation.event.rawValue).preview")
            #if DEBUG
            .onAppear {
                PanelPreviewMountRecorder.register(
                    presentation.event, action: performPreview)
            }
            #endif

            Button(action: onToggleMute) {
                PanelMuteSpeakerIcon(isMuted: !presentation.enabled)
                    .accessibilityHidden(true)
            }
            .buttonStyle(ClaudioIconButtonStyle())
            .disabled(!presentation.controls.muteEnabled)
            .focused(focusedTarget, equals: .eventMute(presentation.event))
            .accessibilityLabel(
                presentation.enabled
                    ? ClaudioL10n(language: language).format(.eventMute, presentation.title)
                    : ClaudioL10n(language: language).format(.eventUnmute, presentation.title)
            )
            .accessibilityValue(
                presentation.enabled
                    ? ClaudioL10n(language: language).text(.eventEnabled)
                    : ClaudioL10n(language: language).text(.eventMuted)
            )
            .accessibilityIdentifier("panel.event.\(presentation.event.rawValue).mute")
        }
        .fixedSize()
    }

    private func performPreview() {
        if onPreview() {
            previewPulseTrigger &+= 1
            let token = UUID()
            previewSuccessToken = token
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if previewSuccessToken == token { previewSuccessToken = nil }
            }
        } else {
            previewSuccessToken = nil
        }
    }
}

private struct PanelPreviewFailureMount: ViewModifier {
    let event: Event
    let text: String

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .onAppear { PanelPreviewMountRecorder.showFailure(for: event, text: text) }
            .onChange(of: text) { value in
                PanelPreviewMountRecorder.showFailure(for: event, text: value)
            }
            .onDisappear { PanelPreviewMountRecorder.hideFailure(for: event) }
        #else
        content
        #endif
    }
}

#if DEBUG
/// Exercises the action registered by an actually mounted production Button, then observes the
/// failure Text's own lifecycle. No duplicate preview handler or gallery-only view is involved.
@MainActor
package enum PanelPreviewMountRecorder {
    private static var isRecording = false
    private static var actions: [Event: () -> Void] = [:]
    private static var failures: [Event: String] = [:]

    package static func reset() {
        actions.removeAll()
        failures.removeAll()
        isRecording = true
    }

    package static func stopRecording() {
        actions.removeAll()
        failures.removeAll()
        isRecording = false
    }

    static func register(_ event: Event, action: @escaping () -> Void) {
        guard isRecording else { return }
        actions[event] = action
    }

    static func showFailure(for event: Event, text: String) {
        guard isRecording else { return }
        failures[event] = text
    }

    static func hideFailure(for event: Event) {
        guard isRecording else { return }
        failures[event] = nil
    }

    package static func invoke(_ event: Event) -> Bool {
        guard let action = actions[event] else { return false }
        action()
        return true
    }

    package static func visibleFailure(for event: Event) -> String? {
        failures[event]
    }
}
#endif

/// Activity segments keep their 29pt target and 13pt visible bar while exposing the same warm
/// interaction language as the shared icon actions. Geometry never changes between states.
private struct PanelActivitySegmentButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        PanelActivitySegmentButtonStyleBody(
            configuration: configuration,
            cornerRadius: cornerRadius)
    }
}

private struct PanelActivitySegmentButtonStyleBody: View {
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    private var interactionState: ClaudioIconButtonInteractionState {
        ClaudioIconButtonInteractionState(
            isEnabled: isEnabled,
            isHovered: isHovered,
            isFocused: isFocused,
            isPressed: configuration.isPressed)
    }

    private var isHighlighted: Bool {
        interactionState == .hovered || interactionState == .focused
    }

    private var backgroundColor: Color {
        if isHighlighted { return ClaudioTheme.claySoft(colorScheme) }
        if interactionState == .pressed { return ClaudioTheme.elevated(colorScheme) }
        return .clear
    }

    private var borderColor: Color {
        isHighlighted ? ClaudioTheme.clay(colorScheme) : .clear
    }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        borderColor,
                        lineWidth: ClaudioTheme.Metrics.hairline)
            )
            .contentShape(Rectangle())
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: interactionState
            )
            .onHover { isHovered = $0 }
    }
}

/// The custom Touch Bar speaker remains the visual mask; the shared button style owns its actual
/// foreground so hover, focus, disabled and Reduce Motion states cannot be overridden locally.
private struct PanelMuteSpeakerIcon: View {
    let isMuted: Bool

    var body: some View {
        Rectangle()
            .fill(.foreground)
            .frame(width: 24, height: 24)
            .mask {
                EventMuteSpeakerIcon(isMuted: isMuted, color: .white)
            }
    }
}
