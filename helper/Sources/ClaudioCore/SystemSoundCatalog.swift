import Foundation

/// macOS-owned alert sounds. Names are stored in pack mappings; audio always stays in the
/// operating system's sound directory. The root is injectable for deterministic tests.
public struct SystemSoundCatalog: Sendable {
    public static let systemDirectory = URL(
        fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
    private static let extensions = ["aiff", "wav", "caf"]

    public let directory: URL

    public init(directory: URL = Self.systemDirectory) {
        self.directory = directory
    }

    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 128 else { return false }
        return name.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte)
                || (48...57).contains(byte) || byte == 32 || byte == 45 || byte == 95
        }
    }

    /// Returns only a current, nonempty regular system file contained in the chosen root.
    public func audioURL(named name: String) -> URL? {
        guard Self.isValidName(name) else { return nil }
        for ext in Self.extensions {
            guard let url = safePackFileURL("\(name).\(ext)", in: directory),
                nonEmptyRegularFileExists(at: url)
            else { continue }
            return url
        }
        return nil
    }

    public func availableNames() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        let names = Set(
            files.compactMap { file -> String? in
                let url = URL(fileURLWithPath: file)
                guard Self.extensions.contains(url.pathExtension.lowercased()) else { return nil }
                let name = url.deletingPathExtension().lastPathComponent
                return audioURL(named: name) == nil ? nil : name
            })
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
