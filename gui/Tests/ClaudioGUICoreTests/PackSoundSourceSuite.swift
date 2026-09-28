import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
private func sourceFixture(_ root: URL) -> AudioImportEnvironment {
    let packs = root.appendingPathComponent("packs")
    writeFixture(
        #"{"id":"user","schema":1,"events":{"stop":"tone.aiff"},"future":{"keep":true}}"#,
        to: packs.appendingPathComponent("user/manifest.json"))
    writeFixture(validAIFFData(), to: packs.appendingPathComponent("user/tone.aiff"))
    writeFixture(validAIFFData(), to: packs.appendingPathComponent("user/other.aiff"))
    writeFixture(validAIFFData(), to: root.appendingPathComponent("system/Basso.aiff"))
    writeFixture(validAIFFData(), to: root.appendingPathComponent("system/Ping.aiff"))
    var environment = makeAudioImportEnvironment(userPacksDirectory: packs)
    environment.systemSoundCatalog = SystemSoundCatalog(
        directory: root.appendingPathComponent("system"))
    return environment
}

@MainActor
func runPackSoundSourceSuites() async {
    suite("Pack source writer upgrades schema and rejects normalized duplicate bindings") {
        withTempDirectory { root in
            let environment = sourceFixture(root)
            let pack = environment.userPacksDirectory.appendingPathComponent("user")
            let manifest = pack.appendingPathComponent("manifest.json")
            expect(
                (try? bindSoundSourceToManifest(
                    event: .notification, source: .systemSound("Basso"),
                    packID: "user", environment: environment, expectedEventBinding: .unmapped
                ).get()) != nil,
                "system source binds through existing writer")
            let json =
                try! JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
                as! [String: Any]
            expect(json["schema"] as? Int == 2, "first system source upgrades schema 1")
            expect(
                (json["future"] as? [String: Bool])?["keep"] == true, "unknown metadata preserved")
            let before = try! Data(contentsOf: manifest)
            if case .failure(.soundAlreadyUsed(event: .notification)) = bindSoundSourceToManifest(
                event: .stop, source: .systemSound("Basso"), packID: "user",
                environment: environment)
            {
            } else {
                expect(false, "system duplicate rejected")
            }
            if case .failure(.soundAlreadyUsed(event: .stop)) = bindEventToManifest(
                event: .taskStart, fileName: "./tone.aiff", packID: "user", environment: environment
            ) {
            } else {
                expect(false, "normalized file duplicate rejected")
            }
            try! FileManager.default.createSymbolicLink(
                atPath: pack.appendingPathComponent("alias.aiff").path,
                withDestinationPath: "tone.aiff")
            if case .failure(.soundAlreadyUsed(event: .stop)) = bindAICueToManifest(
                event: .taskStart, fileName: "alias.aiff",
                displayName: try! AICueDisplayName("Cue"),
                packID: "user", environment: environment)
            {
            } else {
                expect(false, "AI adoption shares duplicate guard including symlinks")
            }
            expect(
                try! Data(contentsOf: manifest) == before,
                "all rejected writes preserve original bindings")
            let inventory = try! packAudioFiles(packID: "user", environment: environment).get()
            expect(
                !inventory.contains { $0.fileName == "Basso" },
                "system audio is absent from inventory")
            expect(
                inventory.first { $0.fileName == "tone.aiff" }?.boundEvents == [.stop],
                "inventory carries occupancy")
            expect(
                PackAudioFile(fileName: "tone.aiff", isOrphan: false, boundEvents: [.stop])
                    != PackAudioFile(
                        fileName: "tone.aiff", isOrphan: false, boundEvents: [.notification]),
                "inventory changes when occupancy moves between events")
            let rows = packCoverage(
                packID: "user", config: ClaudioConfig(selectedPack: "user"),
                environment: environment)
            let notification = rows.first { $0.event == .notification }!
            expect(
                notification.soundSource == .systemSound("Basso")
                    && notification.coverage.previewEnabled,
                "mixed coverage retains typed source")
            expect(
                eventPreviewFileURL(row: notification, packID: "user", environment: environment)
                    == root.appendingPathComponent("system/Basso.aiff"),
                "preview resolves local system sound")
        }
    }

    suite("Pack source CAS compares full source across import and adoption races") {
        withTempDirectory { root in
            var environment = sourceFixture(root)
            let pack = environment.userPacksDirectory.appendingPathComponent("user")
            _ = bindSoundSourceToManifest(
                event: .stop, source: .systemSound("Basso"), packID: "user",
                environment: environment)
            let before = try! Data(contentsOf: pack.appendingPathComponent("manifest.json"))
            for expected in [
                ManifestEventBindingExpectation.unmapped, .mapped(fileName: "Basso"),
                .mapped(source: .systemSound("Ping")),
            ] {
                if case .failure(.targetChanged) = bindEventToManifest(
                    event: .stop, fileName: "other.aiff",
                    packID: "user", environment: environment, expectedEventBinding: expected)
                {
                } else {
                    expect(false, "import must reject a changed source")
                }
            }
            if case .failure(.targetChanged) = bindAICueToManifest(
                event: .stop, fileName: "other.aiff",
                displayName: try! AICueDisplayName("Cue"), packID: "user", environment: environment,
                expectedEventBinding: .mapped(fileName: "tone.aiff"))
            {
            } else {
                expect(false, "adoption must preserve concurrent system binding")
            }
            environment.systemSoundSelectionAllowed = { false }
            if case .failure(.outdatedHelper) = bindSoundSourceToManifest(
                event: .stop, source: .systemSound("Ping"),
                packID: "user", environment: environment)
            {
            } else {
                expect(false, "pack operation owns helper compatibility guard")
            }
            expect(
                try! Data(contentsOf: pack.appendingPathComponent("manifest.json")) == before,
                "CAS and helper refusal leave manifest untouched")
            environment.systemSoundSelectionAllowed = { true }
            _ = withNonBlockingLock(path: environment.packsLockFile.path) {
                if case .failure(.lockBusy) = bindSoundSourceToManifest(
                    event: .stop, source: .systemSound("Ping"),
                    packID: "user", environment: environment)
                {
                } else {
                    expect(false, "system writer uses injected packs.lock")
                }
            }
            expect(
                (try? bindEventToManifest(
                    event: .stop, fileName: "other.aiff", packID: "user", environment: environment,
                    expectedEventBinding: .mapped(source: .systemSound("Basso"))
                ).get()) != nil,
                "captured system source can be replaced with file")
        }
    }

    suite("Legacy duplicate mappings stay playable and can be repaired individually") {
        withTempDirectory { root in
            let environment = sourceFixture(root)
            let pack = environment.userPacksDirectory.appendingPathComponent("user")
            writeFixture(
                #"{"id":"user","events":{"stop":"tone.aiff","notification":"./tone.aiff"}}"#,
                to: pack.appendingPathComponent("manifest.json"))
            let rows = packCoverage(
                packID: "user", config: ClaudioConfig(selectedPack: "user"),
                environment: environment)
            expect(
                rows.first { $0.event == .stop }?.duplicateEvents == [.notification],
                "legacy duplicates produce warning")
            expect(
                rows.filter { $0.coverage.previewEnabled }.count == 2,
                "both old mappings remain playable")
            expect(
                (try? bindSoundSourceToManifest(
                    event: .taskStart, source: .systemSound("Ping"),
                    packID: "user", environment: environment
                ).get()) != nil, "unrelated nonduplicate edit remains possible")
            expect(
                (try? clearEventBinding(
                    event: .notification, packID: "user", environment: environment
                ).get()) != nil,
                "one duplicate can be cleared")
            let after = packCoverage(
                packID: "user", config: ClaudioConfig(selectedPack: "user"),
                environment: environment)
            expect(
                after.allSatisfy { $0.duplicateEvents.isEmpty },
                "warning clears when mapping is repaired")
            writeFixture(
                #"{"id":"user","schema":2,"events":{"stop":{"system_sound":"Basso"},"notification":{"system_sound":"Basso"}}}"#,
                to: pack.appendingPathComponent("manifest.json"))
            let systemRows = packCoverage(
                packID: "user", config: ClaudioConfig(selectedPack: "user"),
                environment: environment)
            expect(
                systemRows.first { $0.event == .stop }?.duplicateEvents == [.notification]
                    && systemRows.filter { $0.coverage.previewEnabled }.count == 2,
                "legacy duplicate system names warn without disabling either event")
        }
    }

    await suite("Editor publishes first system sound, keeps groups unchanged, cancels empty drafts")
    {
        await withTempDirectory { root in
            let environment = sourceFixture(root)
            let config = root.appendingPathComponent("config.json")
            writeFixture(#"{"selected_pack":"user","master_volume":0.4}"#, to: config)
            let before = try! Data(contentsOf: config)
            let owner = SoundPacksEditorOwner(
                configFile: config, lockFile: root.appendingPathComponent("config.lock"),
                environment: environment, refreshCoordinator: SoundPacksRefreshCoordinator())
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 1)))
            expect(owner.beginAICuePackDraft(language: .english), "draft begins")
            guard case .sounds(let sounds) = owner.presentation.mode, let draft = sounds.draft,
                let action = sounds.eventRows.first(where: { $0.event == .stop })?
                    .systemSoundChoices.first?.action
            else { expect(false, "draft offers system sound choices"); return }
            expect(
                !FileManager.default.fileExists(
                    atPath: environment.userPacksDirectory.appendingPathComponent(draft.packID).path
                ),
                "empty draft is unpublished")
            guard case .accepted(let operation) = owner.send(.invoke(action)) else {
                expect(false, "owner accepts system sound action"); return
            }
            await owner.waitForScheduledOperationExitForTesting(operation)
            let published = environment.userPacksDirectory.appendingPathComponent(draft.packID)
            guard case .success(let manifest) = loadPackManifest(in: published) else {
                expect(false, "first sound publishes pack"); return
            }
            expect(
                manifest.eventSources.count == 1 && manifest.events.isEmpty,
                "only one system mapping, no copied audio")
            expect(
                (try? forkInstalledPack(
                    fromID: draft.packID, newID: "system-copy", environment: environment
                ).get()) != nil,
                "system-only pack follows the existing copy flow")
            let copy = environment.userPacksDirectory.appendingPathComponent("system-copy")
            if case .success(let copied) = loadPackManifest(in: copy) {
                expect(
                    copied.eventSources == manifest.eventSources,
                    "copy retains typed system references")
            } else {
                expect(false, "copy has a readable manifest")
            }
            expect(
                try! FileManager.default.contentsOfDirectory(atPath: copy.path) == [
                    "manifest.json"
                ],
                "copy never distributes operating system audio")
            expect(
                try! Data(contentsOf: config) == before,
                "draft publication never applies to a group")
            if case .sounds(let after) = owner.presentation.mode {
                expect(
                    after.draft == nil && after.selectedPack?.id == draft.packID,
                    "published pack is inspected")
                expect(
                    after.eventRows.filter { $0.coverage == .unmapped }.count == 4,
                    "remaining events unconfigured")
                let occupied = after.eventRows.first { $0.event == .notification }?
                    .systemSoundChoices.first { $0.source == .systemSound("Basso") }
                expect(
                    occupied?.action == nil && occupied?.usedByEvents == [.stop],
                    "menu shows occupancy and disables duplicates")
            }
            expect(owner.beginAICuePackDraft(language: .english), "another draft begins")
            guard case .sounds(let next) = owner.presentation.mode, let cancelled = next.draft,
                let cancelledAction = next.eventRows.first?.systemSoundChoices.first?.action
            else { expect(false, "second draft offers choices"); return }
            guard case .accepted(let cancelledOperation) = owner.send(.invoke(cancelledAction))
            else {
                expect(false, "second action is scheduled"); return
            }
            owner.cancelAICuePackDraft()
            await owner.waitForScheduledOperationExitForTesting(cancelledOperation)
            expect(
                !FileManager.default.fileExists(
                    atPath: environment.userPacksDirectory.appendingPathComponent(cancelled.packID)
                        .path),
                "cancel before scheduled write publishes no empty pack")
        }
    }

    await suite("Failed first system sound leaves no published pack or staging tree") {
        for failure in ["missing", "helper", "publication", "vanished"] {
            await withTempDirectory { root in
                var environment = sourceFixture(root)
                let systemFile = root.appendingPathComponent("system/Basso.aiff")
                if failure == "helper" { environment.systemSoundSelectionAllowed = { false } }
                if failure == "publication" {
                    environment.beforeAICueDraftPublish = { _ in
                        throw NSError(domain: "PackSoundSourceSuite", code: 1)
                    }
                }
                if failure == "vanished" {
                    environment.beforeAICueDraftPublish = { _ in
                        try FileManager.default.removeItem(at: systemFile)
                    }
                }
                let config = root.appendingPathComponent("config.json")
                writeFixture(#"{"selected_pack":"user"}"#, to: config)
                let before = try! Data(contentsOf: config)
                let owner = SoundPacksEditorOwner(
                    configFile: config, lockFile: root.appendingPathComponent("config.lock"),
                    environment: environment, refreshCoordinator: SoundPacksRefreshCoordinator())
                _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 1)))
                expect(
                    owner.beginAICuePackDraft(language: .english), "failure fixture starts draft")
                guard case .sounds(let sounds) = owner.presentation.mode, let draft = sounds.draft,
                    let action = sounds.eventRows.first?.systemSoundChoices.first(where: {
                        $0.source == .systemSound("Basso")
                    })?.action
                else { expect(false, "failure fixture offers system choice"); return }
                if failure == "missing" { try! FileManager.default.removeItem(at: systemFile) }
                guard case .accepted(let operation) = owner.send(.invoke(action)) else {
                    expect(false, "failure is checked by the scheduled writer"); return
                }
                await owner.waitForScheduledOperationExitForTesting(operation)
                let entries = try! FileManager.default.contentsOfDirectory(
                    atPath: environment.userPacksDirectory.path)
                expect(
                    !entries.contains(draft.packID) && !entries.contains { $0.contains(".tmp-") },
                    "\(failure) failure leaves neither an empty pack nor staging files")
                expect(
                    try! Data(contentsOf: config) == before,
                    "failed draft never changes a group's selection")
                if case .sounds(let after) = owner.presentation.mode {
                    expect(
                        after.draft?.packID == draft.packID,
                        "failed first binding keeps a retryable draft")
                    guard let status = after.windowStatuses.first(where: { $0.kind == .audio })
                    else {
                        expect(false, "draft failure remains visible"); return
                    }
                    let english = status.message(language: .english)
                    expect(
                        !english.isEmpty
                            && !english.unicodeScalars.contains {
                                (0x4E00...0x9FFF).contains($0.value)
                            },
                        "English draft errors contain a localized reason")
                    expect(
                        status.message(language: .zhHans) != english,
                        "draft errors follow the current UI language")
                } else {
                    expect(false, "failure keeps Sounds mode")
                }
            }
        }
    }

    await suite("Asynchronous import and adoption preserve a concurrent system sound change") {
        for adopting in [false, true] {
            await withTempDirectory { root in
                let environment = sourceFixture(root)
                _ = bindSoundSourceToManifest(
                    event: .stop, source: .systemSound("Basso"), packID: "user",
                    environment: environment)
                let config = root.appendingPathComponent("config.json")
                writeFixture(#"{"selected_pack":"user"}"#, to: config)
                let gate = SoundEditorPostSampleGate()
                defer { gate.release() }
                let library = SoundPackLibrary(environment: environment)
                let owner = SoundPacksEditorOwner(
                    configFile: config, lockFile: root.appendingPathComponent("config.lock"),
                    environment: environment, soundPackLibrary: library,
                    refreshCoordinator: SoundPacksRefreshCoordinator(),
                    afterFinalImportCancellationSampleForTesting: { gate.pauseWorker() })
                let generation = UUID()
                _ = owner.send(
                    .activate(
                        adopting
                            ? .events(
                                route: EventSettingsWindowRoute(scope: .global, event: .stop),
                                requestRevision: 1, candidateGenerationID: generation)
                            : .sounds(route: .overview, requestRevision: 1)))
                await waitForSoundEditorReady(owner, library: library)
                let source = root.appendingPathComponent("imported.mp3")
                writeFixture(validMP3ID3Data(), to: source)
                let request: SoundPacksEditorOperation
                if adopting {
                    guard case .events(let events) = owner.presentation.mode,
                        let permit = events.adoptionPermit
                    else {
                        expect(false, "adoption receives current permit"); return
                    }
                    let candidate = AICueCandidate(
                        id: UUID(), variant: .clear,
                        asset: AICueTemporaryAudioAsset(
                            fileURL: source, byteCount: validMP3ID3Data().count, sniffedFormat: .mp3
                        ),
                        durationMilliseconds: 1_000, mediaType: "audio/mpeg",
                        provenance: AICueCandidateProvenance(
                            providerID: .elevenLabs, profileID: .elevenLabsGlobal,
                            modelID: "eleven_text_to_sound_v2", generationID: generation,
                            requestOrdinal: 1, providerRequestID: nil))
                    request = .adoptAICue(
                        candidate: candidate, displayName: try! AICueDisplayName("Cue"),
                        permit: permit)
                } else {
                    guard case .sounds(let sounds) = owner.presentation.mode,
                        let action = sounds.eventRows.first(where: { $0.event == .stop })?
                            .importAction,
                        case .nativeEffect(.selectAudioFiles(let permit, _)) = owner.send(
                            .invoke(action))
                    else { expect(false, "import receives current permit"); return }
                    request = .importAudio(permit: permit, sources: [source], bindTo: .stop)
                }
                let task = Task { @MainActor in await owner.perform(request) }
                guard await gate.waitUntilEntered() else {
                    gate.release()
                    _ = await task.value
                    expect(false, "import reaches the deterministic post-write gate"); return
                }
                expect(
                    (try? bindSoundSourceToManifest(
                        event: .stop, source: .systemSound("Ping"), packID: "user",
                        environment: environment,
                        expectedEventBinding: .mapped(source: .systemSound("Basso"))
                    ).get()) != nil,
                    "another editor changes Basso to Ping while import is paused")
                gate.release()
                let result = await task.value
                switch result {
                case .adoptionOrphan(_, let failure):
                    expect(
                        adopting && failure == .targetChanged,
                        "adoption reports source CAS conflict")
                case .imported(let outcome):
                    expect(
                        !adopting && outcome.boundEvent == nil && outcome.orphan != nil,
                        "import keeps its copied file as an unbound recoverable orphan")
                default: expect(false, "source drift must settle as a typed orphan")
                }
                let pack = environment.userPacksDirectory.appendingPathComponent("user")
                if case .success(let manifest) = loadPackManifest(in: pack) {
                    expect(
                        manifest.eventSources["stop"] == .systemSound("Ping"),
                        "async completion preserves the new system mapping")
                } else {
                    expect(false, "manifest stays readable after race")
                }
                expect(
                    owner.presentation.activities.contains {
                        if case .orphan(_, .targetChanged) = $0.phase { return true }; return false
                    }, "activity exposes the precise conflict")
                await library.waitUntilIdleForTesting()
            }
        }
    }

    await suite("First system sound publication joins the existing shared library transaction") {
        await withTempDirectory { root in
            let environment = sourceFixture(root)
            let config = root.appendingPathComponent("config.json")
            writeFixture(#"{"selected_pack":"user"}"#, to: config)
            let library = SoundPackLibrary(environment: environment)
            let owner = SoundPacksEditorOwner(
                configFile: config, lockFile: root.appendingPathComponent("config.lock"),
                environment: environment, soundPackLibrary: library,
                refreshCoordinator: SoundPacksRefreshCoordinator())
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 1)))
            await waitForSoundEditorReady(owner, library: library)
            expect(owner.beginAICuePackDraft(language: .english), "live owner begins draft")
            guard case .sounds(let sounds) = owner.presentation.mode, let draft = sounds.draft,
                let action = sounds.eventRows.first(where: { $0.event == .stop })?
                    .systemSoundChoices.first?.action,
                case .accepted(let operation) = owner.send(.invoke(action))
            else { expect(false, "live owner offers and accepts system sound"); return }
            await owner.waitForScheduledOperationExitForTesting(operation)
            await owner.waitForMutationTransactionsToQuiesceForTesting()
            if case .sounds(let after) = owner.presentation.mode {
                expect(
                    after.draft == nil && after.selectedPack?.id == draft.packID,
                    "shared refresh inspects newly published pack")
                expect(
                    after.eventRows.first(where: { $0.event == .stop })?.soundSource
                        == .systemSound("Basso"),
                    "shared snapshot supplies the new source")
            } else {
                expect(false, "published pack stays in Sounds")
            }
            expect(
                loadClaudioConfig(from: config)?.selectedPack == "user",
                "library publication keeps group selection")
        }
    }

    await suite("Shared library refreshes system availability and all pack consumers") {
        await withTempDirectory { root in
            let environment = sourceFixture(root)
            _ = bindSoundSourceToManifest(
                event: .stop, source: .systemSound("Basso"), packID: "user",
                environment: environment)
            let library = SoundPackLibrary(environment: environment)
            guard case .ready(let snapshot) = await library.refreshSnapshot(trigger: .retry) else {
                expect(false, "shared snapshot loads"); return
            }
            var group = ClaudioConfig(selectedPack: "user", masterVolume: 0.2)
            group.eventsEnabled["stop"] = false
            let row = snapshot.eventRows(packID: "user", config: group).first { $0.event == .stop }!
            expect(
                row.soundSource == .systemSound("Basso") && !row.enabled,
                "source shared, event switch group-owned")
            expect(
                snapshot.systemSoundNames.contains("Basso"), "catalog belongs to shared snapshot")
            try! FileManager.default.removeItem(
                at: root.appendingPathComponent("system/Basso.aiff"))
            guard case .ready(let refreshed) = await library.refreshSnapshot(trigger: .retry) else {
                expect(false, "refresh completes"); return
            }
            expect(
                refreshed.eventRows(packID: "user", config: group).first { $0.event == .stop }?
                    .coverage == .broken(fileName: "Basso"),
                "unchanged manifest still refreshes system availability")
            expect(
                !refreshed.systemSoundNames.contains("Basso"),
                "unavailable system sound leaves menu")
        }
    }
}
