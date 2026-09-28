import ClaudioCore

/// Captured complete binding used by the manifest writer's compare-and-set check.
public enum ManifestEventBindingExpectation: Sendable, Equatable {
    case unmapped
    case mapped(source: PackEventSoundSource)

    public static func mapped(fileName: String) -> Self { .mapped(source: .file(fileName)) }
}
