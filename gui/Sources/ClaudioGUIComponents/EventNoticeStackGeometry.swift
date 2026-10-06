import Combine
import Foundation

/// Presentation measurements and screen constraints only; no notice or reading state lives here.
@MainActor
public final class EventNoticeStackGeometry: ObservableObject {
    @Published public var width: Double = 440
    @Published public var queueHeight: Double = 220
    public init() {}
}
