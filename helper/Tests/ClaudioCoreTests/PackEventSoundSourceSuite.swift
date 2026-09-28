import ClaudioCore
import Foundation

private final class PackSoundSpawner: ProcessSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var arguments: [String] = []
    var last: [String] { lock.lock(); defer { lock.unlock() }; return arguments }
    func spawn(executablePath: String, arguments: [String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.arguments = arguments
        return true
    }
}

@MainActor
func runPackEventSoundSourceSuites() {
    suite("Pack sources decode file, mixed and system-only manifests") {
        for events in [
            #"{"stop":"tone.aiff"}"#,
            #"{"stop":{"system_sound":"Basso"},"notification":"tone.aiff"}"#,
            #"{"stop":{"system_sound":"Basso"}}"#,
        ] {
            let data = Data("{\"id\":\"test\",\"schema\":2,\"events\":\(events)}".utf8)
            let manifest = try! JSONDecoder().decode(PackManifest.self, from: data)
            expect(manifest.eventSources["stop"] != nil, "every source decodes")
            expect(
                manifest.events.values.allSatisfy { $0 == "tone.aiff" }, "inventory sees only files"
            )
        }
        let original = PackEventSoundSource.systemSound("Basso")
        expect(
            try! JSONDecoder().decode(
                PackEventSoundSource.self, from: JSONEncoder().encode(original)) == original,
            "system source round trips without storing a path")
    }

    suite("Pack mapping controls playback, independent group volume and event switches") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs")
            let sounds = root.appendingPathComponent("system")
            writeFixture("basso", to: sounds.appendingPathComponent("Basso.aiff"))
            writeFixture("ping", to: sounds.appendingPathComponent("Ping.aiff"))
            writeFixture(
                #"{"id":"mixed","schema":2,"events":{"stop":{"system_sound":"Basso"},"notification":"tone.aiff","task_start":{"system_sound":"Ping"}}}"#,
                to: packs.appendingPathComponent("mixed/manifest.json"))
            writeFixture("file", to: packs.appendingPathComponent("mixed/tone.aiff"))
            writeFixture(
                #"{"id":"system-only","schema":2,"events":{"stop":{"system_sound":"Ping"}}}"#,
                to: packs.appendingPathComponent("system-only/manifest.json"))
            let configFile = root.appendingPathComponent("config.json")
            var config = ClaudioConfig(
                selectedPack: "mixed", masterVolume: 0.3,
                systemSounds: ["stop": "Ping"])
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: root.path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(
                    selectedPack: "mixed", volume: 0.6,
                    systemSounds: ["stop": "Missing"]))
            config.workspaceRules = [rule]
            try! JSONEncoder().encode(config).write(to: configFile)
            let spawner = PackSoundSpawner()
            func makeEnvironment(surface: HostSurfaceID? = nil) -> PlayEnvironment {
                PlayEnvironment(
                    surfaceID: surface, workingDirectory: surface == nil ? nil : root.path,
                    lockFile: root.appendingPathComponent("play.lock"), configFile: configFile,
                    userPacksDirectory: packs, systemSoundDirectory: sounds, spawner: spawner,
                    debounceStateFile: root.appendingPathComponent("debounce"), debounceInterval: 0,
                    logFile: root.appendingPathComponent("log"),
                    logLockFile: root.appendingPathComponent("log.lock"))
            }
            var environment = makeEnvironment()
            expect(
                playSoundEvent("stop", environment: environment)
                    == .played(
                        event: .stop,
                        filePath: sounds.appendingPathComponent("Basso.aiff").path),
                "pack beats retired default override")
            expect(
                spawner.last[1] == AfplayVolume.afplayArgument(forMasterVolume: 0.3),
                "default volume")
            environment = makeEnvironment(surface: .codex)
            expect(
                playSoundEvent("stop", environment: environment)
                    == .played(
                        event: .stop,
                        filePath: sounds.appendingPathComponent("Basso.aiff").path),
                "same pack in workspace")
            expect(
                spawner.last[1] == AfplayVolume.afplayArgument(forMasterVolume: 0.6),
                "workspace volume")
            try! FileManager.default.removeItem(at: sounds.appendingPathComponent("Basso.aiff"))
            expect(
                checkPackIntegrity(
                    configFile: configFile, userPacksDirectory: packs,
                    bundledPacksDirectory: nil,
                    systemSoundCatalog: SystemSoundCatalog(directory: sounds))
                    == .incomplete(packID: "mixed", missingFiles: ["system_sound:Basso"]),
                "diagnostics identify unavailable system sources without treating them as pack files"
            )
            expect(
                playSoundEvent("stop", environment: environment) == .notReady,
                "missing system sound fails only its event")
            expect(
                playSoundEvent("task_start", environment: environment)
                    == .played(
                        event: .taskStart,
                        filePath: sounds.appendingPathComponent("Ping.aiff").path),
                "another system sound still plays")
            expect(
                playSoundEvent("notification", environment: environment)
                    == .played(
                        event: .notification,
                        filePath: packs.appendingPathComponent("mixed/tone.aiff").path),
                "file event still plays")
            environment = makeEnvironment()
            config.selectedPack = "system-only"
            try! JSONEncoder().encode(config).write(to: configFile)
            expect(
                playSoundEvent("stop", environment: environment)
                    == .played(
                        event: .stop,
                        filePath: sounds.appendingPathComponent("Ping.aiff").path),
                "switching packs switches mapping")
            expect(
                checkPackIntegrity(
                    configFile: configFile, userPacksDirectory: packs,
                    bundledPacksDirectory: nil,
                    systemSoundCatalog: SystemSoundCatalog(directory: sounds))
                    == .complete(packID: "system-only", events: ["stop"]),
                "doctor accepts system-only packs")
            config.eventsEnabled["stop"] = false
            try! JSONEncoder().encode(config).write(to: configFile)
            expect(
                playSoundEvent("stop", environment: environment) == .disabled(event: .stop),
                "group mute remains independent")
        }
    }

    suite("Malformed retired fields survive ordinary config writes without invalidating profiles") {
        withTempDirectory { root in
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: root.path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "test", volume: 0.7))
            var config = ClaudioConfig(selectedPack: "test")
            config.workspaceRules = [rule]
            var json =
                try! JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
                as! [String: Any]
            json["system_sounds"] = ["stop": ["future": 7]]
            var rules = json["workspace_rules"] as! [String: [String: Any]]
            var profile = rules[rule.id.uuidString]!["profile"] as! [String: Any]
            profile["systemSounds"] = [1, 2, 3]
            rules[rule.id.uuidString]!["profile"] = profile
            json["workspace_rules"] = rules
            let file = root.appendingPathComponent("config.json")
            try! JSONSerialization.data(withJSONObject: json).write(to: file)
            let loaded = loadClaudioConfig(from: file)!
            expect(
                (try? loaded.resolveSoundProfile(for: nil).get()) != nil,
                "retired defaults do not invalidate config")
            expect(
                (try? loaded.resolveWorkspaceProfile(id: rule.id).get()) != nil,
                "retired workspace values do not invalidate rule")
            expect(
                loaded.hasLegacySystemSounds
                    && loaded.workspaceRules[0].profile?.hasLegacySystemSounds == true,
                "legacy choices remain detectable for migration notice")
            expect(
                (try? setMasterVolume(
                    0.4, configFile: file,
                    lockFile: root.appendingPathComponent("config.lock")
                ).get()) != nil, "ordinary write succeeds")
            expect(
                (try? mutateWorkspaceSound(
                    .event(WorkspaceSoundWriteTarget(rule: rule), .stop, false),
                    configFile: file, lockFile: root.appendingPathComponent("config.lock")
                ).get()) != nil,
                "workspace write succeeds")
            let after =
                try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            expect(
                NSDictionary(dictionary: after["system_sounds"] as! [String: Any])
                    == NSDictionary(dictionary: json["system_sounds"] as! [String: Any]),
                "opaque default value is preserved")
            let afterRules = after["workspace_rules"] as! [String: [String: Any]]
            expect(
                (afterRules[rule.id.uuidString]!["profile"] as! [String: Any])["systemSounds"]
                    as? [Int] == [1, 2, 3],
                "opaque workspace value is preserved")
        }
    }
}
