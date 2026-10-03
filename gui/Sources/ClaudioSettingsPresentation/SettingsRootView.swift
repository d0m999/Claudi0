import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SoundPacksWindow
import SwiftUI

/// Unified Settings navigation shell shared by production and the compiled harness.
@MainActor
package struct SettingsRootView: View {
    @ObservedObject var preferences: ClaudioPreferences
    @ObservedObject var dynamicQuietPolicy: DynamicQuietPolicyController
    @ObservedObject var settingsPresentationSession: SettingsPresentationSession
    @ObservedObject var activityDiagnostics: ActivityDiagnosticsModel
    @ObservedObject var eventNoticeHealth: EventNoticeHealthStore
    @ObservedObject var globalShortcutSettings: GlobalShortcutSettingsModel
    @ObservedObject var aboutSettings: AboutSettingsModel
    let soundPacksEditorOwner: SoundPacksEditorOwner
    let soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher
    let eventSettingsModel: PanelConfigController
    let eventSettingsSelection: EventSettingsWindowSelection
    let hostIntegrations: HostIntegrationPresentationStore
    let integrationsModel: IntegrationDestinationModel
    let integrationsFocusCoordinator: IntegrationDestinationFocusCoordinator
    let aiCueViewModel: AICueGenerationViewModel
    let onEventAudibilityInputsChanged: @MainActor () -> Void
    let onAnnouncement: @MainActor (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @FocusState private var focusedTarget: SettingsWindowFocusTarget?
    @State private var handledFocusDebtRevision: UInt64 = 0

    private var l10n: ClaudioL10n { ClaudioL10n(language: preferences.language) }
    private var destination: SettingsDestination {
        settingsPresentationSession.state.routeResolution.destination
    }

    package init(session: SettingsPresentationSession) {
        let dependencies = session.dependencies
        _preferences = ObservedObject(wrappedValue: dependencies.preferences)
        _dynamicQuietPolicy = ObservedObject(wrappedValue: dependencies.dynamicQuietPolicy)
        _settingsPresentationSession = ObservedObject(wrappedValue: session)
        _activityDiagnostics = ObservedObject(wrappedValue: dependencies.activityDiagnostics)
        _eventNoticeHealth = ObservedObject(wrappedValue: dependencies.eventNoticeHealth)
        _globalShortcutSettings = ObservedObject(
            wrappedValue: dependencies.globalShortcutSettings)
        _aboutSettings = ObservedObject(wrappedValue: dependencies.aboutSettings)
        soundPacksEditorOwner = dependencies.soundPacksEditorOwner
        soundPacksEditorNativeEffects = dependencies.soundPacksEditorNativeEffects
        eventSettingsModel = dependencies.eventSettingsModel
        eventSettingsSelection = session.eventSettingsSelection
        hostIntegrations = dependencies.hostIntegrations
        integrationsModel = dependencies.integrationsModel
        integrationsFocusCoordinator = session.integrationsFocusCoordinator
        aiCueViewModel = dependencies.aiCueViewModel
        onEventAudibilityInputsChanged = {
            _ = session.send(.eventAudibilityInputsChanged)
        }
        onAnnouncement = {
            _ = session.send(.announceDestinationUpdate($0))
        }
    }

    package var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar
                    .frame(
                        width: CGFloat(settingsSidebarWidth(windowWidth: geometry.size.width)),
                        height: geometry.size.height,
                        alignment: .top
                    )
                    .background(SettingsAppearance.sidebar(colorScheme))
                    .soundPacksLayoutProbe("settings.sidebar")
                Rectangle()
                    .fill(SettingsAppearance.hairline(colorScheme))
                    .frame(width: ClaudioTheme.Metrics.hairline)
                    .accessibilityHidden(true)
                routeSlot
                    .settingsContentFocusSection()
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: geometry.size.height,
                        alignment: .topLeading
                    )
                    .background(SettingsAppearance.background(colorScheme))
                    .soundPacksLayoutProbe("settings.content")
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .environment(
                \.settingsUsesCompactLayout,
                geometry.size.width <= SettingsWindowGeometry.compactSidebarWindowThreshold)
        }
        .frame(
            minWidth: SettingsWindowGeometry.minimumWidth,
            minHeight: SettingsWindowGeometry.minimumHeight
        )
        .background(SettingsAppearance.background(colorScheme))
        .tint(SettingsAppearance.accent(colorScheme))
        .font(SettingsAppearance.font(.body))
        .foregroundStyle(SettingsAppearance.text(colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n.text(.settingsWindowTitle))
        .accessibilityIdentifier(SettingsPresentationAccessibilityID.root)
        .settingsExitInteraction(destination: destination) { target in
            focusedTarget = target
        }
        .task(id: settingsPresentationSession.state) {
            // Let the previous page leave the native key-view loop before applying the
            // new request. Otherwise its focus teardown can overwrite the new title.
            await Task.yield()
            guard !Task.isCancelled else { return }
            synchronizeDestinationFocus(settingsPresentationSession.state)
        }
    }

    private func synchronizeDestinationFocus(_ state: SettingsPresentationState) {
        guard state.windowPhase == .key,
            let debt = state.focusDebt,
            debt.revision > handledFocusDebtRevision
        else { return }
        handledFocusDebtRevision = debt.revision
        if let target = settingsWindowRequestedFocusTarget(resolution: state.routeResolution) {
            focusedTarget = target
        }
        _ = settingsPresentationSession.send(.acknowledgeFocus(revision: debt.revision))
    }

    private var sidebar: some View {
        let sections = settingsSidebarSections(
            availableDestinations: preferences.availableSettingsDestinations)
        return VStack(alignment: .leading, spacing: 0) {
            ClaudioOrbitWordmark(height: 19)
                .padding(.horizontal, 14)
                .padding(.bottom, 16)

            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(section.destinations) { item in
                        sidebarButton(item)
                    }
                }
                .padding(
                    .top,
                    section.id == sections.first?.id ? 0 : SettingsAppearance.sidebarGroupGap)
            }

            Spacer(minLength: 0)

            Text(l10n.text(.settingsNativeLocalNotice))
                .font(SettingsAppearance.font(.caption))
                .foregroundStyle(SettingsAppearance.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.top, 18)
                .accessibilityIdentifier("settings.sidebar.local-first")
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private func sidebarButton(_ item: SettingsDestination) -> some View {
        Button {
            settingsPresentationSession.send(.route(.destination(item)))
        } label: {
            HStack(spacing: 8) {
                SettingsSidebarIcon(destination: item)

                Text(item.localizedName(language: preferences.language))
                    .foregroundStyle(
                        item == destination
                            ? Color.white
                            : SettingsAppearance.text(colorScheme)
                    )
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: SettingsAppearance.sidebarRowHeight)
            .background(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                    .fill(
                        item == destination
                            ? SettingsAppearance.sidebarSelection(colorSchemeContrast)
                            : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(SettingsAppearance.font(.body).weight(item == destination ? .semibold : .regular))
        .focused($focusedTarget, equals: SettingsWindowFocusTarget.sidebar(item))
        .soundPacksLayoutProbe("settings.sidebar.item.\(item.rawValue)")
        .settingsSidebarInteraction(
            item: item,
            availableDestinations: preferences.availableSettingsDestinations
        ) { next in
            settingsPresentationSession.send(.route(.destination(next)))
            focusedTarget = .sidebar(next)
        }
        .accessibilityLabel(item.localizedName(language: preferences.language))
        .accessibilityAddTraits(item == destination ? .isSelected : [])
        .accessibilitySortPriority(3)
        .accessibilityIdentifier("settings.sidebar.\(item.rawValue)")
    }

    @ViewBuilder
    private var routeSlot: some View {
        if let failure = settingsPresentationSession.state.routeResolution.failure {
            standardDestination { routeFailure(failure) }
        } else {
            switch destination {
            case .general:
                standardDestination { generalSettings }
            case .integrations:
                IntegrationsSettingsDestinationView(
                    model: integrationsModel,
                    focusCoordinator: integrationsFocusCoordinator,
                    languageStore: preferences,
                    productImages: settingsPresentationSession.dependencies.productImages,
                    route: integrationsRoute,
                    onIntegrationsRoute: {
                        settingsPresentationSession.send(.route(.integrations($0)))
                    },
                    onManageSoundScopes: {
                        settingsPresentationSession.send(
                            .route(.destination(.eventsAndSounds)))
                    },
                    onAnnouncement: onAnnouncement)
            case .eventsAndSounds:
                EventSettingsWindowView(
                    model: eventSettingsModel,
                    selection: eventSettingsSelection,
                    hostIntegrations: hostIntegrations,
                    languageStore: preferences,
                    aiCueViewModel: aiCueViewModel,
                    soundPacksEditorOwner: soundPacksEditorOwner,
                    soundPacksEditorNativeEffects: soundPacksEditorNativeEffects,
                    performPlatformAction: {
                        _ = settingsPresentationSession.send(.performPlatformAction($0))
                    },
                    onConfigureSound: {
                        settingsPresentationSession.editScopeSound($0)
                    },
                    onAudibilityInputsChanged: onEventAudibilityInputsChanged,
                    onAnnouncement: onAnnouncement)
            case .notifications:
                standardDestination { notificationsSettings }
            case .sounds:
                SettingsSoundsDestinationView(
                    aiCueViewModel: aiCueViewModel,
                    editorOwner: soundPacksEditorOwner,
                    route: soundsRoute,
                    routeRequestRevision:
                        settingsPresentationSession.state.explicitRouteRequestRevision,
                    languageStore: preferences,
                    nativeEffects: soundPacksEditorNativeEffects,
                    pageHeader: destinationTitle,
                    scopePicker: SettingsSoundScopePicker(session: settingsPresentationSession),
                    returnToScope: soundScopeReturnAction,
                    onAnnouncement: onAnnouncement,
                    credentialSheetIsPresented: Binding(
                        get: {
                            settingsPresentationSession.state.eventPresentation
                                .credentialSheetIsPresented
                        },
                        set: { presented in
                            if presented {
                                settingsPresentationSession.eventSettingsSelection
                                    .presentCredentialSheet()
                            } else {
                                settingsPresentationSession.eventSettingsSelection
                                    .dismissCredentialSheet()
                            }
                        }),
                    playingCandidateID: Binding(
                        get: {
                            settingsPresentationSession.state.eventPresentation.playingCandidateID
                        },
                        set: { id in
                            if let id {
                                settingsPresentationSession.eventSettingsSelection
                                    .beginCandidatePreview(id: id)
                            } else {
                                settingsPresentationSession.eventSettingsSelection
                                    .noteCandidatePreviewStopped()
                            }
                        })
                )
                .soundPacksLayoutProbe("settings.sounds.editor-slot")
            case .usage:
                standardDestination {
                    ActivityDiagnosticsView(
                        model: activityDiagnostics,
                        preferences: preferences,
                        focusedTarget: $focusedTarget,
                        onAnnouncement: onAnnouncement,
                        performPlatformAction: {
                            settingsPresentationSession.send(.performPlatformAction($0))
                        },
                        eventNoticeModel: settingsPresentationSession.dependencies.eventNoticeModel,
                        noticeNavigation: settingsPresentationSession.dependencies.noticeNavigation)
                }
            case .shortcuts:
                standardDestination {
                    ShortcutSettingsView(
                        model: globalShortcutSettings,
                        preferences: preferences,
                        focusedTarget: $focusedTarget,
                        onAnnouncement: onAnnouncement)
                }
            case .about:
                standardDestination {
                    AboutSettingsView(
                        model: aboutSettings,
                        preferences: preferences,
                        focusedTarget: $focusedTarget,
                        onAnnouncement: onAnnouncement)
                }
            }
        }
    }

    private func standardDestination<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        SettingsDestinationPage(
            destination: destination, header: { destinationTitle }, content: content)
    }

    private var destinationTitle: some View {
        Text(destination.localizedName(language: preferences.language))
            .font(SettingsAppearance.pageTitle)
            .accessibilityAddTraits(.isHeader)
            .accessibilitySortPriority(2)
            .focusable()
            .focused(
                $focusedTarget,
                equals: SettingsWindowFocusTarget.title(destination)
            )
            .accessibilityIdentifier("settings.title.\(destination.rawValue)")
            .soundPacksLayoutProbe("settings.title.\(destination.rawValue)")
    }

    private var soundScopeReturnAction: (@MainActor () -> Void)? {
        guard settingsPresentationSession.soundReturnContext != nil else { return nil }
        return { _ = settingsPresentationSession.returnToSoundScope() }
    }

    private var soundsRoute: SoundPacksWindowRoute {
        guard
            case .sounds(let route) = settingsPresentationSession.state.routeResolution.route
        else { return .overview }
        return route
    }

    private var integrationsRoute: IntegrationsSettingsRoute? {
        guard
            case .integrations(let route) = settingsPresentationSession.state.routeResolution.route
        else { return nil }
        return route
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: SettingsAppearance.sectionGap) {
            SettingsSectionCard {
                LoginItemSettingsSection(session: settingsPresentationSession)
            }
            SettingsSectionCard {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(
                        l10n.text(.settingsGeneralLanguageTitle),
                        selection: languageModeBinding
                    ) {
                        ForEach(ClaudioLanguageMode.allCases) { mode in
                            Text(mode.localizedName(language: preferences.language))
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .focused(
                        $focusedTarget,
                        equals: SettingsWindowFocusTarget.firstAction(.general)
                    )
                    .accessibilityLabel(l10n.text(.settingsGeneralLanguageTitle))
                    .accessibilityValue(
                        preferences.languageMode.localizedName(language: preferences.language)
                    )
                    .accessibilityHint(l10n.text(.settingsGeneralLanguageHint))
                    .accessibilitySortPriority(1)
                    .accessibilityIdentifier("settings.general.language")

                    if preferences.languageMode == .system {
                        Label(
                            l10n.format(
                                .settingsGeneralSystemProjection,
                                preferences.language.selfName as NSString),
                            systemImage: "globe"
                        )
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier(
                            "settings.general.language.system-projection")
                    }
                }
            }

            if !preferences.recoveryIssues.isEmpty {
                Label {
                    Text(l10n.text(.settingsGeneralPreferenceRecovery))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                }
                .padding(12)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .accessibilityIdentifier("settings.general.preference-recovery")
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
        .settingsMountIdentity(SettingsPresentationAccessibilityID.destination(.general))
    }

    private var notificationsSettings: some View {
        VStack(alignment: .leading, spacing: SettingsAppearance.sectionGap) {
            SettingsSectionCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(l10n.text(.settingsNotificationsBannerSection)).font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Toggle(isOn: eventSourcePromptBinding) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(l10n.text(.settingsNotificationsEventSourcePromptsTitle))
                                .font(.headline)
                            Text(l10n.text(.settingsNotificationsEventSourcePromptsDescription))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .frame(minHeight: 61)
                    .accessibilityValue(
                        l10n.text(
                            preferences.showsEventSourcePrompts
                                ? .settingsNotificationsEventSourcePromptsEnabled
                                : .settingsNotificationsEventSourcePromptsDisabled
                        )
                    )
                    .accessibilityIdentifier("settings.notifications.event-source-prompts")

                    settingsStatusRow(
                        title: l10n.text(.settingsNativeReceiverStatus),
                        value: l10n.text(
                            eventNoticeHealth.status == .ready
                                ? .settingsNativeReceiverReady
                                : eventNoticeHealth.status == .disabled
                                    ? .settingsNativeReceiverDisabled : .aiCueServiceUnavailable)
                    )
                    .accessibilityIdentifier("settings.notifications.receiver-health")

                    if eventNoticeHealth.status == .unavailable,
                        let failureCode = eventNoticeHealth.failureCode
                    {
                        Text(
                            l10n.format(
                                .settingsNotificationsEventSourceReceiverUnavailable,
                                failureCode)
                        )
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            "settings.notifications.event-source-receiver-unavailable")
                    }

                }
            }
            SettingsSectionCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(l10n.text(.settingsNotificationsQuietSection)).font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Toggle(isOn: focusQuietBinding) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(l10n.text(.settingsNotificationsFocusTitle))
                                .font(.headline)
                            Text(l10n.text(.settingsNotificationsFocusDescription))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .frame(minHeight: 61)
                    .focused(
                        $focusedTarget,
                        equals: SettingsWindowFocusTarget.firstAction(.notifications)
                    )
                    .accessibilityIdentifier("settings.notifications.focus-toggle")

                    settingsStatusRow(
                        title: l10n.text(.settingsNotificationsPermissionTitle),
                        value: focusAuthorizationText)
                    if dynamicQuietPolicy.presentation.focusAuthorization == .denied
                        || dynamicQuietPolicy.presentation.focusAuthorization == .restricted
                    {
                        Button(l10n.text(.settingsNativeOpenFocusSettings)) {
                            settingsPresentationSession.send(
                                .performPlatformAction(.openFocusSettings))
                        }.accessibilityIdentifier("settings.notifications.focus-settings")
                    }
                    Divider()
                    Toggle(isOn: calendarQuietBinding) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(l10n.text(.settingsNotificationsCalendarTitle))
                                .font(.headline)
                            Text(l10n.text(.settingsNotificationsCalendarDescription))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .frame(minHeight: 61)
                    .accessibilityIdentifier("settings.notifications.calendar-toggle")
                    settingsStatusRow(
                        title: l10n.text(.settingsNotificationsCalendarPermissionTitle),
                        value: calendarAuthorizationText)
                    if dynamicQuietPolicy.presentation.calendarAuthorization == .denied
                        || dynamicQuietPolicy.presentation.calendarAuthorization == .restricted
                    {
                        Button(l10n.text(.settingsNotificationsOpenCalendarPrivacy)) {
                            settingsPresentationSession.send(
                                .performPlatformAction(.openCalendarPrivacySettings))
                        }.accessibilityIdentifier("settings.notifications.calendar-privacy")
                    }
                }
            }

            SettingsSectionCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(l10n.text(.settingsNotificationsCurrentSection)).font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    settingsStatusRow(
                        title: l10n.text(.settingsNotificationsCurrentReasonTitle),
                        value: dynamicQuietCurrentReasonText)
                    settingsStatusRow(
                        title: l10n.text(.settingsNotificationsSnapshotHealthTitle),
                        value: snapshotHealthText)
                }
            }

            if settingsPresentationSession.state.platformActionFailure == .openFocusSettings
                || settingsPresentationSession.state.platformActionFailure
                    == .openCalendarPrivacySettings
            {
                FailureRow(message: l10n.text(.settingsNativeSystemSettingsFailed))
                    .accessibilityIdentifier("settings.notifications.system-settings-failure")
            }

            if dynamicQuietPolicy.presentation.hasObserverFailure,
                dynamicQuietPolicy.presentation.currentReason != .observerFailure
            {
                Label {
                    Text(l10n.text(.settingsNotificationsReasonObserverFailure))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
                .accessibilityIdentifier("settings.notifications.observer-failure")
            }

            if dynamicQuietPolicy.presentation.snapshotHealth != .current {
                Label {
                    Text(l10n.text(.settingsNotificationsPublicationFailed))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                }
                .padding(12)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .accessibilityIdentifier("settings.notifications.publication-failed")
            }

            Button(l10n.text(.settingsNotificationsOpenEvents)) {
                settingsPresentationSession.send(.route(.destination(.eventsAndSounds)))
            }
            .accessibilityIdentifier("settings.notifications.open-events")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .settingsMountIdentity(SettingsPresentationAccessibilityID.destination(.notifications))
        .onChange(of: dynamicQuietPolicy.presentation) { _ in
            onAnnouncement(dynamicQuietAnnouncement)
        }
    }

    private var focusQuietBinding: Binding<Bool> {
        Binding(
            get: { dynamicQuietPolicy.presentation.focusIsEnabled },
            set: { dynamicQuietPolicy.setFocusEnabled($0) })
    }

    private var eventSourcePromptBinding: Binding<Bool> {
        Binding(
            get: { preferences.showsEventSourcePrompts },
            set: {
                preferences.setShowsEventSourcePrompts($0)
                onAnnouncement(
                    l10n.text(
                        $0
                            ? .settingsNotificationsEventSourcePromptsEnabled
                            : .settingsNotificationsEventSourcePromptsDisabled))
            })
    }

    private var calendarQuietBinding: Binding<Bool> {
        Binding(
            get: { dynamicQuietPolicy.presentation.calendarIsEnabled },
            set: { dynamicQuietPolicy.setCalendarEnabled($0) })
    }

    private var focusAuthorizationText: String {
        switch dynamicQuietPolicy.presentation.focusAuthorization {
        case .notRequested: l10n.text(.settingsNotificationsPermissionNotRequested)
        case .authorized: l10n.text(.settingsNotificationsPermissionAuthorized)
        case .denied: l10n.text(.settingsNotificationsPermissionDenied)
        case .restricted: l10n.text(.settingsNotificationsPermissionRestricted)
        }
    }

    private var calendarAuthorizationText: String {
        switch dynamicQuietPolicy.presentation.calendarAuthorization {
        case .notRequested: l10n.text(.settingsNotificationsPermissionNotRequested)
        case .authorized: l10n.text(.settingsNotificationsPermissionAuthorized)
        case .denied: l10n.text(.settingsNotificationsPermissionDenied)
        case .restricted: l10n.text(.settingsNotificationsPermissionRestricted)
        }
    }

    private var dynamicQuietCurrentReasonText: String {
        switch dynamicQuietPolicy.presentation.currentReason {
        case .policiesDisabled: l10n.text(.settingsNotificationsReasonDisabled)
        case .permissionRequired: l10n.text(.settingsNotificationsReasonPermissionRequired)
        case .noDynamicQuiet: l10n.text(.settingsNotificationsReasonInactive)
        case .focusActive: l10n.text(.settingsNotificationsReasonFocusActive)
        case .calendarBusy: l10n.text(.settingsNotificationsReasonCalendarBusy)
        case .focusAndCalendarBusy:
            l10n.text(.settingsNotificationsReasonFocusAndCalendarBusy)
        case .observerFailure: l10n.text(.settingsNotificationsReasonObserverFailure)
        }
    }

    private var snapshotHealthText: String {
        switch dynamicQuietPolicy.presentation.snapshotHealth {
        case .current: l10n.text(.settingsNotificationsSnapshotCurrent)
        case .publicationFailed: l10n.text(.settingsNotificationsSnapshotPublicationFailed)
        case .expired: l10n.text(.settingsNotificationsSnapshotExpired)
        }
    }

    private var dynamicQuietAnnouncement: String {
        l10n.format(
            .settingsNotificationsAnnouncementSummary,
            focusAuthorizationText as NSString,
            calendarAuthorizationText as NSString,
            dynamicQuietCurrentReasonText as NSString,
            snapshotHealthText as NSString)
    }

    private func settingsStatusRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 36) {
            Text(title)
                .foregroundColor(.secondary)
            Spacer(minLength: 20)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var languageModeBinding: Binding<ClaudioLanguageMode> {
        Binding(
            get: { preferences.languageMode },
            set: {
                preferences.setLanguageMode($0)
                onAnnouncement(
                    l10n.format(
                        .settingsAnnouncementValue,
                        l10n.text(.settingsGeneralLanguageTitle) as NSString,
                        $0.localizedName(language: preferences.language) as NSString)
                )
            })
    }

    private func routeFailure(_ failure: SettingsRouteFailure) -> some View {
        Label {
            Text(settingsFailureMessage(failure))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        }
        .padding(14)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .focusable()
        .focused($focusedTarget, equals: .routeFailure(destination))
        .accessibilityIdentifier("settings.route.failure.\(destination.rawValue)")
        .settingsMountIdentity("settings.route.failure.\(destination.rawValue)")
    }

    private func settingsFailureMessage(_ failure: SettingsRouteFailure) -> String {
        switch failure {
        case .invalidSurface(let surface):
            l10n.format(.settingsRouteInvalidSurface, surface.rawValue as NSString)
        case .staleSurface(let surface):
            l10n.format(.settingsRouteStaleSurface, surface.rawValue as NSString)
        case .staleSoundScope(let scope):
            l10n.format(.settingsRouteStaleScope, scope.storedValue as NSString)
        case .staleEvent(let event):
            l10n.format(.settingsRouteStaleEvent, event.cliName as NSString)
        case .invalidSoundPackID:
            l10n.text(.settingsRouteInvalidPack)
        case .staleSoundPack(let packID):
            l10n.format(.settingsRouteStalePack, packID as NSString)
        }
    }

}
