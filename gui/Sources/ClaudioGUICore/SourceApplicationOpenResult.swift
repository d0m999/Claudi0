public enum SourceApplicationOpenResult: Sendable, Equatable {
    case idle, started, opened, unavailable, failed, timedOut, cancelled
}
