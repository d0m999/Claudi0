import Foundation

public enum AdditionalHostPaths {
    public static func configurationRoot(
        host: HostID,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let path: String
        switch host {
        case .opencode:
            if let explicit = environment["OPENCODE_CONFIG_DIR"] {
                path = explicit
            } else if let xdg = environment["XDG_CONFIG_HOME"] {
                guard xdg.hasPrefix("/") else { return nil }
                path = URL(fileURLWithPath: xdg).appendingPathComponent("opencode").path
            } else {
                path = homeDirectory.appendingPathComponent(".config/opencode").path
            }
        case .kimiCode:
            path =
                environment["KIMI_CODE_HOME"]
                ?? homeDirectory.appendingPathComponent(".kimi-code").path
        case .grokBuild:
            let explicit = environment["GROK_HOME"] ?? ""
            path =
                explicit.hasPrefix("/") && explicit.utf8.count <= 4096
                    && !HostEventSource.containsUnsafeScalar(explicit)
                ? explicit : homeDirectory.appendingPathComponent(".grok").path
        default: return nil
        }
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
            !HostEventSource.containsUnsafeScalar(path)
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    public static func file(host: HostID, root: URL) -> URL {
        let relativePath: String
        switch host {
        case .opencode: relativePath = "plugins/claudio.js"
        case .grokBuild: relativePath = "hooks/claudio.json"
        default: relativePath = "config.toml"
        }
        return root.appendingPathComponent(relativePath)
    }

    public static func currentRoot(host: HostID) -> URL? {
        switch host {
        case .opencode: ClaudioPaths.opencodeConfigRoot
        case .kimiCode: ClaudioPaths.kimiCodeConfigRoot
        case .grokBuild: ClaudioPaths.grokBuildConfigRoot
        default: nil
        }
    }
}
