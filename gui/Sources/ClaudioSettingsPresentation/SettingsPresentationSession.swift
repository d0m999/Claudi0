import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Combine
import Foundation
import SoundPacksWindow

/// Single presentation-transaction owner for the retained Settings window. Domain facts remain
/// in their existing owners; this session owns only typed routing, focus/lifecycle debt and the
/// presentation-side orchestration that connects those owners.
@MainActor
package final class SettingsPresentationSession: ObservableObject {
    @Published
    package private(set) var state: SettingsPresentationState

    @Published package private(set) var soundReturnContext: SettingsSoundReturnContext?

    let dependencies: SettingsPresentationDependencies
    let actions: SettingsPresentationActions
    let eventSettingsSelection: EventSettingsWindowSelection
    let integrationsFocusCoordinator: IntegrationDestinationFocusCoordinator
    /// Single owner of the shell's destination focus handshake: every route transaction issues
    /// exactly one request; an explicit payload (today only the event-animation entry's return
    /// focus) overrides the pure policy in `settingsWindowRequestedFocusTarget`.
    package let destinationFocusRequests = FocusRequestCoordinator<SettingsWindowFocusTarget>()
    package let animationPreview = EventAnimationPreviewSession()

    private var preferenceSnapshot: ClaudioPreferenceSnapshot
    private var loginProjection: LoginItemSettingsProjection
    private var availability: SettingsRouteAvailability
    private var routeResolution: SettingsRouteResolution
    private var explicitRouteRequestRevision: UInt64 = 0
    private var focusDebt: SettingsFocusDebt?
    private var windowPhase: SettingsWindowPhase = .hidden
    private var activeDestination: SettingsDestination?
    private var lifecycleDestination: SettingsDestination?
    private var platformActionFailure: SettingsPlatformAction?
    private var pendingAnnouncement: SettingsPresentationAnnouncement?
    private var pendingSoundPackOwnerAnnouncement: SoundPackEditorAnnouncement?
    private var pendingSoundPackAnnouncementID: SoundPackEditorAnnouncement.ID?
    private var eventPresentation: SettingsEventPresentationState
    private var nextAnnouncementID: UInt64 = 0
    private var presentationRevision: UInt64 = 0
    private var isPresented = false
    private var isPerformingTransaction = false
    private var isPublishingProjection = false
    private var projectionRepublishRequested = false
    private var preferenceCancellable: AnyCancellable?
    private var soundPackProjectionCancellable: AnyCancellable?
    private var aboutSurfaceCancellable: AnyCancellable?
    private var aiGenerationCancellable: AnyCancellable?
    private var eventPresentationCancellable: AnyCancellable?
    private var soundScopeSelectionCancellable: AnyCancellable?
    private var integrationsSelectionCancellable: AnyCancellable?

    package init(
        dependencies: SettingsPresentationDependencies,
        actions: SettingsPresentationActions
    ) {
        self.dependencies = dependencies
        self.actions = actions
        eventSettingsSelection = EventSettingsWindowSelection()
        integrationsFocusCoordinator = IntegrationDestinationFocusCoordinator()
        eventPresentation = eventSettingsSelection.presentationState
        preferenceSnapshot = dependencies.preferences.snapshot
        loginProjection = dependencies.loginItemSettings.projection
        let initialShell = SettingsSoundPackShellProjection(
            editorPresentation: dependencies.soundPacksEditorOwner.presentation,
            sourceRows: dependencies.hostIntegrations.content.sourceRows,
            config: dependencies.eventSettingsModel.configState.resolvedConfig)
        availability = initialShell.availability
        pendingSoundPackOwnerAnnouncement = initialShell.pendingAnnouncement
        let initialRoute = SettingsRoute.destination(
            dependencies.preferences.lastSettingsDestination)
        routeResolution = resolveSettingsRoute(
            initialRoute, availability: initialShell.availability)
        state = Self.makeState(
            routeResolution: routeResolution,
            explicitRouteRequestRevision: 0,
            focusDebt: nil,
            windowPhase: .hidden,
            activeDestination: nil,
            eventPresentation: eventPresentation,
            preferenceSnapshot: preferenceSnapshot,
            loginProjection: loginProjection,
            platformActionFailure: nil,
            pendingAnnouncement: nil,
            presentationRevision: 0)

        let workspaceConfig = dependencies.eventSettingsModel
        dependencies.soundPacksEditorOwner.configureWorkspacePackWriter { target, packID in
            workspaceConfig.changeWorkspace(.pack(target, packID))
                ? .success(()) : .failure(workspaceConfig.workspaceError ?? .configFailure)
        }

        preferenceCancellable = dependencies.preferences.$snapshot
            .sink { [weak self] snapshot in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.animationPreview.isActive,
                        self.preferenceSnapshot.eventAnimation.style
                            != snapshot.eventAnimation.style
                    {
                        self.animationPreview.replay()
                    }
                    self.preferenceSnapshot = snapshot
                    self.publishProjection()
                }
            }
        soundPackProjectionCancellable = settingsSoundPackShellProjections(
            editor: dependencies.soundPacksEditorOwner,
            hostIntegrations: dependencies.hostIntegrations,
            configModel: dependencies.eventSettingsModel
        ).sink { [weak self] projection in
            MainActor.assumeIsolated {
                self?.applyAvailabilityProjection(projection)
            }
        }
        aboutSurfaceCancellable = dependencies.hostIntegrations.$safeSurfaceFacts
            .removeDuplicates()
            .sink { [weak self] surfaceFacts in
                MainActor.assumeIsolated {
                    self?.dependencies.aboutSettings.replaceSurfaceFacts(surfaceFacts)
                }
            }
        aiGenerationCancellable = dependencies.aiCueViewModel.$session
            .combineLatest(dependencies.aiCueViewModel.$generation)
            .removeDuplicates { lhs, rhs in
                lhs.0 == rhs.0 && lhs.1 == rhs.1
            }
            .dropFirst()
            .sink { [weak self] projection in
                MainActor.assumeIsolated {
                    guard let self, !self.isPerformingTransaction else { return }
                    switch self.lifecycleDestination {
                    case .sounds:
                        self.dependencies.soundPacksEditorOwner.updateAICueComposer(
                            session: projection.0,
                            generation: projection.1)
                    case .eventsAndSounds:
                        // The old Events route remains a compatibility seam for already-open
                        // legacy sessions. Package-scoped sessions belong exclusively to Sounds.
                        guard projection.0?.packID == nil else { return }
                        self.activateEventsEditor(
                            eventPresentation: self.eventPresentation,
                            aiSession: projection.0,
                            candidateGenerationID: projection.1?.id)
                    default:
                        break
                    }
                }
            }
        eventPresentationCancellable = eventSettingsSelection.$presentationState
            .dropFirst()
            .sink { [weak self] presentation in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let previousPresentation = self.eventPresentation
                    self.eventPresentation = presentation
                    if !self.isPerformingTransaction,
                        self.lifecycleDestination == .eventsAndSounds,
                        presentation.route != previousPresentation.route
                            || presentation.routeRequestRevision
                                != previousPresentation.routeRequestRevision
                    {
                        // A valid deep link hands selection to the Events destination. Keep the
                        // shell in step when that owner deliberately selects another scope (for
                        // example, Default Group after deletion), rather than revalidating the
                        // deleted link forever on later config publications.
                        if case .events(let requestedScope, _) = self.routeResolution.route,
                            requestedScope == previousPresentation.route.scope,
                            presentation.route.scope != previousPresentation.route.scope,
                            presentation.route.unavailableRequestedScopeStoredValue == nil
                        {
                            self.routeResolution = resolveSettingsRoute(
                                .events(
                                    scope: presentation.route.scope,
                                    event: presentation.route.event),
                                availability: self.availability)
                        }
                        self.activateEventsEditor(
                            eventPresentation: presentation,
                            aiSession: self.dependencies.aiCueViewModel.session,
                            candidateGenerationID: self.dependencies.aiCueViewModel.generation?.id)
                    }
                    self.publishProjection()
                }
            }
        let soundScopeSelection = dependencies.eventSettingsModel.soundScopeSelection
        let initialSoundScopeProjection = soundScopeSelection.projection
        soundScopeSelectionCancellable = soundScopeSelection.$projection
            .removeDuplicates { previous, next in
                previous.scope == next.scope && previous.writeTarget == next.writeTarget
                    && previous.staleness == next.staleness
                    && previous.isAvailable == next.isAvailable
            }
            .scan((previous: initialSoundScopeProjection, current: initialSoundScopeProjection)) {
                pair, projection in
                (previous: pair.current, current: projection)
            }
            .dropFirst()
            .sink { [weak self] pair in
                MainActor.assumeIsolated {
                    self?.synchronizeEventSoundScope(pair.current, previous: pair.previous)
                }
            }
        integrationsSelectionCancellable = dependencies.integrationsModel.$selectedHost
            .dropFirst()
            .sink { [weak self] host in
                MainActor.assumeIsolated {
                    self?.synchronizeIntegrationSelection(host)
                }
            }
    }

    @discardableResult
    package func send(
        _ command: SettingsPresentationCommand
    ) -> SettingsPresentationResult {
        switch command {
        case .present(let request):
            return present(request)
        case .route(let route):
            return routeTransaction(.route(route))
        case .setLanguageMode(let languageMode):
            dependencies.preferences.setLanguageMode(languageMode)
            return .routed
        case .setLoginItemEnabled(let enabled):
            setLoginItemEnabled(enabled)
            return .routed
        case .refreshLoginItemState:
            refreshLoginItem()
            publishProjection()
            return .routed
        case .retryLoginItemOperation:
            retryLoginItemOperation()
            return .routed
        case .performPlatformAction(let action):
            return .platformAction(perform(action))
        case .eventAudibilityInputsChanged:
            actions.notifyEventAudibilityInputsChanged()
            return .routed
        case .announceDestinationUpdate(let sentence):
            guard !sentence.isEmpty else { return .unchanged }
            enqueueAnnouncement(.destinationUpdate(sentence))
            return .routed
        case .windowPhaseChanged(let phase):
            return changeWindowPhase(to: phase)
        case .acknowledgeFocus(let revision):
            guard focusDebt?.revision == revision else { return .unchanged }
            focusDebt = nil
            publishProjection()
            return .routed
        case .acknowledgeAnnouncement(let id, let didPost):
            return acknowledgePendingAnnouncement(id: id, didPost: didPost)
        case .windowWillClose:
            return closeWindow()
        }
    }

    package func editScopeSound(_ route: SoundPacksWindowRoute) {
        guard route.scope == eventSettingsSelection.route.scope else { return }
        soundReturnContext = SettingsSoundReturnContext(
            route: EventSettingsWindowRoute(
                scope: route.scope, event: route.editTarget?.event,
                workspaceTarget: route.workspaceTarget))
        _ = send(.route(.sounds(route)))
    }

    @discardableResult
    package func returnToSoundScope() -> SettingsPresentationResult {
        guard let context = soundReturnContext else { return .unchanged }
        soundReturnContext = nil
        let route = context.route
        dependencies.eventSettingsModel.reloadConfigForPinnedRoute()
        guard
            route.workspaceTargetIsCurrent(
                in: dependencies.eventSettingsModel.configState.resolvedConfig),
            availability.eventScopes.contains(route.scope)
        else {
            if let lifecycleDestination { deactivate(lifecycleDestination) }
            lifecycleDestination = nil
            activeDestination = .eventsAndSounds
            eventSettingsSelection.select(route)
            eventSettingsSelection.markCurrentScopeUnavailable()
            routeResolution = SettingsRouteResolution(
                route: .events(scope: route.scope, event: route.event),
                failure: .staleSoundScope(route.scope))
            publishProjection()
            return .rejected(.staleSoundScope(route.scope))
        }
        let result = send(.present(.eventShortcut(route)))
        if let event = route.event { eventSettingsSelection.restoreSoundControlFocus(event) }
        return result
    }

    private func refreshLoginItem() {
        let previousProjection = loginProjection
        dependencies.loginItemSettings.refresh()
        loginProjection = dependencies.loginItemSettings.projection
        guard loginProjection != previousProjection else { return }
        guard loginProjection.registration != previousProjection.registration else {
            publishProjection()
            return
        }
        enqueueAnnouncement(.loginItemStatus(loginProjection.registration))
    }

    private func setLoginItemEnabled(_ enabled: Bool) {
        dependencies.loginItemSettings.setEnabled(enabled)
        loginProjection = dependencies.loginItemSettings.projection
        enqueueLoginItemResult()
    }

    private func retryLoginItemOperation() {
        dependencies.loginItemSettings.retryFailedOperation()
        loginProjection = dependencies.loginItemSettings.projection
        enqueueLoginItemResult()
    }

    @discardableResult
    private func perform(_ action: SettingsPlatformAction) -> SettingsPlatformActionResult {
        let result = actions.perform(action)
        platformActionFailure = result == .performed ? nil : action
        if result != .performed {
            enqueueAnnouncement(.platformAction(action, result))
        } else {
            publishProjection()
        }
        return result
    }

    #if DEBUG
    package func replaceAvailabilityForTesting(_ replacement: SettingsRouteAvailability) {
        applyAvailability(replacement)
    }
    #endif

    private func present(_ request: SettingsPresentationRequest) -> SettingsPresentationResult {
        let wasAlreadyPresented = isPresented
        if wasAlreadyPresented, request == .route(nil) {
            return .presented(wasAlreadyPresented: true)
        }
        isPresented = true
        let effectiveRequest: SettingsPresentationRequest
        if request == .route(nil) {
            effectiveRequest = .route(
                .destination(dependencies.preferences.lastSettingsDestination))
        } else {
            effectiveRequest = request
        }
        let result = routeTransaction(effectiveRequest)
        if case .rejected = result {
            return result
        }
        return .presented(wasAlreadyPresented: wasAlreadyPresented)
    }

    private func routeTransaction(
        _ request: SettingsPresentationRequest
    ) -> SettingsPresentationResult {
        let requestedRoute: SettingsRoute
        let eventShortcut: EventSettingsWindowRoute?
        switch request {
        case .route(let route):
            guard let route else { return .unchanged }
            requestedRoute = route
            eventShortcut = nil
        case .eventShortcut(let requested):
            if requested.workspaceTarget != nil {
                dependencies.eventSettingsModel.reloadConfigForPinnedRoute()
            }
            let route: EventSettingsWindowRoute
            if requested.workspaceTargetIsCurrent(
                in: dependencies.eventSettingsModel.configState.resolvedConfig)
            {
                route = requested
            } else {
                route = EventSettingsWindowRoute(
                    scope: requested.scope, event: requested.event,
                    workspaceTarget: requested.workspaceTarget,
                    unavailableRequestedScopeStoredValue: requested.scope.storedValue)
            }
            requestedRoute =
                route.unavailableRequestedScopeStoredValue == nil
                ? .events(scope: route.scope, event: route.event)
                : .destination(.eventsAndSounds)
            eventShortcut = route
        }

        if requestedRoute.destination != .sounds { soundReturnContext = nil }
        let resolved = resolveSettingsRoute(requestedRoute, availability: availability)
        isPerformingTransaction = true
        defer {
            isPerformingTransaction = false
            publishProjection()
        }

        let previousLifecycleDestination = lifecycleDestination
        let returnsToAnimationEntry =
            routeResolution.route == .notifications(.eventAnimation)
            && requestedRoute == .destination(.notifications)
        routeResolution = resolved
        if resolved.failure == nil {
            applyRoute(requestedRoute, eventShortcut: eventShortcut)
        }
        activeDestination = resolved.destination
        if case .notifications(.eventAnimation) = resolved.route, resolved.failure == nil {
            animationPreview.activate()
        } else {
            animationPreview.deactivate()
        }
        if resolved.failure == nil {
            if let previousLifecycleDestination,
                previousLifecycleDestination != resolved.destination
            {
                deactivate(previousLifecycleDestination)
            }
            lifecycleDestination = resolved.destination
            activate(
                resolved.destination,
                route: requestedRoute,
                requestsFocus: true)
        }
        explicitRouteRequestRevision &+= 1
        let focusDebtRevision = destinationFocusRequests.requestFocus(
            returnsToAnimationEntry ? .eventAnimationEntry : nil)
        focusDebt = SettingsFocusDebt(
            revision: focusDebtRevision,
            destination: resolved.destination)
        if resolved.failure == nil {
            dependencies.preferences.setLastSettingsDestination(resolved.destination)
        }
        synchronizePendingSoundPackAnnouncement()
        if let failure = resolved.failure {
            return .rejected(failure)
        }
        return .routed
    }

    private func applyRoute(
        _ route: SettingsRoute,
        eventShortcut: EventSettingsWindowRoute?
    ) {
        switch route {
        case .integrations(let route):
            if let host = HostID.productVisibleCases.first(where: { $0.surfaceID == route.surface })
            {
                _ = dependencies.integrationsModel.selectHost(host)
            }
        case .events(let scope, let event):
            let eventRoute = eventShortcut ?? EventSettingsWindowRoute(scope: scope, event: event)
            let routeChanged = eventSettingsSelection.route != eventRoute
            eventSettingsSelection.select(eventRoute)
            if routeChanged {
                dependencies.soundPacksEditorNativeEffects.stopPreview(
                    owner: dependencies.soundPacksEditorOwner)
                dependencies.aiCueViewModel.endSession()
                dependencies.soundPacksEditorOwner.updateAICueComposer(
                    session: nil,
                    generation: nil)
            }
            if eventRoute.unavailableRequestedScopeStoredValue == nil {
                let model = dependencies.eventSettingsModel
                let rebindsExplicitSelection =
                    eventRoute.workspaceTarget != nil
                    && model.selectedSoundScope == eventRoute.scope
                    && model.selectedWorkspaceTarget != eventRoute.workspaceTarget
                model.selectSoundScope(
                    eventRoute.scope, rebindSelectedWorkspace: rebindsExplicitSelection)
                if !eventRoute.workspaceTargetIsCurrent(in: model.configState.resolvedConfig)
                    || (eventRoute.workspaceTarget != nil
                        && model.selectedWorkspaceTarget != eventRoute.workspaceTarget)
                {
                    eventSettingsSelection.markCurrentScopeUnavailable()
                }
            }
        case .destination(.eventsAndSounds):
            // C1：通用入口让保留路由跟随共享 owner 的当前选择；route.scope 已与 owner 一致时
            // 原样保留整条 route（含 route.event），生命周期恢复语义不变。
            let eventRoute =
                eventShortcut
                ?? EventSettingsWindowRoute(
                    scope: dependencies.eventSettingsModel.selectedSoundScope)
            if eventShortcut != nil || eventSettingsSelection.route.scope != eventRoute.scope {
                let routeChanged = eventSettingsSelection.route != eventRoute
                eventSettingsSelection.select(eventRoute)
                if routeChanged {
                    dependencies.soundPacksEditorNativeEffects.stopPreview(
                        owner: dependencies.soundPacksEditorOwner)
                    dependencies.aiCueViewModel.endSession()
                    dependencies.soundPacksEditorOwner.updateAICueComposer(
                        session: nil,
                        generation: nil)
                }
            }
        case .sounds(let soundRoute):
            let requestedTarget = soundRoute.editTarget
            let currentSession = dependencies.aiCueViewModel.session
            let sessionMatches: Bool = {
                guard let currentSession, let requestedTarget else { return false }
                return currentSession.packID == requestedTarget.packID
                    && currentSession.event == requestedTarget.event
            }()
            let hasDraft: Bool = {
                guard
                    case .sounds(let sounds) = dependencies.soundPacksEditorOwner.presentation.mode
                else { return false }
                return sounds.draft != nil
            }()
            let routeRequiresCopyGuidance = soundRoute.isCopyAndApply
            if (currentSession != nil || hasDraft)
                && (!sessionMatches || routeRequiresCopyGuidance)
            {
                dependencies.soundPacksEditorNativeEffects.stopPreview(
                    owner: dependencies.soundPacksEditorOwner)
                dependencies.aiCueViewModel.endSession()
                dependencies.soundPacksEditorOwner.cancelAICuePackDraft()
                dependencies.soundPacksEditorOwner.updateAICueComposer(
                    session: nil,
                    generation: nil)
            }
        case .destination, .notifications:
            break
        }
    }

    private func synchronizeIntegrationSelection(_ host: HostID?) {
        // The destination's selected host is a domain fact owned by the integrations model.
        // Outside a route transaction, keep the retained route in step: the previous host's
        // details page closes through the validator instead of rendering a target the
        // selection has left.
        guard !isPerformingTransaction,
            lifecycleDestination == .integrations,
            case .integrations(let route) = routeResolution.route,
            host?.surfaceID != route.surface
        else { return }
        routeResolution = resolveSettingsRoute(
            .integrations(IntegrationsSettingsRoute(surface: host?.surfaceID ?? route.surface)),
            availability: availability)
        publishProjection()
    }

    private func synchronizeEventSoundScope(
        _ projection: SoundScopeSelection.Projection,
        previous: SoundScopeSelection.Projection
    ) {
        // Explicit route transactions retain their event and captured target. Outside those
        // transactions, a shared selection change must reach the retained page immediately.
        // Use the publisher payload because @Published delivers it before its storage changes.
        guard !isPerformingTransaction else { return }
        let selectionChanged =
            previous.scope != projection.scope || previous.writeTarget != projection.writeTarget
        let retainedRoute = eventSettingsSelection.route
        if !selectionChanged {
            // A health update belongs to the shared selection, not an explicit request for a
            // different captured directory. Keep the request's event and detail when it matches.
            guard retainedRoute.scope == projection.scope,
                retainedRoute.workspaceTarget == nil
                    || retainedRoute.workspaceTarget == projection.writeTarget
            else { return }
            if case .scope(let target) = retainedRoute.detail, target != projection.writeTarget {
                return
            }
        }
        let route = EventSettingsWindowRoute(
            scope: projection.scope,
            event: selectionChanged ? nil : retainedRoute.event,
            workspaceTarget:
                selectionChanged ? projection.writeTarget : retainedRoute.workspaceTarget,
            unavailableRequestedScopeStoredValue:
                projection.isAvailable && projection.staleness == .current
                ? nil : projection.scope.storedValue,
            detail: selectionChanged ? .configuration : retainedRoute.detail)
        guard eventSettingsSelection.route != route else { return }
        if lifecycleDestination == .eventsAndSounds {
            dependencies.soundPacksEditorNativeEffects.stopPreview(
                owner: dependencies.soundPacksEditorOwner)
            dependencies.aiCueViewModel.endSession()
            dependencies.soundPacksEditorOwner.updateAICueComposer(session: nil, generation: nil)
        }
        if selectionChanged {
            eventSettingsSelection.select(
                route, preservingSoundsAIState: lifecycleDestination == .sounds)
        } else if route.unavailableRequestedScopeStoredValue != nil {
            eventSettingsSelection.markCurrentScopeUnavailable(
                preservingDetail: true, preservingSoundsAIState: lifecycleDestination == .sounds)
        } else {
            eventSettingsSelection.clearUnavailableScope(preservingDetail: true)
        }
    }

    private func activate(
        _ destination: SettingsDestination,
        route: SettingsRoute,
        requestsFocus: Bool
    ) {
        switch destination {
        case .integrations:
            if requestsFocus {
                requestIntegrationsFocus(route: route)
            }
            synchronizeIntegrationsLifecycle()
        case .eventsAndSounds:
            if eventSettingsSelection.route.scope.workspaceID != nil,
                !availability.eventScopes.contains(eventSettingsSelection.route.scope)
            {
                eventSettingsSelection.markCurrentScopeUnavailable()
            }
            if requestsFocus {
                eventSettingsSelection.requestInitialFocus(
                    scopes: eventSettingsFocusScopes, for: route)
            }
            activateEventsEditor()
        case .sounds:
            let soundRoute: SoundPacksWindowRoute =
                if case .sounds(let requested) = route { requested } else { .overview }
            _ = dependencies.soundPacksEditorOwner.send(
                .activate(
                    .sounds(
                        route: soundRoute,
                        requestRevision: explicitRouteRequestRevision + (requestsFocus ? 1 : 0))))
            dependencies.soundPacksEditorOwner.updateAICueComposer(
                session: dependencies.aiCueViewModel.session,
                generation: dependencies.aiCueViewModel.generation)
        case .general, .notifications, .usage, .shortcuts, .about:
            break
        }
    }

    private func requestIntegrationsFocus(route: SettingsRoute) {
        if case .integrations(let route) = route,
            let host = HostID.productVisibleCases.first(where: { $0.surfaceID == route.surface })
        {
            integrationsFocusCoordinator.requestFocus(.agent(host))
        } else {
            dependencies.integrationsModel.restorePreferredHost()
            integrationsFocusCoordinator.requestFocus(.title)
        }
    }

    private func activateEventsEditor() {
        activateEventsEditor(
            eventPresentation: eventPresentation,
            aiSession: dependencies.aiCueViewModel.session,
            candidateGenerationID: dependencies.aiCueViewModel.generation?.id)
    }

    private func activateEventsEditor(
        eventPresentation: SettingsEventPresentationState,
        aiSession: AICueComposerSession?,
        candidateGenerationID: UUID?
    ) {
        let route =
            if let aiSession {
                EventSettingsWindowRoute(scope: aiSession.scope, event: aiSession.event)
            } else {
                eventPresentation.route
            }
        _ = dependencies.soundPacksEditorOwner.send(
            .activate(
                .events(
                    route: route,
                    requestRevision: eventSettingsSelection.routeRequestRevision,
                    candidateGenerationID: candidateGenerationID)))
    }

    private func deactivate(
        _ destination: SettingsDestination,
        windowIsClosing: Bool = false
    ) {
        switch destination {
        case .integrations:
            dependencies.integrationsModel.noteWindowKeyState(false)
            dependencies.integrationsModel.noteWindowVisibility(false)
        case .eventsAndSounds:
            eventSettingsSelection.leaveDestination()
            dependencies.soundPacksEditorNativeEffects.handleLifecycle(
                windowIsClosing ? .settingsWindowWillClose : .eventsViewDisappeared,
                owner: dependencies.soundPacksEditorOwner)
            dependencies.aiCueViewModel.endSession()
            dependencies.soundPacksEditorOwner.updateAICueComposer(
                session: nil,
                generation: nil)
        case .sounds:
            eventSettingsSelection.leaveDestination()
            dependencies.soundPacksEditorNativeEffects.handleLifecycle(
                windowIsClosing ? .settingsWindowWillClose : .soundsViewDisappeared,
                owner: dependencies.soundPacksEditorOwner)
            dependencies.aiCueViewModel.endSession()
            dependencies.soundPacksEditorOwner.cancelAICuePackDraft()
            dependencies.soundPacksEditorOwner.updateAICueComposer(
                session: nil,
                generation: nil)
        case .usage:
            dependencies.eventNoticeModel.closeReading(.diagnostics)
        case .general, .notifications, .shortcuts, .about:
            break
        }
    }

    private func changeWindowPhase(
        to phase: SettingsWindowPhase
    ) -> SettingsPresentationResult {
        guard isPresented else { return .unchanged }
        guard windowPhase != phase else { return .unchanged }
        isPerformingTransaction = true
        windowPhase = phase
        if phase == .hidden || phase == .closing {
            animationPreview.deactivate()
        } else if routeResolution.route == .notifications(.eventAnimation) {
            animationPreview.activate()
        }
        if phase == .key {
            refreshLoginItem()
        }
        synchronizeIntegrationsLifecycle()
        synchronizePendingSoundPackAnnouncement()
        isPerformingTransaction = false
        publishProjection()
        return .routed
    }

    private func closeWindow() -> SettingsPresentationResult {
        guard isPresented else { return .unchanged }
        isPerformingTransaction = true
        windowPhase = .closing
        animationPreview.deactivate()
        if let lifecycleDestination {
            deactivate(lifecycleDestination, windowIsClosing: true)
        }
        soundReturnContext = nil
        activeDestination = nil
        lifecycleDestination = nil
        isPresented = false
        windowPhase = .hidden
        focusDebt = nil
        destinationFocusRequests.cancelPendingRequest()
        if pendingSoundPackAnnouncementID != nil {
            pendingSoundPackAnnouncementID = nil
            pendingAnnouncement = nil
        }
        isPerformingTransaction = false
        publishProjection()
        return .closed
    }

    private func applyAvailabilityProjection(_ projection: SettingsSoundPackShellProjection) {
        pendingSoundPackOwnerAnnouncement = projection.pendingAnnouncement
        applyAvailability(projection.availability)
    }

    private func applyAvailability(_ replacement: SettingsRouteAvailability) {
        let priorAvailability = availability
        availability = replacement
        guard priorAvailability != availability else {
            synchronizePendingSoundPackAnnouncement()
            publishProjection()
            return
        }
        let previousResolution = routeResolution
        let resolved = resolveSettingsRoute(
            previousResolution.route,
            availability: availability)
        guard resolved != previousResolution else {
            synchronizePendingSoundPackAnnouncement()
            publishProjection()
            return
        }

        let wasPerformingTransaction = isPerformingTransaction
        isPerformingTransaction = true
        routeResolution = resolved
        if previousResolution.failure != nil, resolved.failure == nil, isPresented {
            applyRoute(resolved.route, eventShortcut: nil)
            if let lifecycleDestination,
                lifecycleDestination != resolved.destination
            {
                deactivate(lifecycleDestination)
            }
            lifecycleDestination = resolved.destination
            activate(resolved.destination, route: resolved.route, requestsFocus: false)
        }
        isPerformingTransaction = wasPerformingTransaction
        synchronizePendingSoundPackAnnouncement()
        publishProjection()
    }

    private func synchronizeIntegrationsLifecycle() {
        let visible =
            lifecycleDestination == .integrations
            && (windowPhase == .visibleNonKey || windowPhase == .key)
        dependencies.integrationsModel.noteWindowVisibility(visible)
        dependencies.integrationsModel.noteWindowKeyState(visible && windowPhase == .key)
    }

    private var eventSettingsFocusScopes: [PanelSoundScopeID] {
        panelSoundScopePresentations(
            sourceRows: dependencies.hostIntegrations.content.sourceRows,
            config: dependencies.eventSettingsModel.configState.resolvedConfig,
            language: preferenceSnapshot.language
        ).map(\.scope)
    }

    private func enqueueLoginItemResult() {
        if let failure = loginProjection.failure {
            enqueueAnnouncement(.loginItemFailure(failure))
        } else {
            enqueueAnnouncement(.loginItemStatus(loginProjection.registration))
        }
    }

    private func enqueueAnnouncement(
        _ meaning: SettingsPresentationAnnouncement.Meaning,
        soundPackID: SoundPackEditorAnnouncement.ID? = nil
    ) {
        nextAnnouncementID &+= 1
        pendingAnnouncement = SettingsPresentationAnnouncement(
            id: nextAnnouncementID,
            meaning: meaning)
        pendingSoundPackAnnouncementID = soundPackID
        publishProjection()
    }

    private func synchronizePendingSoundPackAnnouncement() {
        let isEligible =
            windowPhase == .key && activeDestination == .sounds
            && lifecycleDestination == .sounds && routeResolution.failure == nil
        guard isEligible else {
            if pendingSoundPackAnnouncementID != nil {
                pendingSoundPackAnnouncementID = nil
                pendingAnnouncement = nil
            }
            return
        }
        guard pendingAnnouncement == nil,
            let soundAnnouncement = pendingSoundPackOwnerAnnouncement
        else { return }
        let request = soundPacksEditorAccessibilityRequest(
            soundAnnouncement,
            language: preferenceSnapshot.language)
        enqueueAnnouncement(
            .soundPacks(request),
            soundPackID: soundAnnouncement.id)
    }

    private func acknowledgePendingAnnouncement(
        id: UInt64,
        didPost: Bool
    ) -> SettingsPresentationResult {
        guard didPost, pendingAnnouncement?.id == id else { return .unchanged }
        let soundPackID = pendingSoundPackAnnouncementID
        pendingAnnouncement = nil
        pendingSoundPackAnnouncementID = nil
        if let soundPackID {
            _ = dependencies.soundPacksEditorOwner.send(
                .acknowledgeAnnouncement(id: soundPackID, didPost: true))
        }
        synchronizePendingSoundPackAnnouncement()
        publishProjection()
        return .routed
    }

    private func publishProjection() {
        guard !isPerformingTransaction else {
            projectionRepublishRequested = true
            return
        }
        guard !isPublishingProjection else {
            projectionRepublishRequested = true
            return
        }
        isPublishingProjection = true
        defer { isPublishingProjection = false }

        repeat {
            projectionRepublishRequested = false
            let candidate = makeState(presentationRevision: presentationRevision)
            if candidate != state {
                presentationRevision &+= 1
                state = makeState(presentationRevision: presentationRevision)
            }
        } while projectionRepublishRequested
    }

    private func makeState(presentationRevision: UInt64) -> SettingsPresentationState {
        Self.makeState(
            routeResolution: routeResolution,
            explicitRouteRequestRevision: explicitRouteRequestRevision,
            focusDebt: focusDebt,
            windowPhase: windowPhase,
            activeDestination: activeDestination,
            eventPresentation: eventPresentation,
            preferenceSnapshot: preferenceSnapshot,
            loginProjection: loginProjection,
            platformActionFailure: platformActionFailure,
            pendingAnnouncement: pendingAnnouncement,
            presentationRevision: presentationRevision)
    }

    private static func makeState(
        routeResolution: SettingsRouteResolution,
        explicitRouteRequestRevision: UInt64,
        focusDebt: SettingsFocusDebt?,
        windowPhase: SettingsWindowPhase,
        activeDestination: SettingsDestination?,
        eventPresentation: SettingsEventPresentationState,
        preferenceSnapshot: ClaudioPreferenceSnapshot,
        loginProjection: LoginItemSettingsProjection,
        platformActionFailure: SettingsPlatformAction?,
        pendingAnnouncement: SettingsPresentationAnnouncement?,
        presentationRevision: UInt64
    ) -> SettingsPresentationState {
        SettingsPresentationState(
            routeResolution: routeResolution,
            explicitRouteRequestRevision: explicitRouteRequestRevision,
            focusDebt: focusDebt,
            windowPhase: windowPhase,
            activeDestination: activeDestination,
            eventPresentation: eventPresentation,
            language: preferenceSnapshot.language,
            loginItemRegistration: loginProjection.registration,
            loginItemFailure: loginProjection.failure,
            platformActionFailure: platformActionFailure,
            pendingAnnouncement: pendingAnnouncement,
            presentationRevision: presentationRevision)
    }
}
