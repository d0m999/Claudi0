import ClaudioCore
import Foundation

/// Browsing identity plus the complete original source. It is issued by the pack editor and
/// consumed once on explicit Use. It is never persisted in navigation or generation history.
package struct SoundEventSelectionContext: Identifiable, Sendable, Equatable {
    package let id: UUID
    package let packID: String
    package let event: Event
    package let expectedSource: ManifestEventBindingExpectation
    package let draft: AICuePackDraft?
}

/// Local-file preview owns verified bytes in a private staging directory; later Use never rereads
/// the external selected file. Construction, duration probing and cleanup happen off MainActor.
package struct SoundLocalAudioPreview: Sendable, Equatable {
    package let id: UUID
    package let fileURL: URL
    package let name: AICueDisplayName
    package let format: AudioFormat
    package let durationMilliseconds: Int
    package let bytes: Data
    private let directory: URL

    package static func prepare(
        source: URL, environment: AudioImportEnvironment
    ) async throws -> SoundLocalAudioPreview {
        try await Task.detached(priority: .userInitiated) {
            let bytes = try PrivateSoundAssetIO.read(
                source, maximum: environment.limits.maxFileSizeBytes)
            guard let format = sniffAudioFormat(bytes) else { throw SoundAssetStorageError.corrupt }
            let name = try AICueDisplayName(
                String(source.deletingPathExtension().lastPathComponent.prefix(40)))
            let preview = try materialize(
                bytes: bytes, format: format, name: name, durationMilliseconds: 0)
            guard let duration = environment.durationProbe.probeDuration(of: preview.fileURL),
                duration.isFinite, duration > 0, duration <= environment.limits.maxDurationSeconds
            else {
                try? FileManager.default.removeItem(at: preview.directory)
                throw SoundAssetStorageError.corrupt
            }
            return SoundLocalAudioPreview(
                id: preview.id, fileURL: preview.fileURL, name: name,
                format: format, durationMilliseconds: Int((duration * 1_000).rounded()),
                bytes: bytes, directory: preview.directory)
        }.value
    }

    package static func prepare(history proof: GenerationHistoryAudioProof) async throws
        -> SoundLocalAudioPreview
    {
        try await Task.detached(priority: .userInitiated) {
            try materialize(
                bytes: proof.data, format: proof.format, name: proof.name,
                durationMilliseconds: proof.durationMilliseconds)
        }.value
    }

    private static func materialize(
        bytes: Data, format: AudioFormat, name: AICueDisplayName, durationMilliseconds: Int
    ) throws -> SoundLocalAudioPreview {
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claudio-preview-" + id.uuidString)
        try ensurePrivateDirectoryExists(at: directory)
        let file = directory.appendingPathComponent("audio." + format.rawValue)
        do { try PrivateSoundAssetIO.write(bytes, to: file) } catch {
            try? FileManager.default.removeItem(at: directory); throw error
        }
        return SoundLocalAudioPreview(
            id: id, fileURL: file, name: name, format: format,
            durationMilliseconds: durationMilliseconds, bytes: bytes, directory: directory)
    }

    package func discard() async {
        let directory = directory
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }.value
    }
}
