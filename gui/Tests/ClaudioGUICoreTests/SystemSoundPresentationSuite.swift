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

    suite("system sound presentation follows typed pack coverage") {
        let row = EventRow(
            event: .stop, coverage: .present(fileName: "Basso"), enabled: false,
            soundSource: .systemSound("Basso"))
        let stop = panelEventPresentations(
            rows: [row], scope: .global, masterVolume: 0.8,
            language: .english
        ).first { $0.event == .stop }!
        expect(stop.soundFileText == "macOS: Basso", "selected source appears by name")
        expect(
            stop.controls.previewEnabled && !stop.enabled,
            "preview is independent of automatic event switch")
        let missingRow = EventRow(
            event: .stop, coverage: .broken(fileName: "Basso"), enabled: true,
            soundSource: .systemSound("Basso"))
        let missing = panelEventPresentations(
            rows: [missingRow], scope: .global, masterVolume: 0.8,
            language: .english
        ).first { $0.event == .stop }!
        expect(
            missing.soundFileText == "macOS sound unavailable: Basso"
                && !missing.controls.previewEnabled,
            "missing system source has explicit reason without fallback")
    }

    suite("workspace preview follows its pack and detects retired system choices") {
        withTempDirectory { root in
            let sounds = root.appendingPathComponent("system")
            let packs = root.appendingPathComponent("packs")
            writeFixture("sound", to: sounds.appendingPathComponent("Ping.aiff"))
            writeFixture(
                #"{"id":"workspace","schema":2,"events":{"notification":{"system_sound":"Ping"}}}"#,
                to: packs.appendingPathComponent("workspace/manifest.json"))
            let configFile = root.appendingPathComponent("config.json")
            var config = ClaudioConfig(selectedPack: "default", systemSounds: ["stop": "Basso"])
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: root.path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(
                    selectedPack: "workspace", volume: 0.6,
                    systemSounds: ["notification": "Missing"]))
            config.workspaceRules = [rule]
            try! JSONEncoder().encode(config).write(to: configFile)
            var environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            environment.systemSoundCatalog = SystemSoundCatalog(directory: sounds)
            let model = PanelConfigController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"),
                environment: environment)
            model.selectSoundScope(.workspace(rule.id))
            expect(model.config.hasLegacySystemSounds, "retired choices detected for notice")
            expect(
                model.previewURL(for: .notification)?.lastPathComponent == "Ping.aiff",
                "preview uses pack mapping")
            let before = try! Data(contentsOf: configFile)
            expect(
                (try? model.selectSystemSound("Basso", for: .notification).get()) == nil,
                "retired group writer refuses")
            expect(try! Data(contentsOf: configFile) == before, "old choices are preserved")
        }
    }
}
