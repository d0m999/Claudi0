import ClaudioCore
import Foundation

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

    suite("retired group system sound writers preserve config") {
        withTempDirectory { root in
            let config = root.appendingPathComponent("config.json")
            writeFixture(
                #"{"selected_pack":"test","system_sounds":{"stop":"Basso"},"future":7}"#, to: config
            )
            let before = try! Data(contentsOf: config)
            expect(
                (try? setSystemSound(
                    .stop, name: "Ping", configFile: config,
                    lockFile: root.appendingPathComponent("config.lock")
                ).get()) == nil,
                "retired writer rejects changes")
            expect(try! Data(contentsOf: config) == before, "retired bytes stay untouched")
        }
    }
}
