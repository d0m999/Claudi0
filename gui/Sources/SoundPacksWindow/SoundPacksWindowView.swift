import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI
import UniformTypeIdentifiers

/// Presentation-only content supplied by the Sounds destination. The editor keeps ownership of
/// pack selection, mapping controls, and its single reading column.
@MainActor
package struct SoundPacksEditorSupplement {
    package var pageHeader: AnyView = AnyView(EmptyView())
    package var scopePicker: AnyView?
    package var serviceSummary: AnyView = AnyView(EmptyView())
    package var onLeaveEvent: @MainActor () -> Void = {}
    package var returnToScope: (@MainActor () -> Void)? = nil
    package let sidebarHeader: AnyView
    package let auxiliary: AnyView
    package let detailHeader: AnyView
    package let eventContent: (Event) -> AnyView
    package let isEmpty: Bool

    package init(
        sidebarHeader: AnyView,
        detailHeader: AnyView,
        auxiliary: AnyView = AnyView(EmptyView()),
        eventContent: @escaping (Event) -> AnyView
    ) {
        self.sidebarHeader = sidebarHeader
        self.auxiliary = auxiliary
        self.detailHeader = detailHeader
        self.eventContent = eventContent
        isEmpty = false
    }

    package static var empty: Self {
        Self(
            sidebarHeader: AnyView(EmptyView()),
            detailHeader: AnyView(EmptyView()),
            eventContent: { _ in AnyView(EmptyView()) },
            isEmpty: true)
    }

    private init(
        sidebarHeader: AnyView,
        detailHeader: AnyView,
        eventContent: @escaping (Event) -> AnyView,
        isEmpty: Bool
    ) {
        self.sidebarHeader = sidebarHeader
        self.auxiliary = AnyView(EmptyView())
        self.detailHeader = detailHeader
        self.eventContent = eventContent
        self.isEmpty = isEmpty
    }

}

/// Unified Settings presentation of the app-lifetime editor owner. Route/focus state is local to
/// the embedded destination; every disk/config mutation stays behind `SoundPacksEditorOwner`.
@MainActor
public struct EmbeddedSoundPacksEditorView: View {
    @ObservedObject private var editorOwner: SoundPacksEditorOwner
    private let route: SoundPacksWindowRoute
    private let routeRequestRevision: UInt64
    private let nativeEffects: SoundPacksEditorNativeEffectsDispatcher
    private let supplement: SoundPacksEditorSupplement
    @ObservedObject private var languageStore: ClaudioPreferences
    @StateObject private var focusCoordinator = SoundPacksWindowFocusCoordinator()
    @State private var focusApplicationTracker =
        FocusApplicationTracker<SoundPacksEditorFocusProjection>()

    package init(
        editorOwner: SoundPacksEditorOwner,
        route: SoundPacksWindowRoute,
        routeRequestRevision: UInt64,
        languageStore: ClaudioPreferences,
        nativeEffects: SoundPacksEditorNativeEffectsDispatcher,
        supplement: SoundPacksEditorSupplement = .empty
    ) {
        self.editorOwner = editorOwner
        self.route = route
        self.routeRequestRevision = routeRequestRevision
        self.languageStore = languageStore
        self.nativeEffects = nativeEffects
        self.supplement = supplement
    }

    public var body: some View {
        SoundPacksWindowView(
            editorOwner: editorOwner,
            focusCoordinator: focusCoordinator,
            languageStore: languageStore,
            nativeEffects: nativeEffects,
            supplement: supplement
        )
        .onAppear {
            applyFocusFromPresentation(requestsInitialFocus: true)
        }
        .onChange(of: routeRequestRevision) { _ in
            applyFocusFromPresentation(requestsInitialFocus: false)
        }
        .onChange(of: focusProjection) { _ in
            applyFocusFromPresentation(requestsInitialFocus: false)
        }
    }

    private func applyFocusFromPresentation(requestsInitialFocus: Bool) {
        guard case .sounds(let sounds) = editorOwner.presentation.mode else { return }
        let projection = SoundPacksEditorFocusProjection(
            requestRevision: sounds.requestRevision,
            routeState: sounds.routeState,
            scopeAvailability: sounds.scope)
        guard
            focusApplicationTracker.recordAndShouldApply(
                projection,
                force: requestsInitialFocus)
        else { return }
        let focusRoute: SoundPacksWindowRoute
        switch sounds.routeState {
        case .resolved(let resolved):
            focusRoute = resolved
        case .pendingFreshSnapshot, .staleTarget:
            focusRoute = .overview(scope: sounds.route.scope)
        }
        focusCoordinator.requestFocus(focusRoute)
    }

    private var focusProjection: SoundPacksEditorFocusProjection? {
        guard case .sounds(let sounds) = editorOwner.presentation.mode else { return nil }
        return SoundPacksEditorFocusProjection(
            requestRevision: sounds.requestRevision,
            routeState: sounds.routeState,
            scopeAvailability: sounds.scope)
    }
}

package struct SoundPacksEditorFocusProjection: Equatable {
    package let requestRevision: UInt64
    package let routeState: SoundPacksEditorRouteState
    package let scopeAvailability: SoundPackEditorScopeAvailability

    package init(
        requestRevision: UInt64,
        routeState: SoundPacksEditorRouteState,
        scopeAvailability: SoundPackEditorScopeAvailability
    ) {
        self.requestRevision = requestRevision
        self.routeState = routeState
        self.scopeAvailability = scopeAvailability
    }
}

/// Standard-window surface: full pack sidebar plus the selected pack's five mappings.
///
/// T9 adds a window-owned focus/VoiceOver/Dynamic Type layer. T11 adds selected-pack audio
/// inventory, existing-audio assignment, and explicit confirmed orphan deletion.
@MainActor
package struct SoundPacksWindowView: View {
    @ObservedObject private var editorOwner: SoundPacksEditorOwner
    private let focusCoordinator: SoundPacksWindowFocusCoordinator
    @ObservedObject private var languageStore: ClaudioPreferences
    private let nativeEffects: SoundPacksEditorNativeEffectsDispatcher
    private let supplement: SoundPacksEditorSupplement

    package init(
        editorOwner: SoundPacksEditorOwner,
        focusCoordinator: SoundPacksWindowFocusCoordinator,
        languageStore: ClaudioPreferences,
        nativeEffects: SoundPacksEditorNativeEffectsDispatcher,
        supplement: SoundPacksEditorSupplement = .empty
    ) {
        self.editorOwner = editorOwner
        self.focusCoordinator = focusCoordinator
        self.languageStore = languageStore
        self.nativeEffects = nativeEffects
        self.supplement = supplement
    }

    package var body: some View {
        let presentation = editorOwner.presentation
        Group {
            if case .sounds(let sounds) = presentation.mode {
                SoundPacksWindowContentView(
                    editorOwner: editorOwner,
                    presentation: presentation,
                    sounds: sounds,
                    focusCoordinator: focusCoordinator,
                    languageStore: languageStore,
                    nativeEffects: nativeEffects,
                    supplement: supplement)
            } else {
                ProgressView()
                    .frame(minWidth: 0, minHeight: 0)
                    .accessibilityLabel(
                        ClaudioL10n(language: languageStore.language).text(
                            .soundPacksLibraryLoading))
            }
        }
    }
}

@MainActor
private struct SettingsPackCopyConfirmation {
    let action: SoundPackEditorAction
    let packName: String
    let scope: PanelSoundScopeID?
    let workspaceName: String?
}

@MainActor
private final class SoundPacksWindowContentSnapshot {
    let presentation: SoundPacksEditorPresentation
    let sounds: SoundsEditorPresentation

    init(presentation: SoundPacksEditorPresentation, sounds: SoundsEditorPresentation) {
        self.presentation = presentation
        self.sounds = sounds
    }
}

@MainActor
private struct SoundPacksWindowContentView: View {
    private let editorOwner: SoundPacksEditorOwner
    // One immutable render snapshot avoids copying the large owner projections whenever
    // SwiftUI copies this view value. The parent supplies a fresh snapshot on every update.
    private let snapshot: SoundPacksWindowContentSnapshot
    private var presentation: SoundPacksEditorPresentation { snapshot.presentation }
    private var sounds: SoundsEditorPresentation { snapshot.sounds }
    @ObservedObject var focusCoordinator: SoundPacksWindowFocusCoordinator
    @ObservedObject var languageStore: ClaudioPreferences
    @ObservedObject private var nativeEffects: SoundPacksEditorNativeEffectsDispatcher
    private let supplement: SoundPacksEditorSupplement

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsUsesCompactLayout) private var compactLayout
    @FocusState private var focusedTarget: SoundPacksWindowFocusTarget?
    @State private var handledFocusRequestRevision: UInt64 = 0
    @State private var dropTargetEvent: Event?
    @State private var requestedRoute: SoundPacksWindowRoute = .overview
    @State private var awaitsDeepLinkFocus = false
    @State private var settingsDetail: SoundPacksSettingsDetail = .overview
    @State private var detailRouteTracker = SoundPacksSettingsDetailRouteTracker()
    @State private var detailCopyTransition: SoundPacksSettingsDetailCopyTransition?
    @State private var unavailableDetail: SoundPacksSettingsDetail?
    @State private var copyConfirmation: SettingsPackCopyConfirmation?
    @FocusState private var detailTitleFocused: Bool

    init(
        editorOwner: SoundPacksEditorOwner,
        presentation: SoundPacksEditorPresentation,
        sounds: SoundsEditorPresentation,
        focusCoordinator: SoundPacksWindowFocusCoordinator,
        languageStore: ClaudioPreferences,
        nativeEffects: SoundPacksEditorNativeEffectsDispatcher,
        supplement: SoundPacksEditorSupplement
    ) {
        self.editorOwner = editorOwner
        snapshot = SoundPacksWindowContentSnapshot(presentation: presentation, sounds: sounds)
        self.focusCoordinator = focusCoordinator
        self.languageStore = languageStore
        self.nativeEffects = nativeEffects
        self.supplement = supplement
    }

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }

    private var activeSounds: SoundsEditorPresentation { sounds }

    var body: some View {
        AnyView(
            VStack(spacing: 0) {
                SettingsPageHeader {
                    if settingsDetail != .overview {
                        Button {
                            leaveDetail()
                        } label: {
                            Label(l10n.text(.settingsNativeBack), systemImage: "chevron.left")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .accessibilityLabel(l10n.text(.settingsNativeBack))
                        .accessibilityIdentifier("sound-packs.detail.back")
                        Text(detailTitle)
                            .accessibilityAddTraits(.isHeader)
                            .focusable()
                            .focused($detailTitleFocused)
                            .accessibilityIdentifier("sound-packs.detail.title")
                    } else {
                        supplement.pageHeader
                    }
                    Spacer(minLength: 8)
                    if let returnToScope = supplement.returnToScope {
                        Button(l10n.text(.settingsReturnToSoundScope), action: returnToScope)
                            .font(SettingsAppearance.font(.secondary))
                            .accessibilityLabel(l10n.text(.settingsReturnToSoundScope))
                            .accessibilityIdentifier("settings.sounds.return-to-scope")
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: SettingsAppearance.sectionGap) {
                            libraryStatusBar
                            importResultRegion
                            if nativeEffects.previewFailed {
                                FailureRow(message: l10n.text(.eventPreviewPlaybackFailed))
                                    .focusable().focused(
                                        $focusedTarget, equals: .managedScopeFailure
                                    )
                                    .accessibilityIdentifier("sound-packs.preview.failure")
                            }
                            if !activeSounds.windowStatuses.isEmpty { windowStatusRegion }
                            detailContent
                        }
                        .id("detail-top")
                        .soundPacksLayoutProbe("settings.reading.sounds")
                        .settingsReadingColumn()
                    }
                    .soundPacksLayoutProbe("sound-packs.detail-scroll")
                    .onChange(of: settingsDetail) { _ in
                        proxy.scrollTo("detail-top", anchor: .top)
                        detailTitleFocused =
                            settingsDetail != .overview
                            && settingsDetail.targetIsAvailable(in: activeSounds)
                    }
                    .onChange(of: handledFocusRequestRevision) { _ in
                        proxy.scrollTo("detail-top", anchor: .top)
                    }
                }
            }
        )
        .frame(minWidth: 0, minHeight: 0)
        .soundPacksLayoutProbe("sound-packs.editor")
        .background(SettingsAppearance.background(colorScheme))
        .onReceive(focusCoordinator.$requestRevision) { revision in
            guard focusCoordinator.consumeRequest(revision) else { return }
            requestedRoute = focusCoordinator.requestedTarget ?? .overview
            if detailRouteTracker.requestRevision != activeSounds.requestRevision {
                detailCopyTransition = nil
            }
            let nextDetail = detailRouteTracker.detailAfterFocusRequest(
                route: requestedRoute, sounds: activeSounds, currentDetail: settingsDetail)
            // Initial route resolution may already have a composer; only leaving a detail cleans it.
            if settingsDetail != .overview, nextDetail != settingsDetail {
                openDetail(nextDetail)
            } else {
                settingsDetail = nextDetail
            }
            // Scroll trigger only; the request dedup itself lives in the coordinator.
            handledFocusRequestRevision = revision
            applyInitialFocus()
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: activeSounds.packs.map(\.id)) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: activeSounds.selectedPack?.id) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: presentation) { _ in
            reconcileDetailCopyTransition()
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: activeSounds.draft?.packID) { id in
            if let id { settingsDetail = .event(packID: id, event: .taskStart) }
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: activeSounds.inventory) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: activeSounds.eventRows) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: activeSounds.recoveryActions.map(\.packID)) { _ in
            if settingsDetail == .overview, activeSounds.packs.isEmpty,
                focusedTarget != nil || requestedRoute.editTarget != nil,
                let packID = activeSounds.recoveryActions.first?.packID
            {
                focusedTarget = .retryFactoryRestore(packID: packID)
            } else {
                reconcileFocusWithVisibleControls()
            }
        }
        .onChange(of: presentation.library) { _ in
            reconcileFocusWithVisibleControls(assignFirstIfNil: true)
        }
        .confirmationDialog(
            copyConfirmation.map { l10n.format(.soundPacksCopyLabel, $0.packName) }
                ?? l10n.text(.soundPacksCopy),
            isPresented: Binding(
                get: { copyConfirmation != nil },
                set: { if !$0 { copyConfirmation = nil } }),
            titleVisibility: .visible,
            presenting: copyConfirmation
        ) { confirmation in
            Button(l10n.text(.commonCopy)) {
                copyConfirmation = nil
                invoke(confirmation.action)
            }
            .accessibilityIdentifier("sound-packs.confirm-copy")
            Button(l10n.text(.commonCancel), role: .cancel) { copyConfirmation = nil }
                .accessibilityIdentifier("sound-packs.cancel-copy")
        } message: { confirmation in
            Text(copyConfirmationMessage(confirmation))
        }
        .confirmationDialog(
            deleteOrphanConfirmation.map {
                l10n.format(.soundPacksDeleteTitle, $0.fileName ?? "")
            } ?? l10n.text(.soundPacksDeleteButton),
            isPresented: Binding(
                get: { deleteOrphanConfirmation != nil },
                set: { if !$0 { cancelConfirmation(deleteOrphanConfirmation) } }),
            titleVisibility: .visible,
            presenting: deleteOrphanConfirmation
        ) { confirmation in
            let fileName = confirmation.fileName ?? ""
            Button(l10n.text(.soundPacksDeleteButton), role: .destructive) {
                invoke(confirmation.confirmAction)
            }
            .accessibilityLabel(l10n.format(.soundPacksOrphanDeleteLabel, fileName))
            .accessibilityHint(l10n.text(.soundPacksDeleteHint))
            .accessibilityIdentifier("sound-packs.confirm-delete")
            Button(l10n.text(.commonCancel), role: .cancel) {
                invoke(confirmation.cancelAction)
            }
            .accessibilityLabel(l10n.text(.commonCancel))
            .accessibilityIdentifier("sound-packs.cancel-delete")
        } message: { confirmation in
            Text(l10n.format(.soundPacksDeleteMessage, confirmation.fileName ?? ""))
        }
        .confirmationDialog(
            deletePackConfirmation.map {
                l10n.format(
                    .soundPacksPackDeleteTitle,
                    confirmationPackDisplayName($0))
            } ?? l10n.text(.soundPacksPackDelete),
            isPresented: Binding(
                get: { deletePackConfirmation != nil },
                set: { if !$0 { cancelConfirmation(deletePackConfirmation) } }),
            titleVisibility: .visible,
            presenting: deletePackConfirmation
        ) { confirmation in
            let displayName = confirmationPackDisplayName(confirmation)
            Button(l10n.text(.soundPacksPackDelete), role: .destructive) {
                invoke(confirmation.confirmAction)
            }
            .accessibilityLabel(
                l10n.format(.soundPacksPackDeleteLabel, displayName)
            )
            .accessibilityHint(l10n.text(.soundPacksPackDeleteHint))
            .accessibilityIdentifier("sound-packs.confirm-pack-delete")
            Button(l10n.text(.commonCancel), role: .cancel) {
                invoke(confirmation.cancelAction)
            }
            .accessibilityLabel(l10n.text(.commonCancel))
            .accessibilityIdentifier("sound-packs.cancel-pack-delete")
        } message: { confirmation in
            Text(
                l10n.format(
                    .soundPacksPackDeleteMessage, confirmationPackDisplayName(confirmation))
            )
        }
        .confirmationDialog(
            restoreConfirmation.map {
                l10n.format(.soundPacksRestoreTitle, confirmationPackDisplayName($0))
            } ?? l10n.text(.soundPacksRestore),
            isPresented: Binding(
                get: { restoreConfirmation != nil },
                set: { if !$0 { cancelConfirmation(restoreConfirmation) } }),
            titleVisibility: .visible,
            presenting: restoreConfirmation
        ) { confirmation in
            Button(l10n.text(.soundPacksRestoreButton), role: .destructive) {
                invoke(confirmation.confirmAction)
            }
            .accessibilityLabel(
                l10n.format(.soundPacksRestoreLabel, confirmationPackDisplayName(confirmation))
            )
            .accessibilityHint(l10n.text(.soundPacksRestoreHint))
            .accessibilityIdentifier("sound-packs.confirm-factory-restore")
            Button(l10n.text(.commonCancel), role: .cancel) {
                invoke(confirmation.cancelAction)
            }
            .accessibilityLabel(l10n.text(.commonCancel))
            .accessibilityIdentifier("sound-packs.cancel-factory-restore")
        } message: { confirmation in
            Text(factoryRestoreConfirmationMessage(confirmation))
        }
        .disabled(isPerformingWrite)
    }

    private var importResultRegion: AnyView {
        guard let activity = presentation.activities.last(where: { $0.kind == .importAudio }),
            let result = soundPacksImportResultText(activity, language: languageStore.language)
        else { return AnyView(EmptyView()) }
        return AnyView(
            Text(result)
                .font(SettingsAppearance.font(.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .modifier(SettingsSectionSurface())
                .accessibilityIdentifier("sound-packs.import.result"))
    }

    private var managedScopeBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(
                    systemName: activeSounds.route.scope == .global
                        ? "globe" : "square.stack.3d.up.fill"
                )
                .foregroundColor(SettingsAppearance.accent(colorScheme))
                .accessibilityHidden(true)
                Text(l10n.format(.soundPacksManagingScope, managedScopeName))
                    .font(.system(.subheadline, design: .default).weight(.semibold))
                    .foregroundColor(SettingsAppearance.text(colorScheme))
                Spacer(minLength: 0)
            }
            if let reason = localizedManagedScopeFailure {
                FailureRow(message: reason)
                    .focusable()
                    .focused($focusedTarget, equals: .managedScopeFailure)
                    .accessibilityIdentifier("sound-packs.scope.failure")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            l10n.format(.soundPacksManagingScope, managedScopeName)
        )
        .accessibilityIdentifier("sound-packs.managed-scope")
    }

    private var managedScopeName: String {
        switch activeSounds.route.scope {
        case .global:
            return l10n.text(.panelGlobalName)
        case .workspace:
            return activeSounds.workspaceName ?? l10n.text(.workspaceUnavailable)
        case .surface(let surface):
            return HostID.productVisibleCases.first(where: { $0.surfaceID == surface })?.displayName
                ?? surface.rawValue
        }
    }

    private var localizedManagedScopeFailure: String? {
        guard case .unavailable = activeSounds.scope else { return nil }
        if case .workspace = activeSounds.route.scope {
            return l10n.text(.workspaceUnavailable)
        }
        return l10n.format(.soundPacksDamagedScope, managedScopeName)
    }

    @ViewBuilder
    private var libraryStatusBar: some View {
        ForEach(presentation.activities.filter { $0.kind == .importAudio && $0.phase == .busy }) {
            activity in
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(l10n.text(.soundPacksImporting))
                Spacer(minLength: 8)
                if let cancel = activity.cancelAction {
                    Button(l10n.text(.commonCancel)) { invoke(cancel) }
                        .accessibilityLabel(l10n.text(.commonCancel))
                        .accessibilityIdentifier("sound-packs.import.cancel")
                }
            }
            .accessibilityIdentifier("sound-packs.import.in-progress")
        }
        if isPerformingWrite {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(l10n.text(.soundPacksWritingChanges))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(l10n.text(.soundPacksWritingChanges))
            .accessibilityIdentifier("sound-packs.write-in-progress")
        } else {
            switch presentation.library {
            case .unloaded, .loading(previousAvailable: false):
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(l10n.text(.soundPacksLibraryLoading))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    l10n.text(.soundPacksLibraryLoading).replacingOccurrences(of: "…", with: "")
                )
                .accessibilityIdentifier("sound-packs.library.loading")
            case .loading(previousAvailable: true):
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(l10n.text(.soundPacksLibraryRefreshing))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(l10n.text(.soundPacksLibraryRefreshing))
                .accessibilityIdentifier("sound-packs.library.refreshing")
            case .failed(let previousAvailable, let reason):
                HStack(alignment: .center, spacing: 10) {
                    FailureRow(
                        message: previousAvailable
                            ? l10n.format(
                                .soundPacksLibraryRefreshFailed,
                                localizedLibraryFailure(reason))
                            : localizedLibraryFailure(reason))
                    Spacer(minLength: 8)
                    Button(l10n.text(.commonRetry)) {
                        invoke(activeSounds.retryLibraryAction)
                    }
                    .accessibilityLabel(l10n.text(.soundPacksLibraryRetryLabel))
                    .accessibilityHint(l10n.text(.soundPacksLibraryRetryHint))
                    .accessibilityIdentifier("sound-packs.library.retry")
                    .focused($focusedTarget, equals: .retryLibraryLoad)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            case .ready:
                EmptyView()
            }
        }
    }

    private var packSelector: some View {
        SettingsControlRow(title: l10n.text(.panelSoundPackLabel)) {
            Picker(l10n.text(.panelSoundPackLabel), selection: selection) {
                Text(l10n.text(.soundPacksSidebarNone)).tag(Optional<String>.none)
                ForEach(activeSounds.packs) { card in
                    Text(SelectedPackMetadata(id: card.id, name: card.name).displayName)
                        .accessibilityLabel(packAccessibilityLabel(card))
                        .tag(Optional(card.id))
                }
            }
            .focused($focusedTarget, equals: .packList)
            .disabled(activeSounds.packs.isEmpty)
            .accessibilityIdentifier("sound-packs.pack-list")
            .soundPacksLayoutProbe("sound-packs.pack-list.control")
        }
        .soundPacksLayoutProbe("sound-packs.pack-list.row")
        .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
        .soundPacksLayoutProbe("sound-packs.pack-list")
    }

    private var detailTitle: String {
        switch settingsDetail {
        case .overview: l10n.text(.settingsDestinationSounds)
        case .event(_, let event): localizedEventName(event, language: languageStore.language)
        case .audio: l10n.text(.settingsNativeAudioFiles)
        case .service: l10n.text(.settingsNativeAIServices)
        case .panel: l10n.text(.settingsNativePanelDisplaySet)
        }
    }

    private func openDetail(_ detail: SoundPacksSettingsDetail) {
        nativeEffects.stopPreview(owner: editorOwner)
        supplement.onLeaveEvent()
        if activeSounds.draft != nil { editorOwner.cancelAICuePackDraft() }
        detailCopyTransition = nil
        unavailableDetail = nil
        settingsDetail = detail
    }

    private func leaveDetail() {
        openDetail(.overview)
        editorOwner.cancelAICuePackDraft()
        focusedTarget = .packList
    }

    // Keep the detail routing seam shallow; every branch retains its native controls and owner.
    private var detailContent: AnyView {
        switch settingsDetail {
        case .overview: AnyView(overviewDetail)
        case .event(let packID, let event): AnyView(eventDetail(packID: packID, event: event))
        case .audio(let packID): AnyView(audioDetail(packID: packID))
        case .service: supplement.auxiliary
        case .panel: AnyView(panelDisplaySet)
        }
    }

    @ViewBuilder
    private var overviewDetail: some View {
        VStack(spacing: 0) {
            if let scopePicker = supplement.scopePicker {
                scopePicker
                Divider().padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
            }
            packSelector
        }
        .modifier(SettingsSectionSurface(padding: 0))
        .soundPacksLayoutProbe("sound-packs.selector.card")
        if localizedManagedScopeFailure != nil {
            managedScopeBar.modifier(SettingsSectionSurface())
        }
        if let card = selectedCard {
            VStack(alignment: .leading, spacing: 16) {
                detailHeader(card)
                supplement.detailHeader
                if card.isBuiltinReadOnly { builtinCopyExplanation(card) }
                if activeSounds.route.isCopyAndApply {
                    Text(
                        l10n.format(
                            .settingsSoundsAICueCopyAndApply, copyAndApplyScopeName as NSString)
                    )
                    .font(SettingsAppearance.font(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                }
                packActions(card)
            }
            .modifier(SettingsSectionSurface())
            .soundPacksLayoutProbe("sound-packs.information.card")
            overviewEventRows
            disclosure(
                .settingsNativeAIServices, id: "sound-packs.open-service", detail: .service
            ) {
                supplement.serviceSummary
            }
            if !card.isBuiltinReadOnly {
                disclosure(
                    .settingsNativeAudioFiles, id: "sound-packs.open-audio",
                    detail: .audio(packID: card.id)
                ) {
                    Text(l10n.text(.settingsNativeAudioDescription))
                }
            }
            disclosure(
                .settingsNativePanelDisplaySet, id: "sound-packs.open-panel", detail: .panel
            ) {
                Text(l10n.text(.settingsNativePanelDescription))
            }
            libraryActions
        } else {
            emptyState.modifier(SettingsSectionSurface())
            libraryActions
        }
    }

    @ViewBuilder
    private func eventDetail(packID: String, event: Event) -> some View {
        if let row = SoundPacksSettingsDetail.event(packID: packID, event: event)
            .visibleEventRows(in: activeSounds).first
        {
            VStack(alignment: .leading, spacing: 16) {
                if let card = selectedCard {
                    detailHeader(card)
                    supplement.detailHeader
                    if card.isBuiltinReadOnly {
                        builtinCopyExplanation(card)
                        packActions(card)
                    }
                } else {
                    supplement.detailHeader
                }
            }
            .modifier(SettingsSectionSurface())
            VStack(alignment: .leading, spacing: 16) {
                eventMappingRow(row)
                supplement.eventContent(event)
            }
            .modifier(SettingsSectionSurface())
            .soundPacksLayoutProbe("sound-packs.event-detail")
        } else {
            FailureRow(message: l10n.text(.settingsNativeTargetUnavailable))
                .focusable()
                .focused($focusedTarget, equals: .managedScopeFailure)
                .accessibilityIdentifier("sound-packs.detail.unavailable")
        }
    }

    @ViewBuilder
    private func audioDetail(packID: String) -> some View {
        if SoundPacksSettingsDetail.audio(packID: packID).targetIsAvailable(in: activeSounds) {
            audioInventory
        } else {
            FailureRow(message: l10n.text(.settingsNativeTargetUnavailable))
                .focusable().focused($focusedTarget, equals: .managedScopeFailure)
                .accessibilityIdentifier("sound-packs.detail.unavailable")
        }
    }

    private func disclosure<Content: View>(
        _ title: ClaudioL10nKey, id: String, detail: SoundPacksSettingsDetail,
        @ViewBuilder caption: () -> Content
    ) -> some View {
        Button {
            openDetail(detail)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.text(title))
                    caption().font(SettingsAppearance.font(.caption)).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
            .padding(.vertical, SettingsAppearance.controlRowVerticalPadding)
            .frame(
                maxWidth: .infinity, minHeight: SettingsAppearance.multilineControlRowHeight,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SettingsSectionSurface(padding: 0))
        .accessibilityLabel(l10n.text(title))
        .accessibilityIdentifier(id)
    }

    private var overviewEventRows: some View {
        VStack(spacing: 0) {
            ForEach(activeSounds.eventRows) { row in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        eventIdentity(row)
                        Text(mappingText(row)).font(SettingsAppearance.font(.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button {
                        invoke(row.previewAction)
                    } label: {
                        Label(l10n.text(.soundPacksPreview), systemImage: "play.circle")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(row.previewAction == nil)
                    .accessibilityLabel(
                        l10n.format(
                            .soundPacksPreviewLabel,
                            localizedEventName(row.event, language: languageStore.language))
                    )
                    .accessibilityIdentifier("sound-packs.event.\(row.event.rawValue).preview")
                    Button {
                        guard let packID = selectedCard?.id else { return }
                        openDetail(.event(packID: packID, event: row.event))
                    } label: {
                        Label(l10n.text(.settingsNativeEditCue), systemImage: "chevron.right")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        l10n.text(.settingsNativeEditCue) + " "
                            + localizedEventName(row.event, language: languageStore.language)
                    )
                    .accessibilityIdentifier("sound-packs.event.\(row.event.rawValue).edit")
                }
                .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
                .padding(.vertical, SettingsAppearance.controlRowVerticalPadding)
                .frame(minHeight: SettingsAppearance.multilineControlRowHeight)
                .soundPacksLayoutProbe("sound-packs.event-row.\(row.event.rawValue)")
                if row.event != activeSounds.eventRows.last?.event {
                    Divider().padding(.horizontal, 14)
                }
            }
        }
        .modifier(SettingsSectionSurface(padding: 0))
        .soundPacksLayoutProbe("sound-packs.events.group")
    }

    private var audioInventory: some View {
        VStack(alignment: .leading, spacing: 16) {
            if inventoryIsLoading { ProgressView(l10n.text(.soundPacksAudioLoading)) }
            if let error = inventoryFailure {
                FailureRow(message: inventoryErrorMessage(error))
                Button(l10n.text(.commonRetry)) { invoke(activeSounds.retryLibraryAction) }
                    .accessibilityIdentifier("sound-packs.inventory.retry")
            }
            ForEach(inventoryFiles) { file in
                orphanAudioRow(file)
                if file.id != inventoryFiles.last?.id { Divider() }
            }
            if inventoryFiles.isEmpty && !inventoryIsLoading && inventoryFailure == nil {
                Text(l10n.text(.soundPacksEmptyAudio)).foregroundStyle(.secondary)
            }
            Button(l10n.text(.soundPacksAddAudio)) { invoke(activeSounds.requestImportAction) }
                .disabled(activeSounds.requestImportAction == nil)
                .accessibilityLabel(l10n.text(.soundPacksAddAudio))
                .accessibilityIdentifier("sound-packs.add-audio")
        }
        .modifier(SettingsSectionSurface())
        .accessibilityIdentifier("sound-packs.inventory.detail")
    }

    private var panelDisplaySet: some View {
        VStack(spacing: 0) {
            Text(l10n.text(.settingsNativePanelDescription))
                .font(SettingsAppearance.font(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(14)
            ForEach(activeSounds.packs) { card in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(SelectedPackMetadata(id: card.id, name: card.name).displayName)
                        if let reason = card.starDisabledReason {
                            Text(
                                l10n.text(
                                    reason == "面板最多显示 4 个，先取消一颗"
                                        ? .settingsNativePanelLimit
                                        : .settingsNativePanelUnavailable)
                            )
                            .font(SettingsAppearance.font(.caption)).foregroundStyle(.secondary)
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(
                        l10n.text(
                            card.isStarred ? .settingsNativeRemoveStar : .settingsNativeAddStar)
                    ) {
                        invoke(card.toggleStarAction)
                    }
                    .disabled(card.toggleStarAction == nil)
                    .accessibilityLabel(
                        l10n.text(
                            card.isStarred ? .settingsNativeRemoveStar : .settingsNativeAddStar)
                            + " " + SelectedPackMetadata(id: card.id, name: card.name).displayName
                    )
                    .accessibilityIdentifier("sound-packs.star.\(card.id)")
                }
                .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
                .padding(.vertical, SettingsAppearance.controlRowVerticalPadding)
                .frame(minHeight: SettingsAppearance.controlRowHeight)
                if card.id != activeSounds.packs.last?.id { Divider().padding(.horizontal, 14) }
            }
        }
        .modifier(SettingsSectionSurface(padding: 0))
    }

    private var libraryActions: some View {
        HStack(spacing: 12) {
            Button(l10n.text(libraryRefreshLabelKey)) {
                invoke(activeSounds.retryLibraryAction)
            }
            .disabled(activeSounds.retryLibraryAction == nil)
            .accessibilityLabel(l10n.text(libraryRefreshLabelKey))
            .accessibilityIdentifier("sound-packs.refresh-library")
            Button(l10n.text(.soundPacksRestore)) {
                invoke(activeSounds.restoreAllFactoryPacksAction)
            }
            .disabled(activeSounds.restoreAllFactoryPacksAction == nil)
            .accessibilityLabel(l10n.text(.soundPacksRestore))
            .accessibilityIdentifier("sound-packs.restore-library")
            Spacer(minLength: 0)
            supplement.sidebarHeader
        }
    }

    private var libraryRefreshLabelKey: ClaudioL10nKey {
        if case .failed = presentation.library { return .soundPacksLibraryRetryLabel }
        return .eventNoticeRefresh
    }

    private var windowStatusRegion: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(activeSounds.windowStatuses) { status in
                windowStatusRow(status)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailHeader(_ card: SoundPackEditorPackPresentation) -> some View {
        HStack {
            detailIdentity(card)
            Spacer(minLength: 12)
            revealButton(card)
        }
    }

    private func detailIdentity(_ card: SoundPackEditorPackPresentation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(SelectedPackMetadata(id: card.id, name: card.name).displayName)
                    .font(SettingsAppearance.font(.sectionTitle))
                    .fixedSize(horizontal: false, vertical: true)
                if let label = licenseBadgeLabel(metaSlots.license) {
                    Text(label)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if card.isBuiltinReadOnly {
                SettingsStatusCapsule(l10n.text(.soundPacksBuiltinBadge))
                    .accessibilityLabel(l10n.text(.soundPacksBuiltinLabel))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func revealButton(_ card: SoundPackEditorPackPresentation) -> some View {
        Button {
            invoke(card.revealAction)
        } label: {
            Text(l10n.text(.soundPacksReveal))
                .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
                .fixedSize(horizontal: false, vertical: true)
        }
        .focused($focusedTarget, equals: .revealSelectedPack)
        .accessibilityLabel(
            l10n.format(
                .soundPacksRevealLabel,
                SelectedPackMetadata(id: card.id, name: card.name).displayName)
        )
        .accessibilityValue(card.revealDisplayValue ?? "")
        .accessibilityHint(l10n.text(.soundPacksRevealHint))
        .accessibilityIdentifier("sound-packs.reveal-selected")
        .disabled(card.revealAction == nil)
    }

    private func factoryRestoreButton(_ card: SoundPackEditorPackPresentation) -> some View {
        let displayName = SelectedPackMetadata(id: card.id, name: card.name).displayName
        return Button(l10n.text(.soundPacksRestore)) {
            invoke(card.restoreAction)
        }
        .disabled(card.restoreAction == nil)
        .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
        .focused($focusedTarget, equals: .restoreFactoryPack)
        .accessibilityLabel(l10n.format(.soundPacksRestorePackLabel, displayName))
        .accessibilityValue(l10n.text(.soundPacksBuiltinValue))
        .accessibilityHint(l10n.text(.soundPacksRestorePackHint))
        .accessibilityIdentifier("sound-packs.restore-selected-factory-pack")
    }

    private func builtinCopyExplanation(_ card: SoundPackEditorPackPresentation) -> some View {
        let message = l10n.text(.soundPacksBuiltinCopyExplanation)
        return Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .help(message)
            .accessibilityLabel(message)
    }

    private func packActions(_ card: SoundPackEditorPackPresentation) -> AnyView {
        let displayName = SelectedPackMetadata(id: card.id, name: card.name).displayName
        return AnyView(
            VStack(spacing: 0) {
                if card.availability != .missingSelectedPlaceholder {
                    packActionRow(
                        .soundPacksCopy, caption: l10n.text(.settingsSoundsAICueCopyAttribution)
                    ) {
                        Button(l10n.text(.commonCopy)) {
                            requestCopy(card, applying: false)
                        }
                        .disabled(
                            card.isBuiltinReadOnly ? card.forkAction == nil : card.copyAction == nil
                        )
                        .focused($focusedTarget, equals: .forkFactoryPack)
                        .accessibilityLabel(l10n.format(.soundPacksCopyLabel, displayName))
                        .accessibilityIdentifier(
                            card.isBuiltinReadOnly
                                ? "sound-packs.fork-selected-pack"
                                : "sound-packs.copy-selected-pack")
                    }
                    Divider()
                    packActionRow(
                        .soundPacksUse,
                        caption: l10n.format(.soundPacksManagingScope, managedScopeName)
                    ) {
                        if card.isActiveForScope {
                            SettingsStatusCapsule(l10n.text(.soundPacksUsing), isEmphasized: true)
                        } else {
                            Button(l10n.text(.soundPacksUse)) { invoke(card.useAction) }
                                .disabled(card.useAction == nil)
                                .focused($focusedTarget, equals: .useSelectedPack)
                                .accessibilityLabel(l10n.format(.soundPacksUseLabel, displayName))
                                .accessibilityHint(l10n.text(.soundPacksUseHint))
                                .accessibilityIdentifier("sound-packs.use-selected-pack")
                        }
                    }
                }
                if card.copyAndApplyAction != nil {
                    Divider()
                    packActionRow(
                        .settingsNativeCopyAndApplyTitle,
                        caption: l10n.format(
                            .settingsSoundsAICueCopyAndApply, copyAndApplyScopeName)
                    ) {
                        Button(l10n.format(.settingsSoundsAICueCopyAndApply, copyAndApplyScopeName))
                        {
                            requestCopy(card, applying: true)
                        }.fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("sound-packs.copy-and-apply")
                    }
                }
                if card.restoreAction != nil {
                    Divider()
                    packActionRow(.soundPacksRestore, caption: l10n.text(.soundPacksRestoreHint)) {
                        factoryRestoreButton(card)
                    }
                }
                if !card.isBuiltinReadOnly && card.availability != .missingSelectedPlaceholder {
                    Divider()
                    packActionRow(
                        .soundPacksPackDelete,
                        caption: l10n.text(soundPackDeleteExplanationKey(card))
                    ) {
                        Button(l10n.text(.soundPacksPackDelete), role: .destructive) {
                            invoke(card.deleteAction)
                        }
                        .disabled(card.deleteAction == nil)
                        .focused($focusedTarget, equals: .deleteUserPack)
                        .accessibilityLabel(l10n.format(.soundPacksPackDeleteLabel, displayName))
                        .accessibilityIdentifier("sound-packs.delete-selected-pack")
                    }
                }
            })
    }

    private func packActionRow<Content: View>(
        _ title: ClaudioL10nKey, caption: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.text(title)).font(SettingsAppearance.font(.body))
                Text(caption).font(SettingsAppearance.font(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            content().frame(maxWidth: 270, alignment: .trailing)
        }
        .padding(.vertical, SettingsAppearance.controlRowVerticalPadding)
        .frame(minHeight: SettingsAppearance.multilineControlRowHeight)
    }

    private func builtinCopyHelp(_ card: SoundPackEditorPackPresentation) -> String {
        if card.factoryIntegrity == false {
            return l10n.text(.soundPacksBuiltinCopyHelp)
        }
        switch card.state {
        case .complete:
            return l10n.text(.soundPacksBuiltinCopyHelp)
        case .partial, .broken:
            return l10n.text(.soundPacksBuiltinCopyHelp)
        }
    }

    private var copyAndApplyScopeName: String {
        managedScopeName
    }

    private func requestCopy(_ card: SoundPackEditorPackPresentation, applying: Bool) {
        let action =
            applying
            ? card.copyAndApplyAction : (card.isBuiltinReadOnly ? card.forkAction : card.copyAction)
        guard let action else { return }
        copyConfirmation = SettingsPackCopyConfirmation(
            action: action,
            packName: SelectedPackMetadata(id: card.id, name: card.name).displayName,
            scope: applying ? activeSounds.route.scope : nil,
            workspaceName: activeSounds.workspaceName)
    }

    private func copyConfirmationMessage(_ confirmation: SettingsPackCopyConfirmation) -> String {
        let target: String
        switch confirmation.scope {
        case nil: target = l10n.text(.settingsNativeCopyOnly)
        case .global:
            target = l10n.format(.settingsSoundsAICueCopyAndApply, l10n.text(.panelGlobalName))
        case .workspace:
            target = l10n.format(
                .settingsSoundsAICueCopyAndApply,
                confirmation.workspaceName ?? l10n.text(.workspaceUnavailable))
        case .surface(let surface):
            target = l10n.format(
                .settingsSoundsAICueCopyAndApply,
                HostID.productVisibleCases.first(where: { $0.surfaceID == surface })?.displayName
                    ?? surface.rawValue)
        }
        return l10n.text(.settingsSoundsAICueCopyAttribution) + "\n\n" + target
    }

    private func invoke(_ action: SoundPackEditorAction?) {
        guard let action else { return }
        let result = editorOwner.send(.invoke(action))
        if case .accepted(let operationID) = result,
            let transition = SoundPacksSettingsDetailCopyTransition(
                detail: settingsDetail, actionKind: action.kind, operationID: operationID,
                previousPresentation: presentation)
        {
            detailCopyTransition = transition
        }
        nativeEffects.consume(result, owner: editorOwner)
    }

    private func reconcileDetailCopyTransition() {
        guard let transition = detailCopyTransition else { return }
        settingsDetail = settingsDetail.reconciled(
            with: presentation, copyTransition: transition)
        if settingsDetail != transition.detail || !transition.isPending(in: presentation) {
            detailCopyTransition = nil
        }
    }

    private func dropTargetBinding(for event: Event) -> Binding<Bool> {
        Binding(
            get: { dropTargetEvent == event },
            set: { isTargeted in
                if isTargeted {
                    dropTargetEvent = event
                } else if dropTargetEvent == event {
                    dropTargetEvent = nil
                }
            })
    }

    private func handleAudioDrop(_ providers: [NSItemProvider], onto event: Event) -> Bool {
        guard
            !isImportingAudio,
            let importAction = activeSounds.eventRows.first(where: { $0.event == event })?
                .importAction,
            providers.contains(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            })
        else { return false }
        nativeEffects.consumeDrop(
            providers,
            action: importAction,
            owner: editorOwner)
        return true
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(emptyLibraryTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if presentation.library == .unloaded
                || presentation.library == .loading(previousAvailable: false)
            {
                Text(l10n.text(.soundPacksEmptyLoadingMessage))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .failed(previousAvailable: false, _) =
                presentation.library
            {
                Text(l10n.text(.soundPacksEmptyLoadFailedMessage))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .restoreFactory(let action) = activeSounds.emptyLibraryRecovery {
                Text(l10n.text(.soundPacksEmptyFactoryMessage))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(l10n.text(.soundPacksEmptyRestore)) {
                    invoke(action)
                }
                .buttonStyle(.borderedProminent)
                .tint(SettingsAppearance.accent(colorScheme))
                .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
                .focused($focusedTarget, equals: .restoreAllFactoryPacks)
                .accessibilityLabel(l10n.text(.soundPacksEmptyRestoreLabel))
                .accessibilityValue(l10n.text(.soundPacksEmptyRestoreValue))
                .accessibilityHint(l10n.text(.soundPacksEmptyRestoreHint))
                .accessibilityIdentifier("sound-packs.restore-all-factory-packs")
            } else if case .revealRoot(let displayValue, let action) =
                activeSounds.emptyLibraryRecovery
            {
                Text(l10n.text(.soundPacksEmptyNoFactoryMessage))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(l10n.text(.soundPacksEmptyReveal)) {
                    invoke(action)
                }
                .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
                .focused($focusedTarget, equals: .revealPacksDirectory)
                .accessibilityLabel(l10n.text(.soundPacksEmptyRevealLabel))
                .accessibilityValue(displayValue)
                .accessibilityHint(l10n.text(.soundPacksEmptyRevealHint))
                .accessibilityIdentifier("sound-packs.reveal-packs-directory")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var emptyLibraryTitle: String {
        switch presentation.library {
        case .unloaded, .loading(previousAvailable: false):
            return l10n.text(.soundPacksLibraryLoading).replacingOccurrences(of: "…", with: "")
        case .failed(previousAvailable: false, _):
            return l10n.text(.panelPacksReadFailed)
        case .loading(previousAvailable: true), .ready, .failed(previousAvailable: true, _):
            return l10n.text(.panelPacksNoneTitle)
        }
    }

    @ViewBuilder
    private func windowStatusRow(_ status: SoundPacksWindowStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if status.severity == .failure {
                windowFailureRow(
                    action: status.action(language: languageStore.language),
                    reason: status.message(language: languageStore.language))
            } else {
                let message = status.message(language: languageStore.language)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(message)
            }
            if let recovery = activeSounds.manifestRecoveryActions.first(where: {
                $0.statusRevision == status.revision
            }) {
                Text(l10n.format(.soundPacksManifestRecoveryLocation, recovery.path))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    l10n.text(
                        recovery.issue == .unreadable
                            ? .soundPacksManifestReadRepair : .soundPacksManifestWriteRepair)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button(l10n.text(.soundPacksReveal)) {
                        invoke(recovery.revealAction)
                    }
                    .accessibilityValue(recovery.path)
                    .accessibilityIdentifier("sound-packs.manifest-reveal.\(recovery.packID)")
                    if let retryAction = recovery.retryAction {
                        Button(l10n.text(.commonRetry)) {
                            invoke(retryAction)
                        }
                        .accessibilityIdentifier("sound-packs.manifest-retry.\(recovery.packID)")
                    }
                }
            }
            if case .retryFactoryRestores(let packIDs)? = status.recovery {
                ForEach(
                    activeSounds.recoveryActions.filter { packIDs.contains($0.packID) }
                ) { recovery in
                    let packID = recovery.packID
                    let displayName = SelectedPackMetadata(id: packID, name: nil).displayName
                    Button(l10n.format(.soundPacksRetryRestore, displayName)) {
                        invoke(recovery.retryAction)
                    }
                    .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
                    .focused(
                        $focusedTarget,
                        equals: .retryFactoryRestore(packID: packID)
                    )
                    .accessibilityLabel(l10n.format(.soundPacksRetryRestoreLabel, displayName))
                    .accessibilityValue(l10n.text(.soundPacksRetryRestoreValue))
                    .accessibilityHint(l10n.text(.soundPacksRetryRestoreHint))
                    .accessibilityIdentifier("sound-packs.retry-factory-restore.\(packID)")
                }
            }
        }
    }

    private func eventMappingRow(_ row: SoundPackEditorEventPresentation) -> some View {
        HStack(alignment: .center) {
            eventIdentity(row)
            Spacer(minLength: 12)
            eventControls(row)
                .frame(maxWidth: 320, alignment: .trailing)
        }
        .padding(.vertical, SettingsAppearance.controlRowVerticalPadding)
        .frame(
            maxWidth: .infinity, minHeight: SettingsAppearance.controlRowHeight,
            alignment: .leading
        )
        .background {
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                .fill(
                    dropTargetEvent == row.event
                        ? SettingsAppearance.accent(colorScheme).opacity(0.12)
                        : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                .stroke(
                    dropTargetEvent == row.event
                        ? SettingsAppearance.accent(colorScheme)
                        : Color.clear,
                    lineWidth: ClaudioTheme.Metrics.hairline)
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: dropTargetBinding(for: row.event),
            perform: { providers in handleAudioDrop(providers, onto: row.event) }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            localizedSoundPacksEventAccessibilityLabel(
                eventName: localizedEventName(row.event, language: languageStore.language),
                coverage: row.coverage,
                enabled: row.enabled,
                language: languageStore.language)
        )
        .accessibilityHint(
            canEditSelectedPack
                ? l10n.text(.soundPacksMappingHint)
                : l10n.text(.soundPacksBuiltinLabel)
        )
        .accessibilityIdentifier("sound-packs.event.\(row.event.rawValue)")
        .soundPacksLayoutProbe("sound-packs.event.\(row.event.rawValue)")
    }

    private func eventIdentity(_ row: SoundPackEditorEventPresentation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                ClaudioEventGlyph(event: row.event, size: 24)
                Text(localizedEventName(row.event, language: languageStore.language))
                    .font(SettingsAppearance.font(.body).weight(.medium))
            }
            if !row.duplicateEvents.isEmpty {
                Text(l10n.format(.soundPacksDuplicateSource, eventNames(row.duplicateEvents)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sound-packs.event.\(row.event.rawValue).duplicate")
            }
            if row.soundSource?.systemSoundName != nil, !row.coverage.previewEnabled {
                Text(mappingText(row))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func mappingValue(_ coverage: CoverageState) -> some View {
        Text(mappingText(coverage))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func eventControls(_ row: SoundPackEditorEventPresentation) -> some View {
        let availability = row.previewAvailability
        return HStack(spacing: 8) {
            eventAudioControl(row)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                invoke(row.previewAction)
            } label: {
                Label(l10n.text(.soundPacksPreview), systemImage: "play.fill")
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
            .disabled(row.previewAction == nil)
            .focused($focusedTarget, equals: .eventPreview(row.event))
            .accessibilityLabel(
                l10n.format(
                    .soundPacksPreviewLabel,
                    localizedEventName(row.event, language: languageStore.language))
            )
            .accessibilityValue(mappingText(row))
            .accessibilityHint(
                localizedEventPreviewHint(availability, language: languageStore.language)
            )
            .accessibilityIdentifier("sound-packs.event.\(row.event.rawValue).preview")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func eventAudioControl(_ row: SoundPackEditorEventPresentation) -> some View {
        if canEditSelectedPack || activeSounds.draft != nil {
            Menu {
                Section(l10n.text(.soundPacksExistingFiles)) {
                    if inventoryIsLoading && inventoryFiles.isEmpty {
                        Text(l10n.text(.soundPacksAudioLoading))
                    } else if inventoryFiles.isEmpty {
                        Text(l10n.text(.soundPacksEmptyAudio))
                    } else {
                        ForEach(inventoryFiles) { file in
                            Button(
                                sourceChoiceTitle(
                                    file.isOrphan
                                        ? l10n.format(.soundPacksOrphanUnused, file.fileName)
                                        : file.fileName, usedBy: file.usedByEvents)
                            ) {
                                invoke(
                                    file.assignments.first(where: { $0.event == row.event })?
                                        .action)
                            }
                            .disabled(!file.assignments.contains(where: { $0.event == row.event }))
                            .accessibilityLabel(
                                l10n.format(
                                    .soundPacksChooseBindLabel,
                                    "\(localizedEventName(row.event, language: languageStore.language))"
                                        + (languageStore.language == .english ? ": " : "：")
                                        + sourceChoiceTitle(
                                            file.fileName, usedBy: file.usedByEvents))
                            )
                            .accessibilityIdentifier(
                                "sound-packs.event.\(row.event.rawValue).existing.\(file.fileName)")
                        }
                    }
                }
                Section(l10n.text(.eventSettingsSystemSounds)) {
                    if row.systemSoundChoices.isEmpty {
                        Text(l10n.text(.eventSettingsNoSystemSounds))
                    }
                    ForEach(row.systemSoundChoices) { choice in
                        Button(sourceChoiceTitle(choice.source.name, usedBy: choice.usedByEvents)) {
                            invoke(choice.action)
                        }
                        .disabled(choice.action == nil)
                        .accessibilityIdentifier(
                            "sound-packs.event.\(row.event.rawValue).system.\(choice.source.name)")
                    }
                }
                Divider()
                Button(l10n.text(.soundPacksChooseBind)) {
                    invoke(row.importAction)
                }
                .accessibilityLabel(
                    l10n.format(
                        .soundPacksChooseBindLabel,
                        localizedEventName(row.event, language: languageStore.language))
                )
                .disabled(row.importAction == nil)
                .accessibilityHint(l10n.text(.soundPacksChooseBindHint))
                .accessibilityIdentifier(
                    "sound-packs.event.\(row.event.rawValue).choose-and-bind")
                Button(l10n.text(.soundPacksClearBinding), role: .destructive) {
                    invoke(row.clearAction)
                }
                .disabled(row.clearAction == nil)
                .accessibilityLabel(
                    l10n.format(
                        .soundPacksClearBindingLabel,
                        localizedEventName(row.event, language: languageStore.language))
                )
                .accessibilityHint(l10n.text(.soundPacksClearBindingHint))
                .accessibilityIdentifier(
                    "sound-packs.event.\(row.event.rawValue).clear-binding")
                Button(l10n.text(.soundPacksRevealMapping)) {
                    invoke(mappedAudio(for: row)?.revealAction)
                }
                .disabled(mappedAudio(for: row)?.revealAction == nil)
                .accessibilityLabel(
                    l10n.format(
                        .soundPacksRevealMappingLabel,
                        localizedEventName(row.event, language: languageStore.language))
                )
                .accessibilityHint(l10n.text(.soundPacksRevealMappingHint))
                .accessibilityIdentifier(
                    "sound-packs.event.\(row.event.rawValue).reveal-mapping")
            } label: {
                Text(mappingText(row))
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .nativeMenuControl()
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
            .focused($focusedTarget, equals: .eventAudio(row.event))
            .accessibilityLabel(
                l10n.format(
                    .soundPacksMappingLabel,
                    localizedEventName(row.event, language: languageStore.language))
            )
            .accessibilityValue(mappingText(row))
            .accessibilityHint(l10n.text(.soundPacksMappingHint))
            .accessibilityIdentifier("sound-packs.event.\(row.event.rawValue).mapping")
        } else {
            Text(mappingText(row))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    l10n.format(
                        .soundPacksMappingLabel,
                        localizedEventName(row.event, language: languageStore.language))
                )
                .accessibilityValue(mappingText(row))
                .focusable(readOnlyDeepLinkEvent == row.event)
                .focused($focusedTarget, equals: .eventAudio(row.event))
                .accessibilityIdentifier("sound-packs.event.\(row.event.rawValue).readonly-mapping")
        }
    }

    @ViewBuilder
    private func orphanAudioRow(_ file: SoundPackEditorAudioPresentation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: file.isOrphan ? "waveform" : "link")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(
                file.isOrphan
                    ? l10n.format(.soundPacksOrphanUnused, file.fileName)
                    : file.fileName + " · " + eventNames(file.usedByEvents)
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if canEditSelectedPack {
                Menu(l10n.text(.soundPacksOrphanAssign)) {
                    ForEach(file.assignments) { assignment in
                        let event = assignment.event
                        Button(localizedEventName(event, language: languageStore.language)) {
                            invoke(assignment.action)
                        }
                        .accessibilityLabel(
                            l10n.format(
                                .soundPacksOrphanAssignLabel,
                                file.fileName
                                    + (languageStore.language == .english ? ": " : "：")
                                    + localizedEventName(event, language: languageStore.language))
                        )
                        .accessibilityIdentifier(
                            "sound-packs.orphan.\(file.fileName).event.\(event.rawValue)")
                    }
                }
                .nativeMenuControl()
                .disabled(file.assignments.isEmpty)
                .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
                .focused(
                    $focusedTarget,
                    equals: .orphanAssignment(fileName: file.fileName)
                )
                .accessibilityLabel(l10n.format(.soundPacksOrphanAssignLabel, file.fileName))
                .accessibilityValue(
                    soundPackAudioUsageAccessibilityValue(file, language: languageStore.language)
                )
                .accessibilityHint(l10n.text(.soundPacksOrphanAssignHint))
                .accessibilityIdentifier("sound-packs.orphan.\(file.fileName).assign")

                Button(l10n.text(.soundPacksOrphanDelete)) {
                    invoke(file.deleteAction)
                }
                .disabled(file.deleteAction == nil)
                .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
                .focused(
                    $focusedTarget,
                    equals: .orphanDeletion(fileName: file.fileName)
                )
                .accessibilityLabel(l10n.format(.soundPacksOrphanDeleteLabel, file.fileName))
                .accessibilityValue(
                    soundPackAudioUsageAccessibilityValue(file, language: languageStore.language)
                )
                .accessibilityHint(l10n.text(.soundPacksOrphanDeleteHint))
                .accessibilityIdentifier("sound-packs.orphan.\(file.fileName).delete")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func windowFailureRow(action: String, reason: String) -> some View {
        FailureRow(message: reason)
            .accessibilityLabel(
                localizedSoundPacksFailureAccessibilityLabel(
                    action: action,
                    reason: reason,
                    language: languageStore.language))
    }

    private var deleteOrphanConfirmation: SoundPackEditorConfirmation? {
        guard let confirmation = presentation.pendingConfirmation,
            confirmation.kind == .deleteOrphan
        else { return nil }
        return confirmation
    }

    private var deletePackConfirmation: SoundPackEditorConfirmation? {
        guard let confirmation = presentation.pendingConfirmation,
            confirmation.kind == .deletePack
        else { return nil }
        return confirmation
    }

    private var restoreConfirmation: SoundPackEditorConfirmation? {
        guard let confirmation = presentation.pendingConfirmation else { return nil }
        switch confirmation.kind {
        case .restoreFactory, .retryRestore, .restoreAllFactory:
            return confirmation
        case .deletePack, .deleteOrphan:
            return nil
        }
    }

    private func cancelConfirmation(_ confirmation: SoundPackEditorConfirmation?) {
        guard let confirmation,
            presentation.pendingConfirmation?.id == confirmation.id
        else { return }
        invoke(confirmation.cancelAction)
    }

    private func confirmationPackDisplayName(
        _ confirmation: SoundPackEditorConfirmation
    ) -> String {
        guard let packID = confirmation.packID else {
            return l10n.text(.soundPacksEmptyRestoreLabel)
        }
        let name = activeSounds.packs.first(where: { $0.id == packID })?.name
        return SelectedPackMetadata(id: packID, name: name).displayName
    }

    private func localizedLibraryFailure(
        _ reason: SoundPackEditorLibraryFailureReason
    ) -> String {
        switch reason {
        case .locationUnavailable:
            return l10n.text(.soundPacksEmptyLoadFailedMessage)
        case .scanFailed:
            return l10n.text(.panelPacksReadFailed)
        }
    }

    private func factoryRestoreConfirmationMessage(
        _ confirmation: SoundPackEditorConfirmation
    ) -> String {
        switch confirmation.kind {
        case .restoreFactory:
            return l10n.text(.soundPacksRestoreSelectedMessage)
        case .retryRestore:
            return l10n.text(.soundPacksRestoreRetryMessage)
        case .restoreAllFactory:
            return l10n.text(.soundPacksRestoreAllMessage)
        case .deletePack, .deleteOrphan:
            return ""
        }
    }

    private func inventoryErrorMessage(
        _ error: SoundPackEditorInventoryFailureReason
    ) -> String {
        switch error {
        case .packUnavailable:
            return l10n.format(
                .soundPacksInventoryPackNotFound,
                selectedCard?.id ?? "")
        case .manifestUnreadable:
            return l10n.format(
                .soundPacksInventoryManifestUnreadable,
                l10n.text(.panelPacksReadFailed))
        case .directoryUnavailable:
            return l10n.format(
                .soundPacksInventoryDirectoryUnreadable,
                l10n.text(.panelPacksReadFailed))
        }
    }

    private var isImportingAudio: Bool {
        presentation.activities.contains {
            guard case .busy = $0.phase else { return false }
            return $0.kind == .importAudio
        }
    }

    private var isPerformingWrite: Bool {
        return presentation.activities.contains {
            guard case .busy = $0.phase else { return false }
            return $0.kind != .importAudio
        }
    }

    private var inventoryFiles: [SoundPackEditorAudioPresentation] {
        switch activeSounds.inventory {
        case .idle:
            return []
        case .loading(let previous), .failed(let previous, _):
            return previous ?? []
        case .ready(let files):
            return files
        }
    }

    private var inventoryIsLoading: Bool {
        if case .loading = activeSounds.inventory { return true }
        return false
    }

    private var inventoryFailure: SoundPackEditorInventoryFailureReason? {
        guard case .failed(_, let reason) = activeSounds.inventory else { return nil }
        return reason
    }

    private func mappedAudio(
        for row: SoundPackEditorEventPresentation
    ) -> SoundPackEditorAudioPresentation? {
        guard row.soundSource?.systemSoundName == nil else { return nil }
        let fileName: String
        switch row.coverage {
        case .present(let value), .broken(let value):
            fileName = value
        case .unmapped:
            return nil
        }
        return inventoryFiles.first(where: { $0.fileName == fileName })
    }

    private var selection: Binding<String?> {
        Binding(
            get: { activeSounds.selectedPack?.id },
            set: { newValue in
                invoke(activeSounds.packs.first(where: { $0.id == newValue })?.inspectAction)
            })
    }

    private var selectedCard: SoundPackEditorPackPresentation? { activeSounds.selectedPack }

    private var focusScope: SoundPacksWindowFocusScope {
        let overview = settingsDetail == .overview
        let audio: Bool
        if case .audio = settingsDetail {
            audio = settingsDetail.targetIsAvailable(in: activeSounds)
        } else {
            audio = false
        }
        let eventRows = settingsDetail.visibleEventRows(in: activeSounds)
        let hasLibraryFailure: Bool
        if case .failed = presentation.library {
            hasLibraryFailure = true
        } else {
            hasLibraryFailure = false
        }
        let hasPackActions =
            overview || !eventRows.isEmpty && selectedCard?.isBuiltinReadOnly == true
        let emptyRecovery = activeSounds.emptyLibraryRecovery
        let canRestoreAllFactoryPacks: Bool
        let canRevealPacksDirectory: Bool
        switch emptyRecovery {
        case .restoreFactory:
            canRestoreAllFactoryPacks = true
            canRevealPacksDirectory = false
        case .revealRoot:
            canRestoreAllFactoryPacks = false
            canRevealPacksDirectory = true
        case .none:
            canRestoreAllFactoryPacks = false
            canRevealPacksDirectory = false
        }
        return SoundPacksWindowFocusScope(
            packIDs: overview ? activeSounds.packs.map(\.id) : [],
            selectedPackID: activeSounds.selectedPack?.id,
            hasManagedScopeFailure: localizedManagedScopeFailure != nil
                || settingsDetail.unavailableFocusTarget(in: activeSounds) != nil,
            editableEvents: !overview && canEditSelectedPack ? eventRows.map(\.event) : [],
            previewableEvents: eventRows.filter {
                $0.previewAction != nil
            }.map(\.event),
            orphanFileNames: audio && canEditSelectedPack
                ? inventoryFiles.filter(\.isOrphan).map(\.fileName) : [],
            canEditSelectedPack: canEditSelectedPack,
            canForkFactoryPack: hasPackActions && selectedCard?.forkAction != nil,
            canAddAudio: audio && activeSounds.requestImportAction != nil,
            canDeleteUserPack: overview && selectedCard?.deleteAction != nil,
            canRestoreFactoryPack: hasPackActions && selectedCard?.restoreAction != nil,
            canUseSelectedPack: hasPackActions && selectedCard?.useAction != nil,
            canRestoreAllFactoryPacks: overview && canRestoreAllFactoryPacks,
            canRevealPacksDirectory: overview && canRevealPacksDirectory,
            canRetryLibraryLoad: hasLibraryFailure && activeSounds.retryLibraryAction != nil,
            retryFactoryRestorePackIDs: activeSounds.recoveryActions.map(\.packID))
    }

    private func applyInitialFocus() {
        let visibleEvents = Set(activeSounds.eventRows.map(\.event))
        if case .unavailable = activeSounds.scope {
            awaitsDeepLinkFocus = false
        } else {
            awaitsDeepLinkFocus =
                requestedRoute.editTarget.map {
                    activeSounds.selectedPack?.id != $0.packID || !visibleEvents.contains($0.event)
                } ?? false
        }
        focusedTarget = soundPacksWindowDeepLinkFocusTarget(
            route: requestedRoute,
            scopeAvailability: activeSounds.scope,
            selectedPackID: activeSounds.selectedPack?.id,
            visibleEvents: visibleEvents,
            fallback: soundPacksWindowFirstFocusTarget(focusScope))
    }

    private var readOnlyDeepLinkEvent: Event? {
        guard !canEditSelectedPack,
            activeSounds.selectedPack?.id == requestedRoute.editTarget?.packID
        else { return nil }
        switch requestedRoute.destination {
        case .overview: return nil
        case .editEvent(_, let event), .copyAndApply(_, let event): return event
        }
    }

    private func reconcileFocusWithVisibleControls(assignFirstIfNil: Bool = false) {
        if let failureFocus = settingsDetail.unavailableFocusTarget(in: activeSounds) {
            if unavailableDetail != settingsDetail {
                unavailableDetail = settingsDetail
                nativeEffects.stopPreview(owner: editorOwner)
                supplement.onLeaveEvent()
            }
            awaitsDeepLinkFocus = false
            detailTitleFocused = false
            focusedTarget = failureFocus
            return
        }
        unavailableDetail = nil
        if case .unavailable = activeSounds.scope {
            awaitsDeepLinkFocus = false
            if let focusedTarget, soundPacksWindowFocusOrder(focusScope).contains(focusedTarget) {
                return
            }
            focusedTarget = .managedScopeFailure
            return
        }
        if awaitsDeepLinkFocus, let target = requestedRoute.editTarget,
            activeSounds.selectedPack?.id == target.packID,
            activeSounds.eventRows.contains(where: { $0.event == target.event })
        {
            awaitsDeepLinkFocus = false
            focusedTarget = .eventAudio(target.event)
            return
        }
        let order = soundPacksWindowFocusOrder(focusScope)
        if let focusedTarget {
            if case .eventAudio(let event) = focusedTarget,
                readOnlyDeepLinkEvent == event,
                activeSounds.eventRows.contains(where: { $0.event == event })
            {
                return
            }
            if !order.contains(focusedTarget) {
                self.focusedTarget = order.first
            }
        } else if assignFirstIfNil, requestedRoute.editTarget != nil {
            self.focusedTarget = order.first
        }
    }

    private var metaSlots: PackRowMetaSlots {
        guard let card = selectedCard else {
            return PackRowMetaSlots(license: .none, missingCount: nil)
        }
        return packRowMetaSlots(
            isCC0: card.isCC0, state: card.state, factoryIntegrity: card.factoryIntegrity)
    }

    private var canEditSelectedPack: Bool {
        activeSounds.requestImportAction != nil
    }

    private var canDeleteSelectedPack: Bool {
        selectedCard?.deleteAction != nil
    }

    private func licenseBadgeLabel(_ badge: PackRowLicenseBadge) -> String? {
        switch badge {
        case .none:
            return nil
        case .cc0:
            return "CC0"
        case .modified:
            return "⚠ " + l10n.text(.soundPacksPackModified)
        }
    }

    private func eventNames(_ events: [Event]) -> String {
        events.map { localizedEventName($0, language: languageStore.language) }
            .joined(separator: languageStore.language == .english ? ", " : "、")
    }

    private func sourceChoiceTitle(_ name: String, usedBy: [Event]) -> String {
        usedBy.isEmpty
            ? name : name + " · " + l10n.format(.soundPacksSourceUsed, eventNames(usedBy))
    }

    private func mappingText(_ row: SoundPackEditorEventPresentation) -> String {
        if let name = row.soundSource?.systemSoundName {
            return l10n.format(
                row.coverage.previewEnabled
                    ? .workspaceSystemSoundFile : .workspaceSystemSoundMissing, name)
        }
        return mappingText(row.coverage)
    }

    private func mappingText(_ coverage: CoverageState) -> String {
        switch coverage {
        case .present(let fileName): return fileName
        case .unmapped: return l10n.text(.soundPacksCoverageUnmapped)
        case .broken(let fileName): return l10n.format(.soundPacksCoverageBroken, fileName)
        }
    }

    private func packAccessibilityLabel(
        _ card: SoundPackEditorPackPresentation
    ) -> String {
        localizedSoundPacksPackAccessibilityLabel(
            displayName: SelectedPackMetadata(id: card.id, name: card.name).displayName,
            isActivePack: card.isActiveForScope,
            state: card.state,
            license: packRowMetaSlots(
                isCC0: card.isCC0,
                state: card.state,
                factoryIntegrity: card.factoryIntegrity
            ).license,
            language: languageStore.language)
    }

    private func packAccessibilityValue(
        _ card: SoundPackEditorPackPresentation
    ) -> String {
        var values: [String] = []
        if card.isInspected {
            values.append(
                l10n.format(
                    .soundPacksSidebarViewing,
                    SelectedPackMetadata(id: card.id, name: card.name).displayName))
        }
        if card.isActiveForScope { values.append(l10n.text(.soundPacksUsing)) }
        return values.isEmpty
            ? l10n.text(.soundPacksPackNotUsed)
            : values.joined(separator: languageStore.language == .english ? ", " : "，")
    }
}

/// Ordinary navigation leaves focus on the Settings title. Deep links name the inspected event
/// even when its read-only mapping has no preview action.
package func soundPacksWindowDeepLinkFocusTarget(
    route: SoundPacksWindowRoute,
    scopeAvailability: SoundPackEditorScopeAvailability,
    selectedPackID: String?,
    visibleEvents: Set<Event>,
    fallback: SoundPacksWindowFocusTarget?
) -> SoundPacksWindowFocusTarget? {
    if case .unavailable = scopeAvailability { return .managedScopeFailure }
    return switch route.destination {
    case .overview: nil
    case .editEvent(let packID, let event), .copyAndApply(let packID, let event):
        selectedPackID == packID && visibleEvents.contains(event)
            ? .eventAudio(event) : fallback
    }
}
