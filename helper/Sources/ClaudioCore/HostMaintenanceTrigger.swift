public enum HostMaintenanceTrigger: Sendable {
    case startup, wake, activation, fileChanged, discoveryFallback, intentChanged, userRetry
}
