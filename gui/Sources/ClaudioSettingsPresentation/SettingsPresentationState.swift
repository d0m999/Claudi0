import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation
import SoundPacksWindow

package enum SettingsWindowPhase: Equatable, Sendable {
    case hidden
    case visibleNonKey
    case key
    case closing
}

package struct SettingsFocusDebt: Equatable, Sendable {
    package let revision: UInt64
    package let destination: SettingsDestination
}

package enum EventSettingsDestinationPreviewState: Sendable, Equatable {
    case idle
    case running(generation: UInt64)
}

package enum EventSettingsDestinationAISessionState: Sendable, Equatable {
    case idle
    case active(scope: PanelSoundScopeID, event: Event)
}

package struct SettingsEventPresentationState: Equatable, Sendable {
    package let route: EventSettingsWindowRoute
    package let routeRequestRevision: UInt64
    package let focusRequestRevision: UInt64
    package let focusTarget: EventSettingsFocusTarget?
    package let previewState: EventSettingsDestinationPreviewState
    package let previewStopRequestRevision: UInt64
    package let aiSessionState: EventSettingsDestinationAISessionState
    package let aiSessionEndRequestRevision: UInt64
    package let credentialSheetIsPresented: Bool
    package let playingCandidateID: UUID?
}

package enum SettingsPresentationRequest: Equatable, Sendable {
    case route(SettingsRoute?)
    case eventShortcut(EventSettingsWindowRoute)
}

package enum SettingsPresentationCommand: Equatable, Sendable {
    case present(SettingsPresentationRequest)
    case route(SettingsRoute)
    case selectSidebar(SettingsDestination)
    case navigateWorkspace(EventSettingsWindowRoute)
    case dismissAbout(SettingsNavigationStamp)
    case goBack
    case goForward
    case setNavigationBlocked(id: String, blocked: Bool)
    case rememberReading(SettingsReadingBookmark, stamp: SettingsNavigationStamp)
    case destinationReady(SettingsNavigationStamp)
    case restoreFailureFocus(SettingsNavigationStamp)
    case acknowledgeRestoration(SettingsNavigationStamp)
    case goBackFromEventAnimation
    case goForwardToEventAnimation
    /// A detail intent enters the same browsing history as a sidebar or explicit deep link.
    case requestSoundsDetail(SoundPacksWindowRoute.Destination)
    case inspectSoundPack(String)
    case setLanguageMode(ClaudioLanguageMode)
    case setLoginItemEnabled(Bool)
    case refreshLoginItemState
    case retryLoginItemOperation
    case performPlatformAction(SettingsPlatformAction)
    case eventAudibilityInputsChanged
    case announceDestinationUpdate(String)
    case windowPhaseChanged(SettingsWindowPhase)
    case acknowledgeFocus(revision: UInt64)
    case acknowledgeAnnouncement(id: UInt64, didPost: Bool)
    case windowWillClose
}

package enum SettingsPresentationResult: Equatable, Sendable {
    case unchanged
    case presented(wasAlreadyPresented: Bool)
    case routed
    case rejected(SettingsRouteFailure)
    case platformAction(SettingsPlatformActionResult)
    case closed
}

/// Immutable projection for the retained Settings presentation transaction. Domain facts stay in
/// their existing owners; this value contains only route/lifecycle state, render-ready values and
/// semantic delivery debt.
package struct SettingsPresentationState: Equatable, Sendable {
    // Published values share only immutable storage. A later projection creates new storage,
    // preserving old snapshots without expanding route copies into every capturing view.
    private let storage: Storage
    package var routeResolution: SettingsRouteResolution { storage.routeResolution }
    package var chrome: SettingsChromeProjection { storage.chrome }
    package var navigationRestoration: SettingsNavigationRestoration? {
        storage.navigationRestoration
    }
    package var navigationFocus: SettingsNavigationFocus { storage.navigationFocus }
    package var canGoForwardToEventAnimation: Bool { storage.canGoForwardToEventAnimation }
    package var explicitRouteRequestRevision: UInt64 { storage.explicitRouteRequestRevision }
    package var soundsDetail: SoundPacksSettingsDetail { storage.soundsDetail }
    package var focusDebt: SettingsFocusDebt? { storage.focusDebt }
    package var windowPhase: SettingsWindowPhase { storage.windowPhase }
    package var activeDestination: SettingsDestination? { storage.activeDestination }
    package var eventPresentation: SettingsEventPresentationState { storage.eventPresentation }
    package var language: ClaudioAppLanguage { storage.language }
    package var loginItemRegistration: LoginItemRegistrationState { storage.loginItemRegistration }
    package var loginItemFailure: LoginItemOperationFailure? { storage.loginItemFailure }
    package let platformActionFailure: SettingsPlatformAction?
    package var pendingAnnouncement: SettingsPresentationAnnouncement? {
        storage.pendingAnnouncement
    }
    package var presentationRevision: UInt64 { storage.presentationRevision }

    package var canGoBackFromEventAnimation: Bool {
        routeResolution.route == .notifications(.eventAnimation) && routeResolution.failure == nil
            && chrome.canGoBack
    }

    package init(
        routeResolution: SettingsRouteResolution,
        chrome: SettingsChromeProjection,
        navigationRestoration: SettingsNavigationRestoration?,
        navigationFocus: SettingsNavigationFocus,
        canGoForwardToEventAnimation: Bool,
        explicitRouteRequestRevision: UInt64,
        soundsDetail: SoundPacksSettingsDetail,
        focusDebt: SettingsFocusDebt?,
        windowPhase: SettingsWindowPhase,
        activeDestination: SettingsDestination?,
        eventPresentation: SettingsEventPresentationState,
        language: ClaudioAppLanguage,
        loginItemRegistration: LoginItemRegistrationState,
        loginItemFailure: LoginItemOperationFailure?,
        platformActionFailure: SettingsPlatformAction?,
        pendingAnnouncement: SettingsPresentationAnnouncement?,
        presentationRevision: UInt64
    ) {
        self.platformActionFailure = platformActionFailure
        storage = Storage(
            routeResolution: routeResolution,
            chrome: chrome,
            navigationRestoration: navigationRestoration,
            navigationFocus: navigationFocus,
            canGoForwardToEventAnimation: canGoForwardToEventAnimation,
            explicitRouteRequestRevision: explicitRouteRequestRevision,
            soundsDetail: soundsDetail,
            focusDebt: focusDebt,
            windowPhase: windowPhase,
            activeDestination: activeDestination,
            eventPresentation: eventPresentation,
            language: language,
            loginItemRegistration: loginItemRegistration,
            loginItemFailure: loginItemFailure,
            pendingAnnouncement: pendingAnnouncement,
            presentationRevision: presentationRevision
        )
    }

    /// Storage is never mutated or published separately from the value projection.
    private final class Storage: Equatable, Sendable {
        let routeResolution: SettingsRouteResolution
        let chrome: SettingsChromeProjection
        let navigationRestoration: SettingsNavigationRestoration?
        let navigationFocus: SettingsNavigationFocus
        let canGoForwardToEventAnimation: Bool
        let explicitRouteRequestRevision: UInt64
        let soundsDetail: SoundPacksSettingsDetail
        let focusDebt: SettingsFocusDebt?
        let windowPhase: SettingsWindowPhase
        let activeDestination: SettingsDestination?
        let eventPresentation: SettingsEventPresentationState
        let language: ClaudioAppLanguage
        let loginItemRegistration: LoginItemRegistrationState
        let loginItemFailure: LoginItemOperationFailure?
        let pendingAnnouncement: SettingsPresentationAnnouncement?
        let presentationRevision: UInt64

        init(
            routeResolution: SettingsRouteResolution,
            chrome: SettingsChromeProjection,
            navigationRestoration: SettingsNavigationRestoration?,
            navigationFocus: SettingsNavigationFocus,
            canGoForwardToEventAnimation: Bool,
            explicitRouteRequestRevision: UInt64,
            soundsDetail: SoundPacksSettingsDetail,
            focusDebt: SettingsFocusDebt?,
            windowPhase: SettingsWindowPhase,
            activeDestination: SettingsDestination?,
            eventPresentation: SettingsEventPresentationState,
            language: ClaudioAppLanguage,
            loginItemRegistration: LoginItemRegistrationState,
            loginItemFailure: LoginItemOperationFailure?,
            pendingAnnouncement: SettingsPresentationAnnouncement?,
            presentationRevision: UInt64
        ) {
            self.routeResolution = routeResolution
            self.chrome = chrome
            self.navigationRestoration = navigationRestoration
            self.navigationFocus = navigationFocus
            self.canGoForwardToEventAnimation = canGoForwardToEventAnimation
            self.explicitRouteRequestRevision = explicitRouteRequestRevision
            self.soundsDetail = soundsDetail
            self.focusDebt = focusDebt
            self.windowPhase = windowPhase
            self.activeDestination = activeDestination
            self.eventPresentation = eventPresentation
            self.language = language
            self.loginItemRegistration = loginItemRegistration
            self.loginItemFailure = loginItemFailure
            self.pendingAnnouncement = pendingAnnouncement
            self.presentationRevision = presentationRevision
        }

        static func == (lhs: Storage, rhs: Storage) -> Bool {
            lhs === rhs
                || (lhs.routeResolution == rhs.routeResolution
                    && lhs.chrome == rhs.chrome
                    && lhs.navigationRestoration == rhs.navigationRestoration
                    && lhs.navigationFocus == rhs.navigationFocus
                    && lhs.canGoForwardToEventAnimation == rhs.canGoForwardToEventAnimation
                    && lhs.explicitRouteRequestRevision == rhs.explicitRouteRequestRevision
                    && lhs.soundsDetail == rhs.soundsDetail
                    && lhs.focusDebt == rhs.focusDebt
                    && lhs.windowPhase == rhs.windowPhase
                    && lhs.activeDestination == rhs.activeDestination
                    && lhs.eventPresentation == rhs.eventPresentation
                    && lhs.language == rhs.language
                    && lhs.loginItemRegistration == rhs.loginItemRegistration
                    && lhs.loginItemFailure == rhs.loginItemFailure
                    && lhs.pendingAnnouncement == rhs.pendingAnnouncement
                    && lhs.presentationRevision == rhs.presentationRevision)
        }
    }
}
