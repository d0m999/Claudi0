import Foundation

public struct ManualPreviewOrigin: Hashable, Sendable {
    public enum Category: Sendable { case panel, settings }
    public let category: Category
    private let identity = UUID()
    public init(_ category: Category) { self.category = category }
}

public struct ManualPreviewRequest: Hashable, Sendable {
    public let origin: ManualPreviewOrigin
    public let target: String
    public let run: ManualPreviewRun?
    fileprivate let identity = UUID()
    internal init(origin: ManualPreviewOrigin, target: String, run: ManualPreviewRun? = nil) {
        self.origin = origin
        self.target = target
        self.run = run
    }
}

public struct ManualPreviewRun: Hashable, Sendable {
    public let origin: ManualPreviewOrigin
    private let identity = UUID()
    internal init(origin: ManualPreviewOrigin) { self.origin = origin }
}
