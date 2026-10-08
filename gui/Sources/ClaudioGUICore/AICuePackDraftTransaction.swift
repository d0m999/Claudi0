import ClaudioCore
import Darwin
import Foundation

package enum AICuePackDraftTransactionError: Error, Sendable, Equatable {
    case stagingFailed(reason: String)
    case destinationAlreadyExists(packID: String)
    case publishFailed(reason: String)
    case firstBindingInvalid
    case sourceUnavailable(PackEventSoundSource)
    case outdatedHelper
    case lockBusy
    case lockFailed(errno: Int32)
}

/// A hidden, not-yet-selectable draft tree. The caller imports and binds inside `payloadURL`, then
/// publishes only the completed `packDirectoryURL` with one exclusive rename.
package struct AICuePackDraftStage: Sendable, Equatable {
    package let rootURL: URL
    package let payloadURL: URL
    package let packDirectoryURL: URL
    package let finalDirectoryURL: URL
    package var requiresDraftRegistration = false

    package init(
        rootURL: URL,
        payloadURL: URL,
        packDirectoryURL: URL,
        finalDirectoryURL: URL
    ) {
        self.rootURL = rootURL
        self.payloadURL = payloadURL
        self.packDirectoryURL = packDirectoryURL
        self.finalDirectoryURL = finalDirectoryURL
    }
}

@MainActor
package func makeAICuePackDraftStage(
    _ draft: AICuePackDraft,
    environment: AudioImportEnvironment
) -> Result<AICuePackDraftStage, AICuePackDraftTransactionError> {
    do {
        try ensurePrivateDirectoryTree(at: environment.userPacksDirectory)
    } catch {
        return .failure(.stagingFailed(reason: error.localizedDescription))
    }

    let template = environment.userPacksDirectory.appendingPathComponent(
        ".\(draft.packID).tmp-XXXXXX")
    var templateBytes = Array(template.path.utf8CString)
    let created = templateBytes.withUnsafeMutableBufferPointer { buffer in
        mkdtemp(buffer.baseAddress!)
    }
    guard created != nil else {
        return .failure(
            .stagingFailed(reason: "无法创建隐藏暂存目录（errno \(errno)）"))
    }
    let createdPath = String(
        decoding: templateBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
        as: UTF8.self)
    let root = URL(fileURLWithPath: createdPath, isDirectory: true)
    let payload = root.appendingPathComponent("payload", isDirectory: true)
    let pack = payload.appendingPathComponent(draft.packID, isDirectory: true)
    let final = environment.userPacksDirectory.appendingPathComponent(
        draft.packID, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "id": draft.packID,
            "name": draft.name.value,
            "events": [String: String](),
            "audio_names": [String: String](),
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(
            to: pack.appendingPathComponent("manifest.json"),
            options: [.atomic])
    } catch {
        try? FileManager.default.removeItem(at: root)
        return .failure(.stagingFailed(reason: error.localizedDescription))
    }
    var stage = AICuePackDraftStage(
        rootURL: root, payloadURL: payload,
        packDirectoryURL: pack, finalDirectoryURL: final)
    let registrations = environment.userPacksDirectory.deletingLastPathComponent()
        .appendingPathComponent("sound-pack-drafts")
    stage.requiresDraftRegistration = PrivateSoundAssetIO.exists(
        registrations.appendingPathComponent(draft.packID + ".json"))
    return .success(stage)
}

package func stagingEnvironment(
    for stage: AICuePackDraftStage,
    basedOn environment: AudioImportEnvironment
) -> AudioImportEnvironment {
    var staging = environment
    staging.userPacksDirectory = stage.payloadURL
    // A draft is not allowed to resolve a source through a bundled root. Its manifest is created
    // above and the only package identity it can expose is the generated safe draft ID.
    staging.bundledPacksDirectory = nil
    staging.factoryPacksDirectory = nil
    staging.beforeAICueDraftPublish = nil
    return staging
}

@MainActor
package func publishAICuePackDraft(
    _ stage: AICuePackDraftStage,
    importedFile: ImportedAudioFile,
    environment: AudioImportEnvironment
) -> Result<ImportedAudioFile, AICuePackDraftTransactionError> {
    guard importedFile.packID == stage.packDirectoryURL.lastPathComponent else {
        return .failure(.publishFailed(reason: "暂存音频的声音包标识不一致"))
    }
    switch publishSoundPackDraft(stage, environment: environment) {
    case .failure(let error): return .failure(error)
    case .success:
        discardAICuePackDraftStage(stage)
        return .success(
            ImportedAudioFile(
                packID: importedFile.packID,
                destinationURL: stage.finalDirectoryURL.appendingPathComponent(
                    importedFile.fileName),
                fileName: importedFile.fileName, format: importedFile.format,
                fileSizeBytes: importedFile.fileSizeBytes, duration: importedFile.duration))
    }
}

/// Shared atomic publication for an imported cue or a first system-sound binding.
@MainActor
package func publishSoundPackDraft(
    _ stage: AICuePackDraftStage, environment: AudioImportEnvironment
) -> Result<Void, AICuePackDraftTransactionError> {
    guard (try? FileManager.default.attributesOfItem(atPath: stage.finalDirectoryURL.path)) == nil
    else {
        return .failure(
            .destinationAlreadyExists(packID: stage.packDirectoryURL.lastPathComponent))
    }

    let locked = withNonBlockingLock(path: environment.packsLockFile.path) {
        do {
            try environment.beforeAICueDraftPublish?(stage.finalDirectoryURL)
        } catch {
            return Result<Void, AICuePackDraftTransactionError>.failure(
                .publishFailed(reason: error.localizedDescription))
        }
        guard case .success(let manifest) = loadPackManifest(in: stage.packDirectoryURL),
            manifest.id == stage.packDirectoryURL.lastPathComponent,
            !manifest.eventSources.isEmpty
        else { return .failure(.firstBindingInvalid) }
        do {
            let data = try PrivateSoundAssetIO.read(
                stage.packDirectoryURL.appendingPathComponent("manifest.json"), maximum: 1_048_576)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let value = json["name"] as? String
            else { return .failure(.firstBindingInvalid) }
            let name = try AICuePackName(value)
            let registrations = environment.userPacksDirectory.deletingLastPathComponent()
                .appendingPathComponent("sound-pack-drafts")
            if stage.requiresDraftRegistration {
                guard
                    let draft = try SoundPackNames.registeredDraft(
                        manifest.id, directory: registrations),
                    draft.name == name
                else { return .failure(.firstBindingInvalid) }
            }
            try SoundPackNames.validate(
                name, excluding: manifest.id, environment: environment,
                draftsDirectory: registrations)
        } catch { return .failure(.firstBindingInvalid) }
        for source in manifest.eventSources.values {
            guard
                source.audioURL(in: stage.packDirectoryURL, catalog: environment.systemSoundCatalog)
                    != nil
            else { return .failure(.sourceUnavailable(source)) }
        }
        if manifest.eventSources.values.contains(where: { $0.systemSoundName != nil }),
            !environment.systemSoundSelectionAllowed()
        {
            return .failure(.outdatedHelper)
        }
        let result = renameatx_np(
            AT_FDCWD,
            stage.packDirectoryURL.path,
            AT_FDCWD,
            stage.finalDirectoryURL.path,
            UInt32(RENAME_EXCL))
        guard result == 0 else {
            let renameErrno = errno
            if renameErrno == EEXIST {
                return .failure(
                    .destinationAlreadyExists(packID: stage.packDirectoryURL.lastPathComponent))
            }
            return .failure(
                .publishFailed(
                    reason: "renameatx_np errno \(renameErrno): "
                        + String(cString: strerror(renameErrno))))
        }
        return .success(())
    }
    switch locked {
    case .skipped: return .failure(.lockBusy)
    case .failed(let code): return .failure(.lockFailed(errno: code))
    case .ran(let result): return result
    }
}

@MainActor
package func discardAICuePackDraftStage(_ stage: AICuePackDraftStage) {
    try? FileManager.default.removeItem(at: stage.rootURL)
}
