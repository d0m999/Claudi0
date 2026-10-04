import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SoundPacksWindow
import SwiftUI

/// Unified Settings navigation shell shared by production and the compiled harness.
@MainActor
package struct SettingsDestinationContentView: View {
    @ObservedObject var preferences: ClaudioPreferences
    @ObservedObject var dynamicQuietPolicy: DynamicQuietPolicyController
    @ObservedObject var settingsPresentationSession: SettingsPresentationSession
    @ObservedObject var activityDiagnostics: ActivityDiagnosticsModel
    @ObservedObject var eventNoticeHealth: EventNoticeHealthStore
    @ObservedObject var globalShortcutSettings: GlobalShortcutSettingsModel
    @ObservedObject var aboutSettings: AboutSettingsModel
    @ObservedObject private var eventAnimations: EventAnimationResources
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
        _eventAnimations = ObservedObject(wrappedValue: dependencies.eventAnimations)
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
        routeSlot
            .environment(
                \.settingsSuppressesAutomaticContentFocus,
                settingsPresentationSession.state.navigationFocus != .content
            )
            .settingsContentFocusSection()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(SettingsAppearance.background(colorScheme))
            .soundPacksLayoutProbe("settings.content")
            .font(SettingsAppearance.font(.body))
            .foregroundStyle(SettingsAppearance.text(colorScheme))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.presentation.content")
            .task(id: settingsPresentationSession.state.navigationRestoration?.stamp) {
                guard let request = settingsPresentationSession.state.navigationRestoration else {
                    return
                }
                if request.focus != .content { focusedTarget = nil }
                await Task.yield()
                guard !Task.isCancelled else { return }
                _ = settingsPresentationSession.send(.destinationReady(request.stamp))
            }
            .task(id: settingsPresentationSession.state.focusDebt) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                synchronizeDestinationFocus(settingsPresentationSession.state)
            }
    }

    private func synchronizeDestinationFocus(_ state: SettingsPresentationState) {
        guard state.windowPhase == .key,
            let debt = state.focusDebt,
            settingsPresentationSession.destinationFocusRequests.consumeRequest(debt.revision)
        else { return }
        if let requested = settingsPresentationSession.destinationFocusRequests.requestedTarget {
            focusedTarget = requested
        } else if let target = settingsWindowRequestedFocusTarget(resolution: state.routeResolution)
        {
            focusedTarget = target
        }
        _ = settingsPresentationSession.send(.acknowledgeFocus(revision: debt.revision))
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
                    onNavigateWorkspace: {
                        settingsPresentationSession.send(.navigateWorkspace($0))
                    },
                    onConfigureSound: {
                        settingsPresentationSession.editScopeSound($0)
                    },
                    onAudibilityInputsChanged: onEventAudibilityInputsChanged,
                    onAnnouncement: onAnnouncement)
            case .notifications:
                standardDestination {
                    if case .notifications(.eventAnimation) = settingsPresentationSession.state
                        .routeResolution.route
                    {
                        EventAnimationSettingsView(session: settingsPresentationSession)
                    } else {
                        notificationsSettings
                    }
                }
            case .sounds:
                SettingsSoundsDestinationView(
                    aiCueViewModel: aiCueViewModel,
                    editorOwner: soundPacksEditorOwner,
                    route: soundsRoute,
                    routeRequestRevision:
                        settingsPresentationSession.state.explicitRouteRequestRevision,
                    detail: settingsPresentationSession.state.soundsDetail,
                    onDetailIntent: {
                        settingsPresentationSession.send(.requestSoundsDetail($0))
                    },
                    onInspectPack: { settingsPresentationSession.send(.inspectSoundPack($0)) },
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
        SettingsDestinationPage(destination: destination, content: content)
    }

    private var destinationTitle: some View { EmptyView() }

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
            SettingsSectionCard(padding: 0) {
                LoginItemSettingsSection(session: settingsPresentationSession)
            }
            SettingsSectionCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsControlRow(title: l10n.text(.settingsGeneralLanguageTitle)) {
                        SettingsNativePopUp(
                            l10n.text(.settingsGeneralLanguageTitle),
                            selection: languageModeBinding,
                            options: ClaudioLanguageMode.allCases.map {
                                SettingsMenuOption(
                                    $0, $0.localizedName(language: preferences.language))
                            }, identifier: "settings.general.language"
                        )
                        .fixedSize(horizontal: true, vertical: false)
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
                        .soundPacksLayoutProbe("settings.general.language.control")
                    }
                    .soundPacksLayoutProbe("settings.general.language.row")
                    .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)

                    if preferences.languageMode == .system {
                        Label(
                            l10n.format(
                                .settingsGeneralSystemProjection,
                                preferences.language.selfName as NSString),
                            systemImage: "globe"
                        )
                        .font(SettingsAppearance.font(.caption))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
                        .padding(.bottom, SettingsAppearance.controlRowVerticalPadding)
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
            SettingsSectionCard(padding: 0) {
                EventAnimationActionButton(
                    title: l10n.text(.eventAnimationTitle),
                    identifier: "settings.notifications.event-animation",
                    value: l10n.text(effectiveAnimationStyle.localizationKey),
                    requestsFocus: focusedTarget == .eventAnimationEntry,
                    action: {
                        settingsPresentationSession.send(.route(.notifications(.eventAnimation)))
                    }
                ) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(l10n.text(.eventAnimationTitle))
                            Text(l10n.text(.eventAnimationDescription))
                                .font(SettingsAppearance.font(.caption))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text(l10n.text(effectiveAnimationStyle.localizationKey))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.animation.effective-style")
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                    .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
                    .padding(.vertical, SettingsAppearance.controlRowVerticalPadding)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: SettingsAppearance.multilineControlRowHeight)
                .focused($focusedTarget, equals: .eventAnimationEntry)
            }
            SettingsSectionCard(title: l10n.text(.settingsNotificationsBannerSection), padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Toggle(isOn: eventSourcePromptBinding) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(l10n.text(.settingsNotificationsEventSourcePromptsTitle))
                                .font(SettingsAppearance.font(.body))
                            Text(l10n.text(.settingsNotificationsEventSourcePromptsDescription))
                                .font(SettingsAppearance.font(.caption))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                    .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
                    .padding(.vertical, SettingsAppearance.controlRowVerticalPadding)
                    .frame(minHeight: SettingsAppearance.multilineControlRowHeight)
                    .accessibilityValue(
                        l10n.text(
                            preferences.showsEventSourcePrompts
                                ? .settingsNotificationsEventSourcePromptsEnabled
                                : .settingsNotificationsEventSourcePromptsDisabled
                        )
                    )
                    .accessibilityIdentifier("settings.notifications.event-source-prompts")

                    Divider().padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
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
                        .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
                        .padding(.bottom, SettingsAppearance.controlRowVerticalPadding)
                        .accessibilityIdentifier(
                            "settings.notifications.event-source-receiver-unavailable")
                    }

                }
            }
            SettingsSectionCard(title: l10n.text(.settingsNotificationsQuietSection), padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Toggle(isOn: focusQuietBinding) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(l10n.text(.settingsNotificationsFocusTitle))
                                .font(SettingsAppearance.font(.body))
                            Text(l10n.text(.settingsNotificationsFocusDescription))
                                .font(SettingsAppearance.font(.caption))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                    .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
                    .padding(.vertical, SettingsAppearance.controlRowVerticalPadding)
                    .frame(minHeight: SettingsAppearance.multilineControlRowHeight)
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
                        }
                        .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
                        .padding(.bottom, SettingsAppearance.controlRowVerticalPadding)
                        .accessibilityIdentifier("settings.notifications.focus-settings")
                    }
                    Divider().padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
                    Toggle(isOn: calendarQuietBinding) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(l10n.text(.settingsNotificationsCalendarTitle))
                                .font(SettingsAppearance.font(.body))
                            Text(l10n.text(.settingsNotificationsCalendarDescription))
                                .font(SettingsAppearance.font(.caption))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                    .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
                    .padding(.vertical, SettingsAppearance.controlRowVerticalPadding)
                    .frame(minHeight: SettingsAppearance.multilineControlRowHeight)
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
                        }
                        .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
                        .padding(.bottom, SettingsAppearance.controlRowVerticalPadding)
                        .accessibilityIdentifier("settings.notifications.calendar-privacy")
                    }
                }
            }

            SettingsSectionCard(title: l10n.text(.settingsNotificationsCurrentSection), padding: 0)
            {
                VStack(alignment: .leading, spacing: 0) {
                    settingsStatusRow(
                        title: l10n.text(.settingsNotificationsCurrentReasonTitle),
                        value: dynamicQuietCurrentReasonText)
                    Divider().padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
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
        .task(id: "\(preferences.eventAnimation.effectiveStyle.rawValue)-\(colorScheme)") {
            await eventAnimations.load(
                preferences.eventAnimation.effectiveStyle, dark: colorScheme == .dark)
        }
        .onChange(of: dynamicQuietPolicy.presentation) { _ in
            onAnnouncement(dynamicQuietAnnouncement)
        }
    }

    private var effectiveAnimationStyle: EventAnimationStyle {
        eventAnimations.effectiveStyle(for: preferences.eventAnimation, dark: colorScheme == .dark)
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
        .padding(.vertical, SettingsAppearance.controlRowVerticalPadding)
        .frame(minHeight: SettingsAppearance.controlRowHeight)
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
        VStack(alignment: .leading, spacing: SettingsAppearance.informationGap) {
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
            if let location = settingsPresentationSession.navigationHistory.current?.location,
                let directory = location.workspaceRoute?.workspaceTarget?.directory
                    ?? {
                        if case .sounds(let route) = location.route {
                            return route.workspaceTarget?.directory
                        }; return nil
                    }()
            {
                Text(directory.path).font(SettingsAppearance.font(.technical))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.route.captured-directory")
            }
            if case .staleSoundScope = failure {
                Button(l10n.text(.workspaceChooseDefaultGroup)) {
                    if destination == .sounds {
                        settingsPresentationSession.send(.route(.sounds(.overview)))
                    } else {
                        settingsPresentationSession.send(
                            .navigateWorkspace(EventSettingsWindowRoute(scope: .global)))
                    }
                }
                .settingsMountIdentity("workspace.choose-default-group")
            }
        }
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
