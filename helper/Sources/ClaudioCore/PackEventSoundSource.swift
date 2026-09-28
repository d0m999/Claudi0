import Foundation

/// One event's sound in a pack. System audio stays on the local Mac; only its name is stored.
public enum PackEventSoundSource: Codable, Equatable, Hashable, Sendable {
    case file(String)
    case systemSound(String)

    public var name: String {
        switch self {
        case .file(let name), .systemSound(let name): name
        }
    }

    public var fileName: String? {
        if case .file(let name) = self { return name }
        return nil
    }

    public var systemSoundName: String? {
        if case .systemSound(let name) = self { return name }
        return nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let file = try? container.decode(String.self) {
            self = .file(file)
        } else {
            let object = try container.decode([String: String].self)
            guard object.count == 1, let name = object["system_sound"] else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Expected a file or system_sound name")
            }
            // A missing or invalid local name is an event-level failure, not a broken manifest.
            self = .systemSound(name)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .file(let name): try container.encode(name)
        case .systemSound(let name): try container.encode(["system_sound": name])
        }
    }

    public init?(jsonValue: Any) {
        if let file = jsonValue as? String {
            self = .file(file)
        } else if let object = jsonValue as? [String: Any], object.count == 1,
            let name = object["system_sound"] as? String
        {
            self = .systemSound(name)
        } else {
            return nil
        }
    }

    public var jsonValue: Any {
        switch self {
        case .file(let name): name
        case .systemSound(let name): ["system_sound": name]
        }
    }

    public func audioURL(
        in packDirectory: URL, catalog: SystemSoundCatalog = SystemSoundCatalog()
    ) -> URL? {
        switch self {
        case .file(let name):
            guard let url = safePackFileURL(name, in: packDirectory),
                nonEmptyRegularFileExists(at: url)
            else { return nil }
            return url
        case .systemSound(let name): return catalog.audioURL(named: name)
        }
    }

    /// Use the same normalization for menu occupancy, legacy warnings and locked writes.
    public func identity(in packDirectory: URL) -> String {
        switch self {
        case .systemSound(let name): return "system:\(name)"
        case .file(let name):
            return
                "file:\(packDirectory.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath().path)"
        }
    }
}
