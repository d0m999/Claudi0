import ClaudioCore
import Foundation

/// Which of the sound-pack editor's import/bind pipelines one transaction run serves. The
/// envelope below exists exactly once; a variant only narrows how accepted bytes become a bound
/// 提示音候选 Cue Candidate or an unbound remnant.
package enum SoundPackImportBindVariant: Equatable, Sendable {
    /// 提示音采用 Cue Adoption into an installed, healthy 用户声音包 User Sound Pack: exactly one
    /// accepted file, and a file that cannot be bound stays on disk as a reported orphan.
    case adoptCue
    /// First-cue adoption that publishes a hidden draft pack: exactly one accepted file inside a
    /// staged tree, and every non-success terminal discards that stage instead of surfacing an
    /// orphan (ADR 0016: a failure must not leave a selectable empty pack).
    case adoptCueDraftPublish
    /// Batch audio import into the selected 用户声音包 User Sound Pack, optionally binding the last
    /// accepted file to one Event.
    case importAudio(bindsEvent: Bool)
}

/// Off-main target validation before any byte is written.
package enum SoundPackImportBindTargetCheck: Equatable, Sendable {
    case available
    case unavailable
    case cancelled
}

/// Pre-write revalidation at the freshest projection. ADR 0016 fail-closed doctrine: the reason
/// the target stopped being writable decides the typed failure, so the check reports whether
/// writes are still allowed at all.
package enum SoundPackImportBindCurrencyCheck: Equatable, Sendable {
    case current
    case stale(writesAllowed: Bool)
}

/// The off-main importer's terminal fact.
package enum SoundPackImportBindExecution: Equatable, Sendable {
    case cancelledBeforeWrite
    case completed(AudioImportBatchResult, cancellationRequested: Bool)
}

/// The one file a single-file pipeline binds, or the last accepted file a batch import binds.
package struct SoundPackImportBindInput: Equatable, Sendable {
    package let imported: ImportedAudioFile

    package init(imported: ImportedAudioFile) {
        self.imported = imported
    }
}

/// Receipt of a successful manifest bind.
package struct SoundPackImportBindBinding: Equatable, Sendable {
    /// Batch import only: the Event the file was bound to.
    package let boundEvent: Event?
    /// Cue Adoption only: the atomic name+Event manifest receipt.
    package let manifest: AICueManifestBindingOutcome?

    package init(boundEvent: Event?, manifest: AICueManifestBindingOutcome?) {
        self.boundEvent = boundEvent
        self.manifest = manifest
    }
}

/// The variant bind step's result. Failures stay typed so the transaction can attribute them
/// instead of collapsing every cause into one generic error.
package enum SoundPackImportBindResult: Equatable, Sendable {
    case bound(SoundPackImportBindBinding)
    case failed(SoundPackEditorFailure)
}

/// Post-bind revalidation plus the draft's atomic publication. Real-pack variants are the
/// identity finalizer: their target revalidation already happened before the bind.
package enum SoundPackImportBindFinalize: Equatable, Sendable {
    /// Publication completed; for the draft this is the file rewritten to its final pack URL.
    case finalized(imported: ImportedAudioFile)
    /// Cancellation arrived after the bind; the staged remnant is discarded, nothing is claimed.
    case cancelled
    /// The 提示音采用目标 Cue Adoption Target moved after the bind; the staged remnant is discarded.
    case stale
    /// Publication failed; the staged remnant is discarded and no pack claims to exist.
    case failed(SoundPackEditorFailure)
}

/// Successful terminal facts, handed back for the caller's public outcome mapping.
package struct SoundPackImportBindSuccess: Equatable, Sendable {
    /// Adoption: the bound file (for the draft, rewritten to the published pack URL). Batch
    /// import: the last accepted file when one exists.
    package let imported: ImportedAudioFile?
    /// Cue Adoption only: the manifest bind receipt carrying the final display name.
    package let binding: AICueManifestBindingOutcome?
    /// Owner-signed foreground preview capability, when the variant signs one.
    package let previewAction: SoundPackEditorAction?
    /// Batch import only: the retained per-file receipt already settled into the activity.
    package let importOutcome: SoundPackEditorImportOutcome?

    package init(
        imported: ImportedAudioFile?,
        binding: AICueManifestBindingOutcome?,
        previewAction: SoundPackEditorAction?,
        importOutcome: SoundPackEditorImportOutcome?
    ) {
        self.imported = imported
        self.binding = binding
        self.previewAction = previewAction
        self.importOutcome = importOutcome
    }
}

/// Cancellation terminal. `changedOnDisk` is true only when accepted bytes remain in the target
/// pack (batch import without a bind request); a discarded draft stage reports no disk change.
package struct SoundPackImportBindCancelled: Equatable, Sendable {
    package let changedOnDisk: Bool
    /// Batch import only: the retained receipt settled alongside the cancelled phase.
    package let importOutcome: SoundPackEditorImportOutcome?

    package init(changedOnDisk: Bool, importOutcome: SoundPackEditorImportOutcome?) {
        self.changedOnDisk = changedOnDisk
        self.importOutcome = importOutcome
    }
}

/// The importer accepted nothing; nothing was bound and no disk fact changed.
package struct SoundPackImportBindEmpty: Equatable, Sendable {
    /// Batch import only: the retained per-file rejection receipt.
    package let importOutcome: SoundPackEditorImportOutcome?

    package init(importOutcome: SoundPackEditorImportOutcome?) {
        self.importOutcome = importOutcome
    }
}

/// Accepted bytes remain on disk in an installed pack but could not be bound. The honest
/// terminal receipt: the user can inspect or delete the file.
package struct SoundPackImportBindOrphan: Equatable, Sendable {
    package let imported: ImportedAudioFile
    package let failure: SoundPackEditorFailure
    /// Batch import only: the retained per-file receipt already settled into the activity.
    package let importOutcome: SoundPackEditorImportOutcome?

    package init(
        imported: ImportedAudioFile,
        failure: SoundPackEditorFailure,
        importOutcome: SoundPackEditorImportOutcome?
    ) {
        self.imported = imported
        self.failure = failure
        self.importOutcome = importOutcome
    }
}

/// The one typed terminal every import/bind pipeline settles into. Cancellation, orphan and
/// empty semantics are owned by the transaction; callers only map this value to their public
/// operation result.
package enum SoundPackImportBindOutcome: Equatable, Sendable {
    case succeeded(SoundPackImportBindSuccess)
    case cancelled(SoundPackImportBindCancelled)
    case empty(SoundPackImportBindEmpty)
    case orphan(SoundPackImportBindOrphan)
    case failed(SoundPackEditorFailure)
}

/// The owner-side seam a transaction run orchestrates. Implementations adapt the editor owner's
/// existing private primitives (operation ledger, compound mutation envelope, draft stage,
/// announcement publication); the transaction owns only their order and the terminal semantics.
@MainActor
package protocol SoundPackImportBindTransactionHooks {
    /// Registers the busy operation and publishes the busy frame; returns its identity.
    func beginOperation() -> SoundPackEditorOperationID

    /// Off-main check that the target pack directory still resolves before any write.
    func validateTarget() async -> SoundPackImportBindTargetCheck

    /// The target missed validation: re-observe through the one shared 声音包库 Sound Pack Library
    /// and report whether writes are still allowed, for canonical failure attribution.
    func reobserveUnavailableTarget() async -> Bool

    /// Pre-write revalidation at the freshest configuration projection.
    func recheckTargetCurrencyBeforeWrite() -> SoundPackImportBindCurrencyCheck

    /// Opens the compound write scope and publishes the started frame. The staged draft does not
    /// open one: its hidden tree is invisible to the shared library until publication.
    func beginWriteScope()

    /// Runs the importer off-main.
    func executeImport() async -> SoundPackImportBindExecution

    /// Samples the owner-held cancellation token.
    func cancellationIsRequested() -> Bool

    /// Post-write target revalidation before binding.
    func targetRemainsCurrentAfterWrite() -> Bool

    /// Binds the imported file to its 提示音采用目标 Cue Adoption Target or Event.
    func bindImportedAudio(_ input: SoundPackImportBindInput) -> SoundPackImportBindResult

    /// Post-bind revalidation and (draft-only) atomic publication.
    func finalizeBinding(_ input: SoundPackImportBindInput) -> SoundPackImportBindFinalize

    /// Closes the write scope without asking the shared library to scan; no bytes landed.
    func finishWriteScopeWithoutChange()

    /// Closes the write scope with exactly one shared-library refresh for the target pack.
    func finishWriteScope(changedDespiteFailure: Bool)

    /// Discards staged remnants (the draft's hidden tree). Idempotent per run; real-pack
    /// variants are no-ops because their remnant is an honestly reported orphan instead.
    func discardStagedRemnants()

    /// Signs a foreground preview capability for a successfully bound file.
    func signForegroundPreview(for imported: ImportedAudioFile) -> SoundPackEditorAction?

    /// Settles the operation with its terminal phase, optional retained import receipt,
    /// announcement debt and publication.
    func settleOperation(
        _ operationID: SoundPackEditorOperationID,
        phase: SoundPackEditorActivityPhase,
        importOutcome: SoundPackEditorImportOutcome?)
}

/// The sound-pack editor's one import/bind transaction envelope.
///
/// Every automatic write of 提示音候选 Cue Candidate bytes or imported audio into a 用户声音包
/// User Sound Pack runs this state machine exactly once:
///
///     beginOperation → validateTarget → pre-write currency recheck → beginWriteScope
///     → executeImport → cancellation → target currency → empty → bind → finalize → settle
///
/// Cancellation, orphan, empty and fail-closed failure attribution (ADR 0016 revalidation: a
/// lost target is reported as target/scope loss, never blamed on the import) are owned here, so
/// no pipeline can drift its own copy of the envelope. The editor owner keeps permit signing and
/// validation, freshness stamps, announcement publication and the presentation projection; it
/// reaches this module only through ``SoundPackImportBindTransactionHooks``.
@MainActor
package final class SoundPackImportBindTransaction {
    private let variant: SoundPackImportBindVariant
    private let hooks: any SoundPackImportBindTransactionHooks

    package init(
        variant: SoundPackImportBindVariant,
        hooks: any SoundPackImportBindTransactionHooks
    ) {
        self.variant = variant
        self.hooks = hooks
    }

    package func run() async -> SoundPackImportBindOutcome {
        let operationID = hooks.beginOperation()
        switch await hooks.validateTarget() {
        case .cancelled:
            hooks.discardStagedRemnants()
            return settleCancelledBeforeWrite(operationID)
        case .unavailable:
            hooks.discardStagedRemnants()
            let writesAllowed = await hooks.reobserveUnavailableTarget()
            let failure: SoundPackEditorFailure =
                writesAllowed ? .packUnavailable : .scopeUnavailable
            hooks.settleOperation(operationID, phase: .failed(failure), importOutcome: nil)
            return .failed(failure)
        case .available:
            break
        }
        switch hooks.recheckTargetCurrencyBeforeWrite() {
        case .current:
            break
        case .stale(let writesAllowed):
            hooks.discardStagedRemnants()
            let failure: SoundPackEditorFailure =
                writesAllowed ? .stalePermit : .scopeUnavailable
            hooks.settleOperation(operationID, phase: .failed(failure), importOutcome: nil)
            return .failed(failure)
        }
        hooks.beginWriteScope()
        switch await hooks.executeImport() {
        case .cancelledBeforeWrite:
            hooks.finishWriteScopeWithoutChange()
            hooks.discardStagedRemnants()
            return settleCancelledBeforeWrite(operationID)
        case .completed(let batch, let cancellationReported):
            let cancellationRequested =
                cancellationReported || hooks.cancellationIsRequested()
            return completeExecution(
                operationID,
                batch: batch,
                cancellationRequested: cancellationRequested)
        }
    }

    private func settleCancelledBeforeWrite(
        _ operationID: SoundPackEditorOperationID
    ) -> SoundPackImportBindOutcome {
        hooks.settleOperation(
            operationID,
            phase: .cancelled(changedOnDisk: false),
            importOutcome: nil)
        return .cancelled(
            SoundPackImportBindCancelled(changedOnDisk: false, importOutcome: nil))
    }

    private func completeExecution(
        _ operationID: SoundPackEditorOperationID,
        batch: AudioImportBatchResult,
        cancellationRequested: Bool
    ) -> SoundPackImportBindOutcome {
        switch variant {
        case .adoptCue, .adoptCueDraftPublish:
            return completeSingleFileExecution(
                operationID,
                batch: batch,
                cancellationRequested: cancellationRequested)
        case .importAudio(let bindsEvent):
            return completeBatchExecution(
                operationID,
                batch: batch,
                bindsEvent: bindsEvent,
                cancellationRequested: cancellationRequested)
        }
    }

    // MARK: Single-file pipelines (Cue Adoption, real pack or draft publish)

    /// Canonical ADR 0016 order for one accepted 提示音候选 Cue Candidate: cancellation, then
    /// target currency, then empty, then bind. A stale target outranks an empty batch so the
    /// receipt never blames the importer for a target the world already moved.
    private func completeSingleFileExecution(
        _ operationID: SoundPackEditorOperationID,
        batch: AudioImportBatchResult,
        cancellationRequested: Bool
    ) -> SoundPackImportBindOutcome {
        if cancellationRequested {
            return settleSingleFileRemnant(
                operationID,
                imported: batch.accepted.first,
                failure: .cancelled)
        }
        guard hooks.targetRemainsCurrentAfterWrite() else {
            return settleSingleFileRemnant(
                operationID,
                imported: batch.accepted.first,
                failure: .targetChanged)
        }
        guard let imported = batch.accepted.first else {
            hooks.finishWriteScopeWithoutChange()
            hooks.discardStagedRemnants()
            hooks.settleOperation(
                operationID,
                phase: .failed(.importRejected),
                importOutcome: nil)
            return .empty(SoundPackImportBindEmpty(importOutcome: nil))
        }
        switch hooks.bindImportedAudio(SoundPackImportBindInput(imported: imported)) {
        case .failed(let failure):
            return settleSingleFileRemnant(
                operationID,
                imported: imported,
                failure: failure)
        case .bound(let binding):
            switch hooks.finalizeBinding(SoundPackImportBindInput(imported: imported)) {
            case .finalized(let finalImported):
                hooks.finishWriteScope(changedDespiteFailure: false)
                hooks.settleOperation(operationID, phase: .succeeded, importOutcome: nil)
                let previewAction: SoundPackEditorAction? =
                    variant == .adoptCue
                    ? hooks.signForegroundPreview(for: finalImported) : nil
                return .succeeded(
                    SoundPackImportBindSuccess(
                        imported: finalImported,
                        binding: binding.manifest,
                        previewAction: previewAction,
                        importOutcome: nil))
            case .cancelled:
                hooks.discardStagedRemnants()
                return settleCancelledBeforeWrite(operationID)
            case .stale:
                hooks.discardStagedRemnants()
                hooks.settleOperation(
                    operationID,
                    phase: .failed(.targetChanged),
                    importOutcome: nil)
                return .failed(.targetChanged)
            case .failed(let failure):
                hooks.discardStagedRemnants()
                hooks.settleOperation(
                    operationID,
                    phase: .failed(failure),
                    importOutcome: nil)
                return .failed(failure)
            }
        }
    }

    /// One remnant policy per single-file variant: an installed pack keeps the unbound file as a
    /// reported orphan, while the draft's hidden stage is discarded so nothing claims to exist.
    private func settleSingleFileRemnant(
        _ operationID: SoundPackEditorOperationID,
        imported: ImportedAudioFile?,
        failure: SoundPackEditorFailure
    ) -> SoundPackImportBindOutcome {
        switch variant {
        case .adoptCue:
            if let imported {
                hooks.finishWriteScope(changedDespiteFailure: true)
                hooks.settleOperation(
                    operationID,
                    phase: .orphan(fileName: imported.fileName, failure: failure),
                    importOutcome: nil)
                return .orphan(
                    SoundPackImportBindOrphan(
                        imported: imported,
                        failure: failure,
                        importOutcome: nil))
            }
            hooks.finishWriteScopeWithoutChange()
            if failure == .cancelled {
                return settleCancelledBeforeWrite(operationID)
            }
            hooks.settleOperation(operationID, phase: .failed(failure), importOutcome: nil)
            return .failed(failure)
        case .adoptCueDraftPublish:
            hooks.discardStagedRemnants()
            if failure == .cancelled {
                return settleCancelledBeforeWrite(operationID)
            }
            hooks.settleOperation(operationID, phase: .failed(failure), importOutcome: nil)
            return .failed(failure)
        case .importAudio:
            preconditionFailure("batch imports never settle a single-file remnant")
        }
    }

    // MARK: Batch import pipeline

    private func completeBatchExecution(
        _ operationID: SoundPackEditorOperationID,
        batch: AudioImportBatchResult,
        bindsEvent: Bool,
        cancellationRequested: Bool
    ) -> SoundPackImportBindOutcome {
        guard !batch.accepted.isEmpty else {
            hooks.finishWriteScopeWithoutChange()
            let phase: SoundPackEditorActivityPhase
            if cancellationRequested {
                phase = .cancelled(changedOnDisk: false)
            } else {
                phase = batch.rejected.isEmpty ? .succeeded : .failed(.importRejected)
            }
            let completion: SoundPackEditorOperationCompletion =
                cancellationRequested
                ? .cancelled(changedOnDisk: false) : .failed(.importRejected)
            let outcome = SoundPackEditorImportOutcome(
                accepted: [],
                rejected: batch.rejected,
                boundEvent: nil,
                completedInBackground: false,
                orphan: nil,
                completion: completion,
                previewAction: nil)
            hooks.settleOperation(operationID, phase: phase, importOutcome: outcome)
            if cancellationRequested {
                return .cancelled(
                    SoundPackImportBindCancelled(
                        changedOnDisk: false,
                        importOutcome: outcome))
            }
            return .empty(SoundPackImportBindEmpty(importOutcome: outcome))
        }

        let imported = batch.accepted[batch.accepted.count - 1]
        if cancellationRequested {
            // A bind request leaves the last accepted file as the reported orphan; without one
            // every accepted file is a plain import the user asked to keep.
            return settleBatchTerminal(
                operationID,
                batch: batch,
                boundEvent: nil,
                orphan: bindsEvent ? imported : nil,
                failure: .cancelled,
                completedInBackground: false)
        }
        guard bindsEvent else {
            // Files landing unbound by design stay a success; only the foreground follow-up is
            // lost when the target stopped being current meanwhile.
            let remainsForeground = hooks.targetRemainsCurrentAfterWrite()
            return settleBatchTerminal(
                operationID,
                batch: batch,
                boundEvent: nil,
                orphan: nil,
                failure: nil,
                completedInBackground: !remainsForeground)
        }
        guard hooks.targetRemainsCurrentAfterWrite() else {
            return settleBatchTerminal(
                operationID,
                batch: batch,
                boundEvent: nil,
                orphan: imported,
                failure: .targetChanged,
                completedInBackground: true)
        }
        switch hooks.bindImportedAudio(SoundPackImportBindInput(imported: imported)) {
        case .bound(let binding):
            return settleBatchTerminal(
                operationID,
                batch: batch,
                boundEvent: binding.boundEvent,
                orphan: nil,
                failure: nil,
                completedInBackground: false)
        case .failed(let failure):
            return settleBatchTerminal(
                operationID,
                batch: batch,
                boundEvent: nil,
                orphan: imported,
                failure: failure,
                completedInBackground: failure == .targetChanged)
        }
    }

    private func settleBatchTerminal(
        _ operationID: SoundPackEditorOperationID,
        batch: AudioImportBatchResult,
        boundEvent: Event?,
        orphan: ImportedAudioFile?,
        failure: SoundPackEditorFailure?,
        completedInBackground: Bool
    ) -> SoundPackImportBindOutcome {
        hooks.finishWriteScope(changedDespiteFailure: failure != nil)
        let phase: SoundPackEditorActivityPhase
        let completion: SoundPackEditorOperationCompletion
        if let orphan, let failure {
            phase = .orphan(fileName: orphan.fileName, failure: failure)
            completion = .orphan(failure)
        } else if failure == .cancelled {
            phase = .cancelled(changedOnDisk: true)
            completion = .cancelled(changedOnDisk: true)
        } else if !batch.rejected.isEmpty {
            phase = .partial(accepted: batch.accepted.count, rejected: batch.rejected.count)
            completion = .partial(
                accepted: batch.accepted.count,
                rejected: batch.rejected.count)
        } else {
            phase = .succeeded
            completion = .succeeded
        }
        let previewAction: SoundPackEditorAction?
        if !completedInBackground, failure == nil, let last = batch.accepted.last {
            previewAction = hooks.signForegroundPreview(for: last)
        } else {
            previewAction = nil
        }
        let outcome = SoundPackEditorImportOutcome(
            accepted: batch.accepted,
            rejected: batch.rejected,
            boundEvent: boundEvent,
            completedInBackground: completedInBackground,
            orphan: orphan,
            completion: completion,
            previewAction: previewAction)
        hooks.settleOperation(operationID, phase: phase, importOutcome: outcome)
        if let orphan, let failure {
            return .orphan(
                SoundPackImportBindOrphan(
                    imported: orphan,
                    failure: failure,
                    importOutcome: outcome))
        }
        if failure == .cancelled {
            return .cancelled(
                SoundPackImportBindCancelled(changedOnDisk: true, importOutcome: outcome))
        }
        return .succeeded(
            SoundPackImportBindSuccess(
                imported: batch.accepted.last,
                binding: nil,
                previewAction: previewAction,
                importOutcome: outcome))
    }
}
