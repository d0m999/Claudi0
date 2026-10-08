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
    package private(set) var navigationHistory = SettingsNavigationHistory()
    package var captureReadingPosition: (@MainActor () -> SettingsReadingBookmark?)?
    private var navigationFocus: SettingsNavigationFocus = .content
    private var navigationRestoration: SettingsNavigationRestoration?
    @Published package private(set) var renderedNavigationStamp: SettingsNavigationStamp?
    private var modalNavigationBlockers: Set<String> = []
    private var lastViewedSoundPackID: String?
    private var pendingViewedSoundPackRestoration: (packID: String, stamp: SettingsNavigationStamp)?
    private var activeSoundsRequestRevision: UInt64?
    private var workspaceDeletionNavigation:
        (request: WorkspaceDeletionRequest, stamp: SettingsNavigationStamp)?
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
    private var soundsDetailArbitration = SettingsSoundsDetailArbitration()
    private var isArbitratingSoundsDetail = false
    private var pendingSoundEditorPublication: SoundPacksEditorPresentation?
    private var preferenceCancellable: AnyCancellable?
    private var soundPackProjectionCancellable: AnyCancellable?
    private var soundPackEditorCancellable: AnyCancellable?
    private var aboutSurfaceCancellable: AnyCancellable?
    private var aiGenerationCancellable: AnyCancellable?
    private var eventPresentationCancellable: AnyCancellable?
    private var workspaceDeletionCancellable: AnyCancellable?
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
            soundsDetail: .overview,
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
        // No value dedup here: activation republishes an unchanged snapshot on the
        // failure→recovery path, and every emission must still reach the detail reducer.
        soundPackEditorCancellable = dependencies.soundPacksEditorOwner.$presentation
            .sink { [weak self] publication in
                MainActor.assumeIsolated {
                    self?.applySoundEditorPublication(publication)
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
                    if !self.isPerformingTransaction,
                        self.lifecycleDestination == .eventsAndSounds,
                        let current = self.navigationHistory.current
                    {
                        self.navigationHistory.replaceCurrent(
                            SettingsLocation(
                                route: self.routeResolution.route,
                                workspaceRoute: presentation.route,
                                viewedPackID: current.location.viewedPackID))
                    }
                    self.publishProjection()
                }
            }
        workspaceDeletionCancellable = eventSettingsSelection.$deletionPresentation
            .dropFirst()
            .sink { [weak self] deletion in
                MainActor.assumeIsolated { self?.synchronizeWorkspaceDeletion(deletion) }
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
        case .selectSidebar(let destination):
            return routeTransaction(.route(.destination(destination)), focus: .sidebar)
        case .navigateWorkspace(let route):
            return routeTransaction(.eventShortcut(route))
        case .goBack, .goBackFromEventAnimation:
            return traverseHistory(by: -1)
        case .goForward, .goForwardToEventAnimation:
            return traverseHistory(by: 1)
        case .setNavigationBlocked(let id, let blocked):
            if blocked {
                rememberCurrentReadingPosition()
                modalNavigationBlockers.insert(id)
            } else {
                modalNavigationBlockers.remove(id)
                if let current = navigationHistory.current, let stamp = navigationHistory.stamp {
                    navigationRestoration = SettingsNavigationRestoration(
                        stamp: stamp,
                        location: current.location, bookmark: current.bookmark, focus: .restore)
                }
            }
            publishProjection()
            return .routed
        case .rememberReading(let bookmark, let stamp):
            navigationHistory.updateBookmark(bookmark, stamp: stamp)
            return .routed
        case .destinationReady(let stamp):
            guard navigationHistory.stamp == stamp, navigationRestoration?.stamp == stamp
            else { return .unchanged }
            renderedNavigationStamp = stamp
            publishProjection()
            return .routed
        case .acknowledgeRestoration(let stamp):
            guard navigationRestoration?.stamp == stamp, navigationHistory.stamp == stamp
            else { return .unchanged }
            navigationRestoration = nil
            publishProjection()
            return .routed
        case .restoreFailureFocus(let stamp):
            guard navigationHistory.stamp == stamp, renderedNavigationStamp == stamp,
                navigationRestoration?.stamp == stamp, routeResolution.failure != nil,
                windowPhase == .key, navigationEnabled
            else { return .unchanged }
            let revision = destinationFocusRequests.requestFocus(
                .routeFailure(routeResolution.destination))
            focusDebt = SettingsFocusDebt(
                revision: revision, destination: routeResolution.destination)
            publishProjection()
            return .routed
        case .requestSoundsDetail(let destination):
            return requestSoundsDetail(destination)
        case .inspectSoundPack(let packID):
            guard lifecycleDestination == .sounds, routeResolution.failure == nil,
                availability.soundPackIDs.contains(packID)
            else { return .unchanged }
            return routeTransaction(
                .route(
                    .sounds(
                        SoundPacksWindowRoute(scope: .global, destination: .pack(packID: packID)))),
                inspecting: packID)
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
        guard navigationEnabled, let context = soundReturnContext else { return .unchanged }
        soundReturnContext = nil
        let route = context.route
        let result = send(.present(.eventShortcut(route)))
        if state.routeResolution.failure == nil, let event = route.event {
            eventSettingsSelection.restoreSoundControlFocus(event)
        }
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

    /// Local detail disclosures enter the same typed history as sidebar and deep-link requests.
    private func requestSoundsDetail(
        _ destination: SoundPacksWindowRoute.Destination
    ) -> SettingsPresentationResult {
        guard lifecycleDestination == .sounds, routeResolution.failure == nil,
            case .sounds = dependencies.soundPacksEditorOwner.presentation.mode,
            !isArbitratingSoundsDetail
        else { return .unchanged }
        let scope: PanelSoundScopeID
        let target: WorkspaceSoundWriteTarget?
        if case .sounds(let route) = routeResolution.route {
            scope = route.scope
            target = route.workspaceTarget
        } else {
            scope = .global
            target = nil
        }
        return routeTransaction(
            .route(
                .sounds(
                    SoundPacksWindowRoute(
                        scope: scope, destination: destination, workspaceTarget: target))))
    }

    private func applySoundEditorPublication(_ publication: SoundPacksEditorPresentation) {
        guard lifecycleDestination == .sounds, case .sounds(let sounds) = publication.mode,
            sounds.requestRevision == activeSoundsRequestRevision
        else { return }
        if isArbitratingSoundsDetail {
            // Effect execution synchronously republishes the owner; fold that emission into the
            // running pass instead of recursing.
            pendingSoundEditorPublication = publication
            return
        }
        restorePendingViewedSoundPack(from: publication)
        pumpSoundsDetailArbitration {
            soundsDetailArbitration.consume(publication, navigationStamp: navigationHistory.stamp)
        }
        guard pendingViewedSoundPackRestoration == nil else { return }
        if case .sounds(let sounds) = publication.mode,
            sounds.routeState != .pendingFreshSnapshot, routeResolution.failure == nil
        {
            lastViewedSoundPackID = soundsDetailArbitration.detail.capturedPackID
            synchronizeCurrentBrowsingLocation(publication: sounds)
        }
    }

    private func pumpSoundsDetailArbitration(
        _ firstPass: () -> SettingsSoundsDetailEffects
    ) {
        isArbitratingSoundsDetail = true
        defer { isArbitratingSoundsDetail = false }
        runSoundsDetailEffects(firstPass())
        while let queued = pendingSoundEditorPublication {
            pendingSoundEditorPublication = nil
            guard case .sounds(let sounds) = queued.mode,
                sounds.requestRevision == activeSoundsRequestRevision
            else { continue }
            runSoundsDetailEffects(
                soundsDetailArbitration.consume(queued, navigationStamp: navigationHistory.stamp))
        }
    }

    private func runSoundsDetailEffects(_ effects: SettingsSoundsDetailEffects) {
        guard !effects.isEmpty else { return }
        if effects.stopPreviewAndEndAISession {
            dependencies.soundPacksEditorNativeEffects.stopPreview(
                owner: dependencies.soundPacksEditorOwner)
            eventSettingsSelection.noteCandidatePreviewStopped()
            dependencies.aiCueViewModel.endSession()
            dependencies.soundPacksEditorOwner.updateAICueComposer(
                session: nil,
                generation: nil)
        }
        if effects.cancelAICueDraft {
            dependencies.soundPacksEditorOwner.cancelAICuePackDraft()
        }
        if effects.detailChanged {
            publishProjection()
        }
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
        guard navigationEnabled else { return .unchanged }
        let wasAlreadyPresented = isPresented
        if wasAlreadyPresented, request == .route(nil) {
            return .presented(wasAlreadyPresented: true)
        }
        let previousStamp = navigationHistory.stamp
        isPresented = true
        let effectiveRequest: SettingsPresentationRequest
        if request == .route(nil) {
            effectiveRequest = .route(
                .destination(dependencies.preferences.lastSettingsDestination))
        } else {
            effectiveRequest = request
        }
        let result = routeTransaction(
            effectiveRequest, focus: request == .route(nil) ? .sidebar : .content)
        if case .rejected = result {
            if navigationHistory.stamp == previousStamp { isPresented = wasAlreadyPresented }
            return result
        }
        return .presented(wasAlreadyPresented: wasAlreadyPresented)
    }

    private func routeTransaction(
        _ request: SettingsPresentationRequest,
        focus: SettingsNavigationFocus = .content,
        restoring entry: SettingsNavigationEntry? = nil,
        inspecting viewedPackID: String? = nil
    ) -> SettingsPresentationResult {
        guard navigationEnabled else { return .unchanged }
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
            requestedRoute = .events(scope: route.scope, event: route.event)
            eventShortcut = route
        }

        let candidate = makeRequestedLocation(requestedRoute, eventShortcut: eventShortcut)
        let requestedLocation =
            entry?.location
            ?? SettingsLocation(
                route: candidate.route,
                workspaceRoute: candidate.workspaceRoute,
                viewedPackID: viewedPackID ?? candidate.viewedPackID)
        let resolved = requestedLocation.resolve(
            availability: availability,
            config: dependencies.eventSettingsModel.configState.resolvedConfig)
        if let failure = resolved.failure {
            switch failure {
            case .invalidSurface, .invalidSoundPackID: return .rejected(failure)
            default: break
            }
        }
        if entry == nil { rememberCurrentReadingPosition() }
        pendingViewedSoundPackRestoration = nil
        workspaceDeletionNavigation = nil
        if requestedRoute.destination != .sounds { soundReturnContext = nil }
        if entry == nil { navigationHistory.visit(requestedLocation) }
        renderedNavigationStamp = nil
        soundsDetailArbitration.invalidateNavigationTransition()
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
        navigationFocus = focus
        if resolved.failure != nil, resolved.destination == .sounds {
            // The destination view unmounts behind the failure explanation; drop its detail.
            soundsDetailArbitration.reset()
        }
        if resolved.failure == nil {
            applyRoute(
                requestedRoute, eventShortcut: requestedLocation.workspaceRoute ?? eventShortcut)
        }
        if let previousLifecycleDestination, resolved.failure != nil {
            deactivate(previousLifecycleDestination)
            lifecycleDestination = nil
        }
        if case .staleSoundScope = resolved.failure, let pinned = requestedLocation.workspaceRoute {
            eventSettingsSelection.select(
                EventSettingsWindowRoute(
                    scope: pinned.scope, event: pinned.event,
                    workspaceTarget: pinned.workspaceTarget,
                    unavailableRequestedScopeStoredValue: pinned.scope.storedValue,
                    detail: pinned.detail))
            eventSettingsSelection.markCurrentScopeUnavailable(preservingDetail: true)
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
                requestsFocus: focus == .content)
            restoreViewedSoundPack(
                requestedLocation.viewedPackID,
                in: dependencies.soundPacksEditorOwner.presentation)
        }
        explicitRouteRequestRevision &+= 1
        if focus == .sidebar || focus == .restore {
            destinationFocusRequests.cancelPendingRequest()
            integrationsFocusCoordinator.cancelPendingRequest()
            eventSettingsSelection.cancelNavigationFocus()
            focusDebt = nil
        } else {
            let focusDebtRevision = destinationFocusRequests.requestFocus(
                returnsToAnimationEntry ? .eventAnimationEntry : nil)
            focusDebt = SettingsFocusDebt(
                revision: focusDebtRevision, destination: resolved.destination)
        }
        if let stamp = navigationHistory.stamp {
            navigationRestoration = SettingsNavigationRestoration(
                stamp: stamp, location: requestedLocation,
                bookmark: entry?.bookmark ?? .init(), focus: focus)
        }
        if resolved.failure == nil {
            dependencies.preferences.setLastSettingsDestination(resolved.destination)
        }
        synchronizePendingSoundPackAnnouncement()
        if let failure = resolved.failure {
            return .rejected(failure)
        }
        return .routed
    }

    private func restoreViewedSoundPack(
        _ viewedPackID: String?, in publication: SoundPacksEditorPresentation
    ) {
        guard let viewedPackID,
            case .sounds(let sounds) = publication.mode,
            sounds.draft == nil,
            let action = sounds.packs.first(where: { $0.id == viewedPackID })?.inspectAction
        else { return }
        _ = dependencies.soundPacksEditorOwner.send(.invoke(action))
    }

    private func restorePendingViewedSoundPack(from publication: SoundPacksEditorPresentation) {
        guard let pending = pendingViewedSoundPackRestoration else { return }
        guard pending.stamp == navigationHistory.stamp,
            pending.packID == navigationHistory.current?.location.viewedPackID
        else {
            pendingViewedSoundPackRestoration = nil
            return
        }
        guard case .sounds(let sounds) = publication.mode else { return }
        if sounds.selectedPack?.id == pending.packID {
            pendingViewedSoundPackRestoration = nil
            return
        }
        guard publication.library.isFresh else { return }
        // Owner publications arrive before its @Published property is committed. Invoke the
        // matching incoming capability; a reentrant activation may still be queued by the owner.
        restoreViewedSoundPack(pending.packID, in: publication)
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
            applySoundsRoute(soundRoute)
        case .destination(.sounds):
            applySoundsRoute(.overview)
        case .destination, .notifications:
            break
        }
    }

    private func applySoundsRoute(_ soundRoute: SoundPacksWindowRoute) {
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
    }

    private func synchronizeWorkspaceDeletion(_ deletion: WorkspaceDeletionPresentation) {
        if let request = deletion.pending, let stamp = navigationHistory.stamp,
            let target = navigationHistory.current?.location.workspaceRoute?.workspaceTarget,
            target.id == request.target.id, target.directory == request.target.directory
        {
            workspaceDeletionNavigation = (request, stamp)
        }
        guard case .succeeded(let target) = deletion.feedback,
            let transaction = workspaceDeletionNavigation,
            transaction.request.target == target,
            navigationHistory.stamp == transaction.stamp,
            isPresented
        else { return }
        workspaceDeletionNavigation = nil
        // The writer already removed the captured rule. Convert only its current browsing
        // entry; a navigation during the transaction revokes this presentation permission.
        let route = EventSettingsWindowRoute(scope: .global)
        routeResolution = resolveSettingsRoute(
            .events(scope: .global, event: nil), availability: availability)
        navigationHistory.replaceCurrent(
            SettingsLocation(route: routeResolution.route, workspaceRoute: route),
            matching: transaction.stamp)
        lifecycleDestination = .eventsAndSounds
        activateEventsEditor(
            eventPresentation: eventPresentation,
            aiSession: nil, candidateGenerationID: nil)
        if let restoration = navigationRestoration, restoration.stamp == transaction.stamp {
            navigationRestoration = SettingsNavigationRestoration(
                stamp: restoration.stamp,
                location: navigationHistory.current!.location, bookmark: .init(),
                focus: restoration.focus)
        }
        publishProjection()
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
        navigationHistory.replaceCurrent(SettingsLocation(route: routeResolution.route))
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
        // A history failure is tied to its captured directory, including when the shared
        // selection has since rebound the same UUID. Health publications cannot adopt it.
        if routeResolution.failure != nil,
            let captured = navigationHistory.current?.location.workspaceRoute?.workspaceTarget,
            captured != projection.writeTarget
        {
            return
        }
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
            if soundRoute.destination == .history {
                dependencies.aiCueViewModel.coordinator.markHistoryRead()
            }
            activeSoundsRequestRevision = explicitRouteRequestRevision + 1
            _ = dependencies.soundPacksEditorOwner.send(
                .activate(
                    .sounds(
                        route: soundRoute,
                        requestRevision: explicitRouteRequestRevision + 1)))
            dependencies.soundPacksEditorOwner.updateAICueComposer(
                session: dependencies.aiCueViewModel.session,
                generation: dependencies.aiCueViewModel.generation)
        case .general, .notifications, .usage, .shortcuts, .about:
            break
        }
    }

    #if DEBUG
    package var integrationRequestedFocusTarget: IntegrationDestinationFocusTarget? {
        integrationsFocusCoordinator.requestedTarget
    }
    #endif

    private func requestIntegrationsFocus(route: SettingsRoute) {
        if case .integrations(let route) = route,
            let host = HostID.productVisibleCases.first(where: { $0.surfaceID == route.surface })
        {
            integrationsFocusCoordinator.requestFocus(
                route.level == .diagnostics ? .connectionRow(.connectionStatus) : .agent(host))
        } else {
            dependencies.integrationsModel.restorePreferredHost()
            integrationsFocusCoordinator.requestFocus(
                dependencies.integrationsModel.selectedHost.map(
                    IntegrationDestinationFocusTarget.agent))
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
        windowIsClosing: Bool = false,
        preservingAcceptedDeletion: Bool = false
    ) {
        switch destination {
        case .integrations:
            dependencies.integrationsModel.noteWindowKeyState(false)
            dependencies.integrationsModel.noteWindowVisibility(false)
        case .eventsAndSounds:
            eventSettingsSelection.leaveDestination(
                preservingAcceptedDeletion: preservingAcceptedDeletion)
            dependencies.soundPacksEditorNativeEffects.handleLifecycle(
                windowIsClosing ? .settingsWindowWillClose : .eventsViewDisappeared,
                owner: dependencies.soundPacksEditorOwner)
            dependencies.aiCueViewModel.endSession()
            dependencies.soundPacksEditorOwner.updateAICueComposer(
                session: nil,
                generation: nil)
        case .sounds:
            activeSoundsRequestRevision = nil
            eventSettingsSelection.leaveDestination()
            dependencies.soundPacksEditorNativeEffects.handleLifecycle(
                windowIsClosing ? .settingsWindowWillClose : .soundsViewDisappeared,
                owner: dependencies.soundPacksEditorOwner)
            dependencies.aiCueViewModel.endSession()
            dependencies.soundPacksEditorOwner.cancelAICuePackDraft()
            dependencies.soundPacksEditorOwner.updateAICueComposer(
                session: nil,
                generation: nil)
            // The unmounted destination drops its detail exactly like the retired view-local
            // state; the next activation re-derives it from the retained route.
            soundsDetailArbitration.reset()
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
        navigationHistory.clear()
        pendingViewedSoundPackRestoration = nil
        workspaceDeletionNavigation = nil
        navigationRestoration = nil
        renderedNavigationStamp = nil
        modalNavigationBlockers.removeAll()
        if let lifecycleDestination {
            deactivate(lifecycleDestination, windowIsClosing: true)
        } else if eventSettingsSelection.hasAcceptedDeletion {
            eventSettingsSelection.leaveDestination()
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
        guard
            priorAvailability != availability
                || navigationHistory.current?.location.workspaceRoute != nil
                || routeResolution.destination == .sounds
        else {
            synchronizePendingSoundPackAnnouncement()
            publishProjection()
            return
        }
        let previousResolution = routeResolution
        let location =
            navigationHistory.current?.location ?? SettingsLocation(route: previousResolution.route)
        let resolved = location.resolve(
            availability: availability,
            config: dependencies.eventSettingsModel.configState.resolvedConfig)
        guard resolved != previousResolution else {
            synchronizePendingSoundPackAnnouncement()
            publishProjection()
            return
        }

        let wasPerformingTransaction = isPerformingTransaction
        isPerformingTransaction = true
        routeResolution = resolved
        if previousResolution.failure == nil, resolved.failure != nil {
            if let lifecycleDestination {
                let preservesDeletion =
                    eventSettingsSelection.hasAcceptedDeletion
                    && workspaceDeletionNavigation?.stamp == navigationHistory.stamp
                deactivate(lifecycleDestination, preservingAcceptedDeletion: preservesDeletion)
            }
            lifecycleDestination = nil
            if location.workspaceRoute != nil {
                eventSettingsSelection.markCurrentScopeUnavailable(preservingDetail: true)
            }
        }
        if previousResolution.failure != nil, resolved.failure == nil, isPresented {
            applyRoute(resolved.route, eventShortcut: location.workspaceRoute)
            if let lifecycleDestination,
                lifecycleDestination != resolved.destination
            {
                deactivate(lifecycleDestination)
            }
            lifecycleDestination = resolved.destination
            if let packID = location.viewedPackID, let stamp = navigationHistory.stamp {
                pendingViewedSoundPackRestoration = (packID, stamp)
            }
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
            canGoForwardToEventAnimation: navigationHistory.canGoForward,
            chrome: chromeProjection,
            navigationRestoration: navigationRestoration,
            navigationFocus: navigationFocus,
            explicitRouteRequestRevision: explicitRouteRequestRevision,
            soundsDetail: soundsDetailArbitration.detail,
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
        canGoForwardToEventAnimation: Bool = false,
        chrome: SettingsChromeProjection? = nil,
        navigationRestoration: SettingsNavigationRestoration? = nil,
        navigationFocus: SettingsNavigationFocus = .content,
        explicitRouteRequestRevision: UInt64,
        soundsDetail: SoundPacksSettingsDetail,
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
            chrome: chrome
                ?? SettingsChromeProjection(
                    destination: routeResolution.destination,
                    title: routeResolution.destination.localizedName(
                        language: preferenceSnapshot.language),
                    navigationEnabled: true, canGoBack: false, canGoForward: false),
            navigationRestoration: navigationRestoration,
            navigationFocus: navigationFocus,
            canGoForwardToEventAnimation: canGoForwardToEventAnimation,
            explicitRouteRequestRevision: explicitRouteRequestRevision,
            soundsDetail: soundsDetail,
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

// Browsing remains in this session; native chrome only captures and consumes reading requests.
extension SettingsPresentationSession {
    private var navigationEnabled: Bool {
        modalNavigationBlockers.isEmpty
            && !eventPresentation.credentialSheetIsPresented
            && eventSettingsSelection.deletionPresentation.pending == nil
            && dependencies.integrationsModel.pendingConfirmation == nil
            && dependencies.soundPacksEditorOwner.presentation.pendingConfirmation == nil
    }

    private func rememberCurrentReadingPosition() {
        guard let stamp = navigationHistory.stamp, let bookmark = captureReadingPosition?() else {
            return
        }
        navigationHistory.updateBookmark(bookmark, stamp: stamp)
    }

    private func makeRequestedLocation(
        _ route: SettingsRoute, eventShortcut: EventSettingsWindowRoute?
    ) -> SettingsLocation {
        let config = dependencies.eventSettingsModel.configState.resolvedConfig
        let workspaceRoute: EventSettingsWindowRoute?
        switch route {
        case .events(let scope, let event):
            let target = scope.workspaceID.flatMap { id in
                config.workspaceRules.first(where: { $0.id == id }).map(
                    WorkspaceSoundWriteTarget.init(rule:))
            }
            if let shortcut = eventShortcut {
                workspaceRoute = EventSettingsWindowRoute(
                    scope: shortcut.scope, event: shortcut.event,
                    workspaceTarget: shortcut.workspaceTarget ?? target,
                    unavailableRequestedScopeStoredValue: shortcut
                        .unavailableRequestedScopeStoredValue,
                    detail: shortcut.detail)
            } else {
                workspaceRoute = EventSettingsWindowRoute(
                    scope: scope, event: event, workspaceTarget: target)
            }
        case .destination(.eventsAndSounds):
            workspaceRoute = EventSettingsWindowRoute(
                scope: dependencies.eventSettingsModel.selectedSoundScope,
                event: eventSettingsSelection.route.event,
                workspaceTarget: dependencies.eventSettingsModel.selectedWorkspaceTarget)
        default: workspaceRoute = nil
        }
        let viewedPackID: String?
        if route.destination == .sounds {
            if case .sounds(let requested) = route, let packID = requested.destinationPackID {
                viewedPackID = packID
            } else {
                viewedPackID = nil
            }
        } else {
            viewedPackID = nil
        }
        return SettingsLocation(
            route: route, workspaceRoute: workspaceRoute, viewedPackID: viewedPackID)
    }

    private func traverseHistory(by delta: Int) -> SettingsPresentationResult {
        guard navigationEnabled else { return .unchanged }
        rememberCurrentReadingPosition()
        guard let entry = navigationHistory.move(by: delta) else { return .unchanged }
        let request: SettingsPresentationRequest =
            entry.location.workspaceRoute.map {
                .eventShortcut($0)
            } ?? .route(entry.location.route)
        return routeTransaction(request, focus: .restore, restoring: entry)
    }

    private func synchronizeCurrentBrowsingLocation(publication: SoundsEditorPresentation) {
        guard let current = navigationHistory.current, current.location.destination == .sounds
        else { return }
        // Preserve a pending/stale identity; refresh fallback is not a browsing choice.
        if let packID = current.location.viewedPackID,
            !publication.packs.contains(where: { $0.id == packID }),
            publication.draft?.packID != packID
        {
            return
        }
        let previous = current.location.route
        let scope: PanelSoundScopeID
        let target: WorkspaceSoundWriteTarget?
        if case .sounds(let route) = previous {
            scope = route.scope; target = route.workspaceTarget
        } else {
            scope = .global; target = nil
        }
        let destination: SoundPacksWindowRoute.Destination
        switch soundsDetailArbitration.detail {
        case .overview: destination = .overview
        case .pack(let id):
            if case .sounds(let previousRoute) = previous,
                case .editEvent(let requestedID, let event) = previousRoute.destination,
                requestedID == id
            {
                destination = .editEvent(packID: id, event: event)
            } else {
                destination = .pack(packID: id)
            }
        case .draft(let id): destination = .draft(packID: id)
        case .history: destination = .history
        case .event(let packID, let event):
            if case .sounds(let route) = previous, route.isCopyAndApply,
                route.destinationPackID == packID
            {
                destination = .copyAndApply(packID: packID, event: event)
            } else {
                destination = .editEvent(packID: packID, event: event)
            }
        case .audio(let packID): destination = .audio(packID: packID)
        case .service: destination = .service
        case .panel: destination = .panel
        }
        let route: SettingsRoute = .sounds(
            SoundPacksWindowRoute(scope: scope, destination: destination, workspaceTarget: target))
        // Generic roots keep their compatibility route; detail routes follow visible identity.
        if case .sounds = routeResolution.route {
            routeResolution = .init(route: route, failure: nil)
        }
        navigationHistory.replaceCurrent(
            SettingsLocation(
                route: routeResolution.route,
                viewedPackID: soundsDetailArbitration.detail.capturedPackID))
        publishProjection()
    }

    private var chromeProjection: SettingsChromeProjection {
        let l10n = ClaudioL10n(language: preferenceSnapshot.language)
        var title = routeResolution.destination.localizedName(language: preferenceSnapshot.language)
        switch routeResolution.destination {
        case .notifications:
            if routeResolution.route == .notifications(.eventAnimation) {
                title = l10n.text(.eventAnimationTitle)
            }
        case .sounds:
            switch soundsDetailArbitration.detail {
            case .overview, .pack, .draft: break
            case .history: title = l10n.text(.soundsHistory)
            case .event(_, let event):
                title = localizedEventName(event, language: preferenceSnapshot.language)
            case .audio: title = l10n.text(.settingsNativeAudioFiles)
            case .service: title = l10n.text(.settingsNativeAIServices)
            case .panel: title = l10n.text(.settingsNativePanelDisplaySet)
            }
        case .integrations:
            if case .integrations(let route) = routeResolution.route,
                let host = HostID(rawValue: route.surface.rawValue)
            {
                title =
                    route.level == .diagnostics
                    ? l10n.format(.integrationsAutoDiagnosticsTitle, host.displayName)
                    : host.displayName
            }
        case .eventsAndSounds:
            switch eventPresentation.route.detail {
            case .configuration: break
            case .workspaces: title = l10n.text(.settingsNativeWorkspaces)
            case .scope(let target):
                title =
                    dependencies.eventSettingsModel.workspaceRules.first(where: {
                        $0.id == target.id
                    })?.name ?? l10n.text(.workspaceUnavailable)
            }
        default: break
        }
        return SettingsChromeProjection(
            destination: routeResolution.destination, title: title,
            navigationEnabled: navigationEnabled,
            canGoBack: navigationEnabled && navigationHistory.canGoBack,
            canGoForward: navigationEnabled && navigationHistory.canGoForward)
    }
}
