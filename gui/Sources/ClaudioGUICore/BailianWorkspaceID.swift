import Foundation

/// A Bailian business-space identity, unrelated to Claudio's local Workspace Sound Rule.
public struct BailianWorkspaceID: Sendable, Equatable {
    public let rawValue: String

    public init(_ value: String) throws {
        let ascii = Array(value.utf8)
        guard (1...63).contains(ascii.count),
            ascii.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }),
            ascii.first != 45, ascii.last != 45
        else { throw AICueProviderError.invalidRequest }
        rawValue = value
    }

    package func endpoint(path: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = rawValue + ".cn-beijing.maas.aliyuncs.com"
        components.path = path
        return components.url!
    }
}
