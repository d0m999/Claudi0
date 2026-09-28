import ClaudioCore
import Foundation

private final class SystemSoundPlaybackRecorder: ProcessSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func spawn(executablePath: String, arguments: [String]) -> Bool {
        lock.lock()
        recorded.append(arguments)
        lock.unlock()
        return true
    }
}

@MainActor
func runSystemSoundSelectionSuites() {
    suite("system choice guard requires the current installed helper") {
        withTempDirectory { root in
            let bundled = root.appendingPathComponent("bundled")
            let installed = root.appendingPathComponent("installed")
            writeFixture("current helper", to: bundled)
            writeFixture("old helper", to: installed)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: bundled.path)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: installed.path)
            expect(
                !installedHelperMatchesBundledRuntime(
                    bundledHelper: bundled, installedHelper: installed),
                "older helper is rejected")
            try! Data(contentsOf: bundled).write(to: installed)
            expect(
                installedHelperMatchesBundledRuntime(
                    bundledHelper: bundled, installedHelper: installed),
                "same executable is accepted")
            expect(
                !installedHelperMatchesBundledRuntime(
                    bundledHelper: nil, installedHelper: installed),
                "missing app-bundled helper cannot authorize selection")
        }
    }

    suite("system sound catalog accepts only installed, contained regular audio") {
        withTempDirectory { root in
            let sounds = root.appendingPathComponent("system", isDirectory: true)
            try! FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
            writeFixture("fixture", to: sounds.appendingPathComponent("Basso.aiff"))
            let outside = root.appendingPathComponent("outside.aiff")
            writeFixture("outside", to: outside)
            try! FileManager.default.createSymbolicLink(
                at: sounds.appendingPathComponent("Escape.aiff"), withDestinationURL: outside)
            writeFixture("", to: sounds.appendingPathComponent("Empty.aiff"))
            let catalog = SystemSoundCatalog(directory: sounds)
            expect(catalog.availableNames() == ["Basso"], "only installed regular sounds appear")
            expect(
                catalog.audioURL(named: "Basso")?.lastPathComponent == "Basso.aiff",
                "valid name resolves")
            expect(catalog.audioURL(named: "../outside") == nil, "traversal is rejected")
            expect(catalog.audioURL(named: "Escape") == nil, "symlink escape is rejected")
            expect(catalog.audioURL(named: "Empty") == nil, "empty audio is rejected")
        }
    }

    suite("default and workspace system choices are independent and preserve unknown config") {
        withTempDirectory { root in
            let sounds = root.appendingPathComponent("system", isDirectory: true)
            try! FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
            writeFixture("basso", to: sounds.appendingPathComponent("Basso.aiff"))
            writeFixture("ping", to: sounds.appendingPathComponent("Ping.aiff"))
            let catalog = SystemSoundCatalog(directory: sounds)
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let directory = WorkspaceDirectory(
                kind: .directory, path: root.resolvingSymlinksInPath().path)
            let rule = WorkspaceSoundRule(
                directory: directory, surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "workspace", volume: 0.6))
            var config = ClaudioConfig(selectedPack: "default", masterVolume: 0.3)
            config.workspaceRules = [rule]
            var json =
                try! JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
                as! [String: Any]
            json["future_key"] = ["keep": true]
            try! JSONSerialization.data(withJSONObject: json).write(to: configFile)

            expect(
                (try? setSystemSound(
                    .stop, name: "Basso", catalog: catalog,
                    configFile: configFile, lockFile: lockFile
                ).get()) != nil,
                "default event choice writes")
            expect(
                (try? mutateWorkspaceSound(
                    .systemSound(WorkspaceSoundWriteTarget(rule: rule), .notification, "Ping"),
                    configFile: configFile, lockFile: lockFile,
                    systemSoundCatalog: catalog
                ).get()) != nil,
                "workspace event choice writes")
            let loaded = loadClaudioConfig(from: configFile)!
            expect(loaded.systemSounds == ["stop": "Basso"], "default retains only its choice")
            expect(
                loaded.workspaceRules.first?.profile?.systemSounds == ["notification": "Ping"],
                "workspace retains only its choice")
            expect(
                try! loaded.resolveSoundProfile(for: .codex, cwd: root.path).get()
                    .systemSounds == ["notification": "Ping"],
                "matched workspace uses its own event choices")
            expect(
                try! loaded.resolveSoundProfile(for: nil).get().systemSounds == ["stop": "Basso"],
                "default group uses its own event choices")
            let recorder = SystemSoundPlaybackRecorder()
            let environment = PlayEnvironment(
                surfaceID: .codex, workingDirectory: root.path,
                lockFile: root.appendingPathComponent("play.lock"), configFile: configFile,
                userPacksDirectory: root.appendingPathComponent("packs"),
                systemSoundDirectory: sounds, spawner: recorder,
                debounceStateFile: root.appendingPathComponent("debounce"), debounceInterval: 0,
                logFile: root.appendingPathComponent("log"),
                logLockFile: root.appendingPathComponent("log.lock"))
            expect(
                playSoundEvent("notification", environment: environment)
                    == .played(
                        event: .notification,
                        filePath: sounds.appendingPathComponent("Ping.aiff").path),
                "matched workspace plays its own system choice")
            expect(
                recorder.calls.last?[1] == AfplayVolume.afplayArgument(forMasterVolume: 0.6),
                "workspace volume applies to system audio")
            let written =
                try! JSONSerialization.jsonObject(with: Data(contentsOf: configFile))
                as! [String: Any]
            expect(
                (written["future_key"] as? [String: Bool])?["keep"] == true,
                "unknown top-level data survives both writes")
            expect(
                (try? setSystemSound(
                    .stop, name: "Missing", catalog: catalog,
                    configFile: configFile, lockFile: lockFile
                ).get()) == nil,
                "uninstalled sound cannot be selected")
            expect(
                loadClaudioConfig(from: configFile)?.systemSounds == ["stop": "Basso"],
                "rejected selection leaves config intact")
        }
    }

    suite("system choice plays system-owned file without pack fallback; mute still wins") {
        withTempDirectory { root in
            let sounds = root.appendingPathComponent("system", isDirectory: true)
            let packs = root.appendingPathComponent("packs/default", isDirectory: true)
            try! FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
            try! FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
            writeFixture("system", to: sounds.appendingPathComponent("Basso.aiff"))
            writeFixture("pack", to: packs.appendingPathComponent("tone.aiff"))
            let events = Dictionary(
                uniqueKeysWithValues: Event.allCases.map { ($0.cliName, "tone.aiff") })
            try! JSONSerialization.data(withJSONObject: [
                "id": "default", "name": "default", "events": events,
            ]).write(to: packs.appendingPathComponent("manifest.json"))
            let configFile = root.appendingPathComponent("config.json")
            var config = ClaudioConfig(selectedPack: "default", systemSounds: ["stop": "Basso"])
            try! JSONEncoder().encode(config).write(to: configFile)
            let recorder = SystemSoundPlaybackRecorder()
            let environment = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"), configFile: configFile,
                userPacksDirectory: root.appendingPathComponent("packs"),
                systemSoundDirectory: sounds, spawner: recorder,
                debounceStateFile: root.appendingPathComponent("debounce"), debounceInterval: 0,
                logFile: root.appendingPathComponent("log"),
                logLockFile: root.appendingPathComponent("log.lock"))
            expect(
                playSoundEvent("stop", environment: environment)
                    == .played(
                        event: .stop, filePath: sounds.appendingPathComponent("Basso.aiff").path),
                "selected system sound plays")
            expect(
                recorder.calls.last?[2] == sounds.appendingPathComponent("Basso.aiff").path,
                "system audio is loaded from the runtime OS directory")
            expect(
                playSoundEvent("notification", environment: environment)
                    == .played(
                        event: .notification,
                        filePath: packs.appendingPathComponent("tone.aiff").path),
                "unselected event still uses pack")
            expect(
                recorder.calls.last?[2].contains("/packs/default/") == true,
                "unselected event uses selected pack file")
            try! FileManager.default.removeItem(at: sounds.appendingPathComponent("Basso.aiff"))
            expect(
                playSoundEvent("stop", environment: environment) == .notReady,
                "missing selected system sound fails closed")
            expect(recorder.calls.count == 2, "missing system sound never falls back to pack")
            config.eventsEnabled["stop"] = false
            try! JSONEncoder().encode(config).write(to: configFile)
            expect(
                playSoundEvent("stop", environment: environment) == .disabled(event: .stop),
                "event switch still mutes system choice")
        }
    }
}
