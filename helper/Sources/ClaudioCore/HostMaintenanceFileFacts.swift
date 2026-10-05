import Foundation

/// Change hints only, never a second configuration/snapshot owner. Reads stay off MainActor and
/// unrelated activity/receipt/log writes in a watched parent do not reset another host's failure.
public enum HostMaintenanceFileFacts {
    public static func capture(
        intentStore: HostIntegrationIntentStore = .init(),
        locator: HostExecutableLocator = .standard(),
        sharedHelper: URL = ClaudioPaths.claudioBinary,
        receiptStore: HostHookReceiptStore = HostHookReceiptStore(
            receiptsRoot: ClaudioPaths.receiptsDirectory,
            locksRoot: ClaudioPaths.receiptLocksDirectory,
            installationsRoot: ClaudioPaths.activeInstallationsDirectory,
            installationLocksRoot: ClaudioPaths.activeInstallationLocksDirectory),
        configurationFiles: [HostID: [URL]]? = nil, workBuddyURL: URL? = nil
    ) -> [HostID: [String]] {
        let intents = intentStore.read()
        let sharedHelper = stamp(sharedHelper)
        var result: [HostID: [String]] = [:]
        for host in HostIntegrationManager.automaticHosts {
            let intent: String
            switch intents {
            case .success(let entries):
                intent = entries[host.surfaceID].map { "\($0.enabled):\($0.revision)" } ?? "missing"
            case .failure: intent = "unreadable"
            }
            var files: [URL]
            switch host {
            case .claudeCode: files = [ClaudioPaths.claudeSettingsFile]
            case .codex:
                files = [
                    ClaudioPaths.codexHooksFile, ClaudioPaths.codexConfigFile,
                    ClaudioPaths.root.appendingPathComponent("bin/codex-notify"),
                ]
            case .workBuddy: files = [ClaudioPaths.workBuddySettingsFile]
            default: continue
            }
            files = configurationFiles?[host] ?? files
            files.append(receiptStore.installationFile(host: host))
            if host == .workBuddy, let app = workBuddyURL ?? HostDiscovery.workBuddyApplicationURL()
            {
                files.append(app.appendingPathComponent("Contents/Info.plist"))
                if let executable = Bundle(url: app)?.executableURL { files.append(executable) }
            } else if host != .workBuddy,
                let path = locator.executablePath(
                    command: host == .codex ? "codex" : "claude")
            {
                files.append(URL(fileURLWithPath: path))
            }
            result[host] = [intent, sharedHelper] + files.map(stamp)
        }
        return result
    }

    private static func stamp(_ file: URL) -> String {
        let resolved = file.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path)
        else {
            return "absent:\(resolved.path)"
        }
        return
            "\(resolved.path):\(attributes[.systemFileNumber] ?? "?"):\(attributes[.size] ?? "?"):\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(attributes[.posixPermissions] ?? "?")"
    }
}
