import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Combine
import SoundPacksWindow
import SwiftUI

/// Production Events & Sounds surface corresponding to the prototype's scoped events page.
/// It reuses the panel's manager-owned scope and event projections; full per-event file editing
/// routes inside the same retained Settings window to the embedded Sounds editor.
@MainActor
struct EventSettingsWindowView: View {
    @ObservedObject var model: PanelConfigController
    @ObservedObject var selection: EventSettingsWindowSelection
    @ObservedObject var hostIntegrations: HostIntegrationPresentationStore
    @ObservedObject var languageStore: ClaudioPreferences
    @ObservedObject var aiCueViewModel: AICueGenerationViewModel
    @ObservedObject var soundPacksEditorOwner: SoundPacksEditorOwner

    let soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher
    let performPlatformAction: @MainActor (SettingsPlatformAction) -> Void
    let onNavigateWorkspace: (@MainActor (EventSettingsWindowRoute) -> Void)?
    let onConfigureSound: @MainActor (SoundPacksWindowRoute) -> Void
    let onAudibilityInputsChanged: @MainActor () -> Void
    let onAnnouncement: @MainActor (String) -> Void
    #if DEBUG
    var reloadsOnAppear = true
    #endif
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsUsesCompactLayout) private var compactLayout
    @Environment(\.settingsSuppressesAutomaticContentFocus) private var suppressesContentFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedTarget: EventSettingsFocusTarget?
    @State private var isAddingWorkspace = false
    @State private var previewSequence = EventPreviewSequenceCoordinator()
    @State private var player = NSSoundAudioPreviewPlayer()
    @State private var previewPulseTriggers: [Event: Int] = [:]
    @State private var previewSuccessTokens: [Event: UUID] = [:]
    @State private var migrationSeen = false

    init(
        model: PanelConfigController,
        selection: EventSettingsWindowSelection,
        hostIntegrations: HostIntegrationPresentationStore,
        languageStore: ClaudioPreferences,
        aiCueViewModel: AICueGenerationViewModel,
        soundPacksEditorOwner: SoundPacksEditorOwner,
        soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher,
        performPlatformAction: @escaping @MainActor (SettingsPlatformAction) -> Void,
        onNavigateWorkspace: (@MainActor (EventSettingsWindowRoute) -> Void)? = nil,
        onConfigureSound: @escaping @MainActor (SoundPacksWindowRoute) -> Void,
        onAudibilityInputsChanged: @escaping @MainActor () -> Void,
        onAnnouncement: @escaping @MainActor (String) -> Void
    ) {
        self.model = model
        self.selection = selection
        self.hostIntegrations = hostIntegrations
        self.languageStore = languageStore
        self.aiCueViewModel = aiCueViewModel
        self.soundPacksEditorOwner = soundPacksEditorOwner
        self.soundPacksEditorNativeEffects = soundPacksEditorNativeEffects
        self.performPlatformAction = performPlatformAction
        self.onNavigateWorkspace = onNavigateWorkspace
        self.onConfigureSound = onConfigureSound
        self.onAudibilityInputsChanged = onAudibilityInputsChanged
        self.onAnnouncement = onAnnouncement
    }

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }
    private var detail: WorkspaceSettingsDetail { selection.route.detail }
    private var scopes: [PanelSoundScopePresentation] {
        panelSoundScopePresentations(
            sourceRows: [], config: model.configState.resolvedConfig,
            language: languageStore.language)
    }
    private var current: PanelSoundScopePresentation? {
        scopes.first { $0.scope == selection.route.scope }
    }
    private var rule: WorkspaceSoundRule? {
        model.workspaceRules.first { $0.id == selection.route.scope.workspaceID }
    }
    private var writable: Bool {
        guard case .operational = model.configState else { return false }
        if model.workspaceError == .invalidRule || model.workspaceError == .staleRule {
            return false
        }
        guard selection.route.workspaceTargetIsCurrent(in: model.configState.resolvedConfig)
        else { return false }
        if let target = selection.route.workspaceTarget,
            model.selectedWorkspaceTarget != target
        {
            return false
        }
        return current != nil && selection.unavailableRequestedScopeStoredValue == nil
            && model.selectedSoundScope == selection.route.scope
    }
    private var events: [PanelEventPresentation] {
        panelEventPresentations(
            rows: model.eventRows, scope: selection.route.scope,
            masterVolume: model.config.masterVolume,
            language: languageStore.language, configWritesAllowed: writable,
            safetyFailures: model.previewSafetyFailures)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: SettingsAppearance.sectionGap) {
                        detailContent
                    }
                    .id("workspace-top")
                    .soundPacksLayoutProbe("settings.reading.events-and-sounds")
                    .settingsReadingColumn()
                }
                .accessibilityIdentifier("workspace.settings.scroll")
                .onChange(of: selection.route.detail) { _ in
                    previewSequence.cancel()
                    player.stop()
                    previewSuccessTokens.removeAll()
                    proxy.scrollTo("workspace-top", anchor: .top)
                }
                .onChange(of: selection.presentationState.focusRequestRevision) { _ in
                    if let event = selection.route.event {
                        proxy.scrollTo("workspace-event-\(event.rawValue)", anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsAppearance.background(colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.settings")
        .onAppear {
            migrationSeen = languageStore.hasSeenWorkspaceMigration
            #if DEBUG
            if reloadsOnAppear && !model.usesInjectedPreviewState { model.reload() }
            #else
            model.reload()
            #endif
            synchronize()
        }
        .onChange(of: selection.route) { _ in
            previewSequence.cancel()
            player.stop()
            previewSuccessTokens.removeAll()
            synchronize()
        }
        .onChange(of: model.config.selectedPack) { _ in
            previewSequence.cancel()
            player.stop()
            previewSuccessTokens.removeAll()
        }
        .onChange(of: model.configState) { _ in
            if !selection.route.workspaceTargetIsCurrent(in: model.configState.resolvedConfig) {
                selection.markCurrentScopeUnavailable()
            }
        }
        .onChange(of: selection.presentationState.focusRequestRevision) { _ in synchronize() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) {
            _ in
            restoreDeletionCancelFocus(clearRequest: true)
        }
        .onDisappear {
            previewSequence.cancel()
            player.stop()
            previewSuccessTokens.removeAll()
            selection.cancelDeletion()
            selection.clearReturnFocus()
        }
        .sheet(
            isPresented: Binding(
                get: { selection.presentationState.credentialSheetIsPresented },
                set: {
                    if $0 {
                        selection.presentCredentialSheet()
                    } else {
                        selection.dismissCredentialSheet()
                    }
                })
        ) {
            EventSettingsAICueCredentialSheet(
                viewModel: aiCueViewModel, languageStore: languageStore)
        }
        .settingsMountIdentity(SettingsPresentationAccessibilityID.destination(.eventsAndSounds))
        .sheet(isPresented: $isAddingWorkspace) {
            AddWorkspaceSoundRuleView(model: model, languageStore: languageStore) { id in
                selection.select(EventSettingsWindowRoute(scope: .workspace(id)))
                model.selectSoundScope(.workspace(id))
                isAddingWorkspace = false
            }
        }
        .alert(
            l10n.format(
                .workspaceDeleteConfirmTitle,
                selection.deletionPresentation.pending?.target.name ?? ""),
            isPresented: Binding(
                get: { selection.deletionPresentation.pending != nil },
                set: { presented in
                    guard !presented, let pending = selection.deletionPresentation.pending else {
                        return
                    }
                    // A native dismissal may arrive before its button action. Defer cancellation
                    // until the action has had a chance to consume the captured target.
                    Task { @MainActor in
                        if selection.deletionPresentation.pending == pending {
                            cancelDeletionFromAlert(pending)
                        }
                    }
                }),
            presenting: selection.deletionPresentation.pending
        ) { request in
            Button(l10n.text(.workspaceCancel), role: .cancel) {
                cancelDeletionFromAlert(request)
            }
            .keyboardShortcut(.cancelAction)
            Button(l10n.text(.workspaceDeleteAction), role: .destructive) {
                confirmDeletion(request)
            }
        } message: { request in
            Text(l10n.format(.workspaceDeleteConfirmMessage, request.target.directory.path))
        }
    }

    private var detailContent: AnyView {
        switch detail {
        case .configuration: AnyView(configurationDetail)
        case .workspaces: AnyView(workspaceList)
        case .scope(let target): AnyView(workspaceDetail(target))
        }
    }

    private var configurationDetail: some View {
        Group {
            scopeSelector
            scopeContent
            workspaceNavigation
        }
    }

    @ViewBuilder
    private func workspaceDetail(_ target: WorkspaceSoundWriteTarget) -> some View {
        if let rule, WorkspaceSoundWriteTarget(rule: rule) == target, writable {
            workspaceDetails(rule).settingsSectionSurface()
            if let feedback = selection.deletionPresentation.feedback {
                deletionFeedback(feedback)
            }
            if let error = model.workspaceError { workspaceFailure(error) }
            writeFailures
        } else {
            scopeContent
        }
    }

    private func cancelDeletionFromAlert(_ request: WorkspaceDeletionRequest) {
        guard selection.deletionPresentation.pending == request else { return }
        selection.cancelDeletion()
        // SwiftUI can restore the title while its native alert is closing. Reapply the request
        // after dismissal; the sheet-end callback above handles the later AppKit focus handback.
        restoreDeletionCancelFocus()
    }

    private func restoreDeletionCancelFocus(clearRequest: Bool = false) {
        guard case .workspaceRemove(let id)? = selection.pendingReturnFocusTarget,
            selection.deletionPresentation.pending == nil,
            selection.route.scope == .workspace(id),
            selection.presentationState.focusTarget == .workspaceRemove(id)
        else { return }
        focusedTarget = nil
        DispatchQueue.main.async {
            guard selection.pendingReturnFocusTarget == .workspaceRemove(id),
                selection.deletionPresentation.pending == nil,
                selection.route.scope == .workspace(id),
                selection.presentationState.focusTarget == .workspaceRemove(id)
            else { return }
            focusedTarget = .workspaceRemove(id)
            if clearRequest {
                selection.consumeReturnFocus(.workspaceRemove(id))
            }
        }
    }

    private func synchronize() {
        player.stop()
        // Preserve invalid identities so delayed actions cannot write the Default Group.
        // C1：选择事实住在共享 owner（`SoundScopeSelection`）；这里不再把保留路由推回 model ——
        // 显式选择走 `selectScope`，通用入口经 session 的 applyRoute 跟随 owner，工作区删除
        // 在 `confirmDeletion` 里显式 `selectSoundScope(.global)`。
        if selection.unavailableRequestedScopeStoredValue == nil {
            if !selection.route.workspaceTargetIsCurrent(in: model.configState.resolvedConfig)
                || (selection.route.workspaceTarget != nil
                    && model.selectedWorkspaceTarget != selection.route.workspaceTarget)
            {
                selection.markCurrentScopeUnavailable()
            }
        }
        guard !suppressesContentFocus else { return }
        if let target = selection.presentationState.focusTarget {
            focusedTarget = target
        } else if selection.unavailableRequestedScopeStoredValue != nil {
            focusedTarget = .unavailableScope
        } else {
            focusedTarget =
                selection.route.event.map(EventSettingsFocusTarget.event)
                ?? .scope(selection.route.scope)
        }
    }

    private var libraryNotice: some View {
        Group {
            switch model.libraryPresentationState {
            case .loading:
                Text(l10n.text(.soundPacksLibraryLoading)).font(.caption)
            case .refreshing, .ready:
                EmptyView()
            case .refreshFailed:
                libraryFailure(l10n.text(.panelLibraryRefreshFailed))
            case .loadFailed:
                libraryFailure(l10n.text(.panelAudibleEventsUnavailable))
            }
        }
    }

    private func libraryFailure(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            FailureRow(message: message)
            Button(l10n.text(.soundPacksLibraryRetryLabel)) {
                model.retrySoundPackLibraryRefresh()
            }
            .accessibilityIdentifier("workspace.library.retry")
        }
        .settingsMountIdentity("workspace.library.failure")
    }

    private var scopeSelector: some View {
        SettingsControlRow(title: l10n.text(.settingsDestinationEventsAndSounds)) {
            SettingsNativePopUp(
                l10n.text(.settingsDestinationEventsAndSounds),
                selection: Binding(
                    get: { selection.route.scope },
                    set: selectScope
                ),
                options: (current == nil
                    ? [
                        SettingsMenuOption(
                            selection.route.scope, l10n.text(.workspaceUnavailable),
                            isEnabled: false)
                    ] : []) + scopes.map { SettingsMenuOption($0.scope, $0.name) },
                identifier: "workspace.scope-selector"
            )
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("workspace.scope-selector")
            .focused($focusedTarget, equals: .scope(selection.route.scope))
            .soundPacksLayoutProbe("workspace.scope-selector.control")
        }
        .soundPacksLayoutProbe("workspace.scope-selector.row")
        .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
        .settingsSectionSurface(padding: 0)
        .soundPacksLayoutProbe("workspace.scope-selector.card")
    }

    private func navigateDetail(_ detail: WorkspaceSettingsDetail) {
        let current = selection.route
        let route = EventSettingsWindowRoute(
            scope: current.scope, event: current.event,
            workspaceTarget: current.workspaceTarget,
            unavailableRequestedScopeStoredValue: current.unavailableRequestedScopeStoredValue,
            detail: detail)
        if let onNavigateWorkspace { onNavigateWorkspace(route) } else { selection.select(route) }
    }

    private func selectScope(_ scope: PanelSoundScopeID) {
        guard scopes.contains(where: { $0.scope == scope }) else { return }
        previewSequence.cancel()
        player.stop()
        let target = scope.workspaceID.flatMap { id in
            model.workspaceRules.first(where: { $0.id == id }).map(
                WorkspaceSoundWriteTarget.init(rule:))
        }
        if let onNavigateWorkspace {
            onNavigateWorkspace(EventSettingsWindowRoute(scope: scope, workspaceTarget: target))
        } else {
            selection.select(EventSettingsWindowRoute(scope: scope, workspaceTarget: target))
            model.selectSoundScope(scope, rebindSelectedWorkspace: true)
        }
    }

    private var scopeContent: some View {
        VStack(alignment: .leading, spacing: SettingsAppearance.sectionGap) {
            if !migrationSeen && !model.configState.resolvedConfig.selectedPack.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(l10n.text(.workspaceMigration))
                    Button(l10n.text(.workspaceDismiss)) {
                        languageStore.acknowledgeWorkspaceMigration()
                        migrationSeen = true
                    }
                    .accessibilityIdentifier("workspace.migration-dismiss")
                }.frame(minHeight: 64).settingsSectionSurface()
                    .soundPacksLayoutProbe("workspace.migration.card")
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("workspace.migration-notice")
            }
            if model.workspaceRulesMalformed {
                FailureRow(message: l10n.text(.workspaceInvalidRule))
            }
            if let category = model.configState.errorCopyCategory {
                FailureRow(message: l10n.text(category.key))
                configRevealButton
            }
            if let failure = selection.previewFailure,
                failure.scope == selection.route.scope,
                (failure.packID != model.config.selectedPack || !writable
                    || !model.libraryPresentationState.hasUsableSnapshot)
            {
                FailureRow(
                    message: localizedEventPreviewAttemptFailure(
                        failure.reason, language: languageStore.language)
                )
                .settingsMountIdentity("workspace.event.preview-failure-readback")
                Button(l10n.text(.eventPreviewRepairSound)) {
                    openSoundRepair(
                        scope: failure.scope, packID: failure.packID,
                        event: failure.event,
                        readOnly: failure.sourcePackReadOnly,
                        workspaceTarget: failure.workspaceTarget)
                }
                .accessibilityIdentifier("workspace.event.preview-failure-repair")
            }
            if selection.conflictWasReadBack {
                FailureRow(message: l10n.text(.eventSettingsConflictReadback))
                    .settingsMountIdentity("workspace.write.conflict-readback")
                recoveryFileButtons(
                    selection.conflictRecoveryFiles,
                    identifierPrefix: "workspace.write.conflict-recovery-file")
            }
            unresolvedConflictNotice
            if let failure = selection.writeRetryFailure {
                FailureRow(message: writeRetryFailureMessage(failure))
                    .focusable()
                    .settingsMountIdentity("workspace.write.retry-failure")
            }
            if let feedback = selection.deletionPresentation.feedback {
                deletionFeedback(feedback)
            } else if let error = model.workspaceError,
                !isRetainedWorkspaceConflict(error),
                !(error == .lockBusy && selection.writeRetryFailure != nil)
            {
                workspaceFailure(error)
            }
            libraryNotice
            if writable {
                if model.libraryPresentationState.hasUsableSnapshot {
                    VStack(alignment: .leading, spacing: SettingsAppearance.informationGap) {
                        soundControls
                        if model.config.hasLegacySystemSounds {
                            Text(l10n.text(.soundPacksLegacySystemSounds))
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("workspace.legacy-system-sounds")
                        }
                        VStack(spacing: 0) {
                            ForEach(events) { event in
                                eventRow(event)
                                    .padding(
                                        .horizontal, SettingsAppearance.controlRowHorizontalPadding
                                    )
                                    .padding(
                                        .vertical, SettingsAppearance.controlRowVerticalPadding
                                    )
                                    .frame(minHeight: SettingsAppearance.multilineControlRowHeight)
                                    .soundPacksLayoutProbe(
                                        "workspace.event-row.\(event.event.rawValue)"
                                    )
                                    .id("workspace-event-\(event.event.rawValue)")
                                if event.event != events.last?.event {
                                    Divider().padding(.horizontal, 14)
                                }
                            }
                        }
                        .settingsSectionSurface(padding: 0)
                        .soundPacksLayoutProbe("workspace.events.group")
                    }
                    previewControls
                }
                Button(l10n.text(.eventSettingsManageSounds)) {
                    openSoundOverview(scope: selection.route.scope)
                }
            } else {
                Text(l10n.text(.workspaceUnavailable)).foregroundColor(.secondary)
                    .focusable()
                    .focused($focusedTarget, equals: .unavailableScope)
                    .settingsMountIdentity("workspace.scope.unavailable")
                if selection.route.scope != .global {
                    Button(l10n.text(.workspaceChooseDefaultGroup)) {
                        player.stop()
                        selection.select(EventSettingsWindowRoute(scope: .global))
                        model.selectSoundScope(.global)
                    }
                    .settingsMountIdentity("workspace.choose-default-group")
                }
            }
            writeFailures
        }
    }

    private var detailTitle: String {
        switch detail {
        case .configuration: l10n.text(.settingsDestinationEventsAndSounds)
        case .workspaces: l10n.text(.settingsNativeWorkspaces)
        case .scope: current?.name ?? l10n.text(.workspaceUnavailable)
        }
    }

    private var workspaceNavigation: some View {
        Button {
            if let rule {
                navigateDetail(.scope(WorkspaceSoundWriteTarget(rule: rule)))
            } else {
                navigateDetail(.workspaces)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        l10n.text(
                            rule == nil
                                ? .settingsNativeManageWorkspaces
                                : .settingsNativeDirectoryAndSurfaces))
                    Text(rule?.directory.path ?? l10n.text(.workspaceDefaultApplicability))
                        .font(SettingsAppearance.font(.caption)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 33).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settingsSectionSurface(padding: 14)
        .settingsMountIdentity("workspace.open-management")
    }

    private var workspaceList: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.workspaceRules.isEmpty {
                Text(l10n.text(.settingsNativeNoWorkspaces)).foregroundStyle(.secondary)
            }
            ForEach(model.workspaceRules, id: \.id) { rule in
                Button {
                    selectScope(.workspace(rule.id))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.name)
                            Text(rule.directory.path).font(SettingsAppearance.font(.caption))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .settingsSectionSurface(padding: 14)
                .accessibilityIdentifier("workspace.rule.\(rule.id.uuidString)")
            }
            Text(l10n.text(.workspaceGitScope) + "\n" + l10n.text(.workspacePlainScope))
                .font(SettingsAppearance.font(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(l10n.text(.workspaceAdd)) { isAddingWorkspace = true }
                .accessibilityIdentifier("workspace.add")
        }
    }

    private var soundControls: some View {
        let scope = selection.route.scope
        let workspaceTarget = model.selectedWorkspaceTarget
        return SettingsSectionCard(
            title: current?.name ?? l10n.text(.workspaceUnavailable),
            padding: SettingsAppearance.controlRowHorizontalPadding
        ) {
            VStack(alignment: .leading, spacing: 8) {
            SettingsControlRow(title: l10n.text(.panelSoundPackLabel)) {
                    SettingsNativePopUp(
                    l10n.text(.panelSoundPackLabel),
                    selection: Binding(
                        get: { model.config.selectedPack },
                        set: {
                            guard model.selectedSoundScope == scope else { return }
                            previewSequence.cancel()
                            player.stop()
                            previewSuccessTokens.removeAll()
                            let retry = EventSettingsWriteRetry(
                                scope: scope, workspaceDirectory: workspaceTarget?.directory,
                                operation: .pack(before: model.config.selectedPack, requested: $0))
                            selection.clearConflictReadback()
                            _ = model.switchPack(to: $0)
                            selection.noteWriteResult(retry, using: model)
                            selection.clearPreviewFailure()
                            onAudibilityInputsChanged()
                            }),
                        options: (model.allSoundPacks.contains(where: {
                            $0.id == model.config.selectedPack
                        })
                            ? []
                            : [
                                SettingsMenuOption(
                                    model.config.selectedPack, model.config.selectedPack,
                                    isEnabled: false)
                            ])
                            + model.allSoundPacks.map {
                                SettingsMenuOption(
                                    $0.id,
                                    SelectedPackMetadata(id: $0.id, name: $0.name).displayName)
                            }, identifier: "event-settings.sound-pack-picker"
                    )
                    .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("event-settings.sound-pack-picker")
                .focused($focusedTarget, equals: .packPicker)
                .soundPacksLayoutProbe("event-settings.sound-pack-picker.control")
            }
            .soundPacksLayoutProbe("event-settings.sound-pack-picker.row")
            Divider()
            EventSettingsMasterVolumeControl(
                diskVolume: model.config.masterVolume, isEnabled: writable,
                language: languageStore.language, focusedTarget: $focusedTarget
            ) { volume in
                let retry = EventSettingsWriteRetry(
                    scope: scope, workspaceDirectory: workspaceTarget?.directory,
                    operation: .volume(before: model.config.masterVolume, requested: volume))
                selection.clearConflictReadback()
                let landed = model.setVolume(
                    volume, for: scope, workspaceTarget: workspaceTarget)
                selection.noteWriteResult(retry, using: model)
                selection.clearPreviewFailure()
                onAudibilityInputsChanged()
                return landed
            }.id(selection.route.scope)
            if model.eventRows.contains(where: {
                if case .broken = $0.coverage { return true }; return false
            })
                || eventSettingsPackNeedsRepair(
                    selectedPackID: model.config.selectedPack, cards: model.allSoundPacks)
            {
                FailureRow(message: l10n.text(.workspacePackRepair))
                    .accessibilityIdentifier("workspace.pack.repair-reason")
            }
            }
        }
            .soundPacksLayoutProbe("workspace.configuration.card")
    }

    private var previewControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(l10n.text(.eventSettingsPreviewAll)) { previewAvailableEvents() }
                .disabled(!events.contains(where: { $0.controls.previewEnabled }))
                .accessibilityIdentifier("workspace.preview-available")
            Text(
                l10n.text(
                    events.contains(where: { $0.controls.previewEnabled })
                        ? .workspacePreviewNote : .eventPreviewNoAvailableEvents)
            ).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func previewAvailableEvents() {
        let scope = selection.route.scope
        let target = model.selectedWorkspaceTarget
        let packID = model.config.selectedPack
        let available = events.filter { $0.controls.previewEnabled }.map(\.event)
        let generation = selection.beginPreviewSequence()
        Task { @MainActor in
            _ = await previewSequence.run(
                events: available,
                isCurrent: {
                    selection.route.scope == scope && model.selectedWorkspaceTarget == target
                        && model.config.selectedPack == packID
                }
            ) { event in
                switch model.attemptPreview(event, using: player) {
                case .started:
                    selection.clearPreviewFailure()
                    previewPulseTriggers[event, default: 0] &+= 1
                    return model.previewDuration(for: event) ?? 3
                case .failed(let failure):
                    reportPreviewFailure(
                        failure, event: event, scope: scope, packID: model.config.selectedPack,
                        sourcePackReadOnly: model.selectedPackIsBuiltinReadOnly)
                    return nil
                }
            }
            _ = selection.completePreviewSequence(generation: generation)
        }
    }

    private func workspaceDetails(_ rule: WorkspaceSoundRule) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.text(.workspaceDirectory)).font(.headline)
            Text(rule.directory.path).textSelection(.enabled).font(
                .system(.body, design: .monospaced))
            Text(l10n.text(rule.directory.kind == .git ? .workspaceGitScope : .workspacePlainScope))
                .font(.caption)
            Text(l10n.text(.workspaceSurfaces)).font(.headline)
            ForEach(WorkspaceSurfaceEligibility.candidates, id: \.rawValue) { surface in
                let host = HostID.productVisibleCases.first { $0.surfaceID == surface }
                let sourceRow = hostIntegrations.content.sourceRows.first {
                    $0.host.surfaceID == surface
                }
                let localizedSourceRow = sourceRow.map {
                    localizedHostSourceRow($0, language: languageStore.language)
                }
                Toggle(
                    isOn: Binding(
                        get: { rule.surfaces.contains(surface) },
                        set: { enabled in
                            var surfaces = rule.surfaces.filter { $0 != surface }
                            if enabled { surfaces.append(surface) }
                            let retry = EventSettingsWriteRetry(
                                scope: .workspace(rule.id), workspaceDirectory: rule.directory,
                                operation: .surfaces(before: rule.surfaces, requested: surfaces))
                            selection.clearConflictReadback()
                            _ = model.changeWorkspace(
                                .surfaces(WorkspaceSoundWriteTarget(rule: rule), surfaces))
                            selection.noteWriteResult(retry, using: model)
                        })
                ) {
                    VStack(alignment: .leading) {
                        Text(host?.displayName ?? surface.rawValue)
                        Text(
                            !WorkspaceSurfaceEligibility.verified.contains(surface)
                                ? l10n.text(.workspaceEvidencePending)
                                : localizedSourceRow.map {
                                    "\($0.readinessText) · \($0.coverageText)"
                                } ?? l10n.text(.workspaceDisconnected)
                        )
                        .font(.caption).foregroundColor(.secondary)
                    }
                }.disabled(!WorkspaceSurfaceEligibility.verified.contains(surface))
            }
            if rule.surfaces.isEmpty { Text(l10n.text(.workspaceNoSurfaces)).font(.caption) }
            Text("WorkBuddy · " + l10n.text(.workspaceEvidencePending)).font(.caption)
                .foregroundColor(.secondary)
            workspaceRemoveButton(rule)
                .focused($focusedTarget, equals: .workspaceRemove(rule.id))
                .settingsMountIdentity("workspace.remove")
        }
    }

    @ViewBuilder
    private func workspaceRemoveButton(_ rule: WorkspaceSoundRule) -> some View {
        SettingsFocusableButton(
            l10n.text(.workspaceRemove),
            requestsFocus: selection.pendingReturnFocusTarget == .workspaceRemove(rule.id)
                || selection.presentationState.focusTarget == .workspaceRemove(rule.id)
        ) {
            _ = selection.requestDeletion(of: rule)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func deletionFeedback(_ feedback: WorkspaceDeleteFeedback) -> some View {
        switch feedback {
        case .succeeded(let target):
            Label(
                l10n.format(.workspaceDeleteSucceeded, target.name),
                systemImage: "checkmark.circle.fill"
            )
            .focusable()
            .focused($focusedTarget, equals: .workspaceDeleteResult)
            .settingsMountIdentity("workspace.delete.result")
        case .failed(let target, let error, let readback):
            FailureRow(message: deletionFailureMessage(target, error: error, readback: readback))
                .focusable()
                .focused($focusedTarget, equals: .workspaceDeleteFeedback)
                .settingsMountIdentity("workspace.delete.failure")
            if error == .configFailure || error == .invalidRule || error.isPublishedConflict {
                configRevealButton
            }
            recoveryFileButtons(
                error.recoveryPath.map { [URL(fileURLWithPath: $0)] } ?? [],
                identifierPrefix: "workspace.delete.recovery-file")
            Button(l10n.text(.workspaceDeleteReload)) {
                model.reload()
                selection.refreshDeletionReadback(configState: model.configState)
            }
            .accessibilityIdentifier("workspace.delete.reload")
            if error == .lockBusy {
                Button(l10n.text(.commonRetry)) {
                    if !selection.retryDeletion(using: model),
                        case .failed(let failedTarget, let reason, let readback)? =
                            selection.deletionPresentation.feedback
                    {
                        onAnnouncement(
                            deletionFailureMessage(
                                failedTarget, error: reason, readback: readback))
                    }
                }
                .accessibilityIdentifier("workspace.delete.retry-confirmation")
            }
        }
    }

    private func workspaceFailure(_ error: WorkspaceSoundError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FailureRow(message: localizedWorkspaceError(error, language: languageStore.language))
            if error == .configFailure || error == .invalidRule || error.isPublishedConflict {
                configRevealButton
            }
            recoveryFileButtons(
                model.workspaceRecoveryFile.map { [$0] } ?? [],
                identifierPrefix: "workspace.write.recovery-file")
            if error == .invalidPack {
                Button(l10n.text(.eventSettingsManageSounds)) {
                    openSoundOverview(scope: selection.route.scope)
                }
            }
            if error == .lockBusy, canRetryCurrentWrite {
                Button(l10n.text(.commonRetry)) { retryCurrentWrite() }
                    .accessibilityIdentifier("workspace.write.retry")
            }
            if error == .configFailure || error == .invalidRule || error.isPublishedConflict
                || error == .staleRule
            {
                Button(l10n.text(.workspaceDeleteReload)) {
                    if error.isPublishedConflict {
                        reloadConflict(
                            .workspace(error),
                            recoveryFiles: model.workspaceRecoveryFile.map { [$0] } ?? [])
                    } else {
                        model.reload()
                    }
                }
                .accessibilityIdentifier("workspace.write.reload")
            }
        }
        .settingsMountIdentity("workspace.write.failure")
    }

    private func recoveryFileButtons(
        _ files: [URL], identifierPrefix: String
    ) -> some View {
        let existing = files.compactMap(panelExistingRecoveryFileTarget)
        return ForEach(Array(existing.enumerated()), id: \.element) { index, file in
            Button(
                existing.count == 1
                    ? l10n.text(.panelRevealRecoveryFile)
                    : l10n.format(.panelRevealRecoveryFileNumber, Int64(index + 1))
            ) {
                guard let currentTarget = panelExistingRecoveryFileTarget(file) else { return }
                performPlatformAction(.revealInFinder(currentTarget))
            }
            .accessibilityValue(file.path)
            .accessibilityIdentifier("\(identifierPrefix).\(index + 1)")
        }
    }

    @ViewBuilder
    private var configRevealButton: some View {
        if let target = model.configRecoveryTarget {
            Button(l10n.text(.panelRevealConfig)) {
                guard let currentTarget = model.configRecoveryTarget else { return }
                performPlatformAction(.revealInFinder(currentTarget))
            }
            .accessibilityHint(l10n.text(.panelRevealConfigHint))
            .accessibilityIdentifier("workspace.reveal-config")
            .accessibilityValue(target.path)
        }
    }

    private var writeFailureItems: [PanelWriteFailure] {
        panelWriteFailureItems(
            muteError: model.muteError,
            packSwitchError: model.packSwitchError,
            masterVolumeError: model.masterVolumeError)
    }

    private var writeFailures: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(panelWriteFailureRows(items: writeFailureItems, l10n: l10n)) { row in
                FailureRow(message: row.message)
            }
            recoveryFileButtons(
                writeFailureRecoveryFiles,
                identifierPrefix: "workspace.write.reveal-recovery")
            if writeFailureItems.contains(where: { $0.reason.copyCategory.offersConfigRecovery }) {
                configRevealButton
            }
            if writeFailureItems.contains(where: {
                if case .lockBusy = $0.reason { return true }
                return false
            }), canRetryCurrentWrite {
                Button(l10n.text(.commonRetry)) { retryCurrentWrite() }
                    .accessibilityIdentifier("workspace.write.retry")
            }
            if writeFailureItems.contains(where: {
                if case .configPublishedButFailed = $0.reason { return true }
                return false
            }) {
                Button(l10n.text(.workspaceDeleteReload)) {
                    reloadConflict(
                        .writes(writeFailureItems), recoveryFiles: writeFailureRecoveryFiles)
                }
                .accessibilityIdentifier("workspace.write.reload")
            }
        }
    }

    private var writeFailureRecoveryFiles: [URL] {
        panelWriteFailureRecoveryFiles(items: writeFailureItems, surfaceRecoveryFile: nil)
    }

    @ViewBuilder
    private var unresolvedConflictNotice: some View {
        if let source = selection.unresolvedConflict {
            VStack(alignment: .leading, spacing: 8) {
                switch source {
                case .workspace(let error):
                    FailureRow(
                        message: localizedWorkspaceError(error, language: languageStore.language))
                case .writes(let failures):
                    ForEach(panelWriteFailureRows(items: failures, l10n: l10n)) { row in
                        FailureRow(message: row.message)
                    }
                }
                configRevealButton
                recoveryFileButtons(
                    selection.conflictRecoveryFiles,
                    identifierPrefix: "workspace.write.unresolved-recovery-file")
                Button(l10n.text(.workspaceDeleteReload)) {
                    reloadConflict(source, recoveryFiles: selection.conflictRecoveryFiles)
                }
                .accessibilityIdentifier("workspace.write.unresolved-reload")
            }
            .settingsMountIdentity("workspace.write.conflict-unresolved")
        }
    }

    private func isRetainedWorkspaceConflict(_ error: WorkspaceSoundError) -> Bool {
        guard case .workspace(let retained)? = selection.unresolvedConflict else { return false }
        return retained == error
    }

    private func reloadConflict(
        _ source: EventSettingsConflictSource, recoveryFiles: [URL]
    ) {
        let scope = selection.route.scope
        model.reload()
        _ = selection.finishConflictReadback(
            scope: scope, configState: model.configState, source: source,
            recoveryFiles: recoveryFiles)
    }

    private var canRetryCurrentWrite: Bool {
        selection.writeRetry != nil
    }

    private func retryCurrentWrite() {
        if selection.retryWrite(using: model) {
            onAudibilityInputsChanged()
        } else if let failure = selection.writeRetryFailure {
            onAnnouncement(writeRetryFailureMessage(failure))
        }
    }

    private func writeRetryFailureMessage(_ failure: EventSettingsWriteRetryFailure) -> String {
        switch failure {
        case .targetChanged: l10n.text(.eventSettingsRetryTargetChanged)
        case .readbackUnavailable: l10n.text(.eventSettingsRetryReadbackUnavailable)
        }
    }

    private func deletionFailureMessage(
        _ target: WorkspaceSoundDeleteTarget,
        error: WorkspaceSoundError,
        readback: WorkspaceDeleteReadback?
    ) -> String {
        let reason = localizedWorkspaceError(error, language: languageStore.language)
        var message = l10n.format(.workspaceDeleteFailed, target.name, reason)
        if let readback {
            let key: ClaudioL10nKey
            switch readback {
            case .originalPresent: key = .workspaceDeleteReadbackPresent
            case .absent: key = .workspaceDeleteReadbackAbsent
            case .replaced: key = .workspaceDeleteReadbackReplaced
            case .unavailable: key = .workspaceDeleteReadbackUnavailable
            }
            message += " " + l10n.text(key)
        }
        return message
    }

    private func confirmDeletion(_ request: WorkspaceDeletionRequest) {
        guard selection.consumeDeletion(request) else { return }
        let target = request.target
        let succeeded = model.changeWorkspace(.remove(target))
        let error = model.workspaceError
        let selectedDefault = selection.finishDeletion(
            request, succeeded: succeeded, error: error, configState: model.configState)
        if selectedDefault { model.selectSoundScope(.global) }
        if let feedback = selection.deletionPresentation.feedback {
            switch feedback {
            case .succeeded:
                onAnnouncement(l10n.format(.workspaceDeleteSucceeded, target.name))
            case .failed(let failedTarget, let reason, let readback):
                onAnnouncement(
                    deletionFailureMessage(
                        failedTarget, error: reason, readback: readback))
            }
        }
    }

    private func eventRow(_ event: PanelEventPresentation) -> some View {
        let scope = selection.route.scope
        let recovery = eventPreviewRecoveryAction(for: event.controls.previewAvailability)
        let failure = selection.previewFailure.flatMap {
            $0.scope == scope && $0.packID == model.config.selectedPack
                && $0.event == event.event ? $0 : nil
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ClaudioEventGlyph(event: event.event, size: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(SettingsAppearance.font(.body).weight(.semibold))
                    Text(event.soundFileText).font(.caption).foregroundColor(.secondary)
                        .fixedSize(
                            horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint(
                    localizedEventPreviewHint(
                        event.controls.previewAvailability,
                        language: languageStore.language)
                )
                .focusable()
                .focused($focusedTarget, equals: .event(event.event))
                Spacer()
                Button {
                    previewSequence.cancel()
                    let packID = model.config.selectedPack
                    let sourcePackReadOnly = model.selectedPackIsBuiltinReadOnly
                    switch model.attemptPreview(event.event, using: player) {
                    case .started:
                        selection.clearPreviewFailure()
                        previewPulseTriggers[event.event, default: 0] &+= 1
                        let token = UUID()
                        previewSuccessTokens[event.event] = token
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            if previewSuccessTokens[event.event] == token {
                                previewSuccessTokens.removeValue(forKey: event.event)
                            }
                        }
                    case .failed(let failure):
                        previewSuccessTokens.removeValue(forKey: event.event)
                        reportPreviewFailure(
                            failure, event: event.event, scope: scope, packID: packID,
                            sourcePackReadOnly: sourcePackReadOnly)
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .claudioPreviewPulse(
                            trigger: previewPulseTriggers[event.event, default: 0])
                }
                .disabled(!event.controls.previewEnabled)
                .accessibilityLabel(l10n.format(.eventPreviewLabel, event.title))
                .accessibilityHint(
                    localizedEventPreviewHint(
                        event.controls.previewAvailability,
                        language: languageStore.language)
                )
                .focused($focusedTarget, equals: .preview(event.event))
                Button {
                    configureSound(event.event, scope: scope)
                } label: {
                    Label(l10n.text(.settingsNativeEditCue), systemImage: "chevron.right")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .accessibilityLabel(l10n.text(.settingsNativeEditCue) + " " + event.title)
                .accessibilityIdentifier("workspace.event.\(event.event.rawValue).edit")
                .disabled(!writable)
                .focused($focusedTarget, equals: .configure(event.event))
                Toggle(
                    event.title,
                    isOn: Binding(
                        get: { event.enabled },
                        set: { _ in
                            guard model.selectedSoundScope == scope else { return }
                            let retry = EventSettingsWriteRetry(
                                scope: scope,
                                workspaceDirectory: model.selectedWorkspaceTarget?.directory,
                                operation: .event(
                                    event.event, before: model.config.isEnabled(event.event)))
                            selection.clearConflictReadback()
                            model.toggleMute(event.event)
                            selection.noteWriteResult(retry, using: model)
                            selection.clearPreviewFailure()
                            onAudibilityInputsChanged()
                        })
                ).labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(
                    !event.controls.muteEnabled
                )
                    .focused($focusedTarget, equals: .mute(event.event))
            }
            if !event.controls.previewEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        localizedEventPreviewHint(
                            event.controls.previewAvailability,
                            language: languageStore.language)
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(
                        "workspace.event.preview-reason.\(event.event.cliName)")
                    if recovery == .adjustGroupVolume {
                        Button(l10n.text(.eventPreviewAdjustGroupVolume)) {
                            guard selection.requestGroupVolumeFocus(for: scope) else { return }
                            focusedTarget = .masterVolume
                        }
                        .accessibilityIdentifier(
                            "workspace.event.adjust-volume.\(event.event.cliName)")
                    }
                }
                .padding(.leading, 36)
            }
            if reduceMotion && previewSuccessTokens[event.event] != nil {
                Label(l10n.text(.eventPreviewStarted), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(SettingsAppearance.accent(colorScheme))
                    .accessibilityIdentifier(
                        "workspace.event.preview-started.\(event.event.cliName)")
            }
            if let failure {
                FailureRow(
                    message: localizedEventPreviewAttemptFailure(
                        failure.reason, language: languageStore.language)
                )
                .settingsMountIdentity("workspace.event.preview-failure.\(event.event.cliName)")
            }
        }.frame(minHeight: 38)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workspace.event.\(event.event.cliName)")
    }

    private func configureSound(_ event: Event, scope: PanelSoundScopeID) {
        guard model.selectedSoundScope == scope, selection.route.scope == scope else { return }
        openSoundRepair(
            scope: scope, packID: model.config.selectedPack, event: event,
            readOnly: model.selectedPackIsBuiltinReadOnly,
            workspaceTarget: model.selectedWorkspaceTarget)
    }

    private func openSoundOverview(scope: PanelSoundScopeID) {
        guard model.selectedSoundScope == scope, selection.route.scope == scope else { return }
        let target = model.selectedWorkspaceTarget
        guard scope.workspaceID == nil || target?.id == scope.workspaceID else {
            onAnnouncement(localizedWorkspaceError(.staleRule, language: languageStore.language))
            return
        }
        onConfigureSound(.overview(scope: scope, workspaceTarget: target))
    }

    private func openSoundRepair(
        scope: PanelSoundScopeID,
        packID: String,
        event: Event,
        readOnly: Bool,
        workspaceTarget: WorkspaceSoundWriteTarget?
    ) {
        guard scope.workspaceID == nil || workspaceTarget?.id == scope.workspaceID else {
            onAnnouncement(localizedWorkspaceError(.staleRule, language: languageStore.language))
            return
        }
        onConfigureSound(
            readOnly
                ? .copyAndApply(
                    scope: scope, packID: packID, event: event,
                    workspaceTarget: workspaceTarget)
                : .editEvent(
                    scope: scope, packID: packID, event: event,
                    workspaceTarget: workspaceTarget))
    }

    private func reportPreviewFailure(
        _ reason: EventPreviewAttemptFailure,
        event: Event,
        scope: PanelSoundScopeID,
        packID: String,
        sourcePackReadOnly: Bool
    ) {
        guard
            selection.notePreviewFailure(
                event: event, scope: scope, packID: packID, reason: reason,
                sourcePackReadOnly: sourcePackReadOnly,
                workspaceTarget: model.selectedWorkspaceTarget)
        else { return }
        let message = localizedEventPreviewAttemptFailure(reason, language: languageStore.language)
        onAnnouncement(message)
    }
}

@MainActor
private struct AddWorkspaceSoundRuleView: View {
    @ObservedObject var model: PanelConfigController
    @ObservedObject var languageStore: ClaudioPreferences
    let onCreated: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var directory: WorkspaceDirectory?
    @State private var selectedPack = ""
    @State private var volume = ClaudioConfig.defaultMasterVolume
    @State private var volumeConfirmed = false
    @State private var surfaces = WorkspaceSurfaceEligibility.verified
    @State private var resolving = false
    @State private var failure: WorkspaceSoundError?
    @State private var resolutionTask: Task<Void, Never>?
    @State private var resolutionID: UUID?
    private var language: ClaudioAppLanguage { languageStore.language }
    private var l10n: ClaudioL10n { ClaudioL10n(language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n.text(.workspaceAdd)).font(SettingsAppearance.pageTitle)
            Text(l10n.text(.settingsNativeWorkspaceCreation))
                .font(SettingsAppearance.font(.secondary)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(l10n.text(.workspaceChooseDirectory)) { chooseDirectory() }.disabled(resolving)
            if let directory {
                Text(URL(fileURLWithPath: directory.path).lastPathComponent)
                    .font(SettingsAppearance.font(.sectionTitle))
                Text(directory.path).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(l10n.text(directory.kind == .git ? .workspaceGitScope : .workspacePlainScope))
                    .font(.caption)
            }
            SettingsControlRow(title: l10n.text(.panelSoundPackLabel)) {
                SettingsNativePopUp(
                    l10n.text(.panelSoundPackLabel), selection: $selectedPack,
                    options: [
                        SettingsMenuOption("", l10n.text(.workspaceSelectPack), isEnabled: false)
                    ]
                        + model.allSoundPacks.map {
                            SettingsMenuOption(
                                $0.id, SelectedPackMetadata(id: $0.id, name: $0.name).displayName)
                        }, identifier: "workspace.new.sound-pack-picker"
                )
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("workspace.new.sound-pack-picker")
                .soundPacksLayoutProbe("workspace.new.sound-pack-picker.control")
            }
            .soundPacksLayoutProbe("workspace.new.sound-pack-picker.row")
            HStack {
                Text(l10n.text(.panelMasterVolume))
                Slider(value: $volume, in: 0...1).accessibilityLabel(l10n.text(.panelMasterVolume))
                    .onChange(of: volume) { _ in
                        volumeConfirmed = false
                    }
                Text("\(Int(volume * 100))%").monospacedDigit()
            }
            Toggle(l10n.text(.workspaceVolumeConfirm), isOn: $volumeConfirmed)
            Text(l10n.text(.workspaceSurfaces)).font(SettingsAppearance.font(.sectionTitle))
            ForEach(WorkspaceSurfaceEligibility.candidates, id: \.rawValue) { surface in
                Toggle(
                    HostID.productVisibleCases.first { $0.surfaceID == surface }?.displayName
                        ?? surface.rawValue,
                    isOn: Binding(
                        get: { surfaces.contains(surface) },
                        set: {
                            if $0 { surfaces.insert(surface) } else { surfaces.remove(surface) }
                        })
                ).disabled(!WorkspaceSurfaceEligibility.verified.contains(surface))
            }
            if WorkspaceSurfaceEligibility.verified.isEmpty {
                Text(l10n.text(.workspaceEvidencePending)).font(.caption)
            }
            if let error = failure ?? model.workspaceError {
                FailureRow(message: localizedWorkspaceError(error, language: language))
            }
            HStack {
                Button(l10n.text(.workspaceCancel)) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(l10n.text(.workspaceCreate)) {
                    guard let directory else { return }
                    let rule = WorkspaceSoundRule(
                        directory: directory,
                        surfaces: surfaces.sorted { $0.rawValue < $1.rawValue },
                        profile: WorkspaceSoundProfile(selectedPack: selectedPack, volume: volume))
                    if model.changeWorkspace(.add(rule)) { onCreated(rule.id) }
                }.disabled(
                    directory == nil || selectedPack.isEmpty || !volumeConfirmed || resolving
                )
                .keyboardShortcut(.defaultAction)
            }
        }.font(SettingsAppearance.font(.body)).padding(24).frame(width: 520)
            .onDisappear {
                resolutionID = nil
                resolutionTask?.cancel()
                resolutionTask = nil
            }
    }
    private func chooseDirectory() {
        guard let url = runWorkspaceDirectoryOpenPanel() else { return }
        resolving = true; failure = nil
        let identity = UUID()
        resolutionID = identity
        resolutionTask?.cancel()
        resolutionTask = Task {
            let result = await Task.detached { WorkspaceDirectoryResolver.resolve(url.path) }.value
            guard !Task.isCancelled, resolutionID == identity else { return }
            resolving = false
            resolutionTask = nil
            switch result {
            case .success(let resolved): directory = resolved
            case .failure: directory = nil; failure = .invalidRule
            }
        }
    }
}

/// Settings wrapper around the shared slider lifecycle; only its wider label layout and focus
/// identity differ from the compact panel row.
@MainActor
private struct EventSettingsMasterVolumeControl: View {
    let diskVolume: Double
    let isEnabled: Bool
    let language: ClaudioAppLanguage
    let onCommit: (Double) -> Double?
    private let focusedTarget: FocusState<EventSettingsFocusTarget?>.Binding

    init(
        diskVolume: Double,
        isEnabled: Bool,
        language: ClaudioAppLanguage,
        focusedTarget: FocusState<EventSettingsFocusTarget?>.Binding,
        onCommit: @escaping (Double) -> Double?
    ) {
        self.diskVolume = diskVolume
        self.isEnabled = isEnabled
        self.language = language
        self.focusedTarget = focusedTarget
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ClaudioL10n(language: language).text(.panelMasterVolume))
                    .font(SettingsAppearance.font(.body).weight(.semibold))
                Text(ClaudioL10n(language: language).text(.panelMasterVolumeDescription))
                    .font(SettingsAppearance.font(.caption))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 10)
            SharedMasterVolumeSlider(
                diskVolume: diskVolume,
                isEnabled: isEnabled,
                language: language,
                accessibilityIdentifier: "event-settings.master-volume",
                flushesOnDisappear: true,
                usesSettingsAppearance: true,
                onCommit: onCommit
            )
            .focused(focusedTarget, equals: .masterVolume)
            .frame(maxWidth: 302)
        }
    }
}
