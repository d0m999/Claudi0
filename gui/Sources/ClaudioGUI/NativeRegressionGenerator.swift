#if DEBUG && CLAUDIO_UI_REGRESSION
import ClaudioCore
import ClaudioGUICore
import Foundation

actor NativeRegressionCredentials: AICueCredentialManaging {
    func status(for profileID: AICueProviderProfileID) -> AICueCredentialStatus {
        .stored(verification: .verified, hasPendingReplacement: false)
    }
    func save(_ credential: SensitiveCredentialInput, for profileID: AICueProviderProfileID) throws
        -> AICueCredentialStatus
    {
        throw AICueCredentialManagerError.probeUnavailable
    }
    func delete(for profileID: AICueProviderProfileID) throws {
        throw AICueCredentialManagerError.probeUnavailable
    }
    func cancelPendingReplacement(for profileID: AICueProviderProfileID) {}
}

/// External generation is replaced, while description planning, view-model transitions,
/// candidate identity, real local adoption and publication still use their production seams.
final class NativeRegressionGenerationFacts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func started() { lock.lock(); count += 1; lock.unlock() }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
}

actor NativeRegressionGenerator: AICueGenerating {
    enum Outcome { case complete, partial, failure }
    private let root: URL
    private let facts: NativeRegressionGenerationFacts
    private var outcome: Outcome = .complete
    private var gate: (UUID, CheckedContinuation<Void, any Error>)?
    private var generations: [UUID: URL] = [:]
    init(root: URL, facts: NativeRegressionGenerationFacts) { self.root = root; self.facts = facts }
    func setOutcome(_ value: Outcome) { outcome = value }
    func finish() { gate?.1.resume(); gate = nil }
    private func cancel(_ id: UUID) {
        guard gate?.0 == id else { return }
        gate?.1.resume(throwing: CancellationError()); gate = nil
    }
    func generate(
        description: String, locale: String, providerProfileID: AICueProviderProfileID,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueGeneration {
        facts.started()
        let request = try AICueGenerationRequest(
            description: description, locale: locale, providerProfileID: providerProfileID)
        let plan = try AICueSoundPlanner().makePlan(for: request)
        let profile = try AICueProviderRegistry().profile(for: providerProfileID)
        guard let route = profile.routes[plan.modality] else {
            throw AICueGenerationError.providerUnavailable
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in gate = (id, continuation)
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancel(id) }
        }
        if outcome == .failure { throw AICueGenerationError.provider(.serviceUnavailable) }
        let policy = route.candidateSetPolicy
        let count =
            outcome == .partial && policy.minimumAcceptedCount < policy.requestedCount
            ? 2 : policy.requestedCount
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var candidates: [AICueCandidate] = []
        for ordinal in 1...count {
            let identity: AICueCandidateIdentity =
                policy.semantics == .styled
                ? .styled(AICueVariant.allCases[ordinal - 1])
                : .numbered(AICueCandidateOrdinal(rawValue: ordinal)!)
            let data = Self.wav(ordinal: ordinal)
            let file = directory.appendingPathComponent("candidate-\(ordinal).wav")
            try data.write(to: file, options: .atomic)
            candidates.append(
                AICueCandidate(
                    id: UUID(), identity: identity,
                    asset: AICueTemporaryAudioAsset(
                        fileURL: file, byteCount: data.count, sniffedFormat: .wav),
                    durationMilliseconds: 200, mediaType: "audio/wav",
                    provenance: AICueCandidateProvenance(
                        providerID: profile.providerID, profileID: profile.id,
                        modelID: route.modelID, generationID: id, requestOrdinal: ordinal,
                        providerRequestID: nil)))
        }
        generations[id] = directory
        return AICueGeneration(
            id: id, profileID: profile.id, plan: plan, candidates: candidates,
            completion: count == policy.requestedCount ? .complete : .partial, generatedAt: Date())
    }
    func discard(generationID: UUID) {
        if let directory = generations.removeValue(forKey: generationID) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
    func discardAll() {
        for directory in generations.values { try? FileManager.default.removeItem(at: directory) }
        generations.removeAll()
    }
    nonisolated static func wav(ordinal: Int, sampleCount: Int = 4_800) -> Data {
        var data = Data("RIFF".utf8)
        func append(_ value: UInt32, bytes: Int) {
            for index in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        append(UInt32(36 + sampleCount * 2), bytes: 4)
        data.append(Data("WAVEfmt ".utf8)); append(16, bytes: 4)
        append(1, bytes: 2); append(1, bytes: 2); append(24_000, bytes: 4)
        append(48_000, bytes: 4); append(2, bytes: 2); append(16, bytes: 2)
        data.append(Data("data".utf8)); append(UInt32(sampleCount * 2), bytes: 4)
        for index in 0..<sampleCount {
            append(
                UInt32(
                    UInt16(bitPattern: Int16(sin(Double(index) * Double(ordinal + 1) / 24) * 1_000))
                ), bytes: 2)
        }
        return data
    }
}
#endif
