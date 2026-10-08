import ClaudioCore
import Combine
import Darwin
import Foundation

package struct SoundPackDraftSnapshot: Sendable, Equatable {
    package let revision: UInt64
    package let drafts: [AICuePackDraft]
}

/// Only unpublished identities are owned here. Installed pack facts remain in SoundPackLibrary;
/// authoritative manifest reads below are confined to name validation at the shared write lock.
@MainActor
package final class SoundPackDraftStore: ObservableObject {
    @Published package private(set) var snapshot = SoundPackDraftSnapshot(revision: 0, drafts: [])
    @Published package private(set) var failure: SoundAssetStorageError?
    package let directory: URL
    private let disk: SoundPackDraftDisk

    package init(directory: URL, environment: AudioImportEnvironment) {
        self.directory = directory
        disk = SoundPackDraftDisk(root: directory, environment: environment)
    }

    package func refresh() async {
        do { accept(try await disk.refresh()) } catch {
            failure = (error as? SoundAssetStorageError) ?? .unavailable
        }
    }

    package func create(name: AICuePackName) async throws -> AICuePackDraft {
        do {
            let (draft, snapshot) = try await disk.create(name: name)
            accept(snapshot)
            return draft
        } catch { failure = (error as? SoundAssetStorageError) ?? .unavailable; throw error }
    }

    package func rename(packID: String, name: AICuePackName) async throws -> AICuePackDraft {
        do {
            let (draft, snapshot) = try await disk.rename(packID: packID, name: name)
            accept(snapshot)
            return draft
        } catch { failure = (error as? SoundAssetStorageError) ?? .unavailable; throw error }
    }

    package func delete(packID: String) async throws {
        do { accept(try await disk.delete(packID: packID)) } catch {
            failure = (error as? SoundAssetStorageError) ?? .unavailable; throw error
        }
    }

    private func accept(_ next: SoundPackDraftSnapshot) {
        guard next.revision >= snapshot.revision else { return }
        snapshot = next
        failure = nil
    }
}

private struct DraftMetadata: Codable {
    let version: Int
    let packID: String
    let name: String
}

package enum SoundPackNames {
    package static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Call only while holding packs.lock, also used by draft creation and rename. No installed
    /// package cache is created; the write must reject a competing name newer than the UI snapshot.
    package static func validate(
        _ name: AICuePackName, excluding packID: String? = nil,
        environment: AudioImportEnvironment, draftsDirectory: URL
    ) throws {
        var roots = [environment.userPacksDirectory]
        if let factory = environment.factoryPacksDirectory { roots.append(factory) }
        if let bundled = environment.bundledPacksDirectory { roots.append(bundled) }
        for root in roots where PrivateSoundAssetIO.exists(root) {
            for entry in try PrivateSoundAssetIO.entries(root)
            where !entry.lastPathComponent.hasPrefix(".") && entry.lastPathComponent != packID {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else { continue }
                let data = try PrivateSoundAssetIO.read(
                    entry.appendingPathComponent("manifest.json"), maximum: 1_048_576)
                let manifest = try JSONDecoder().decode(PackManifest.self, from: data)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if key((json?["name"] as? String) ?? manifest.id) == key(name.value) {
                    throw SoundAssetStorageError.nameConflict
                }
            }
        }
        for draft in try readDraftRegistrations(draftsDirectory) where draft.packID != packID {
            if case .success(let installed) = loadPackManifest(
                in: environment.userPacksDirectory.appendingPathComponent(draft.packID)),
                installed.id == draft.packID
            {
                continue
            }
            if key(draft.name.value) == key(name.value) {
                throw SoundAssetStorageError.nameConflict
            }
        }
    }

    package static func registeredDraft(_ packID: String, directory: URL) throws -> AICuePackDraft?
    {
        try readDraftRegistrations(directory).first { $0.packID == packID }
    }

    package static func reservedDraftIDs(_ directory: URL) throws -> Set<String> {
        Set(try readDraftRegistrations(directory).map(\.packID))
    }
}

private func readDraftRegistrations(_ root: URL) throws -> [AICuePackDraft] {
    guard PrivateSoundAssetIO.exists(root) else { return [] }
    return try PrivateSoundAssetIO.entries(root).filter { !$0.lastPathComponent.hasPrefix(".") }.map
    { file in
        guard file.pathExtension == "json" else { throw SoundAssetStorageError.corrupt }
        let metadata = try JSONDecoder().decode(
            DraftMetadata.self, from: PrivateSoundAssetIO.read(file, maximum: 16_384))
        guard metadata.version == 1,
            file.deletingPathExtension().lastPathComponent == metadata.packID
        else {
            throw SoundAssetStorageError.corrupt
        }
        return try AICuePackDraft(packID: metadata.packID, name: AICuePackName(metadata.name))
    }
}

private actor SoundPackDraftDisk {
    let root: URL
    let environment: AudioImportEnvironment
    var revision: UInt64 = 0

    init(root: URL, environment: AudioImportEnvironment) {
        self.root = root; self.environment = environment
    }

    func refresh() throws -> SoundPackDraftSnapshot {
        guard PrivateSoundAssetIO.exists(root) else { return try readSnapshot() }
        return try PrivateSoundAssetIO.withLock(at: environment.packsLockFile) {
            let registrations = try readDraftRegistrations(root)
            let fd = try PrivateSoundAssetIO.directory(root)
            defer { close(fd) }
            for draft in registrations {
                if case .success(let manifest) = loadPackManifest(
                    in: environment.userPacksDirectory.appendingPathComponent(draft.packID)),
                    manifest.id == draft.packID
                {
                    // Only a metadata file is removed. If cleanup is unavailable, readSnapshot
                    // still suppresses the already-published identity on this and future launches.
                    _ = (draft.packID + ".json").withCString { unlinkat(fd, $0, 0) }
                }
            }
            return try readSnapshot()
        }
    }

    private func readSnapshot() throws -> SoundPackDraftSnapshot {
        let drafts = try readDraftRegistrations(root).filter { draft in
            // Publication commits before registration cleanup. A restarted app projects that
            // stable identity only as installed, even when cleanup was interrupted or failed.
            let installed = environment.userPacksDirectory.appendingPathComponent(draft.packID)
            guard case .success(let manifest) = loadPackManifest(in: installed) else { return true }
            return manifest.id != draft.packID
        }
        revision &+= 1
        return SoundPackDraftSnapshot(
            revision: revision, drafts: drafts.sorted { $0.packID < $1.packID })
    }

    func create(name: AICuePackName) throws -> (AICuePackDraft, SoundPackDraftSnapshot) {
        try ensurePrivateDirectoryExists(at: root)
        return try PrivateSoundAssetIO.withLock(at: environment.packsLockFile) {
            try SoundPackNames.validate(name, environment: environment, draftsDirectory: root)
            let draft = try AICuePackDraft(
                packID: "cue-" + UUID().uuidString.lowercased(), name: name)
            try write(draft)
            return (draft, try readSnapshot())
        }
    }

    func rename(packID: String, name: AICuePackName) throws -> (
        AICuePackDraft, SoundPackDraftSnapshot
    ) {
        try PrivateSoundAssetIO.withLock(at: environment.packsLockFile) {
            guard let original = try readSnapshot().drafts.first(where: { $0.packID == packID })
            else {
                throw SoundAssetStorageError.changed
            }
            if original.name == name { return (original, try readSnapshot()) }
            try SoundPackNames.validate(
                name, excluding: packID, environment: environment, draftsDirectory: root)
            let draft = try AICuePackDraft(packID: packID, name: name)
            try write(draft)
            return (draft, try readSnapshot())
        }
    }

    func delete(packID: String) throws -> SoundPackDraftSnapshot {
        try PrivateSoundAssetIO.withLock(at: environment.packsLockFile) {
            guard try readSnapshot().drafts.contains(where: { $0.packID == packID }) else {
                throw SoundAssetStorageError.changed
            }
            // An unpublished registration contains no audio assets. This is the explicit draft
            // delete command only; closing a window or moving between pages never calls it.
            try FileManager.default.removeItem(at: root.appendingPathComponent(packID + ".json"))
            return try readSnapshot()
        }
    }

    private func write(_ draft: AICuePackDraft) throws {
        let data = try JSONEncoder().encode(
            DraftMetadata(version: 1, packID: draft.packID, name: draft.name.value))
        try PrivateSoundAssetIO.write(data, to: root.appendingPathComponent(draft.packID + ".json"))
    }
}
