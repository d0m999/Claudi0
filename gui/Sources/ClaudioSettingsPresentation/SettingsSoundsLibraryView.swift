import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SoundPacksWindow
import SwiftUI
import UniformTypeIdentifiers

private enum SoundsSheet: String, Identifiable {
    case newPack, renamePack, copyPack, ai, local, history, packFiles, system, manage, importPack,
        service, renameAudio
    var id: String { rawValue }
}

private struct HistorySelection: Equatable {
    let batchID: UUID
    let audioID: UUID
}

private enum SoundsConfirmation {
    case history(UUID, Int)
    case pending(Int)
    case draft(String, String)
    case owner(SoundPackEditorConfirmation)
}

/// Pack browsing and attached forms borrow app-lifetime owners. Selection and playback are
/// separate controls; a sheet's closing edge invalidates only its event adoption context.
@MainActor
struct SettingsSoundsLibraryView: View {
    @ObservedObject var model: AICueGenerationViewModel
    @ObservedObject var owner: SoundPacksEditorOwner
    @ObservedObject var preferences: ClaudioPreferences
    @ObservedObject var effects: SoundPacksEditorNativeEffectsDispatcher
    @ObservedObject var coordinator: AICueGenerationCoordinator
    @ObservedObject var selectionSession: SoundEventSelectionSession
    @ObservedObject var history: GenerationHistoryStore
    @ObservedObject var drafts: SoundPackDraftStore
    let route: SoundPacksWindowRoute
    let requestRevision: UInt64
    let navigate: @MainActor (SoundPacksWindowRoute.Destination) -> Void
    @Binding var modalIsPresented: Bool

    @State private var sheet: SoundsSheet?
    @State private var returnFromService: SoundsSheet?
    @State private var selectedItem: String?
    @State private var selectedCandidate: UUID?
    @State private var historySelection: HistorySelection?
    @State private var preparedPack: PreparedSoundPack?
    @State private var inputName = ""
    @State private var errorText: String?
    @State private var selectionRecoveryURL: URL?
    @State private var working = false
    @State private var confirmation: SoundsConfirmation?
    @State private var collapsedGroups: Set<UUID> = []
    @State private var parentWindow: NSWindow?
    @State private var previewOrigin = ManualPreviewOrigin(.settings)
    @State private var afterSheetDestination: SoundPacksWindowRoute.Destination?
    @State private var dropTargetEvent: Event?
    @FocusState private var focusedEvent: Event?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var l10n: ClaudioL10n { ClaudioL10n(language: preferences.language) }
    private var selection: SoundEventSelectionContext? { selectionSession.context }
    private var localPreview: SoundLocalAudioPreview? { selectionSession.localPreview }
    private var isWorking: Bool {
        working || selectionSession.isPreparingLocalSound || selectionSession.isUsingSound
    }
    private var sounds: SoundsEditorPresentation? {
        guard case .sounds(let value) = owner.presentation.mode else { return nil }
        return value
    }
    private var pack: SoundPackEditorPackPresentation? { sounds?.selectedPack }
    private var packID: String? { sounds?.draft?.packID ?? pack?.id }
    private var packName: String { sounds?.draft?.name ?? pack?.name ?? pack?.id ?? "" }
    private var inventory: [SoundPackEditorAudioPresentation] {
        switch sounds?.inventory {
        case .ready(let files): files
        case .loading(let previous), .failed(let previous, _): previous ?? []
        default: []
        }
    }
    private var canEdit: Bool {
        sounds?.draft != nil || (pack != nil && pack?.isBuiltinReadOnly == false)
    }
    private var isHistory: Bool { route.destination == .history }
    private var isList: Bool {
        route.destination == .overview || route.destination == .panel
            || route.destination == .service
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isHistory {
                    heading(l10n.text(.soundsHistory))
                    generationStatus
                    historyContent(selecting: false)
                } else if isList {
                    heading(l10n.text(.settingsDestinationSounds))
                    libraryContent
                } else {
                    libraryStatus
                    packContent
                }
                if let errorText { errorLabel(errorText) }
                if let selectionRecoveryURL {
                    recoveryButton(.recoveryRequired(selectionRecoveryURL))
                }
                if effects.previewSession.failedOrigin == previewOrigin {
                    errorLabel(l10n.text(.soundsUnavailable))
                }
                if let sounds {
                    ForEach(sounds.windowStatuses, id: \.revision) { status in
                        Text(status.message(language: preferences.language))
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .soundPacksLayoutProbe("settings.reading.sounds")
            .settingsReadingColumn()
        }
        .background(SoundsWindowProbe { parentWindow = $0 }.frame(width: 0, height: 0))
        .settingsMountIdentity("settings.sounds.library")
        .onAppear {
            previewOrigin = selectionSession.activate(route: route)
        }
        .task {
            await drafts.refresh()
            await model.refreshCredentialStatus()
            if isHistory { coordinator.markHistoryRead(); await history.refresh() }
            if sheet == nil, let event = route.editTarget?.event { focusedEvent = event }
            if modalIsPresented, sheet == nil { present(.service) }
            openLegacySheetIfNeeded()
        }
        .onChange(of: route) { _ in
            if let origin = selectionSession.routeChanged(to: route, origin: previewOrigin) {
                previewOrigin = origin
            }
            errorText = nil
            if isHistory { coordinator.markHistoryRead(); Task { await history.refresh() } }
            if let event = route.editTarget?.event { focusedEvent = event }
            openLegacySheetIfNeeded()
        }
        .onChange(of: model.providerProfileID) { _ in
            selectedCandidate = nil
        }
        .onChange(of: model.phase) { phase in
            if phase == .applied { finishUse() }
        }
        .onChange(of: owner.presentation.pendingConfirmation) { value in
            if let value { confirmation = .owner(value); modalIsPresented = true }
        }
        .sheet(item: $sheet, onDismiss: sheetClosed) { sheet in
            sheetContent(sheet)
                .interactiveDismissDisabled(isWorking)
                .alert(confirmationTitle, isPresented: confirmationBinding) {
                    confirmationButtons
                } message: {
                    Text(confirmationMessage)
                }
        }
        .alert(confirmationTitle, isPresented: outerConfirmationBinding) {
            confirmationButtons
        } message: {
            Text(confirmationMessage)
        }
        .onDisappear {
            selectionSession.end(origin: previewOrigin)
            modalIsPresented = false
        }
    }

    private func heading(_ title: String) -> some View {
        HStack {
            Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer()
        }
    }

    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(l10n.text(.soundsNewPack)) {
                    inputName = ""; present(.newPack)
                }
                .accessibilityIdentifier("settings.sounds.new-pack")
                Button(l10n.text(.soundsImportPack)) { choosePack() }
                    .accessibilityIdentifier("settings.sounds.import-pack")
                Spacer()
                Button {
                    navigate(.history)
                } label: {
                    Label(historyEntryTitle, systemImage: "clock.arrow.circlepath")
                }.accessibilityIdentifier("settings.sounds.history")
            }
            Text(l10n.format(.soundsFavoritesHint, Int64(maxStarredPacks)))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.sounds.favorites-hint")
                .soundPacksLayoutProbe("settings.sounds.favorites-hint")
            libraryStatus
            VStack(spacing: 0) {
                ForEach(sounds?.packs ?? []) { item in
                    HStack {
                        Button {
                            navigate(.pack(packID: item.id))
                        } label: {
                            HStack {
                                Image(systemName: "waveform").frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name ?? item.id).foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .soundPacksLayoutProbe(
                                            "settings.sounds.pack.\(item.id).name")
                                    Text(
                                        l10n.text(
                                            item.isBuiltinReadOnly
                                                ? .soundsBuiltin : .soundsUserPack)
                                    )
                                    .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(item.name ?? item.id)
                            .accessibilityIdentifier("settings.sounds.pack.\(item.id)")
                            .soundPacksLayoutProbe("settings.sounds.pack.\(item.id).detail")
                        if let star = item.toggleStarAction {
                            let starTitle = l10n.text(
                                item.isStarred ? .soundsFavorited : .soundsFavorite)
                            let starHelp = l10n.text(
                                item.isStarred ? .soundsUnfavoriteHelp : .soundsFavoriteHelp)
                            let starLabel = l10n.format(
                                item.isStarred ? .soundsFavoritedLabel : .soundsFavoriteLabel,
                                item.name ?? item.id)
                            Button {
                                invoke(star)
                            } label: {
                                Label(
                                    starTitle,
                                    systemImage: item.isStarred ? "star.fill" : "star")
                            }
                            .fixedSize()
                            .help(starHelp)
                            .accessibilityLabel(starLabel)
                            .accessibilityHint(starHelp)
                            .accessibilityIdentifier("settings.sounds.pack.\(item.id).panel")
                            .soundPacksLayoutProbe("settings.sounds.pack.\(item.id).panel")
                        }
                    }.padding(12)
                    Divider()
                }
                ForEach(drafts.snapshot.drafts, id: \.packID) { draft in
                    Button {
                        owner.inspectDraft(draft); navigate(.draft(packID: draft.packID))
                    } label: {
                        HStack {
                            Image(systemName: "doc.badge.plus").frame(width: 28)
                            Text(draft.name.value)
                            Text(l10n.text(.soundsDraft)).font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.contentShape(Rectangle()).padding(12)
                    }.buttonStyle(.plain).accessibilityIdentifier(
                        "settings.sounds.draft.\(draft.packID)")
                    Divider()
                }
                if owner.presentation.library == .ready, sounds?.packs.isEmpty == true,
                    drafts.snapshot.drafts.isEmpty
                {
                    Text(l10n.text(.panelPacksNoneTitle))
                        .foregroundColor(.secondary).padding()
                        .accessibilityIdentifier("settings.sounds.library.empty")
                }
            }.settingsSectionSurface()
            serviceCard
            if case .revealRoot(_, let action) = sounds?.emptyLibraryRecovery {
                Button(l10n.text(.settingsNativeRevealInFinder)) { invoke(action) }
            }
            if let action = sounds?.restoreAllFactoryPacksAction {
                Button(l10n.text(.soundPacksRestore)) { invoke(action) }
            }
            if let failure = drafts.failure { errorLabel(storageMessage(failure)) }
        }
    }

    @ViewBuilder private var libraryStatus: some View {
        switch owner.presentation.library {
        case .unloaded, .loading(previousAvailable: false):
            ProgressView(l10n.text(.soundPacksLibraryLoading))
                .accessibilityIdentifier("settings.sounds.library.loading")
        case .loading(previousAvailable: true):
            ProgressView(l10n.text(.soundPacksLibraryRefreshing))
                .accessibilityIdentifier("settings.sounds.library.refreshing")
        case .failed(let previousAvailable, let reason):
            let message = l10n.text(
                reason == .locationUnavailable
                    ? .soundPacksEmptyLoadFailedMessage : .panelPacksReadFailed)
            HStack {
                errorLabel(
                    previousAvailable
                        ? l10n.format(.soundPacksLibraryRefreshFailed, message) : message
                )
                .accessibilityIdentifier("settings.sounds.library.failure")
                Spacer()
                Button(l10n.text(.commonRetry)) {
                    if let action = sounds?.retryLibraryAction { invoke(action) }
                }
                .disabled(sounds?.retryLibraryAction == nil)
                .accessibilityLabel(l10n.text(.soundPacksLibraryRetryLabel))
                .accessibilityHint(l10n.text(.soundPacksLibraryRetryHint))
                .accessibilityIdentifier("settings.sounds.library.retry")
            }
        case .ready: EmptyView()
        }
    }

    @ViewBuilder private var packContent: some View {
        if route.destinationPackID != packID || packID == nil {
            heading(l10n.text(.soundsUnavailable))
            Button(l10n.text(.soundsBack)) { navigate(.overview) }
        } else {
            heading(packName)
            Text(l10n.text(sounds?.draft != nil ? .soundsDraftHint : .soundsSharedWarning))
                .font(.callout).foregroundColor(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            HStack {
                if let pack {
                    Button(l10n.text(.soundsCopy)) {
                        inputName = ""; present(.copyPack)
                    }
                    .disabled(pack.copyAction == nil)
                    .accessibilityIdentifier("settings.sounds.copy-pack")
                    if !pack.isBuiltinReadOnly {
                        Button(l10n.text(.soundsRename)) {
                            inputName = packName; present(.renamePack)
                        }
                        .accessibilityIdentifier("settings.sounds.rename-pack")
                    }
                    if let action = pack.revealAction {
                        Button(l10n.text(.settingsNativeRevealInFinder)) { invoke(action) }
                    }
                    if let action = pack.restoreAction {
                        Button(l10n.text(.soundPacksRestore)) { invoke(action) }
                    }
                } else {
                    Button(l10n.text(.soundsRename)) {
                        inputName = packName; present(.renamePack)
                    }
                    .accessibilityIdentifier("settings.sounds.rename-pack")
                }
                Spacer()
                if sounds?.draft == nil {
                    Button(l10n.text(.soundsManageFiles)) { present(.manage) }
                        .accessibilityIdentifier("settings.sounds.manage-files")
                }
            }
            if pack?.isBuiltinReadOnly == true {
                Text(l10n.text(.soundsReadOnly)).font(.callout).foregroundColor(.secondary)
            }
            // 导向说明行（变体 4 定稿的唯一教学位）：紧贴事件列表上沿，先讲本页事实再教拖拽捷径；
            // 原型 11px 弱文字，对应 .caption。
            if canEdit {
                Text(l10n.text(.soundsEventDropHint))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.sounds.event-drop-hint")
                    .soundPacksLayoutProbe("settings.sounds.event-drop-hint")
            }
            VStack(spacing: 0) {
                ForEach(sounds?.eventRows ?? []) { row in
                    HStack(spacing: 12) {
                        ClaudioEventGlyph(event: row.event, size: 24).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(localizedEventName(row.event, language: preferences.language))
                                .font(.headline)
                            Text(
                                row.audioDisplayName ?? row.soundSource?.name
                                    ?? l10n.text(.soundsEmptyEvent)
                            )
                            .font(.callout).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if let action = row.previewAction {
                            previewButton(id: "event.\(row.event.rawValue)") { origin in
                                selectionSession.preview(
                                    id: "event.\(row.event.rawValue)", action: action,
                                    origin: origin)
                            }
                        }
                        if canEdit {
                            SettingsNativeActionMenu(
                                l10n.text(row.soundSource == nil ? .soundsSet : .soundsChange),
                                identifier: "settings.sounds.event.\(row.event.rawValue).source",
                                items: sourceMenu(row.event)
                            )
                            .fixedSize().focused($focusedEvent, equals: row.event)
                            .accessibilityIdentifier(
                                "settings.sounds.event.\(row.event.rawValue).source")
                            if let action = row.clearAction {
                                Button(l10n.text(.soundsClear)) {
                                    effects.stopPreview(owner: owner, origin: previewOrigin);
                                    invoke(action)
                                }
                                .accessibilityIdentifier(
                                    "settings.sounds.event.\(row.event.rawValue).clear")
                            }
                        }
                    }.padding(14)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                dropTargetEvent == row.event
                                    ? Color.accentColor.opacity(0.12) : Color.clear)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                dropTargetEvent == row.event
                                    ? Color.accentColor : Color.clear,
                                lineWidth: 1)
                    }
                    .overlay(alignment: .topTrailing) {
                        if dropTargetEvent == row.event {
                            // 「松开导入到『事件名』」浮标（变体 4）：9.5 semibold 胶囊，
                            // 右上跨骑行框上缘（right 10 / top -9）。
                            Text(
                                l10n.format(
                                    .soundsEventDropBadge,
                                    localizedEventName(
                                        row.event, language: preferences.language))
                            )
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 8).padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.accentColor))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                            .padding(.trailing, 10)
                            .offset(y: -9)
                            .transition(.opacity)
                            .accessibilityIdentifier(
                                "settings.sounds.event.\(row.event.rawValue).drop-badge")
                        }
                    }
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.12), value: dropTargetEvent)
                    .onDrop(
                        of: [UTType.fileURL.identifier],
                        isTargeted: eventDropTargetBinding(for: row.event),
                        perform: { providers in handleEventSoundDrop(providers, event: row.event) }
                    )
                    .soundPacksLayoutProbe("sound-packs.event-row.\(row.event.rawValue)")
                    if row.event != Event.allCases.last { Divider() }
                }
            }.settingsSectionSurface().soundPacksLayoutProbe("sound-packs.events.group")
            if let pack {
                HStack {
                    Button(l10n.text(.soundPacksPackDelete), role: .destructive) {
                        if let action = pack.deleteAction { invoke(action) }
                    }.disabled(pack.deleteAction == nil)
                        .accessibilityIdentifier("settings.sounds.delete-pack")
                    if pack.deleteAction == nil {
                        Text(
                            l10n.text(
                                pack.isBuiltinReadOnly
                                    ? .soundPacksPackDeleteBuiltin : .soundsPackProtected)
                        )
                        .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if pack.factoryIntegrity == false {
                        Label(
                            l10n.text(.soundPacksPackModified),
                            systemImage: "exclamationmark.triangle"
                        ).font(.caption).foregroundColor(.secondary)
                    } else if pack.isCC0 {
                        Text("CC0").font(.caption).foregroundColor(.secondary)
                    }
                }
            } else if let draft = sounds?.draft {
                Button(l10n.text(.soundPacksPackDelete), role: .destructive) {
                    confirmation = .draft(draft.packID, draft.name); modalIsPresented = true
                }
            }
        }
    }

    private func sourceMenu(_ event: Event) -> [SettingsNativeActionMenu.Item] {
        [
            (.ai, ClaudioL10nKey.soundsAI), (.history, .soundsFromHistory),
            (.packFiles, .soundsFromPack), (.local, .soundsFromFile), (.system, .soundsFromSystem),
        ]
        .map { (mode: SoundsSheet, key: ClaudioL10nKey) in
            SettingsNativeActionMenu.Item(
                l10n.text(key), identifier: "settings.sounds.source.\(mode.rawValue)"
            ) {
                begin(mode, event: event)
            }
        }
    }

    private var serviceCard: some View {
        EventSettingsAICueServiceCard(viewModel: model, languageStore: preferences) {
            returnFromService = sheet
            present(.service)
        }
    }

    private var historyEntryTitle: String {
        switch coordinator.state {
        case .generating: l10n.text(.soundsGenerating)
        case .saving: l10n.text(.soundsSaving)
        case .pending: l10n.text(.soundsPending)
        case .failed: l10n.text(.soundsFailed)
        default: l10n.text(coordinator.hasUnreadCompletion ? .soundsSaved : .soundsHistory)
        }
    }

    @ViewBuilder private var generationStatus: some View {
        if sheet == .ai {
            generationStatusContent()
        } else {
            generationStatusContent().settingsSectionSurface()
        }
    }

    @ViewBuilder private func generationStatusContent(
        focus: FocusState<AICueTaskFocus?>.Binding? = nil
    ) -> some View {
        switch coordinator.state {
        case .generating:
            HStack {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading) {
                    Text(l10n.text(.soundsGenerating))
                    if let profile = coordinator.requestProfileID {
                        Text(profileTitle(profile)).font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button(l10n.text(.soundsCancelGeneration)) { coordinator.cancel() }
                    .modifier(AICueOptionalFocus(binding: focus, target: .cancel))
                    .accessibilityIdentifier("settings.sounds.generation.cancel")
            }.accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.sounds.generation-progress")
        case .saving:
            HStack {
                ProgressView().controlSize(.small); Text(l10n.text(.soundsSaving)); Spacer()
            }
        case .pending(_, let failure):
            VStack(alignment: .leading, spacing: 12) {
                Text(l10n.text(.soundsPending)).font(.headline)
                Text(
                    l10n.format(
                        .soundsGeneratedCount, Int64(coordinator.generation?.candidates.count ?? 0))
                )
                .font(.caption).foregroundColor(.secondary)
                errorLabel(storageMessage(failure))
                recoveryButton(failure)
                ForEach(coordinator.generation?.candidates ?? []) { candidate in
                    HStack {
                        Text(candidateName(candidate))
                        Spacer()
                        previewButton(id: candidate.id.uuidString) { origin in
                            selectionSession.preview(
                                id: candidate.id.uuidString, fileURL: candidate.asset.fileURL,
                                origin: origin)
                        }
                    }
                }
                HStack {
                    Button(l10n.text(.soundsRetrySave)) { coordinator.retrySave() }
                        .modifier(AICueOptionalFocus(binding: focus, target: .retrySave))
                        .accessibilityIdentifier("settings.sounds.generation.retry-save")
                    Button(l10n.text(.soundsDiscard), role: .destructive) {
                        confirmation = .pending(coordinator.generation?.candidates.count ?? 0)
                        modalIsPresented = true
                    }
                    .accessibilityIdentifier("settings.sounds.generation.discard")
                }
                Text(l10n.text(.soundsPendingHint)).font(.caption).foregroundColor(.secondary)
            }.accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.sounds.pending-results")
        case .failed(let failure):
            errorLabel(
                aiCueFailureText(
                    .generation(failure),
                    providerProfileID: coordinator.requestProfileID ?? model.providerProfileID,
                    l10n: l10n))
        default: EmptyView()
        }
    }

    private func historyContent(selecting: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if history.isLoading { ProgressView().controlSize(.small) }
            if let failure = history.failure {
                errorLabel(storageMessage(failure))
                recoveryButton(failure)
                Button(l10n.text(.soundsRetry)) { Task { await history.refresh() } }
            }
            if history.snapshot.batches.isEmpty, !history.isLoading {
                Text(l10n.text(.soundsEmptyHistory)).foregroundColor(.secondary)
            }
            ForEach(history.snapshot.batches) { batch in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { !collapsedGroups.contains(batch.id) },
                        set: {
                            if $0 {
                                collapsedGroups.remove(batch.id)
                            } else {
                                collapsedGroups.insert(batch.id)
                            }
                        })
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let failure = batch.failure { errorLabel(storageMessage(failure)) }
                        ForEach(batch.audio) { audio in
                            HStack {
                                if selecting {
                                    Button {
                                        historySelection = HistorySelection(
                                            batchID: batch.id, audioID: audio.id)
                                    } label: {
                                        HStack {
                                            Image(
                                                systemName: historySelection
                                                    == HistorySelection(
                                                        batchID: batch.id, audioID: audio.id)
                                                    ? "largecircle.fill.circle" : "circle")
                                            Text(
                                                audio.name.isEmpty
                                                    ? l10n.text(.soundsUnavailable) : audio.name)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain).disabled(audio.failure != nil)
                                        .accessibilityIdentifier(
                                            "settings.sounds.history.select.\(audio.id)")
                                } else {
                                    Text(
                                        audio.name.isEmpty
                                            ? l10n.text(.soundsUnavailable) : audio.name)
                                }
                                Spacer()
                                Text(
                                    l10n.format(
                                        .soundsSeconds, Double(audio.durationMilliseconds) / 1_000)
                                )
                                .font(.caption).foregroundColor(.secondary)
                                previewButton(id: audio.id.uuidString) { origin in
                                    previewHistory(batch.id, audio.id, origin: origin)
                                }
                                .disabled(audio.failure != nil)
                                if !selecting {
                                    Button(l10n.text(.soundsRename)) {
                                        historySelection = HistorySelection(
                                            batchID: batch.id, audioID: audio.id)
                                        inputName = audio.name; present(.renameAudio)
                                    }.disabled(audio.failure != nil)
                                        .accessibilityIdentifier(
                                            "settings.sounds.history.rename.\(audio.id)")
                                    Button(l10n.text(.soundsTrash), role: .destructive) {
                                        Task { await trashHistory(batch.id, audio.id) }
                                    }
                                    .accessibilityIdentifier(
                                        "settings.sounds.history.trash.\(audio.id)")
                                }
                            }
                            if let failure = audio.failure { errorLabel(storageMessage(failure)) }
                        }
                        if !selecting {
                            Button(l10n.text(.soundsTrash), role: .destructive) {
                                confirmation = .history(batch.id, batch.audio.count);
                                modalIsPresented = true
                            }
                            .accessibilityIdentifier(
                                "settings.sounds.history.trash-batch.\(batch.id)")
                        }
                    }.padding(.top, 10)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            batch.soundDescription.isEmpty
                                ? l10n.text(.soundsUnavailable) : batch.soundDescription
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            if let date = batch.generatedAt {
                                Text(date, style: .date); Text(date, style: .time)
                            }
                            if let profile = batch.profileID { Text(profileTitle(profile)) }
                        }.font(.caption).foregroundColor(.secondary)
                    }
                }.settingsSectionSurface().accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings.sounds.history.batch.\(batch.id)")
            }
        }
    }

    @ViewBuilder private func sheetContent(_ mode: SoundsSheet) -> some View {
        if mode == .service {
            EventSettingsAICueCredentialSheet(viewModel: model, languageStore: preferences) {
                if let returnFromService {
                    self.returnFromService = nil; sheet = returnFromService
                } else {
                    closeSheet()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text(sheetTitle(mode)).font(.title2.weight(.semibold))
                if let selection {
                    Text(
                        (selection.draft?.name.value ?? packName) + " · "
                            + localizedEventName(selection.event, language: preferences.language)
                    )
                    .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                // 列表型主体自带滚动，必须直接占据 VStack 的弹性位；只有表单型主体才包
                // ScrollView。曾无条件外包 ScrollView，内部 List 在嵌套滚动容器里塌到
                // minHeight 附近，高 sheet 里列表与底部按钮之间实测留下 241–400pt 死区
                // （系统提示音 sheet 的列表只占约三成高度）。
                if sheetIsListBacked(mode) {
                    sheetBody(mode)
                } else {
                    ScrollView { sheetBody(mode) }
                }
                if effects.previewSession.failedOrigin == previewOrigin {
                    errorLabel(l10n.text(.soundsUnavailable))
                        .accessibilityIdentifier("settings.sounds.sheet.preview-failure")
                }
                if let errorText { errorLabel(errorText) }
                if let selectionRecoveryURL {
                    recoveryButton(.recoveryRequired(selectionRecoveryURL))
                }
                if isWorking { ProgressView().controlSize(.small) }
                HStack {
                    Spacer()
                    Button(l10n.text(.soundsClose)) { closeSheet() }.keyboardShortcut(.cancelAction)
                        .disabled(isWorking).accessibilityIdentifier("settings.sounds.sheet.close")
                    if mode != .manage { sheetPrimaryButton(mode) }
                }
            }.padding(24).frame(
                width: 620,
                height: [.ai, .history, .packFiles, .system, .manage].contains(mode)
                    ? min(620, (parentWindow?.contentLayoutRect.height ?? 740) - 40) : 260
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.sounds.sheet.\(mode.rawValue)")
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    /// 主体是自带滚动的 `List`／滚动区的 sheet：必须由外层 VStack 直接给足弹性高度，
    /// 不再包 `ScrollView`。其余（命名、AI、本机导入、整包导入）是表单型，保留外层滚动。
    private static let listBackedSheetModes: Set<SoundsSheet> = [
        .system, .packFiles, .manage, .history,
    ]

    private func sheetIsListBacked(_ mode: SoundsSheet) -> Bool {
        Self.listBackedSheetModes.contains(mode)
    }

    @ViewBuilder private func sheetBody(_ mode: SoundsSheet) -> some View {
        switch mode {
        case .newPack, .renamePack, .copyPack, .renameAudio:
            SoundsNameInput(
                title: l10n.text(mode == .renameAudio ? .soundsAudioName : .soundsPackName),
                text: $inputName)
            if mode == .copyPack {
                Text(l10n.text(.settingsSoundsAICueCopyAttribution))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .ai:
            aiComposer
        case .history:
            if pack != nil {
                Text(l10n.text(.settingsSoundsAICueAdoptAttribution))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView { historyContent(selecting: true) }
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                .soundPacksLayoutProbe("settings.sounds.sheet.history.list")
        case .local:
            if let localPreview {
                HStack {
                    Text(localPreview.name.value)
                    Text(
                        l10n.format(
                            .soundsSeconds, Double(localPreview.durationMilliseconds) / 1_000))
                    Spacer()
                    previewButton(id: localPreview.id.uuidString) { origin in
                        selectionSession.preview(
                            id: localPreview.id.uuidString, fileURL: localPreview.fileURL,
                            origin: origin)
                    }
                }
            } else {
                Button(l10n.text(.soundsFromFile)) { chooseLocalFile() }
            }
        case .packFiles, .manage:
            inventoryContent(managing: mode == .manage)
        case .system:
            systemContent
        case .importPack:
            if let preparedPack {
                Text(preparedPack.name).font(.headline)
                Text(
                    l10n.format(
                        .soundsImportSummary, preparedPack.eventCount, preparedPack.fileCount))
            }
        case .service: EmptyView()
        }
    }

    private var aiComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            EventSettingsAICueServiceCard(
                viewModel: model, languageStore: preferences, compact: true
            ) {
                returnFromService = .ai
                present(.service)
            }
            Text(l10n.text(.soundsDescription)).font(.headline)
            if model.phase == .generating || model.phase == .adopting {
                Text(model.soundDescription).frame(
                    maxWidth: .infinity, minHeight: 70, alignment: .topLeading
                )
                .textSelection(.enabled).accessibilityIdentifier(
                    "settings.sounds.ai.description-readonly")
            } else {
                SoundsDescriptionInput(
                    text: Binding(
                        get: { model.soundDescription }, set: { model.updateDescription($0) })
                )
                .frame(height: 70).border(Color.secondary.opacity(0.25))
            }
            AICueTaskSurface(expanded: aiTaskExpanded, stateKey: aiTaskKey) { taskFocus in
                VStack(alignment: .leading, spacing: aiTaskExpanded ? 12 : 0) {
                    if aiTaskPresentation.isDetachedTask {
                        Text(l10n.text(.soundsBackgroundTask))
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.sounds.ai.background-task")
                    }
                    generationStatusContent(focus: taskFocus)
                    if case .saved = coordinator.state, let generation = model.generation {
                        Text(l10n.text(.soundsSaved)).font(.headline)
                        Text(l10n.format(.soundsGeneratedCount, Int64(generation.candidates.count)))
                            .font(.caption).foregroundColor(.secondary)
                        if generation.completion == .partial {
                            Text(
                                l10n.format(
                                    .aiCueCandidatePartial, Int64(generation.candidates.count))
                            )
                            .font(.caption).foregroundColor(.secondary)
                            .accessibilityIdentifier("settings.sounds.ai.partial")
                        }
                        List(selection: $selectedCandidate) {
                            ForEach(generation.candidates) { candidate in
                                HStack {
                                    Text(candidateName(candidate)); Spacer()
                                    Text(
                                        l10n.format(
                                            .soundsSeconds,
                                            Double(candidate.durationMilliseconds) / 1_000)
                                    )
                                    .foregroundColor(.secondary)
                                    previewButton(id: candidate.id.uuidString) { origin in
                                        selectionSession.preview(
                                            id: candidate.id.uuidString,
                                            fileURL: candidate.asset.fileURL, origin: origin)
                                    }
                                }.tag(candidate.id)
                            }
                        }.frame(height: CGFloat(generation.candidates.count) * 44 + 10)
                            .focused(taskFocus, equals: .results).accessibilityIdentifier(
                                "settings.sounds.ai.candidates")
                        if pack != nil {
                            Text(l10n.text(.settingsSoundsAICueAdoptAttribution))
                                .font(.caption).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if coordinator.generationBlock == nil {
                        HStack {
                            Button {
                                if model.requiresCredentialConfiguration {
                                    returnFromService = .ai; present(.service); return
                                }
                                effects.stopPreview(owner: owner, origin: previewOrigin)
                                selectedCandidate = nil
                                model.startGeneration(locale: preferences.language.rawValue)
                            } label: {
                                Text(
                                    l10n.text(
                                        model.requiresCredentialConfiguration
                                            ? .aiCueConfigureKey
                                            : (model.generation == nil
                                                ? .soundsGenerate : .soundsGenerateAgain))
                                )
                                .frame(minWidth: 124, minHeight: 34)
                                .contentShape(Rectangle())
                            }
                            .disabled(
                                !model.providerIsAdmitted || !model.providerCredentialAccessAllowed
                                    || coordinator.generationBlock != nil
                                    || model.soundDescription.trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    )
                                    .isEmpty
                            )
                            .buttonStyle(.plain)
                            .foregroundColor(aiTaskExpanded ? .accentColor : .white)
                            .focused(taskFocus, equals: .generate)
                            .accessibilityIdentifier("settings.sounds.ai.generate")

                        }
                    }
                    if let failure = model.failure, aiTaskPresentation.showsLocalFailure {
                        Text(
                            aiCueFailureText(
                                failure, providerProfileID: model.providerProfileID, l10n: l10n)
                        ).foregroundColor(.red)
                    }
                }
            }
            if model.requiresCredentialConfiguration {
                Button(l10n.text(.aiCueManageKey)) {
                    returnFromService = .ai; present(.service)
                }
                .disabled(!model.providerIsAdmitted || !model.providerCredentialAccessAllowed)
                .accessibilityIdentifier("settings.sounds.ai.credential-manage")
            }
        }
    }

    private var aiTaskPresentation: AICueTaskPresentation {
        AICueTaskPresentation(
            state: coordinator.state, hasVisibleResults: model.generation != nil,
            hasFailure: model.failure != nil, isCurrentContext: model.hasCurrentGenerationContext)
    }
    private var aiTaskExpanded: Bool { aiTaskPresentation.isExpanded }
    private var aiTaskKey: String { aiTaskPresentation.kind.rawValue }

    private func inventoryContent(managing: Bool) -> some View {
        VStack(alignment: .leading) {
            inventoryStatus
            List(selection: $selectedItem) {
                ForEach(inventory) { audio in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(audio.fileName)
                            Text(
                                audio.usedByEvents.isEmpty
                                    ? l10n.text(.soundsUnused) : occupancy(audio.usedByEvents)
                            )
                            .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if let action = audio.previewAction {
                            previewButton(id: "file.\(audio.fileName)") { origin in
                                selectionSession.preview(
                                    id: "file.\(audio.fileName)", action: action, origin: origin)
                            }
                        }
                        if managing {
                            Button(l10n.text(.soundsTrash), role: .destructive) {
                                if let action = audio.deleteAction { invoke(action) }
                            }.disabled(audio.deleteAction == nil)
                                .help(
                                    audio.isOrphan
                                        ? l10n.text(.soundsTrash) : l10n.text(.soundsInUseProtected)
                                )
                                .accessibilityIdentifier(
                                    "settings.sounds.file.trash.\(audio.fileName)")
                        }
                    }.tag(audio.fileName)
                        .disabled(
                            !managing && !audio.usedByEvents.isEmpty
                                && !audio.usedByEvents.contains(selection?.event ?? .taskStart))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
            .soundPacksLayoutProbe("settings.sounds.sheet.files.list")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var inventoryStatus: some View {
        switch sounds?.inventory {
        case .idle, .loading:
            ProgressView(l10n.text(.soundPacksAudioLoading))
                .accessibilityIdentifier("settings.sounds.inventory.loading")
        case .failed(let previous, let reason):
            let message = inventoryFailureMessage(reason)
            errorLabel(
                previous == nil ? message : l10n.format(.soundPacksLibraryRefreshFailed, message)
            )
            .accessibilityIdentifier("settings.sounds.inventory.failure")
            Button(l10n.text(.commonRetry)) {
                if let action = sounds?.retryLibraryAction { invoke(action) }
            }
            .disabled(sounds?.retryLibraryAction == nil)
            .accessibilityIdentifier("settings.sounds.inventory.retry")
        case .ready(let files) where files.isEmpty:
            Text(l10n.text(.soundsNoAudio)).foregroundColor(.secondary)
                .accessibilityIdentifier("settings.sounds.inventory.empty")
        case .ready, nil: EmptyView()
        }
    }

    private func inventoryFailureMessage(_ reason: SoundPackEditorInventoryFailureReason) -> String
    {
        switch reason {
        case .packUnavailable:
            l10n.format(.soundPacksInventoryPackNotFound, packID ?? "")
        case .manifestUnreadable:
            l10n.format(.soundPacksInventoryManifestUnreadable, l10n.text(.panelPacksReadFailed))
        case .directoryUnavailable:
            l10n.format(.soundPacksInventoryDirectoryUnreadable, l10n.text(.panelPacksReadFailed))
        }
    }

    private var systemContent: some View {
        List(selection: $selectedItem) {
            ForEach(
                sounds?.eventRows.first(where: { $0.event == selection?.event })?.systemSoundChoices
                    ?? []
            ) { choice in
                HStack {
                    VStack(alignment: .leading) {
                        Text(choice.source.name)
                        if !choice.usedByEvents.isEmpty {
                            Text(occupancy(choice.usedByEvents)).font(.caption).foregroundColor(
                                .secondary)
                        }
                        if owner.soundImportEnvironment.systemSoundCatalog.audioURL(
                            named: choice.source.name) == nil
                        {
                            Text(l10n.text(.soundsUnavailable)).font(.caption).foregroundColor(
                                .secondary)
                        }
                    }
                    Spacer()
                    if let url = owner.soundImportEnvironment.systemSoundCatalog.audioURL(
                        named: choice.source.name)
                    {
                        previewButton(id: "system.\(choice.source.name)") { origin in
                            selectionSession.preview(
                                id: "system.\(choice.source.name)", fileURL: url, origin: origin)
                        }
                    }
                }.tag(choice.source.name).disabled(choice.action == nil)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
        .soundPacksLayoutProbe("settings.sounds.sheet.system.list")
    }

    private func sheetPrimaryButton(_ mode: SoundsSheet) -> some View {
        Button(
            l10n.text(
                [.newPack, .renamePack, .copyPack, .renameAudio].contains(mode)
                    ? .settingsSoundsAICueSaveName
                    : mode == .importPack ? .soundsImport : .soundsUse)
        ) {
            if SoundEventSelectionSession.Mode(rawValue: mode.rawValue) != nil {
                submitSelection(mode)
            } else {
                Task { await submit(mode) }
            }
        }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            .disabled(isWorking || !canSubmit(mode)).accessibilityIdentifier(
                "settings.sounds.sheet.use")
    }

    private func canSubmit(_ mode: SoundsSheet) -> Bool {
        switch mode {
        case .newPack, .renamePack, .copyPack, .renameAudio:
            !inputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .ai:
            selectedCandidate != nil && model.phase == .candidatesReady
                && coordinator.generationBlock == nil && model.generation != nil
        case .history: historySelection != nil
        case .local: localPreview != nil
        case .system, .packFiles: selectedItem != nil
        case .importPack: preparedPack != nil
        default: false
        }
    }

    private func submit(_ mode: SoundsSheet) async {
        working = true
        errorText = nil
        defer { working = false }
        do {
            switch mode {
            case .newPack:
                let draft = try await owner.createNamedDraft(AICuePackName(inputName))
                closeSheet(navigatingTo: .draft(packID: draft.packID))
            case .copyPack:
                guard let packID else { throw SoundAssetStorageError.changed }
                let newID = try await owner.copyNamedPack(
                    packID: packID, name: AICuePackName(inputName))
                closeSheet(navigatingTo: .pack(packID: newID))
            case .renamePack:
                guard let packID else { throw SoundAssetStorageError.changed }
                if sounds?.draft != nil {
                    try await owner.renameNamedDraft(AICuePackName(inputName))
                } else {
                    try await owner.renameInstalledPack(
                        packID: packID, name: AICuePackName(inputName))
                }
                closeSheet()
            case .renameAudio:
                guard let historySelection else { return }
                try await history.rename(
                    batchID: historySelection.batchID, audioID: historySelection.audioID,
                    name: inputName)
                closeSheet()
            case .importPack:
                guard let preparedPack else { return }
                try await owner.importPreparedPack(preparedPack)
                self.preparedPack = nil;
                closeSheet(navigatingTo: .pack(packID: preparedPack.packID))
            default: break
            }
        } catch { errorText = storageMessage(error) }
    }

    private func submitSelection(_ mode: SoundsSheet) {
        let origin = previewOrigin
        if mode == .ai {
            guard let candidate = selectedCandidate else { return }
            errorText = nil
            if !selectionSession.adopt(candidateID: candidate, origin: origin) {
                errorText = l10n.text(.soundsChanged)
            }
            return
        }
        let choice: SoundEventSelectionSession.Choice
        switch mode {
        case .local: choice = .local
        case .history:
            guard let historySelection else { return }
            choice = .history(batchID: historySelection.batchID, audioID: historySelection.audioID)
        case .packFiles, .system:
            guard let selectedItem else { return }
            choice = .existing(mode == .system ? .systemSound(selectedItem) : .file(selectedItem))
        default: return
        }
        errorText = nil
        Task { handleSelectionResult(await selectionSession.use(choice, origin: origin)) }
    }

    private func begin(_ mode: SoundsSheet, event: Event) {
        guard let selectionMode = SoundEventSelectionSession.Mode(rawValue: mode.rawValue),
            selectionSession.begin(event: event, mode: selectionMode) != nil
        else {
            errorText = l10n.text(.soundsUnavailable); return
        }
        previewOrigin = selectionSession.origin
        selectedCandidate = nil; selectedItem = nil; historySelection = nil
        if mode == .history { Task { await history.refresh() } }
        present(mode)
    }

    private func present(_ mode: SoundsSheet) {
        guard
            mode != .service
                || (model.providerIsAdmitted && model.providerCredentialAccessAllowed)
        else {
            if sheet == nil { modalIsPresented = false }
            return
        }
        if selection == nil {
            previewOrigin = selectionSession.activateForm(route: route)
        } else {
            effects.stopPreview(owner: owner, origin: previewOrigin)
        }
        errorText = nil
        selectionRecoveryURL = nil
        sheet = mode
        modalIsPresented = true
    }

    private func closeSheet(navigatingTo destination: SoundPacksWindowRoute.Destination? = nil) {
        afterSheetDestination = destination
        sheet = nil
    }
    private func sheetClosed() {
        let event = selection?.event
        guard sheet == nil, let origin = selectionSession.closeForm(origin: previewOrigin) else {
            return
        }
        if let event { focusedEvent = event }
        previewOrigin = origin
        if let preparedPack { Task { await preparedPack.discard() }; self.preparedPack = nil }
        returnFromService = nil
        modalIsPresented = false
        if let destination = afterSheetDestination {
            afterSheetDestination = nil
            navigate(destination)
        }
    }

    private func finishUse() {
        let target = selection?.packID
        closeSheet(navigatingTo: target.map { .pack(packID: $0) })
    }

    private func handleUseResult(_ result: SoundPacksEditorOperationResult) {
        switch result {
        case .adopted: finishUse()
        case .adoptionOrphan(let imported, _):
            selectionRecoveryURL = imported.destinationURL
            errorText = l10n.format(.soundsOrphan, imported.fileName)
        case .rejected(let reason):
            switch reason {
            case .mutationFailed: errorText = latestWriteFailure ?? l10n.text(.soundsStorageFailure)
            case .importRejected, .invalidImport, .unsafeTarget:
                errorText = latestWriteFailure ?? l10n.text(.soundsUnsafeAsset)
            default: errorText = l10n.text(.soundsChanged)
            }
        default: errorText = l10n.text(.soundsStorageFailure)
        }
    }

    private func handleSelectionResult(_ result: SoundEventSelectionSession.UseResult) {
        switch result {
        case .assigned: finishUse()
        case .assignmentRejected: errorText = latestWriteFailure ?? l10n.text(.soundsChanged)
        case .completed(let completion): handleUseResult(completion.result)
        case .superseded: break
        }
    }

    private var latestWriteFailure: String? {
        sounds?.windowStatuses.last(where: { $0.severity == .failure })?
            .message(language: preferences.language)
    }

    private func chooseLocalFile() {
        let origin = previewOrigin
        Task {
            let result = await selectionSession.prepareLocalSound(origin: origin) {
                await chooseDirectoryOrAudio(directory: false)
            }
            if case .failed(let error) = result { errorText = storageMessage(error) }
        }
    }

    /// 只有可写包（用户包/草稿）的事件行才跟踪拖放目标高亮；出厂包行不注册为目标，
    /// 界面不谎称可写（Q7）。是否可写由 owner 投影的 acceptsEventSoundDrop 给出。
    private func eventDropTargetBinding(for event: Event) -> Binding<Bool>? {
        guard sounds?.acceptsEventSoundDrop == true else { return nil }
        return Binding(
            get: { dropTargetEvent == event },
            set: { targeted in
                if targeted {
                    dropTargetEvent = event
                } else if dropTargetEvent == event {
                    dropTargetEvent = nil
                }
            })
    }

    /// drop = 打开导入流程的预览态（文件预填），手动试听、显式「选用」才绑定（Q3）；
    /// 在出厂包行上松手复用点击路径的「复制为我的包」引导（Q7）。受理时固定呈现身份；
    /// URL 装载悬挂期间换包或开表单都作废受理，迟到回调不得接管新上下文（ADR 0008）。
    private func handleEventSoundDrop(_ providers: [NSItemProvider], event: Event) -> Bool {
        let provider = providers.first {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        if sounds?.acceptsEventSoundDrop == true {
            guard sheet == nil, !isWorking, let provider,
                let acceptance = selectionSession.acceptEventSoundDrop()
            else { return false }
            Task {
                guard let url = await loadSoundPacksDropURL(from: provider) else { return }
                guard selectionSession.acceptanceIsCurrent(acceptance) else { return }
                begin(.local, event: event)
                let result = await selectionSession.prepareLocalSound(
                    fromDrop: url, origin: previewOrigin)
                if case .failed(let error) = result { errorText = storageMessage(error) }
            }
            return true
        }
        if sounds?.draft == nil, pack?.isBuiltinReadOnly == true, pack?.copyAction != nil,
            provider != nil
        {
            inputName = ""
            present(.copyPack)
            return true
        }
        return false
    }

    private func choosePack() {
        Task {
            modalIsPresented = true
            guard let url = await chooseDirectoryOrAudio(directory: true) else {
                modalIsPresented = false; return
            }
            working = true
            defer { working = false }
            do { preparedPack = try await owner.preparePackImport(url); present(.importPack) } catch
            { errorText = storageMessage(error); modalIsPresented = false }
        }
    }

    private func chooseDirectoryOrAudio(directory: Bool) async -> URL? {
        guard let parentWindow else { return nil }
        return await chooseSoundAsset(attachedTo: parentWindow, directory: directory)
    }

    private func previewHistory(_ batch: UUID, _ audio: UUID, origin: ManualPreviewOrigin) {
        Task {
            let result = await selectionSession.previewHistory(
                batchID: batch, audioID: audio, history: history, origin: origin)
            if case .failed(let error) = result { errorText = storageMessage(error) }
        }
    }

    private func trashHistory(_ batch: UUID, _ audio: UUID?) async {
        effects.stopPreview(owner: owner, origin: previewOrigin)
        do { try await history.trash(batchID: batch, audioID: audio) } catch {
            errorText = storageMessage(error)
        }
    }

    private func invoke(_ action: SoundPackEditorAction) {
        effects.consume(owner.send(.invoke(action)), owner: owner)
    }
    private func candidateName(_ candidate: AICueCandidate) -> String {
        let ordinal =
            (model.generation ?? coordinator.generation)?.candidates.firstIndex(where: {
                $0.id == candidate.id
            }).map { $0 + 1 } ?? 1
        return (model.generation ?? coordinator.generation)?.plan.suggestedDisplayName.appending(
            " \(ordinal)") ?? String(ordinal)
    }
    private func occupancy(_ events: [Event]) -> String {
        l10n.format(
            .soundsOccupied,
            events.map { localizedEventName($0, language: preferences.language) }.joined(
                separator: "、"))
    }
    private func profileTitle(_ id: AICueProviderProfileID) -> String {
        if id == .qwenBeijing { return l10n.text(.aiCueProviderProfileQwenBeijing) }
        if id == .qwenSingapore { return l10n.text(.aiCueProviderProfileQwenSingapore) }
        guard let profile = try? AICueProviderRegistry().profile(for: id) else {
            return id.rawValue
        }
        return l10n.text(profile.displayNameKey)
    }
    private func previewButton(
        id: String, action: @escaping (ManualPreviewOrigin) -> Void
    ) -> some View {
        let origin = previewOrigin
        return MotionPreviewButton(
            isPlaying: effects.previewSession.isPlaying(id, origin: origin),
            playLabel: l10n.text(.soundsPlay), stopLabel: l10n.text(.soundsStop),
            action: { action(origin) }
        )
        .accessibilityIdentifier("settings.sounds.preview.\(id)")
    }
    private func errorLabel(_ message: String) -> some View {
        Text(message).foregroundColor(.red).font(.callout).fixedSize(
            horizontal: false, vertical: true
        )
        .textSelection(.enabled)
        .accessibilityIdentifier("settings.sounds.error")
    }
    @ViewBuilder private func recoveryButton(_ error: SoundAssetStorageError) -> some View {
        if case .recoveryRequired(let url) = error {
            Button(l10n.text(.settingsNativeRevealInFinder)) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }.accessibilityIdentifier("settings.sounds.reveal-recovery")
        }
    }
    private func storageMessage(_ error: Error) -> String {
        if error is AICuePackNameValidationError || error is AICueValidationError {
            return l10n.text(.soundsNameInvalid)
        }
        switch error as? SoundAssetStorageError {
        case .nameConflict: return l10n.text(.soundsNameConflict)
        case .corrupt, .unsafeEntry: return l10n.text(.soundsUnsafeAsset)
        case .changed: return l10n.text(.soundsChanged)
        case .busy: return l10n.text(.soundsBusy)
        case .trashFailed: return l10n.text(.soundsTrashFailure)
        case .recoveryRequired(let url): return l10n.format(.soundsRecovery, url.path)
        default: return l10n.text(.soundsStorageFailure)
        }
    }
    private func sheetTitle(_ mode: SoundsSheet) -> String {
        let key: ClaudioL10nKey =
            switch mode {
            case .newPack: .soundsNewPack
            case .copyPack: .soundsCopy
            case .renamePack, .renameAudio: .soundsRename
            case .ai: .soundsAI
            case .history: .soundsFromHistory
            case .local: .soundsFromFile
            case .packFiles: .soundsFromPack
            case .system: .soundsFromSystem
            case .manage: .soundsManageFiles
            case .importPack: .soundsImportPack
            case .service: .soundsService
            }
        return l10n.text(key)
    }
    private func openLegacySheetIfNeeded() {
        if case .audio = route.destination, sheet == nil { present(.manage) }
    }
    private var confirmationTitle: String { l10n.text(.soundsConfirm) }
    private var confirmationMessage: String {
        switch confirmation {
        case .history(_, let count): l10n.format(.soundsTrashGroup, count)
        case .pending(let count): l10n.format(.soundsDiscardPending, count)
        case .draft(_, let name): l10n.format(.soundsDeleteDraft, name)
        case .owner(let item):
            switch item.kind {
            case .restoreFactory: l10n.text(.soundPacksRestoreSelectedMessage)
            case .retryRestore: l10n.text(.soundPacksRestoreRetryMessage)
            case .restoreAllFactory: l10n.text(.soundPacksRestoreAllMessage)
            case .deletePack, .deleteOrphan:
                l10n.format(.soundsTrashFile, item.fileName ?? packName)
            }
        case nil: ""
        }
    }
    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil; modalIsPresented = sheet != nil } })
    }
    private var outerConfirmationBinding: Binding<Bool> {
        Binding(
            get: { confirmation != nil && sheet == nil },
            set: { if !$0 { confirmation = nil; modalIsPresented = sheet != nil } })
    }
    private var confirmationButtons: some View {
        Group {
            Button(l10n.text(.commonCancel), role: .cancel) {
                if case .owner(let item) = confirmation { invoke(item.cancelAction) }
                confirmation = nil; modalIsPresented = sheet != nil
            }
            Button(l10n.text(.soundsConfirm), role: .destructive) {
                let action = confirmation
                confirmation = nil
                effects.stopPreview(owner: owner, origin: previewOrigin)
                Task {
                    do {
                        switch action {
                        case .history(let id, let count):
                            try await history.trash(batchID: id, expectedCount: count)
                        case .pending(let count):
                            await coordinator.abandonPending(expectedCount: count)
                        case .draft(let id, _):
                            try await owner.deleteNamedDraft(id); navigate(.overview)
                        case .owner(let item): invoke(item.confirmAction)
                        case nil: break
                        }
                    } catch { errorText = storageMessage(error) }
                    modalIsPresented = sheet != nil
                }
            }
        }
    }
}

/// Focus belongs to the sheet's view hierarchy, not the presenting window's FocusState scope.
private struct SoundsDescriptionInput: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        TextEditor(text: $text).focused($focused)
            .accessibilityIdentifier("settings.sounds.ai.description")
            .task {
                await Task.yield()
                if !Task.isCancelled { focused = true }
            }
    }
}

private struct SoundsNameInput: View {
    let title: String
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        TextField(title, text: $text).textFieldStyle(.roundedBorder).focused($focused)
            .accessibilityIdentifier("settings.sounds.name-input")
            .task {
                await Task.yield()
                if !Task.isCancelled { focused = true }
            }
    }
}

private struct SoundsWindowProbe: NSViewRepresentable {
    let receive: @MainActor (NSWindow?) -> Void
    func makeNSView(context: Context) -> Probe {
        let view = Probe(); view.receive = receive; return view
    }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.receive = receive }
    final class Probe: NSView {
        var receive: (@MainActor (NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); receive?(window) }
    }
}

private struct AICueOptionalFocus: ViewModifier {
    let binding: FocusState<AICueTaskFocus?>.Binding?
    let target: AICueTaskFocus
    @ViewBuilder func body(content: Content) -> some View {
        if let binding { content.focused(binding, equals: target) } else { content }
    }
}
