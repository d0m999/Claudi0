import Combine
import Foundation

package enum AICueGenerationTaskState: Sendable, Equatable {
    case idle
    case generating(UUID)
    case saving(UUID)
    case pending(UUID, SoundAssetStorageError)
    case saved(UUID)
    case failed(AICueGenerationError)
}

package enum AICueGenerationBlock: Sendable, Equatable {
    case generating
    case saving
    case pendingResults
    case adopting
}

package enum AICueTerminationReason: Sendable, Equatable {
    case generating
    case unsavedAudio
}

/// One app-lifetime owner, distinct from the visible composer's lifetime. No task is queued.
/// Request inputs and the absolute deadline are captured before the first suspension point.
@MainActor
package final class AICueGenerationCoordinator: ObservableObject {
    @Published package private(set) var state: AICueGenerationTaskState = .idle
    @Published package private(set) var generation: AICueGeneration?
    @Published package private(set) var hasUnreadCompletion = false
    package private(set) var soundDescription = ""
    package private(set) var requestProfileID: AICueProviderProfileID?
    package let history: GenerationHistoryStore
    private let generator: any AICueGenerating
    private let registry: AICueProviderRegistry
    private let trash: @Sendable (URL) throws -> Void
    private var task: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var composerAttached = false
    @Published private var adoptionLeases: Set<UUID> = []

    package init(
        generator: any AICueGenerating, history: GenerationHistoryStore,
        registry: AICueProviderRegistry = AICueProviderRegistry(),
        trash: @escaping @Sendable (URL) throws -> Void = PrivateSoundAssetIO.systemTrash
    ) {
        self.generator = generator
        self.history = history
        self.registry = registry
        self.trash = trash
    }

    package var generationBlock: AICueGenerationBlock? {
        if !adoptionLeases.isEmpty { return .adopting }
        return switch state {
        case .generating: .generating
        case .saving: .saving
        case .pending: .pendingResults
        default: nil
        }
    }

    package var terminationReason: AICueTerminationReason? {
        switch state {
        case .generating: .generating
        case .saving, .pending: .unsavedAudio
        default: nil
        }
    }

    @discardableResult
    package func start(description: String, locale: String, profileID: AICueProviderProfileID)
        -> Bool
    {
        guard generationBlock == nil, adoptionLeases.isEmpty else { return false }
        releaseSavedCandidates()
        epoch &+= 1
        let capturedEpoch = epoch
        let taskID = UUID()
        let deadline = AICueGenerationDeadline.startingNow(
            description: description, locale: locale, profileID: profileID, registry: registry)
        soundDescription = description
        requestProfileID = profileID
        composerAttached = true
        generation = nil
        state = .generating(taskID)
        let generator = self.generator
        task = Task { [weak self] in
            let result: Result<AICueGeneration, AICueGenerationError>
            do {
                result = .success(
                    try await generator.generate(
                        description: description, locale: locale,
                        providerProfileID: profileID, deadline: deadline))
            } catch let error as AICueGenerationError {
                result = .failure(error)
            } catch is CancellationError {
                result = .failure(.cancelled)
            } catch {
                result = .failure(.provider(.transportFailure))
            }
            guard let self, self.epoch == capturedEpoch, !Task.isCancelled else {
                if case .success(let value) = result {
                    await generator.discard(generationID: value.id)
                }
                return
            }
            switch result {
            case .success(let value):
                self.generation = value
                await self.save(capturedEpoch: capturedEpoch)
            case .failure(let error):
                self.state = .failed(error)
                self.task = nil
            }
        }
        return true
    }

    package func cancel() {
        guard case .generating = state else { return }
        epoch &+= 1
        task?.cancel()
        task = nil
        composerAttached = false
        state = .idle
    }

    package func detachComposer() {
        composerAttached = false
        releaseSavedCandidates()
    }

    /// A committed adoption may still be reading its validated temporary asset when the sheet
    /// closes. Keep that asset alive until the transaction returns, without retaining UI authority.
    package func beginAdoption(generationID: UUID) -> UUID? {
        guard state == .saved(generationID), generation?.id == generationID else { return nil }
        let lease = UUID()
        adoptionLeases.insert(lease)
        return lease
    }

    package func finishAdoption(_ lease: UUID, adopted: Bool) async {
        guard adoptionLeases.remove(lease) != nil else { return }
        if adopted { composerAttached = false }
        guard !composerAttached, adoptionLeases.isEmpty, case .saved = state,
            let generation
        else { return }
        self.generation = nil
        await generator.discard(generationID: generation.id)
    }

    package func markHistoryRead() { hasUnreadCompletion = false }

    #if DEBUG
    /// Render-only gallery projection. No task, archive, network request or adoption lease exists.
    package func applyGalleryState(_ preview: AICueGenerationPreviewState) {
        generation = preview.generation
        requestProfileID = preview.providerProfileID
        switch preview.phase {
        case .generating: state = .generating(UUID())
        case .candidatesReady, .adopting:
            if let generation = preview.generation { state = .saved(generation.id) }
        default: state = .idle
        }
    }
    #endif

    package func retrySave() {
        guard case .pending = state, task == nil else { return }
        let capturedEpoch = epoch
        state = .saving(generation!.id)
        task = Task { [weak self] in await self?.save(capturedEpoch: capturedEpoch) }
    }

    /// The caller confirms the displayed count. Each successful Trash operation removes exactly
    /// that item; failures retain the remaining assets and the application-wide generation gate.
    package func abandonPending(expectedCount: Int) async {
        guard case .pending = state, task == nil, let original = generation,
            original.candidates.count == expectedCount
        else { return }
        state = .saving(original.id)
        composerAttached = false
        var remaining = original.candidates
        var failure: SoundAssetStorageError?
        let adapter = trash
        for candidate in original.candidates {
            do {
                try await Task.detached(priority: .utility) {
                    try PrivateSoundAssetIO.trash(candidate.asset.fileURL, using: adapter)
                }.value
                remaining.removeAll { $0.id == candidate.id }
            } catch {
                failure = (error as? SoundAssetStorageError) ?? .trashFailed
                if case .recoveryRequired(let recovered) = failure,
                    let index = remaining.firstIndex(where: { $0.id == candidate.id })
                {
                    remaining[index] = AICueCandidate(
                        id: candidate.id, identity: candidate.identity,
                        asset: AICueTemporaryAudioAsset(
                            fileURL: recovered,
                            byteCount: candidate.asset.byteCount,
                            sniffedFormat: candidate.asset.sniffedFormat),
                        durationMilliseconds: candidate.durationMilliseconds,
                        mediaType: candidate.mediaType, provenance: candidate.provenance)
                }
            }
        }
        if remaining.isEmpty {
            generation = nil
            await generator.discard(generationID: original.id)
            state = .idle
        } else {
            generation = AICueGeneration(
                id: original.id, profileID: original.profileID, plan: original.plan,
                candidates: remaining, completion: .partial, generatedAt: original.generatedAt)
            state = .pending(original.id, failure ?? .trashFailed)
        }
    }

    /// Called only once native termination has actually been approved. Cancels local waiting;
    /// it makes no claim about remote cancellation or charges.
    package func terminate() {
        epoch &+= 1
        task?.cancel()
        task = nil
        composerAttached = false
    }

    private func save(capturedEpoch: UInt64) async {
        guard let generation, epoch == capturedEpoch else { return }
        state = .saving(generation.id)
        do {
            _ = try await history.archive(generation, soundDescription: soundDescription)
            guard epoch == capturedEpoch else { return }
            task = nil
            hasUnreadCompletion = true
            state = .saved(generation.id)
            if !composerAttached { releaseSavedCandidates() }
        } catch {
            guard epoch == capturedEpoch else { return }
            task = nil
            state = .pending(generation.id, (error as? SoundAssetStorageError) ?? .unavailable)
        }
    }

    private func releaseSavedCandidates() {
        guard adoptionLeases.isEmpty, case .saved = state, let generation else { return }
        self.generation = nil
        let generator = self.generator
        Task { await generator.discard(generationID: generation.id) }
    }
}
