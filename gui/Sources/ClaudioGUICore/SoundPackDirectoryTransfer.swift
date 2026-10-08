import ClaudioCore
import Darwin
import Foundation

/// An import preview is a verified private snapshot, not permission to reread a user's directory
/// later. Both ordinary folders and .claudiopack directory packages use the existing manifest.
package struct PreparedSoundPack: Sendable {
    package let packID: String
    package let name: String
    package let eventCount: Int
    package let fileCount: Int
    fileprivate let stage: URL
    fileprivate let payload: URL
    fileprivate let requiresUniqueName: Bool

    package func discard() async {
        let stage = stage
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: stage) }
            .value
    }
}

package enum SoundPackDirectoryTransfer {
    package static func prepare(
        source: URL, environment: AudioImportEnvironment, copyName: AICuePackName? = nil
    ) async throws -> PreparedSoundPack {
        try await Task.detached(priority: .userInitiated) {
            try ensurePrivateDirectoryExists(at: environment.userPacksDirectory)
            let stage = environment.userPacksDirectory.appendingPathComponent(
                ".pack-transfer-" + UUID().uuidString)
            let payload = stage.appendingPathComponent("payload")
            try ensurePrivateDirectoryExists(at: payload)
            do {
                var totalBytes = 0
                var files = 0
                if copyName != nil {
                    // A package copy must describe one source revision, not a mixture of files
                    // from two cooperating edits. Import previews are external immutable snapshots.
                    try PrivateSoundAssetIO.withLock(at: environment.packsLockFile) {
                        try clone(
                            source, to: payload, depth: 0, totalBytes: &totalBytes, files: &files)
                    }
                } else {
                    try clone(source, to: payload, depth: 0, totalBytes: &totalBytes, files: &files)
                }
                let manifestURL = payload.appendingPathComponent("manifest.json")
                let originalData = try PrivateSoundAssetIO.read(manifestURL, maximum: 1_048_576)
                var json =
                    try JSONSerialization.jsonObject(with: originalData) as? [String: Any] ?? [:]
                if let copyName {
                    json["id"] = "copy-" + UUID().uuidString.lowercased()
                    json["name"] = copyName.value
                    json.removeValue(forKey: "license")
                    json.removeValue(forKey: "author")
                    try PrivateSoundAssetIO.write(
                        JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
                        to: manifestURL)
                }
                let manifest = try validate(payload, environment: environment)
                let name = (json["name"] as? String) ?? manifest.id
                return PreparedSoundPack(
                    packID: manifest.id, name: name,
                    eventCount: manifest.eventSources.count, fileCount: files - 1,
                    stage: stage, payload: payload, requiresUniqueName: copyName != nil)
            } catch {
                try? FileManager.default.removeItem(at: stage)
                throw error
            }
        }.value
    }

    package static func publish(
        _ prepared: PreparedSoundPack, environment: AudioImportEnvironment, draftsDirectory: URL
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try PrivateSoundAssetIO.withLock(at: environment.packsLockFile) {
                let manifest = try validate(prepared.payload, environment: environment)
                guard manifest.id == prepared.packID else { throw SoundAssetStorageError.changed }
                guard !environment.builtinPackIDs.contains(manifest.id),
                    !(try SoundPackNames.reservedDraftIDs(draftsDirectory)).contains(manifest.id)
                else { throw SoundAssetStorageError.changed }
                if prepared.requiresUniqueName {
                    try SoundPackNames.validate(
                        AICuePackName(prepared.name), environment: environment,
                        draftsDirectory: draftsDirectory)
                }
                let destination = environment.userPacksDirectory.appendingPathComponent(manifest.id)
                try PrivateSoundAssetIO.moveExclusively(prepared.payload, to: destination)
            }
        }.value
    }

    package static func rename(
        packID: String, name: AICuePackName, environment: AudioImportEnvironment,
        draftsDirectory: URL
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard isSafePackID(packID), !environment.builtinPackIDs.contains(packID) else {
                throw SoundAssetStorageError.unsafeEntry
            }
            try PrivateSoundAssetIO.withLock(at: environment.packsLockFile) {
                let file = environment.userPacksDirectory.appendingPathComponent(packID)
                    .appendingPathComponent("manifest.json")
                let data = try PrivateSoundAssetIO.read(file, maximum: 1_048_576)
                guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    json["id"] as? String == packID
                else { throw SoundAssetStorageError.corrupt }
                if (json["name"] as? String ?? packID) == name.value { return }
                try SoundPackNames.validate(
                    name, excluding: packID, environment: environment,
                    draftsDirectory: draftsDirectory)
                json["name"] = name.value
                try PrivateSoundAssetIO.write(
                    JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), to: file)
            }
        }.value
    }

    private static func clone(
        _ source: URL, to destination: URL, depth: Int, totalBytes: inout Int, files: inout Int
    ) throws {
        guard depth < 16 else { throw SoundAssetStorageError.unsafeEntry }
        for entry in try PrivateSoundAssetIO.entries(source) {
            var info = stat()
            guard lstat(entry.path, &info) == 0 else { throw SoundAssetStorageError.unavailable }
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                try ensurePrivateDirectoryExists(at: target)
                try clone(
                    entry, to: target, depth: depth + 1, totalBytes: &totalBytes, files: &files)
            case S_IFREG:
                let data = try PrivateSoundAssetIO.read(entry, maximum: 16 * 1024 * 1024)
                totalBytes += data.count
                files += 1
                guard totalBytes <= 256 * 1024 * 1024, files <= 10_000 else {
                    throw SoundAssetStorageError.corrupt
                }
                try PrivateSoundAssetIO.write(data, to: target)
            default: throw SoundAssetStorageError.unsafeEntry
            }
        }
    }

    private static func validate(_ directory: URL, environment: AudioImportEnvironment) throws
        -> PackManifest
    {
        let data = try PrivateSoundAssetIO.read(
            directory.appendingPathComponent("manifest.json"), maximum: 1_048_576)
        let manifest = try JSONDecoder().decode(PackManifest.self, from: data)
        guard isSafePackID(manifest.id), !manifest.id.hasPrefix(".") else {
            throw SoundAssetStorageError.unsafeEntry
        }
        for source in manifest.eventSources.values {
            guard let name = source.fileName else { continue }
            guard let url = safePackFileURL(name, in: directory) else {
                throw SoundAssetStorageError.unsafeEntry
            }
            let bytes = try PrivateSoundAssetIO.read(
                url, maximum: environment.limits.maxFileSizeBytes)
            guard sniffAudioFormat(bytes) != nil,
                let duration = environment.durationProbe.probeDuration(of: url), duration.isFinite,
                duration > 0, duration <= environment.limits.maxDurationSeconds
            else { throw SoundAssetStorageError.corrupt }
        }
        try validateAudioFiles(directory, environment: environment)
        return manifest
    }

    private static func validateAudioFiles(_ directory: URL, environment: AudioImportEnvironment)
        throws
    {
        for file in try PrivateSoundAssetIO.entries(directory) {
            var info = stat()
            guard lstat(file.path, &info) == 0 else { throw SoundAssetStorageError.unavailable }
            if info.st_mode & S_IFMT == S_IFDIR {
                try validateAudioFiles(file, environment: environment)
            } else {
                guard info.st_mode & S_IFMT == S_IFREG else {
                    throw SoundAssetStorageError.unsafeEntry
                }
                guard AudioFormat(rawValue: file.pathExtension.lowercased()) != nil else {
                    continue
                }
                let bytes = try PrivateSoundAssetIO.read(
                    file, maximum: environment.limits.maxFileSizeBytes)
                guard sniffAudioFormat(bytes) != nil,
                    let duration = environment.durationProbe.probeDuration(of: file),
                    duration.isFinite,
                    duration > 0, duration <= environment.limits.maxDurationSeconds
                else { throw SoundAssetStorageError.corrupt }
            }
        }
    }
}
