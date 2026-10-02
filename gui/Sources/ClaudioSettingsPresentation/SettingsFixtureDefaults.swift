#if DEBUG
import Foundation

/// DEBUG fixtures retain the existing UserDefaults injection seam while keeping every preference
/// byte under their supplied temporary root. No app, global or named persistent domain is used.
package final class SettingsFixtureDefaults: UserDefaults, @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var values: [String: Any]

    package init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file),
            let decoded = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        {
            values = decoded
        } else {
            values = [:]
        }
        super.init(suiteName: "Claudio.SettingsFixture.Unused.\(UUID().uuidString)")!
    }

    override package func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    override package func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override package func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }

    override package func dictionaryRepresentation() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    override package func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try PropertyListSerialization.data(
                fromPropertyList: values, format: .binary, options: 0)
            try data.write(to: file, options: .atomic)
        } catch {
            preconditionFailure("Isolated fixture preferences could not be written")
        }
    }

    override package func removeObject(forKey key: String) { set(nil, forKey: key) }
    override package func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    override package func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    override package func set(_ value: Float, forKey key: String) { set(value as Any, forKey: key) }
    override package func set(_ value: Double, forKey key: String) {
        set(value as Any, forKey: key)
    }
}
#endif
