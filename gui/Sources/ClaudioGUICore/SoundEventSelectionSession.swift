import ClaudioCore
import Combine
import Foundation

/// Coordinates one presentation lifetime inside the pack editor. Generation, history, playback
/// and disk writes remain facts of their existing owners; callers do not order their cleanup.
@MainActor
package final class SoundEventSelectionSession: @preconcurrency ObservableObject {
    package enum Mode: String, CaseIterable { case ai, history, packFiles, local, system }
    package enum ResourceResult: Equatable {
        case ready, cancelled, superseded
        case failed(SoundAssetStorageError)
    }
    package enum Choice {
        case local
        case history(batchID: UUID, audioID: UUID)
        case existing(PackEventSoundSource)
    }
    package enum UseResult: Sendable {
        case completed(Completion)
        case assigned
        case assignmentRejected
        case superseded
    }

    /// An immutable carrier avoids copying the editor's large result through a second enum.
    package final class Completion: Sendable {
        package let result: SoundPacksEditorOperationResult
        fileprivate init(_ result: SoundPacksEditorOperationResult) { self.result = result }
    }

    /// 事件行拖放的受理身份：受理瞬间的呈现 origin 与退役代数。URL 装载悬挂期间，呈现一旦
    /// 退役或轮换（换包、开关表单、离开页面）origin 即更换；目标失效收回采用权保留页面
    /// origin 供恢复，但退役代数已递增——两条任一变化都作废旧受理（ADR 0008 迟到结果隔离）。
    package struct EventSoundDropAcceptance: Sendable {
        fileprivate let origin: ManualPreviewOrigin
        fileprivate let epoch: UInt64
    }

    package let objectWillChange = ObservableObjectPublisher()
    package private(set) var context: SoundEventSelectionContext? {
        willSet { objectWillChange.send() }
    }
    package private(set) var localPreview: SoundLocalAudioPreview? {
        willSet { objectWillChange.send() }
    }
    package private(set) var isPreparingLocalSound = false {
        willSet { objectWillChange.send() }
    }
    package private(set) var isUsingSound = false {
        willSet { objectWillChange.send() }
    }
    package private(set) var origin = ManualPreviewOrigin(.settings) {
        willSet { objectWillChange.send() }
    }
    private weak var editor: SoundPacksEditorOwner?
    private var composer: AICueGenerationViewModel?
    private var playback: ManualAudioPreviewSession?
    private var composerObservation: AnyCancellable?
    private var mode: Mode?
    private enum PresentationPhase { case inactive, page, form, invalidatedForm }
    private var presentationPhase: PresentationPhase = .inactive
    /// 退役代数：每次 retirePresentation 递增。`invalidateTarget` 保留页面 origin 供恢复，
    /// 受理令牌靠它区分「同一页面身份的不同时代」。
    private var presentationEpoch: UInt64 = 0
    private var presentationIsActive: Bool {
        presentationPhase == .page || presentationPhase == .form
    }
    private var presentedRoute: SoundPacksWindowRoute?
    private var publishedDraftID: String?
    private var localRequestID = UUID()
    private var historyPreview: SoundLocalAudioPreview?
    #if DEBUG
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    #endif

    package init(editor: SoundPacksEditorOwner) { self.editor = editor }

    /// Composition borrows the same app-lifetime owners used by the rest of Settings. Repeated
    /// wiring of the retained window is harmless and does not recreate an adoption context.
    package func configure(
        composer: AICueGenerationViewModel, playback: ManualAudioPreviewSession
    ) {
        guard self.composer !== composer || self.playback !== playback else { return }
        end()
        self.composer = composer
        self.playback = playback
        composerObservation = composer.$session.combineLatest(
            composer.$generation, composer.coordinator.$state
        ).sink { [weak self] projection in
            MainActor.assumeIsolated {
                self?.synchronizeComposer(
                    session: projection.0, generation: projection.1, state: projection.2)
            }
        }
    }

    /// An editor route transition is authoritative even when a compatibility composer has not
    /// mounted a new selection form. Cold activation borrows its projection; leaving the active
    /// Sounds context retires it. Repeated native callbacks only carry an origin instead.
    package func editorWillChangeContext(
        from previous: SoundPacksEditorContext, to next: SoundPacksEditorContext
    ) -> Bool {
        if !previous.isSounds, case .sounds(let route, _) = next,
            let borrowed = composer?.session,
            route.isCopyAndApply || route.editTarget?.packID != borrowed.packID
                || route.editTarget?.event != borrowed.event
        {
            composer?.endSession()
            editor?.updateAICueComposer(session: nil, generation: nil)
        }
        if case .sounds(let oldRoute, _) = previous, case .sounds(let newRoute, _) = next,
            oldRoute == newRoute || preservesPublishedDraft(route: newRoute)
        {
            return false
        }
        guard previous.isSounds || next.isSounds || next == .inactive else { return false }
        let hadPresentation = presentationPhase != .inactive
        end()
        if previous.isSounds, !hadPresentation {
            composer?.endSession()
            editor?.updateAICueComposer(session: nil, generation: nil)
        }
        return true
    }

    /// Opens a page. The returned origin is a presentation identity, not a
    /// second playback state. A late disappearance can only end the lifetime it captured.
    @discardableResult
    package func activate(route: SoundPacksWindowRoute? = nil) -> ManualPreviewOrigin {
        activate(route: route, preservingComposer: false)
    }

    private func activate(
        route: SoundPacksWindowRoute?, preservingComposer: Bool
    ) -> ManualPreviewOrigin {
        retirePresentation(detachComposer: !preservingComposer)
        origin = ManualPreviewOrigin(.settings)
        presentedRoute = route
        presentationPhase = .page
        return origin
    }

    /// Attached management forms share dismissal and preview cleanup without adoption authority.
    @discardableResult
    package func activateForm(route: SoundPacksWindowRoute? = nil) -> ManualPreviewOrigin {
        let origin = activate(route: route)
        presentationPhase = .form
        return origin
    }

    /// A successful first-sound publication changes browsing identity before the operation's
    /// presentation completion. It is the same explicit selection, not a leave/reopen.
    package func routeChanged(
        to route: SoundPacksWindowRoute, origin expectedOrigin: ManualPreviewOrigin
    ) -> ManualPreviewOrigin? {
        guard expectedOrigin == origin, let editor, case .sounds = editor.presentation.mode
        else { return nil }
        if preservesPublishedDraft(route: route) {
            presentedRoute = route
            return origin
        }
        let hadOpenForm = presentationPhase == .form || presentationPhase == .invalidatedForm
        let updatedOrigin = activate(route: route)
        // An accepted operation can change the route before its form finishes dismissing.
        // Revoke selection and playback, but let that form clear its modal navigation blocker.
        if hadOpenForm { presentationPhase = .invalidatedForm }
        return updatedOrigin
    }

    package func preservesPublishedDraft(route: SoundPacksWindowRoute) -> Bool {
        guard presentationIsActive, let publishedDraftID, context?.packID == publishedDraftID else {
            return false
        }
        return route.destination == .pack(packID: publishedDraftID)
            || route.destination == .draft(packID: publishedDraftID)
    }

    /// The editor calls this only after the exclusive first-sound publish succeeded. This is an
    /// operation-bound presentation permission; library snapshots still own installed-pack facts.
    package func noteDraftPublished(packID: String) {
        if presentationIsActive, context?.draft?.packID == packID { publishedDraftID = packID }
    }

    package func invalidateTarget(viewedPackID: String?) {
        if presentationIsActive, let publishedDraftID, viewedPackID == publishedDraftID,
            context?.packID == publishedDraftID
        {
            return
        }
        let hadOpenForm = presentationPhase == .form || presentationPhase == .invalidatedForm
        let hadMountedPage = presentationPhase == .page
        end()
        // Revoking adoption must not strand this same sheet's modal navigation blocker. Only
        // its dismissal remains permitted; preparation, playback and Use stay invalidated.
        if hadOpenForm {
            presentationPhase = .invalidatedForm
        }
        // A target failure does not unmount the page. Its new explicit preview actions still
        // resolve through the editor after recovery; old asynchronous requests remain revoked.
        else if hadMountedPage {
            presentationPhase = .page
        }
    }

    /// Dismissal and returning to the page are one identity-checked transition. A rejected late
    /// dismissal cannot perform a subsequent unconditional activation against a new owner.
    package func closeForm(origin expectedOrigin: ManualPreviewOrigin) -> ManualPreviewOrigin? {
        guard expectedOrigin == origin,
            presentationPhase == .form || presentationPhase == .invalidatedForm
        else { return nil }
        if presentationPhase == .invalidatedForm {
            guard let editor, case .sounds = editor.presentation.mode else { return nil }
        }
        return activate(route: presentedRoute)
    }

    /// 受理事件行拖放：固定当前呈现身份。仅在页面/表单活跃时可受理；URL 装载完成后的
    /// 迟到回调必须先经 ``acceptanceIsCurrent(_:)`` 重验，不得接管换包或新表单上下文。
    package func acceptEventSoundDrop() -> EventSoundDropAcceptance? {
        guard presentationIsActive else { return nil }
        return EventSoundDropAcceptance(origin: origin, epoch: presentationEpoch)
    }

    /// 受理身份仅在呈现仍活跃、未轮换且未经历退役（含目标失效收回）时有效。
    package func acceptanceIsCurrent(_ acceptance: EventSoundDropAcceptance) -> Bool {
        isCurrent(acceptance.origin) && presentationEpoch == acceptance.epoch
    }

    @discardableResult
    package func begin(event: Event, mode: Mode) -> SoundEventSelectionContext? {
        guard let editor, let selection = editor.beginSoundSelection(event: event) else {
            return nil
        }
        // A matching composer already mounted through a legacy route may transfer into its first
        // explicit form. This never transfers a previous selection or revives a closed session.
        let borrowsMatchingComposer =
            mode == .ai && context == nil && self.mode == nil
            && composer?.session?.packID == selection.packID
            && composer?.session?.event == event
        let hadPresentation = presentationPhase != .inactive
        _ = activate(route: presentedRoute, preservingComposer: borrowsMatchingComposer)
        if !borrowsMatchingComposer, !hadPresentation {
            composer?.endSession()
            editor.updateAICueComposer(session: nil, generation: nil)
        }
        self.mode = mode
        context = selection
        presentationPhase = .form
        if mode == .ai {
            composer?.begin(packID: selection.packID, event: event)
            synchronizeComposer()
        }
        return selection
    }

    package func end(origin expectedOrigin: ManualPreviewOrigin? = nil) {
        guard presentationPhase != .inactive else { return }
        if let expectedOrigin {
            guard presentationPhase != .inactive, expectedOrigin == origin else { return }
        }
        retirePresentation(detachComposer: true)
    }

    private func retirePresentation(detachComposer: Bool) {
        guard presentationPhase != .inactive else { return }
        presentationEpoch &+= 1
        let selection = context
        presentationPhase = .inactive
        localRequestID = UUID()
        isPreparingLocalSound = false
        isUsingSound = false
        publishedDraftID = nil
        // Revoke authority and stop playback synchronously before releasing any staged file.
        context = nil
        mode = nil
        if let selection { editor?.endSoundSelection(selection) }
        playback?.stop(origin: origin)
        if detachComposer {
            composer?.endSession()
            editor?.updateAICueComposer(session: nil, generation: nil)
        }
        if let localPreview { release(localPreview); self.localPreview = nil }
        if let historyPreview { release(historyPreview); self.historyPreview = nil }
    }

    package func synchronizeComposer() {
        guard let composer else { return }
        synchronizeComposer(
            session: composer.session, generation: composer.generation,
            state: composer.coordinator.state)
    }

    private func synchronizeComposer(
        session: AICueComposerSession?, generation: AICueGeneration?,
        state: AICueGenerationTaskState
    ) {
        guard presentationIsActive, mode == .ai, let context,
            session?.packID == context.packID, session?.event == context.event
        else { return }
        let archived: AICueGeneration?
        if case .saved = state { archived = generation } else { archived = nil }
        editor?.updateAICueComposer(session: session, generation: archived)
    }

    /// Includes the native picker suspension, so neither late success nor late failure can
    /// become a resource or error of a subsequently opened form.
    package func prepareLocalSound(
        origin expectedOrigin: ManualPreviewOrigin? = nil,
        choosing: @MainActor () async -> URL?
    ) async -> ResourceResult {
        if let expectedOrigin, !self.isCurrent(expectedOrigin) { return .superseded }
        guard presentationIsActive, mode == .local, let contextID = context?.id, let editor else {
            return .superseded
        }
        let capturedOrigin = origin
        let requestID = UUID()
        localRequestID = requestID
        isPreparingLocalSound = false
        func isCurrent() -> Bool {
            self.isCurrent(capturedOrigin) && self.context?.id == contextID
                && self.localRequestID == requestID
        }
        let source = await choosing()
        guard isCurrent() else { return .superseded }
        guard let source else { return .cancelled }
        isPreparingLocalSound = true
        defer { if isCurrent() { isPreparingLocalSound = false } }
        do {
            let prepared = try await editor.prepareLocalSound(source)
            guard isCurrent() else { await prepared.discard(); return .superseded }
            if let localPreview {
                playback?.stop(origin: capturedOrigin)
                release(localPreview)
            }
            localPreview = prepared
            return .ready
        } catch {
            guard isCurrent() else { return .superseded }
            return .failed((error as? SoundAssetStorageError) ?? .unavailable)
        }
    }

    /// 拖放导入与文件选择面板共享同一本地导入流程：来源 URL 已由拖拽给出，只是跳过系统
    /// 面板的悬挂。硬化校验、预览态与「选用」提交与面板路径完全一致。
    package func prepareLocalSound(
        fromDrop source: URL,
        origin expectedOrigin: ManualPreviewOrigin? = nil
    ) async -> ResourceResult {
        await prepareLocalSound(origin: expectedOrigin) { source }
    }

    /// History management uses the same resource seam without acquiring adoption authority.
    package func previewHistory(
        batchID: UUID, audioID: UUID, history: GenerationHistoryStore,
        origin expectedOrigin: ManualPreviewOrigin? = nil
    ) async -> ResourceResult {
        if let expectedOrigin, !self.isCurrent(expectedOrigin) { return .superseded }
        guard presentationIsActive, let playback else { return .superseded }
        let capturedOrigin = origin
        guard let token = playback.prepare(origin: capturedOrigin, target: audioID.uuidString)
        else { return .cancelled }
        func isCurrent() -> Bool {
            self.isCurrent(capturedOrigin) && playback.isCurrent(token)
        }
        do {
            let proof = try await history.audio(batchID: batchID, audioID: audioID)
            guard isCurrent() else { return .superseded }
            let prepared = try await SoundLocalAudioPreview.prepare(history: proof)
            guard isCurrent() else { await prepared.discard(); return .superseded }
            let previous = historyPreview
            historyPreview = nil
            if let previous { await previous.discard() }
            guard isCurrent() else { await prepared.discard(); return .superseded }
            historyPreview = prepared
            _ = playback.start(token, fileURL: prepared.fileURL, volume: 1)
            return .ready
        } catch {
            guard isCurrent() else { return .superseded }
            playback.fail(token)
            return .failed((error as? SoundAssetStorageError) ?? .unavailable)
        }
    }

    /// Accepted disk work settles in the editor even after dismissal. Only the still-current
    /// presentation receives a result that may navigate or show recovery feedback.
    package func use(_ choice: Choice, origin expectedOrigin: ManualPreviewOrigin? = nil) async
        -> UseResult
    {
        if let expectedOrigin, !isCurrent(expectedOrigin) { return .superseded }
        guard presentationIsActive, !isUsingSound, let context, let editor else {
            return .superseded
        }
        let capturedOrigin = origin
        isUsingSound = true
        defer { if isCurrent(capturedOrigin) { isUsingSound = false } }
        let result: SoundPacksEditorOperationResult
        switch choice {
        case .local:
            guard mode == .local, let localPreview else { return .superseded }
            result = await editor.useLocalSound(localPreview, selection: context)
        case .history(let batchID, let audioID):
            guard mode == .history, let composer else { return .superseded }
            result = await editor.useHistorySound(
                batchID: batchID, audioID: audioID, history: composer.coordinator.history,
                selection: context)
        case .existing(let source):
            guard mode == .system || mode == .packFiles else { return .superseded }
            return editor.useExistingSound(source, selection: context)
                ? .assigned : .assignmentRejected
        }
        guard isCurrent(capturedOrigin), self.context?.id == context.id else {
            return .superseded
        }
        return .completed(Completion(result))
    }

    @discardableResult
    package func adopt(candidateID: UUID, origin expectedOrigin: ManualPreviewOrigin? = nil) -> Bool
    {
        if let expectedOrigin, !isCurrent(expectedOrigin) { return false }
        guard presentationIsActive, mode == .ai, let context, let composer, let editor,
            composer.phase == .candidatesReady, composer.coordinator.generationBlock == nil,
            case .sounds(let sounds) = editor.presentation.mode,
            let permit = sounds.eventRows.first(where: { $0.event == context.event })?
                .aiCueAdoptionPermit
        else { return false }
        composer.adopt(candidateID: candidateID, permit: permit) { candidate, name, permit in
            await editor.perform(
                .adoptAICue(candidate: candidate, displayName: name, permit: permit))
        }
        return true
    }

    private func isCurrent(_ origin: ManualPreviewOrigin) -> Bool {
        presentationIsActive && self.origin == origin
    }

    package func preview(id: String, fileURL: URL, origin: ManualPreviewOrigin) {
        guard isCurrent(origin), let playback,
            let token = playback.prepare(origin: origin, target: id)
        else { return }
        _ = playback.start(token, fileURL: fileURL, volume: 1)
    }

    package func preview(id: String, action: SoundPackEditorAction, origin: ManualPreviewOrigin) {
        guard isCurrent(origin), let playback, let editor,
            let token = playback.prepare(origin: origin, target: id)
        else { return }
        guard case .nativeEffect(.playAudio(let url, _)) = editor.send(.invoke(action)) else {
            playback.fail(token)
            return
        }
        _ = playback.start(token, fileURL: url, volume: 1)
    }

    private func release(_ preview: SoundLocalAudioPreview) {
        #if DEBUG
        let id = UUID()
        cleanupTasks[id] = Task { [weak self] in
            await preview.discard()
            self?.cleanupTasks.removeValue(forKey: id)
        }
        #else
        Task { await preview.discard() }
        #endif
    }

    #if DEBUG
    package func waitForResourceCleanupForTesting() async {
        while !cleanupTasks.isEmpty {
            for task in Array(cleanupTasks.values) { await task.value }
        }
    }
    #endif
}
