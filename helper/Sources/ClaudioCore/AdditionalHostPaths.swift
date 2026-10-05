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
        default: return nil
        }
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
            !HostEventSource.containsUnsafeScalar(path)
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    public static func file(host: HostID, root: URL) -> URL {
        root.appendingPathComponent(host == .opencode ? "plugins/claudio.js" : "config.toml")
    }

    public static func currentRoot(host: HostID) -> URL? {
        switch host {
        case .opencode: ClaudioPaths.opencodeConfigRoot
        case .kimiCode: ClaudioPaths.kimiCodeConfigRoot
        default: nil
        }
    }
}
