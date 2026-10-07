import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SoundPacksWindow
import SwiftUI

package enum AICuePackDraftNameEdit: Equatable {
    case noDraft
    case unchanged
    case pending(AICuePackName)
    case invalid

    package var needsSave: Bool {
        switch self {
        case .pending, .invalid: true
        case .noDraft, .unchanged: false
        }
    }

    package var savableName: AICuePackName? {
        guard case .pending(let name) = self else { return nil }
        return name
    }
}

package func aiCuePackDraftNameEdit(draftName: String?, input: String) -> AICuePackDraftNameEdit {
    guard let draftName else { return .noDraft }
    guard let name = try? AICuePackName(input) else { return .invalid }
    if name.value == draftName { return .unchanged }
    return .pending(name)
}

/// Package-scoped AI cue generation belongs to the Sounds destination. Events & Sounds keeps its
/// source facts and missing-sound deep links, while this view owns the visible package/event
/// composer and the one-shot adoption permit that the retained editor owner signs.
@MainActor
struct SettingsSoundsAICueView: View {
    @ObservedObject var viewModel: AICueGenerationViewModel
    @ObservedObject var editorOwner: SoundPacksEditorOwner
    @ObservedObject var languageStore: ClaudioPreferences
    let nativeEffects: SoundPacksEditorNativeEffectsDispatcher
    let route: SoundPacksWindowRoute
    let routeRequestRevision: UInt64
    let detail: SoundPacksSettingsDetail
    let onDetailIntent: @MainActor (SoundPacksWindowRoute.Destination) -> Void
    var onInspectPack: (@MainActor (String) -> Void)? = nil
    var pageHeader: AnyView = AnyView(EmptyView())
    var scopePicker: AnyView = AnyView(EmptyView())
    var returnToScope: (@MainActor () -> Void)? = nil
    let onAnnouncement: @MainActor (String) -> Void
    @Binding var credentialSheetIsPresented: Bool
    @Binding var playingCandidateID: UUID?

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedEvent: Event?
    @State private var pendingRouteSession: AICueComposerSession?
    @State private var draftNameInput = ""
    @State private var renamingDraftID: String?
    @FocusState private var draftNameButtonFocused: Bool

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }

    private var sounds: SoundsEditorPresentation? {
        guard case .sounds(let presentation) = editorOwner.presentation.mode else { return nil }
        return presentation
    }

    private var selectedPack: SoundPackEditorPackPresentation? { sounds?.selectedPack }

    private var draftNameEdit: AICuePackDraftNameEdit {
        aiCuePackDraftNameEdit(draftName: sounds?.draft?.name, input: draftNameInput)
    }

    private var activePackID: String? {
        sounds?.draft?.packID ?? selectedPack?.id
    }

    private var activeEvent: Event? {
        guard let session = viewModel.session, session.packID == activePackID else { return nil }
        return session.event
    }

    var body: some View {
        EmbeddedSoundPacksEditorView(
            editorOwner: editorOwner,
            route: route,
            routeRequestRevision: routeRequestRevision,
            languageStore: languageStore,
            nativeEffects: nativeEffects,
            detail: detail,
            onDetailIntent: onDetailIntent,
            supplement: editorSupplement
        )
        .onAppear {
            draftNameInput = sounds?.draft?.name ?? ""
            syncOwnerComposer()
            Task { await viewModel.refreshCredentialStatus() }
        }
        .onChange(of: route) { newRoute in
            let nextSession = newRoute.editTarget.map {
                AICueComposerSession(packID: $0.packID, event: $0.event)
            }
            if pendingRouteSession != nextSession { pendingRouteSession = nil }
            if viewModel.session != nextSession {
                stopCandidatePreview()
                viewModel.endSession()
                editorOwner.updateAICueComposer(session: nil, generation: nil)
            }
            beginRouteSessionIfNeeded(for: newRoute)
        }
        .onChange(of: editorOwner.presentation) { _ in beginRouteSessionIfNeeded() }
        .onChange(of: detail) { _ in beginRouteSessionIfNeeded() }
        .onChange(of: selectedPack?.id) { selectedID in
            if let session = viewModel.session, session.packID != activePackID {
                stopCandidatePreview()
                viewModel.endSession()
                syncOwnerComposer()
                focusedEvent = nil
            }
        }
        .onChange(of: sounds?.draft?.name) { name in
            draftNameInput = name ?? ""
        }
        .onChange(of: viewModel.session) { _ in syncOwnerComposer() }
        .onChange(of: viewModel.generation) { _ in syncOwnerComposer() }
        .sheet(isPresented: $credentialSheetIsPresented) {
            EventSettingsAICueCredentialSheet(
                viewModel: viewModel,
                languageStore: languageStore)
        }
        .sheet(
            isPresented: Binding(
                get: { renamingDraftID != nil }, set: { if !$0 { cancelDraftRename() } })
        ) {
            draftNameSheet
        }
        .onChange(of: sounds?.draft?.packID) { _ in cancelDraftRename() }
        .onDisappear {
            cancelDraftRename()
            stopCandidatePreview()
            editorOwner.cancelAICuePackDraft()
            viewModel.endSession()
            editorOwner.updateAICueComposer(session: nil, generation: nil)
        }
        .accessibilityElement(children: .contain)
    }

    private var editorSupplement: SoundPacksEditorSupplement {
        var supplement = SoundPacksEditorSupplement(
            sidebarHeader: AnyView(newPackButton),
            detailHeader: AnyView(packContext),
            auxiliary: AnyView(serviceDetail),
            eventContent: { event in AnyView(eventGenerationContent(event)) })
        supplement.pageHeader = pageHeader
        supplement.scopePicker = scopePicker
        supplement.serviceSummary = AnyView(
            Text(l10n.text(viewModel.providerProfile.displayNameKey)))
        supplement.serviceOverview = serviceCard
        supplement.eventGenerationAction = { event in
            AnyView(generationEntry(event, opensDetail: true))
        }
        supplement.eventComposerIsPresented = { event in activeEvent == event }
        supplement.onLeaveEvent = {
            stopCandidatePreview()
            viewModel.endSession()
            editorOwner.updateAICueComposer(session: nil, generation: nil)
        }
        supplement.returnToScope = returnToScope
        supplement.onInspectPack = onInspectPack
        return supplement
    }

    private var serviceDetail: some View {
        VStack(alignment: .leading, spacing: SettingsAppearance.sectionGap) {
            serviceCard
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n.text(viewModel.providerProfile.privacyDisclosureKey))
                Text(l10n.text(viewModel.providerProfile.credentialStorageDisclosureKey))
            }
            .font(SettingsAppearance.font(.caption))
            .fixedSize(horizontal: false, vertical: true)
            .settingsSectionSurface()
        }
    }

    private var newPackButton: some View {
        Button(l10n.text(.settingsSoundsAICueNewPack)) {
            beginDraft()
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.isBusy || sounds?.draft != nil)
        .accessibilityIdentifier("settings.sounds.ai-cue.new-pack")
    }

    private var serviceCard: AnyView {
        AnyView(
            EventSettingsAICueServiceCard(
                viewModel: viewModel,
                languageStore: languageStore,
                onManageCredential: { credentialSheetIsPresented = true }
            )
            .settingsMountIdentity("settings.sounds.ai-cue.service")
            .soundPacksLayoutProbe("settings.sounds.ai-cue.service")
        )
    }

    @ViewBuilder
    private var packContext: some View {
        if let draft = sounds?.draft {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(draft.name).font(SettingsAppearance.font(.body))
                        Text(l10n.text(.settingsSoundsAICueDraft))
                            .font(SettingsAppearance.font(.caption)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(l10n.text(.settingsNativeEditDraftName)) {
                        nativeEffects.stopPreview(owner: editorOwner)
                        draftNameInput = draft.name
                        renamingDraftID = draft.packID
                    }.disabled(viewModel.isBusy || draft.cancelAction == nil)
                        .focused($draftNameButtonFocused)
                        .accessibilityIdentifier("settings.sounds.ai-cue.rename-draft")
                }
                Text(l10n.text(.settingsSoundsAICueDescription))
                    .font(.caption)
                    .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                if draftNameEdit == .invalid {
                    Text(l10n.text(.settingsSoundsAICueInvalidName))
                        .font(.caption)
                        .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                }
                if let cancelAction = draft.cancelAction {
                    Button(l10n.text(.commonCancel)) {
                        invoke(cancelAction)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("settings.sounds.ai-cue.cancel-draft")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.sounds.ai-cue.draft")
        } else if let selectedPack {
            VStack(alignment: .leading, spacing: 8) {
                if selectedPack.usage.isShared {
                    Text(l10n.text(.settingsSoundsAICueShared))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                }
                if selectedPack.usage.usageIsIncomplete {
                    Label(
                        l10n.text(.settingsSoundsAICueScopeIncomplete),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.sounds.ai-cue.scope-incomplete")
                }
                Text(l10n.text(.settingsSoundsAICueUsage))
                    .font(.caption.weight(.semibold))
                if selectedPack.usage.consumers.isEmpty
                    && !selectedPack.usage.usageIsIncomplete
                {
                    Text(l10n.text(.soundPacksPackNotUsed))
                        .font(.caption)
                        .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                } else {
                    ForEach(Array(selectedPack.usage.consumers.enumerated()), id: \.offset) {
                        _, consumer in
                        Text(usageLabel(consumer))
                            .font(.caption)
                            .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.sounds.ai-cue.pack-context")
        } else {
            Text(l10n.text(.settingsSoundsAICueDescription))
                .font(.caption)
                .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var draftNameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n.text(.settingsNativeEditDraftName)).font(SettingsAppearance.pageTitle)
            if sounds?.draft?.packID == renamingDraftID {
                TextField(l10n.text(.settingsSoundsAICuePackName), text: $draftNameInput)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings.sounds.ai-cue.draft-name")
                if draftNameEdit == .invalid {
                    FailureRow(message: l10n.text(.settingsSoundsAICueInvalidName))
                }
                HStack {
                    Button(l10n.text(.commonCancel)) { cancelDraftRename() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("settings.sounds.ai-cue.cancel-draft-name")
                    Spacer()
                    Button(l10n.text(.settingsSoundsAICueSaveName)) {
                        guard sounds?.draft?.packID == renamingDraftID,
                            let name = draftNameEdit.savableName,
                            editorOwner.renameAICuePackDraft(name)
                        else { return }
                        renamingDraftID = nil
                        draftNameButtonFocused = true
                    }.disabled(draftNameEdit.savableName == nil || viewModel.isBusy)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("settings.sounds.ai-cue.save-draft-name")
                }
            } else {
                FailureRow(message: l10n.text(.settingsNativeTargetUnavailable))
                Button(l10n.text(.commonClose)) { cancelDraftRename() }
            }
        }.font(SettingsAppearance.font(.body)).padding(24).frame(width: 440)
    }

    private func cancelDraftRename() {
        let wasPresented = renamingDraftID != nil
        renamingDraftID = nil
        draftNameInput = sounds?.draft?.name ?? ""
        if wasPresented { draftNameButtonFocused = true }
    }

    @ViewBuilder
    private func generationEntry(_ event: Event, opensDetail: Bool) -> some View {
        if selectedPack?.isBuiltinReadOnly != true {
            Button(l10n.text(.settingsNativeGenerateCue)) {
                if opensDetail, let packID = activePackID {
                    pendingRouteSession = AICueComposerSession(packID: packID, event: event)
                    onDetailIntent(.editEvent(packID: packID, event: event))
                    beginRouteSessionIfNeeded()
                } else {
                    beginSession(for: event)
                }
            }
            .buttonStyle(.bordered)
            .disabled(
                activePackID == nil || viewModel.isBusy
                    || sounds?.eventRows.contains(where: { $0.event == event }) != true
            )
            .focused($focusedEvent, equals: event)
            .accessibilityLabel(
                l10n.text(.settingsNativeGenerateCue) + " "
                    + localizedEventName(event, language: languageStore.language)
            )
            .accessibilityIdentifier("settings.sounds.ai-cue.event.\(event.rawValue)")
            .soundPacksLayoutProbe("settings.sounds.ai-cue.event.\(event.rawValue)")
        }
    }

    private func eventGenerationContent(_ event: Event) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if activeEvent == event {
                if selectedPack?.isBuiltinReadOnly == true {
                    readOnlyCopyGuidance
                } else if let packID = activePackID {
                    serviceCard
                    composer(packID: packID, event: event)
                }
            } else {
                generationEntry(event, opensDetail: false)
            }
        }
    }

    private var readOnlyCopyGuidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.text(.aiCueEligibilityBuiltin))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n.text(.settingsSoundsAICueCopyAttribution))
                .font(.caption)
                .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("settings.sounds.ai-cue.readonly-guidance")
        .soundPacksLayoutProbe("settings.sounds.ai-cue.readonly-guidance")
    }

    private func composer(packID: String, event: Event) -> some View {
        let row = sounds?.eventRows.first(where: { $0.event == event })
        let availability =
            row?.aiCueAdoptionAvailability
            ?? .ineligible(.configurationUnavailable)
        return EventSettingsAICueComposerView(
            viewModel: viewModel,
            languageStore: languageStore,
            eventTitle: localizedEventName(event, language: languageStore.language),
            playingCandidateID: playingCandidateID,
            adoptionEnabled: row?.aiCueAdoptionPermit != nil
                && !draftNameEdit.needsSave,
            generationEnabled: canGenerate(packID: packID, event: event),
            onGenerate: {
                guard canGenerate(packID: packID, event: event) else { return }
                viewModel.startGeneration(locale: languageStore.language.rawValue)
            },
            attributionDisclosure: selectedPack?.isBuiltinReadOnly == false
                ? l10n.text(.settingsSoundsAICueAdoptAttribution) : nil,
            adoptionUnavailableHint: draftNameEdit.needsSave
                ? l10n.text(.settingsSoundsAICueSaveNameBeforeAdopting)
                : adoptionHint(availability),
            onConfigureCredential: { credentialSheetIsPresented = true },
            onPreviewCandidate: previewCandidate,
            onAdoptCandidate: {
                candidateID in
                adoptCandidate(candidateID: candidateID, packID: packID, event: event)
            },
            onClose: closeComposer
        )
        .accessibilityIdentifier("settings.sounds.ai-cue.composer.\(event.rawValue)")
        .soundPacksLayoutProbe("settings.sounds.ai-cue.composer.\(event.rawValue)")
    }

    private var routeSession: AICueComposerSession? {
        guard let target = route.editTarget else { return nil }
        return AICueComposerSession(packID: target.packID, event: target.event)
    }

    private func beginRouteSessionIfNeeded(for requestedRoute: SoundPacksWindowRoute? = nil) {
        let targetRoute = requestedRoute ?? route
        guard let pendingRouteSession, let sounds,
            let target = targetRoute.editTarget,
            target.packID == pendingRouteSession.packID, target.event == pendingRouteSession.event
        else { return }
        switch soundsAICueRouteStep(pendingRouteSession, route: targetRoute, sounds: sounds) {
        case .pending:
            return
        case .inspect(let action):
            invoke(action)
        case .begin(let target):
            self.pendingRouteSession = nil
            guard let packID = target.packID else { return }
            beginSession(for: target.event, packID: packID)
        case .unavailable:
            self.pendingRouteSession = nil
        }
    }

    private func beginSession(for event: Event) {
        guard let packID = activePackID else { return }
        pendingRouteSession = nil
        beginSession(for: event, packID: packID)
    }

    private func beginSession(for event: Event, packID: String) {
        nativeEffects.stopPreview(owner: editorOwner)
        playingCandidateID = nil
        viewModel.begin(packID: packID, event: event)
        syncOwnerComposer()
        focusedEvent = nil
    }

    private func beginDraft() {
        nativeEffects.stopPreview(owner: editorOwner)
        playingCandidateID = nil
        viewModel.endSession()
        editorOwner.updateAICueComposer(session: nil, generation: nil)
        let language: AICuePackDraftLanguage =
            languageStore.language == .english
            ? .english : .zhHans
        guard editorOwner.beginAICuePackDraft(language: language) else { return }
        onAnnouncement(l10n.text(.settingsSoundsAICueNewPack))
    }

    private func closeComposer() {
        let closingEvent = activeEvent
        let hadSession = viewModel.session != nil
        let hadCandidates = viewModel.generation != nil
        stopCandidatePreview()
        viewModel.endSession()
        editorOwner.cancelAICuePackDraft()
        editorOwner.updateAICueComposer(session: nil, generation: nil)
        focusedEvent = closingEvent
        guard hadSession else { return }
        onAnnouncement(
            l10n.text(
                hadCandidates
                    ? .aiCueComposerClosedCandidatesCleared : .aiCueComposerClosed))
    }

    private func syncOwnerComposer() {
        editorOwner.updateAICueComposer(
            session: viewModel.session,
            generation: viewModel.generation)
    }

    private func previewCandidate(_ candidate: AICueCandidate) {
        let togglesCurrentCandidate = playingCandidateID == candidate.id
        stopCandidatePreview()
        if togglesCurrentCandidate { return }
        guard nonEmptyRegularFileExists(at: candidate.asset.fileURL),
            nativeEffects.playAICueCandidate(
                candidate,
                volume: AfplayVolume.clamped(
                    sounds?.masterVolume ?? ClaudioConfig.defaultMasterVolume))
                != nil
        else {
            viewModel.reportCandidateUnavailable()
            return
        }
        playingCandidateID = candidate.id
        let candidateID = candidate.id
        let resetDelay = Double(candidate.durationMilliseconds) / 1_000 + 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + resetDelay) {
            guard playingCandidateID == candidateID else { return }
            stopCandidatePreview()
        }
    }

    private func adoptCandidate(candidateID: UUID, packID: String, event: Event) {
        stopCandidatePreview()
        guard
            !draftNameEdit.needsSave,
            let permit = sounds?.eventRows.first(where: { $0.event == event })?
                .aiCueAdoptionPermit,
            viewModel.session == AICueComposerSession(packID: packID, event: event)
        else { return }
        viewModel.adopt(candidateID: candidateID, permit: permit) {
            candidate, displayName, permit in
            await editorOwner.perform(
                .adoptAICue(
                    candidate: candidate,
                    displayName: displayName,
                    permit: permit))
        }
    }

    private func stopCandidatePreview() {
        guard playingCandidateID != nil else { return }
        nativeEffects.stopPreview(owner: editorOwner)
        playingCandidateID = nil
    }

    private func invoke(_ action: SoundPackEditorAction) {
        nativeEffects.consume(editorOwner.send(.invoke(action)), owner: editorOwner)
    }

    private func adoptionHint(_ availability: SoundPackEditorAdoptionAvailability) -> String {
        switch availability {
        case .eligible:
            return l10n.text(.aiCueGenerateHint)
        case .ineligible(.builtinReadOnly):
            return l10n.text(.aiCueEligibilityBuiltin)
        case .ineligible(.sharedPack):
            return l10n.text(.aiCueEligibilityShared)
        case .ineligible:
            return l10n.text(.aiCueEligibilityUnavailable)
        }
    }

    private func usageLabel(_ usage: AICuePackUsageConsumer) -> String {
        let name: String
        switch usage.consumer {
        case .global:
            name = l10n.text(.panelGlobalName)
        case .workspace:
            name = usage.workspaceName ?? l10n.text(.workspaceLabel)
        case .surface(let surface):
            name =
                HostID.productVisibleCases.first(where: { $0.surfaceID == surface })?
                .displayName ?? surface.rawValue
        }
        return usage.inherited
            ? l10n.format(.settingsSoundsAICueInheritedUsage, name as NSString)
            : name
    }

    private func canGenerate(packID: String, event: Event) -> Bool {
        guard viewModel.session == AICueComposerSession(packID: packID, event: event) else {
            return false
        }
        return soundsAICueGenerationIsAllowed(
            sounds: sounds,
            library: editorOwner.presentation.library,
            session: viewModel.session,
            event: event)
    }
}
