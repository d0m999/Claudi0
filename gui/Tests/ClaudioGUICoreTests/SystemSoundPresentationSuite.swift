import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runSystemSoundPresentationSuites() {
    suite("system sound selection errors localize the reason in the current app language") {
        let cases: [(SystemSoundSelectionError, String, String)] = [
            (.unavailable(name: "Basso"), "macOS sound Basso is unavailable", "系统提示音 Basso 不可用"),
            (.outdatedHelper, "repair the installed helper", "修复已安装的 helper"),
            (
                .configFailure(reason: "无法写入 /private/fixture-config"),
                "Could not write settings", "配置或迁移备份写入失败"
            ),
            (
                .publishedConflict(recoveryPath: "/private/fixture-recovery"),
                "another change was detected", "检测到并发冲突"
            ),
            (.lockBusy, "configuration is busy", "声音配置正被占用"),
            (.lockFailed(errno: 13), "could not be locked", "无法锁定声音配置"),
        ]
        for (error, englishReason, chineseReason) in cases {
            let english = localizedSystemSoundSelectionError(error, language: .english)
            let chinese = localizedSystemSoundSelectionError(error, language: .zhHans)
            expect(english.contains(englishReason), "English includes the localized failure reason")
            expect(chinese.contains(chineseReason), "Chinese includes the localized failure reason")
            expect(
                !english.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
                "English errors never append a Chinese diagnostic description")
            expect(
                !english.contains("/private/fixture") && !chinese.contains("/private/fixture"),
                "raw config and recovery diagnostics are not inserted into UI or announcements")
            expect(
                !english.contains("%@") && !chinese.contains("%@"),
                "both languages substitute the error and sound-name placeholders")
        }
    }

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
