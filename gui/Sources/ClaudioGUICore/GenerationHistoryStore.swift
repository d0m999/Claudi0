import ClaudioCore
import Combine
import CryptoKit
import Foundation

package struct GenerationHistoryAudio: Identifiable, Sendable, Equatable {
    package let id: UUID
    package let name: String
    package let durationMilliseconds: Int
    package let failure: SoundAssetStorageError?
}

package struct GenerationHistoryBatch: Identifiable, Sendable, Equatable {
    package let id: UUID
    package let soundDescription: String
    package let generatedAt: Date?
    package let profileID: AICueProviderProfileID?
    package let audio: [GenerationHistoryAudio]
    package let failure: SoundAssetStorageError?
}

/// A fresh, byte-bound source for history adoption, independent of candidate/session permits.
package struct GenerationHistoryAudioProof: Sendable {
    package let batchID: UUID
    package let audioID: UUID
    package let name: AICueDisplayName
    package let data: Data
    package let format: AudioFormat
    package let durationMilliseconds: Int
    package let digest: String
}

package struct GenerationHistorySnapshot: Sendable, Equatable {
    package let revision: UInt64
    package let batches: [GenerationHistoryBatch]
}

/// Sole owner of durable generated-audio facts. Construction does no I/O. Directory and audio
/// reads, archive, rename and Trash run serially on the disk actor, off the main actor.
@MainActor
package final class GenerationHistoryStore: ObservableObject {
    @Published package private(set) var snapshot = GenerationHistorySnapshot(
        revision: 0, batches: [])
    @Published package private(set) var failure: SoundAssetStorageError?
    @Published package private(set) var isLoading = false
    private let disk: GenerationHistoryDisk
    private var loads = 0

    package init(
        directory: URL,
        trash: @escaping @Sendable (URL) throws -> Void = PrivateSoundAssetIO.systemTrash,
        beforePublish: @escaping @Sendable () throws -> Void = {},
        afterPublish: @escaping @Sendable () throws -> Void = {}
    ) {
        disk = GenerationHistoryDisk(
            directory: directory, trash: trash, beforePublish: beforePublish,
            afterPublish: afterPublish)
    }

    package func refresh() async {
        loads += 1
        isLoading = true
        defer { loads -= 1; isLoading = loads > 0 }
        do { accept(try await disk.snapshot()) } catch { failure = storageError(error) }
    }

    @discardableResult
    package func archive(
        _ generation: AICueGeneration, soundDescription: String,
        candidateIDs: Set<UUID>? = nil
    ) async throws -> GenerationHistoryBatch {
        do {
            let value = try await disk.archive(
                generation, soundDescription: soundDescription, candidateIDs: candidateIDs)
            accept(value)
            guard let batch = value.batches.first(where: { $0.id == generation.id }) else {
                throw SoundAssetStorageError.corrupt
            }
            return batch
        } catch { failure = storageError(error); throw storageError(error) }
    }

    package func rename(batchID: UUID, audioID: UUID, name: String) async throws {
        let validated = try AICueDisplayName(name)
        do {
            accept(try await disk.rename(batchID: batchID, audioID: audioID, name: validated.value))
        } catch { failure = storageError(error); throw storageError(error) }
    }

    package func trash(batchID: UUID, audioID: UUID? = nil, expectedCount: Int? = nil) async throws
    {
        do {
            accept(
                try await disk.trash(
                    batchID: batchID, audioID: audioID, expectedCount: expectedCount))
        } catch {
            failure = storageError(error)
            // A failed rollback may have moved an item to a recoverable isolation directory.
            // Read back rather than retaining a row that falsely claims the original still exists.
            if let current = try? await disk.snapshot() { accept(current, clearFailure: false) }
            throw storageError(error)
        }
    }

    package func audio(batchID: UUID, audioID: UUID) async throws -> GenerationHistoryAudioProof {
        try await disk.audio(batchID: batchID, audioID: audioID)
    }

    private func accept(_ value: GenerationHistorySnapshot, clearFailure: Bool = true) {
        guard value.revision >= snapshot.revision else { return }
        snapshot = value
        if clearFailure { failure = nil }
    }
}

private func storageError(_ error: Error) -> SoundAssetStorageError {
    (error as? SoundAssetStorageError) ?? .unavailable
}

private struct HistoryBatchMetadata: Codable, Equatable {
    let version: Int
    let id: UUID
    let soundDescription: String
    let generatedAt: Date
    let profileID: String
    let initialAudioIDs: [UUID]
}

private struct HistoryAudioMetadata: Codable {
    let version: Int
    let id: UUID
    var name: String
    let durationMilliseconds: Int
    let format: String
    let byteCount: Int
    let digest: String
}

private actor GenerationHistoryDisk {
    let root: URL
    let trashAdapter: @Sendable (URL) throws -> Void
    let beforePublish: @Sendable () throws -> Void
    let afterPublish: @Sendable () throws -> Void
    var revision: UInt64 = 0
    private let maxAudioBytes = 5 * 1024 * 1024

    init(
        directory: URL, trash: @escaping @Sendable (URL) throws -> Void,
        beforePublish: @escaping @Sendable () throws -> Void,
        afterPublish: @escaping @Sendable () throws -> Void
    ) {
        root = directory.standardizedFileURL
        trashAdapter = trash
        self.beforePublish = beforePublish
        self.afterPublish = afterPublish
    }

    func snapshot() throws -> GenerationHistorySnapshot {
        guard PrivateSoundAssetIO.exists(root) else {
            revision &+= 1
            return GenerationHistorySnapshot(revision: revision, batches: [])
        }
        let entries = try PrivateSoundAssetIO.entries(root)
        let batches = try entries.compactMap { entry -> GenerationHistoryBatch? in
            guard let id = UUID(uuidString: entry.lastPathComponent) else { return nil }
            return try readBatch(id)
        }.sorted {
            if $0.generatedAt == $1.generatedAt { return $0.id.uuidString < $1.id.uuidString }
            return ($0.generatedAt ?? .distantPast) > ($1.generatedAt ?? .distantPast)
        }
        revision &+= 1
        return GenerationHistorySnapshot(revision: revision, batches: batches)
    }

    func archive(
        _ generation: AICueGeneration, soundDescription: String, candidateIDs: Set<UUID>?
    ) throws -> GenerationHistorySnapshot {
        let candidates = generation.candidates.filter { candidateIDs?.contains($0.id) ?? true }
        guard !candidates.isEmpty, candidates.count <= 3,
            Set(candidates.map(\.id)).count == candidates.count,
            soundDescription.count <= AICueGenerationRequest.maximumDescriptionCharacters,
            candidates.allSatisfy({
                $0.durationMilliseconds > 0 && $0.durationMilliseconds <= 3_000
                    && $0.provenance.generationID == generation.id
                    && $0.provenance.profileID == generation.profileID
            })
        else { throw SoundAssetStorageError.corrupt }
        try ensurePrivateDirectoryExists(at: root)
        return try PrivateSoundAssetIO.withLock(at: root.appendingPathComponent(".store.lock")) {
            let metadata = HistoryBatchMetadata(
                version: 1, id: generation.id, soundDescription: soundDescription,
                generatedAt: generation.generatedAt, profileID: generation.profileID.rawValue,
                initialAudioIDs: candidates.map(\.id))
            let destination = batchURL(generation.id)
            if PrivateSoundAssetIO.exists(destination) {
                let saved: HistoryBatchMetadata = try decode(
                    destination.appendingPathComponent("batch.json"))
                guard saved == metadata else { throw SoundAssetStorageError.changed }
                // A successful but uncertain publish is read back, never duplicated or overwritten.
                for candidate in candidates {
                    _ = try audio(batchID: generation.id, audioID: candidate.id)
                }
                return try snapshot()
            }
            let staging = root.appendingPathComponent(".archive-" + UUID().uuidString.lowercased())
            try ensurePrivateDirectoryExists(at: staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            try encode(metadata, at: staging.appendingPathComponent("batch.json"))
            for (offset, candidate) in candidates.enumerated() {
                let data = try PrivateSoundAssetIO.read(
                    candidate.asset.fileURL, maximum: maxAudioBytes)
                guard data.count == candidate.asset.byteCount,
                    sniffAudioFormat(data) == candidate.asset.sniffedFormat
                else { throw SoundAssetStorageError.changed }
                let item = staging.appendingPathComponent(key(candidate.id))
                try ensurePrivateDirectoryExists(at: item)
                let suffix = candidates.count > 1 ? " \(offset + 1)" : ""
                let name =
                    String(generation.plan.suggestedDisplayName.prefix(40 - suffix.count)) + suffix
                let audioMetadata = HistoryAudioMetadata(
                    version: 1, id: candidate.id, name: try AICueDisplayName(name).value,
                    durationMilliseconds: candidate.durationMilliseconds,
                    format: candidate.asset.sniffedFormat.rawValue, byteCount: data.count,
                    digest: digest(data))
                try PrivateSoundAssetIO.write(
                    data, to: item.appendingPathComponent("audio." + audioMetadata.format))
                try encode(audioMetadata, at: item.appendingPathComponent("audio.json"))
            }
            try beforePublish()
            try PrivateSoundAssetIO.moveExclusively(staging, to: destination)
            try afterPublish()
            return try snapshot()
        }
    }

    func rename(batchID: UUID, audioID: UUID, name: String) throws -> GenerationHistorySnapshot {
        try PrivateSoundAssetIO.withLock(at: root.appendingPathComponent(".store.lock")) {
            _ = try audio(batchID: batchID, audioID: audioID)
            let url = itemURL(batchID, audioID).appendingPathComponent("audio.json")
            var metadata: HistoryAudioMetadata = try decode(url)
            metadata.name = name
            try encode(metadata, at: url)
            return try snapshot()
        }
    }

    func trash(batchID: UUID, audioID: UUID?, expectedCount: Int?) throws
        -> GenerationHistorySnapshot
    {
        try PrivateSoundAssetIO.withLock(at: root.appendingPathComponent(".store.lock")) {
            let directory = batchURL(batchID)
            let items = try PrivateSoundAssetIO.entries(directory).filter {
                UUID(uuidString: $0.lastPathComponent) != nil
            }
            if let expectedCount, expectedCount != items.count {
                throw SoundAssetStorageError.changed
            }
            if let audioID {
                guard items.contains(where: { $0.lastPathComponent == key(audioID) }) else {
                    throw SoundAssetStorageError.changed
                }
                // Last audio is one group-directory Trash operation, with no extra confirmation.
                let source = items.count == 1 ? directory : itemURL(batchID, audioID)
                try PrivateSoundAssetIO.trash(source, using: trashAdapter)
            } else {
                try PrivateSoundAssetIO.trash(directory, using: trashAdapter)
            }
            return try snapshot()
        }
    }

    func audio(batchID: UUID, audioID: UUID) throws -> GenerationHistoryAudioProof {
        let batch: HistoryBatchMetadata = try decode(
            batchURL(batchID).appendingPathComponent("batch.json"))
        guard batch.version == 1, batch.id == batchID, batch.initialAudioIDs.contains(audioID)
        else {
            throw SoundAssetStorageError.corrupt
        }
        let metadata = try itemMetadata(batchID, audioID)
        guard let format = AudioFormat(rawValue: metadata.format) else {
            throw SoundAssetStorageError.corrupt
        }
        let data = try PrivateSoundAssetIO.read(
            itemURL(batchID, audioID).appendingPathComponent("audio." + format.rawValue),
            maximum: maxAudioBytes)
        guard data.count == metadata.byteCount, digest(data) == metadata.digest,
            sniffAudioFormat(data) == format
        else { throw SoundAssetStorageError.changed }
        return GenerationHistoryAudioProof(
            batchID: batchID, audioID: audioID, name: try AICueDisplayName(metadata.name),
            data: data, format: format, durationMilliseconds: metadata.durationMilliseconds,
            digest: metadata.digest)
    }

    private func readBatch(_ id: UUID) throws -> GenerationHistoryBatch {
        do {
            let directory = batchURL(id)
            let metadata: HistoryBatchMetadata = try decode(
                directory.appendingPathComponent("batch.json"))
            guard metadata.version == 1, metadata.id == id,
                metadata.soundDescription.count
                    <= AICueGenerationRequest.maximumDescriptionCharacters,
                !metadata.initialAudioIDs.isEmpty, metadata.initialAudioIDs.count <= 3
            else { throw SoundAssetStorageError.corrupt }
            let audio = try PrivateSoundAssetIO.entries(directory).compactMap {
                entry -> GenerationHistoryAudio? in
                guard let audioID = UUID(uuidString: entry.lastPathComponent) else { return nil }
                do {
                    guard metadata.initialAudioIDs.contains(audioID) else {
                        throw SoundAssetStorageError.corrupt
                    }
                    let item = try itemMetadata(id, audioID)
                    // Metadata-only projection; audio bytes are read and revalidated only on demand.
                    let file = entry.appendingPathComponent("audio." + item.format)
                    let values = try file.resourceValues(forKeys: [
                        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                    ])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                        values.fileSize == item.byteCount
                    else { throw SoundAssetStorageError.corrupt }
                    return GenerationHistoryAudio(
                        id: audioID, name: item.name,
                        durationMilliseconds: item.durationMilliseconds, failure: nil)
                } catch {
                    return GenerationHistoryAudio(
                        id: audioID, name: "", durationMilliseconds: 0, failure: storageError(error)
                    )
                }
            }
            guard !audio.isEmpty else { throw SoundAssetStorageError.corrupt }
            return GenerationHistoryBatch(
                id: id, soundDescription: metadata.soundDescription,
                generatedAt: metadata.generatedAt,
                profileID: AICueProviderProfileID(rawValue: metadata.profileID), audio: audio,
                failure: nil)
        } catch {
            let unavailableAudio =
                (try? PrivateSoundAssetIO.entries(batchURL(id)))?.compactMap {
                    entry -> GenerationHistoryAudio? in
                    guard let audioID = UUID(uuidString: entry.lastPathComponent) else {
                        return nil
                    }
                    return GenerationHistoryAudio(
                        id: audioID, name: "", durationMilliseconds: 0, failure: .corrupt)
                } ?? []
            return GenerationHistoryBatch(
                id: id, soundDescription: "", generatedAt: nil, profileID: nil,
                audio: unavailableAudio, failure: storageError(error))
        }
    }

    private func itemMetadata(_ batch: UUID, _ audio: UUID) throws -> HistoryAudioMetadata {
        let metadata: HistoryAudioMetadata = try decode(
            itemURL(batch, audio).appendingPathComponent("audio.json"))
        guard metadata.version == 1, metadata.id == audio,
            metadata.durationMilliseconds > 0, metadata.durationMilliseconds <= 3_000,
            metadata.byteCount > 0, metadata.byteCount <= maxAudioBytes,
            AudioFormat(rawValue: metadata.format) != nil, metadata.digest.count == 64,
            (try? AICueDisplayName(metadata.name)) != nil
        else { throw SoundAssetStorageError.corrupt }
        return metadata
    }

    private func decode<T: Decodable>(_ url: URL) throws -> T {
        try JSONDecoder().decode(T.self, from: PrivateSoundAssetIO.read(url, maximum: 64 * 1024))
    }

    private func encode(_ value: some Encodable, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try PrivateSoundAssetIO.write(encoder.encode(value), to: url)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func key(_ id: UUID) -> String { id.uuidString.lowercased() }
    private func batchURL(_ id: UUID) -> URL { root.appendingPathComponent(key(id)) }
    private func itemURL(_ batch: UUID, _ audio: UUID) -> URL {
        batchURL(batch).appendingPathComponent(key(audio))
    }
}
