import Foundation

/// No source strings are retained here. Each result belongs to the complete captured action.
public struct SessionNavigationFeedback: Sendable, Equatable {
    public var result: SessionNavigationActionResult
    public var applicationResult: SourceApplicationOpenResult

    public init(
        result: SessionNavigationActionResult = .idle,
        applicationResult: SourceApplicationOpenResult = .idle
    ) {
        self.result = result
        self.applicationResult = applicationResult
    }
}
