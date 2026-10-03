import Combine

/// Presentation-only visibility, supplied by the retained native window owner.
@MainActor
public final class EventAnimationVisibility: ObservableObject {
    @Published public var isVisible: Bool

    public init(isVisible: Bool = true) { self.isVisible = isVisible }
}
