import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runSystemSoundPresentationSuites() {
    suite("system sound presentation replaces only its event's pack coverage") {
        let rows = Event.allCases.map { event in
            EventRow(event: event, coverage: .broken(fileName: "missing.aiff"), enabled: true)
        }
        let available = panelEventPresentations(
            rows: rows, scope: .global, masterVolume: 0.8, language: .english,
            systemSounds: ["stop": "Basso"], availableSystemSoundNames: ["Basso"],
            eventsEnabled: ["stop": false])
        let stop = available.first { $0.event == .stop }!
        let notification = available.first { $0.event == .notification }!
        expect(stop.soundFileText == "macOS: Basso", "selected source appears by name")
        expect(stop.controls.previewEnabled, "system audio is previewable despite broken pack")
        expect(!stop.enabled, "the event switch stays independent of source selection")
        expect(
            !notification.controls.previewEnabled,
            "other events retain their selected-pack coverage")

        let missing = panelEventPresentations(
            rows: rows, scope: .global, masterVolume: 0.8, language: .english,
            systemSounds: ["stop": "Basso"], availableSystemSoundNames: [])
        let missingStop = missing.first { $0.event == .stop }!
        expect(
            missingStop.soundFileText == "macOS sound unavailable: Basso",
            "missing current system audio is explicit")
        expect(
            !missingStop.controls.previewEnabled,
            "missing system audio never previews the pack instead")
    }

    suite("workspace model projects its own system choices and preview URLs") {
        withTempDirectory { root in
            let sounds = root.appendingPathComponent("system", isDirectory: true)
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            writeFixture("sound", to: sounds.appendingPathComponent("Ping.aiff"))
            let configFile = root.appendingPathComponent("config.json")
            var config = ClaudioConfig(
                selectedPack: "default", systemSounds: ["stop": "Basso"])
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: root.path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(
                    selectedPack: "workspace", volume: 0.6,
                    systemSounds: ["notification": "Ping"]))
            config.workspaceRules = [rule]
            try! JSONEncoder().encode(config).write(to: configFile)
            let model = PanelConfigController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"),
                environment: makeAudioImportEnvironment(userPacksDirectory: packs),
                systemSoundCatalog: SystemSoundCatalog(directory: sounds))
            model.selectSoundScope(.workspace(rule.id))
            expect(
                model.config.systemSounds == ["notification": "Ping"],
                "workspace projection does not inherit Default Group system choices")
            expect(
                model.previewURL(for: .notification)?.lastPathComponent == "Ping.aiff",
                "workspace preview points at installed system sound")
            let guarded = PanelConfigController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"),
                environment: makeAudioImportEnvironment(userPacksDirectory: packs),
                systemSoundCatalog: SystemSoundCatalog(directory: sounds),
                systemSoundSelectionAllowed: { false })
            let rejected = guarded.selectSystemSound("Ping", for: .stop)
            if case .failure(.outdatedHelper) = rejected {
                expect(true, "older installed helper rejects a new system selection")
            } else {
                expect(false, "older installed helper must reject a new system selection")
            }
            expect(
                loadClaudioConfig(from: configFile)?.systemSounds == ["stop": "Basso"],
                "rejected selection does not change Default Group")
        }
    }
}
