import CryptoKit
import Foundation

/// Resolves host CLIs without assuming a Finder/LaunchServices process inherited the user's shell
/// `PATH`. Every returned path is absolute and resolves to an executable regular file; callers can
/// invoke that exact path, including its shim basename, instead of handing a bare command back to
/// `/usr/bin/env`.
public struct HostExecutableLocator: Sendable {
    public let searchDirectories: [URL]

    public init(searchDirectories: [URL]) {
        var seen: Set<String> = []
        self.searchDirectories = searchDirectories.compactMap { directory in
            guard directory.path.hasPrefix("/") else { return nil }
            let path = directory.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    public var executableSearchPath: String {
        searchDirectories.map(\.path).joined(separator: ":")
    }

    /// GUI `PATH` remains the first choice when it is useful. Explicit per-user installation roots
    /// then cover native installers and common Node version managers, including configured and
    /// default mise data roots, before system package-manager roots. NVM versions are
    /// numeric-descending so a GUI process with no shell-selected version still makes a
    /// deterministic choice.
    public static func standard(
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> HostExecutableLocator {
        let pathDirectories = (environmentPath ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let userDirectories = [
            ".local/bin",
            "bin",
            ".claude/local",
            ".codex/bin",
            ".opencode/bin",
            ".kimi-code/bin",
            ".volta/bin",
            ".asdf/shims",
        ].map { homeDirectory.appendingPathComponent($0, isDirectory: true) }
        let miseDirectories = [
            absoluteDirectory(environment["MISE_DATA_DIR"]),
            absoluteDirectory(environment["XDG_DATA_HOME"])?
                .appendingPathComponent("mise", isDirectory: true),
            homeDirectory.appendingPathComponent(".local/share/mise", isDirectory: true),
            homeDirectory.appendingPathComponent(".mise", isDirectory: true),
        ].compactMap { $0?.appendingPathComponent("shims", isDirectory: true) }
        let kimiDirectories = [absoluteDirectory(environment["KIMI_CODE_HOME"])]
            .compactMap { $0?.appendingPathComponent("bin", isDirectory: true) }
        let remainingUserDirectories = [
            ".fnm/current/bin",
            ".npm-global/bin",
            "Library/pnpm",
            ".bun/bin",
        ].map { homeDirectory.appendingPathComponent($0, isDirectory: true) }
        let nvmDirectories = nvmNodeBinDirectories(
            homeDirectory: homeDirectory,
            fileManager: fileManager)
        let systemDirectories = [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            URL(fileURLWithPath: "/bin", isDirectory: true),
        ]
        return HostExecutableLocator(
            searchDirectories:
                pathDirectories + kimiDirectories + userDirectories + miseDirectories
                + remainingUserDirectories
                + nvmDirectories + systemDirectories)
    }

    public func executablePath(command: String, fileManager: FileManager = .default) -> String? {
        guard !command.isEmpty, !command.contains("/") else { return nil }
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(command, isDirectory: false)
                .standardizedFileURL
            let validationTarget = candidate.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: validationTarget.path, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                fileManager.isExecutableFile(atPath: validationTarget.path),
                (try? validationTarget.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile)
                    == true
            else { continue }
            return candidate.path
        }
        return nil
    }

    private static func absoluteDirectory(_ path: String?) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func nvmNodeBinDirectories(
        homeDirectory: URL,
        fileManager: FileManager
    ) -> [URL] {
        let versionsRoot = homeDirectory.appendingPathComponent(
            ".nvm/versions/node",
            isDirectory: true)
        guard
            let children = try? fileManager.contentsOfDirectory(
                at: versionsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        return children.compactMap { directory -> (SemanticVersion, URL)? in
            let token =
                directory.lastPathComponent.hasPrefix("v")
                ? String(directory.lastPathComponent.dropFirst())
                : directory.lastPathComponent
            guard let version = SemanticVersion(parsing: token) else { return nil }
            return (version, directory.appendingPathComponent("bin", isDirectory: true))
        }
        .sorted { $0.0 > $1.0 }
        .map(\.1)
    }
}

/// Current Activation 的版本身份。调用方只能比较完整 fingerprint，不得拆开后自行放宽。
public enum HostActivationScope {
    public static func fingerprint(host: HostID, hostVersion: String) -> String? {
        let normalizedVersion = hostVersion.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalizedVersion.isEmpty, normalizedVersion.utf8.count <= 256 else { return nil }
        let bindingSchema = HostCapabilityCatalog.bindings(for: host)
            .filter(\.isAudibleCapability)
            .map(\.id.rawValue)
            .sorted()
            .joined(separator: ",")
        guard !bindingSchema.isEmpty else { return nil }
        return
            "surface=\(host.surfaceID.rawValue);host=\(normalizedVersion);"
            + "claudio=\(ClaudioVersion.current);bindings=\(bindingSchema)"
    }

    public static func discoveredVersion(
        for host: HostID, executableLocator: HostExecutableLocator = .standard(),
        commandRunner: (any CommandRunning)? = nil
    ) -> String? {
        guard host == .claudeCode || host == .codex else { return nil }
        return commandVersion(
            command: host == .claudeCode ? "claude" : "codex",
            executableLocator: executableLocator, commandRunner: commandRunner)
    }

    public static func claudeCode(
        executableLocator: HostExecutableLocator = .standard(),
        commandRunner: (any CommandRunning)? = nil
    ) -> String? {
        guard
            let version = commandVersion(
                command: "claude",
                executableLocator: executableLocator,
                commandRunner: commandRunner)
        else { return nil }
        return fingerprint(host: .claudeCode, hostVersion: version)
    }

    public static func codex(
        executableLocator: HostExecutableLocator = .standard(),
        commandRunner: (any CommandRunning)? = nil
    ) -> String? {
        guard
            let version = commandVersion(
                command: "codex",
                executableLocator: executableLocator,
                commandRunner: commandRunner)
        else { return nil }
        return fingerprint(host: .codex, hostVersion: "cli=\(version)")
    }

    public static func workBuddy() -> String? {
        guard let application = HostDiscovery.workBuddyApplicationURL(),
            let version = bundleVersion(at: application.path)
        else { return nil }
        return fingerprint(host: .workBuddy, hostVersion: "app=\(version)")
    }

    public static func additionalHost(
        _ host: HostID,
        configurationRoot: URL?,
        executableLocator: HostExecutableLocator = .standard(),
        commandRunner: (any CommandRunning)? = nil
    ) -> String? {
        guard host == .opencode || host == .kimiCode, let configurationRoot,
            let version = additionalHostVersion(
                host, executableLocator: executableLocator,
                commandRunner: commandRunner),
            // The new Kimi CLI is distinct from the Python 1.x CLI with the same command name.
            let parsed = SemanticVersion(parsing: version),
            (host == .opencode && parsed >= SemanticVersion(major: 1, minor: 18, patch: 34))
                || (host == .kimiCode && parsed >= SemanticVersion(major: 2, minor: 1, patch: 1)),
            let base = fingerprint(host: host, hostVersion: version)
        else { return nil }
        let rootDigest = SHA256.hash(
            data: Data(
                configurationRoot.resolvingSymlinksInPath()
                    .standardizedFileURL.path.utf8)
        ).map { String(format: "%02x", $0) }.joined()
        return base
            + ";config=\(rootDigest);acceptance=\(AdditionalHostReleasePolicy.isAcceptanceBuild)"
    }

    private static func additionalHostVersion(
        _ host: HostID,
        executableLocator: HostExecutableLocator, commandRunner: (any CommandRunning)?
    ) -> String? {
        guard host == .kimiCode else {
            return commandVersion(
                command: "opencode", executableLocator: executableLocator,
                commandRunner: commandRunner)
        }
        // Both CLI generations use `kimi`. A Python 1.x shim must not hide a separately
        // installed 2.x binary from a Finder-launched GUI. Inspect at most four real candidates.
        var checkedPaths: Set<String> = []
        let runner: any CommandRunning =
            commandRunner
            ?? SystemCommandRunner(
                environmentOverrides: ["PATH": executableLocator.executableSearchPath])
        for directory in executableLocator.searchDirectories {
            let candidate = HostExecutableLocator(searchDirectories: [directory])
            guard let path = candidate.executablePath(command: "kimi") else { continue }
            guard
                checkedPaths.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
                    .inserted
            else { continue }
            if let version = commandVersion(
                command: "kimi", executableLocator: candidate,
                commandRunner: runner), let parsed = SemanticVersion(parsing: version),
                parsed >= SemanticVersion(major: 2, minor: 1, patch: 1)
            {
                return version
            }
            if checkedPaths.count >= 4 { break }
        }
        return nil
    }

    public static func current(for host: HostID) -> String? {
        switch host {
        case .claudeCode: claudeCode()
        case .codex: codex()
        case .workBuddy: workBuddy()
        case .opencode, .kimiCode:
            additionalHost(host, configurationRoot: AdditionalHostPaths.currentRoot(host: host))
        case .chatGPTDesktopAX, .claudeDesktopAX: nil
        }
    }

    private static func bundleVersion(at path: String) -> String? {
        guard let bundle = Bundle(path: path) else { return nil }
        let shortVersion =
            (bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let buildVersion = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = [
            shortVersion.flatMap { $0.isEmpty ? nil : "short=\($0)" },
            buildVersion.flatMap { $0.isEmpty ? nil : "build=\($0)" },
        ].compactMap { $0 }
        return components.isEmpty ? nil : components.joined(separator: ";")
    }

    private static func commandVersion(
        command: String,
        executableLocator: HostExecutableLocator,
        commandRunner: (any CommandRunning)?
    ) -> String? {
        guard let executablePath = executableLocator.executablePath(command: command) else {
            return nil
        }
        let resolvedRunner =
            commandRunner
            ?? SystemCommandRunner(
                environmentOverrides: ["PATH": executableLocator.executableSearchPath])
        switch resolvedRunner.run(
            executablePath: executablePath,
            arguments: ["--version"],
            timeout: 1.0)
        {
        case .completed(let exitCode, let stdout) where exitCode == 0:
            let normalized = stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return normalized.isEmpty || normalized.utf8.count > 256 ? nil : normalized
        case .completed, .timedOut, .cleanupFailed, .launchFailed:
            return nil
        }
    }
}
