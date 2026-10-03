import ClaudioLocalization
import Foundation

public enum EventAnimationStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case original, mechanicalDuck, pixelGhost, bitcoin

    public var id: String { rawValue }

    public var localizationKey: ClaudioL10nKey {
        switch self {
        case .original: .eventAnimationOriginal
        case .mechanicalDuck: .eventAnimationMechanicalDuck
        case .pixelGhost: .eventAnimationPixelGhost
        case .bitcoin: .eventAnimationBitcoin
        }
    }
}

public struct EventAnimationPreferences: Codable, Sendable, Equatable {
    public var style: EventAnimationStyle
    public var showsCharacter: Bool
    public var usesStaticExpression: Bool

    public init(
        style: EventAnimationStyle = .original, showsCharacter: Bool = true,
        usesStaticExpression: Bool = false
    ) {
        self.style = style
        self.showsCharacter = showsCharacter
        self.usesStaticExpression = usesStaticExpression
    }

    public static let defaultValue = Self()
    public static let defaultsKey = "Claudio.Notifications.EventAnimation"
    public var effectiveStyle: EventAnimationStyle { showsCharacter ? style : .original }
}
