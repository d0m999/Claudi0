import ClaudioCore
import ClaudioLocalization
import Combine
import Foundation

extension SettingsDestination {
    public static let defaultsKey = "Claudio.Settings.LastDestination"

    /// Top-level destinations with production content today. Later destination migrations extend
    /// this list when their real views ship; DEBUG galleries inject `allCases` explicitly.
    public static let availableCases: [SettingsDestination] = allCases

}

public enum ClaudioPreferenceRecoveryIssue: String, Sendable, Hashable {
    case invalidLanguageMode
    case invalidSettingsDestination
    case invalidIntegrationSurface
    case invalidEventSourcePromptVisibility
    case invalidEventAnimation
}

/// One atomic projection of the Settings preferences currently owned by Claudio. New preference
/// fields belong here only when their destination ships; consumers observe one coherent value.
public struct ClaudioPreferenceSnapshot: Sendable, Equatable {
    public fileprivate(set) var languageMode: ClaudioLanguageMode
    public fileprivate(set) var language: ClaudioAppLanguage
    public fileprivate(set) var lastSettingsDestination: SettingsDestination
    public fileprivate(set) var lastIntegrationSurface: HostSurfaceID
    public fileprivate(set) var showsEventSourcePrompts: Bool
    public fileprivate(set) var eventAnimation: EventAnimationPreferences
    public fileprivate(set) var recoveryIssues: Set<ClaudioPreferenceRecoveryIssue>

    public init(
        languageMode: ClaudioLanguageMode,
        language: ClaudioAppLanguage,
        lastSettingsDestination: SettingsDestination,
        lastIntegrationSurface: HostSurfaceID = .claudeCode,
        showsEventSourcePrompts: Bool = true,
        eventAnimation: EventAnimationPreferences = .defaultValue,
        recoveryIssues: Set<ClaudioPreferenceRecoveryIssue> = []
    ) {
        self.languageMode = languageMode
        self.language = language
        self.lastSettingsDestination = lastSettingsDestination
        self.lastIntegrationSurface = lastIntegrationSurface
        self.showsEventSourcePrompts = showsEventSourcePrompts
        self.eventAnimation = eventAnimation
        self.recoveryIssues = recoveryIssues
    }
}

/// App-lifetime typed preference owner shared by every visible consumer. Publishing one snapshot
/// keeps language mode, its resolved projection, navigation restoration, and recovery state
/// mutually consistent for SwiftUI and AppKit observers.
@MainActor
public final class ClaudioPreferences: ObservableObject {
    @Published public private(set) var snapshot: ClaudioPreferenceSnapshot
    public let availableSettingsDestinations: [SettingsDestination]

    public var languageMode: ClaudioLanguageMode { snapshot.languageMode }
    public var language: ClaudioAppLanguage { snapshot.language }
    public var lastSettingsDestination: SettingsDestination {
        snapshot.lastSettingsDestination
    }
    public var lastIntegrationSurface: HostSurfaceID { snapshot.lastIntegrationSurface }
    public var showsEventSourcePrompts: Bool { snapshot.showsEventSourcePrompts }
    public var eventAnimation: EventAnimationPreferences { snapshot.eventAnimation }
    public var recoveryIssues: Set<ClaudioPreferenceRecoveryIssue> {
        snapshot.recoveryIssues
    }

    private let defaults: UserDefaults
    private let preferredLanguageIdentifiers: @MainActor () -> [String]
    private var localeCancellable: AnyCancellable?

    /// Reuses the existing acknowledgement key in this owner's injected defaults domain.
    package var hasSeenWorkspaceMigration: Bool {
        defaults.bool(forKey: "claudio.workspace-migration-notice-seen")
    }

    package func acknowledgeWorkspaceMigration() {
        defaults.set(true, forKey: "claudio.workspace-migration-notice-seen")
    }

    public init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        availableSettingsDestinations: [SettingsDestination] = SettingsDestination.availableCases,
        preferredLanguageIdentifiers: @escaping @MainActor () -> [String] = {
            Locale.preferredLanguages
        }
    ) {
        self.defaults = defaults
        self.preferredLanguageIdentifiers = preferredLanguageIdentifiers
        let legalDestinations =
            availableSettingsDestinations.isEmpty
            ? [.general] : availableSettingsDestinations
        self.availableSettingsDestinations = legalDestinations

        let languageObject = defaults.object(forKey: ClaudioAppLanguage.defaultsKey)
        let languageRawValue = languageObject as? String
        let languageMode = ClaudioLanguageMode(storedValue: languageRawValue)
        let destinationObject = defaults.object(forKey: SettingsDestination.defaultsKey)
        let destinationRawValue = destinationObject as? String
        let parsedDestination = destinationRawValue.flatMap(SettingsDestination.init(rawValue:))
        let destination =
            parsedDestination.flatMap {
                legalDestinations.contains($0) ? $0 : nil
            } ?? .general
        let integrationSurfaceObject = defaults.object(
            forKey: Self.integrationSurfaceDefaultsKey)
        let integrationSurfaceRawValue = integrationSurfaceObject as? String
        let parsedIntegrationSurface = integrationSurfaceRawValue.flatMap(
            HostSurfaceID.init(rawValue:))
        let legalIntegrationSurfaces = Set(HostID.productVisibleCases.map(\.surfaceID))
        let integrationSurface =
            parsedIntegrationSurface.flatMap {
                legalIntegrationSurfaces.contains($0) ? $0 : nil
            } ?? .claudeCode
        let eventSourcePromptObject = defaults.object(
            forKey: Self.eventSourcePromptsDefaultsKey)
        let showsEventSourcePrompts =
            (eventSourcePromptObject as? Bool) ?? (eventSourcePromptObject == nil)
        var recoveryIssues: Set<ClaudioPreferenceRecoveryIssue> = []
        let animationObject = defaults.object(forKey: EventAnimationPreferences.defaultsKey)
        let animation = (animationObject as? Data).flatMap {
            try? JSONDecoder().decode(EventAnimationPreferences.self, from: $0)
        }
        if animationObject != nil, animation == nil {
            recoveryIssues.insert(.invalidEventAnimation)
        }
        if languageObject != nil {
            if let languageRawValue {
                if ClaudioLanguageMode(rawValue: languageRawValue) == nil {
                    recoveryIssues.insert(.invalidLanguageMode)
                }
            } else {
                recoveryIssues.insert(.invalidLanguageMode)
            }
        }
        if destinationObject != nil {
            if let destinationRawValue {
                // The retired Display route is a valid historical value. Keep it on disk while
                // projecting General; only unknown or damaged values need a recovery notice.
                if destinationRawValue != "display",
                    SettingsDestination(rawValue: destinationRawValue).map(
                        legalDestinations.contains) != true
                {
                    recoveryIssues.insert(.invalidSettingsDestination)
                }
            } else {
                recoveryIssues.insert(.invalidSettingsDestination)
            }
        }
        if eventSourcePromptObject != nil, eventSourcePromptObject is Bool == false {
            recoveryIssues.insert(.invalidEventSourcePromptVisibility)
        }
        if integrationSurfaceObject != nil {
            if integrationSurfaceRawValue != nil {
                if parsedIntegrationSurface.map(legalIntegrationSurfaces.contains) != true {
                    recoveryIssues.insert(.invalidIntegrationSurface)
                }
            } else {
                recoveryIssues.insert(.invalidIntegrationSurface)
            }
        }

        snapshot = ClaudioPreferenceSnapshot(
            languageMode: languageMode,
            language: languageMode.resolvedLanguage(
                preferredLanguageIdentifiers: preferredLanguageIdentifiers()),
            lastSettingsDestination: destination,
            lastIntegrationSurface: integrationSurface,
            showsEventSourcePrompts: showsEventSourcePrompts,
            eventAnimation: animation ?? .defaultValue,
            recoveryIssues: recoveryIssues)

        localeCancellable =
            notificationCenter
            .publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .sink { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshSystemLanguage()
                }
            }
    }

    #if DEBUG
    /// State-gallery initializer that does not read or observe the app's real preferences.
    public convenience init(previewLanguage: ClaudioAppLanguage) {
        self.init(
            defaults: UserDefaults(),
            notificationCenter: NotificationCenter(),
            availableSettingsDestinations: SettingsDestination.allCases,
            preferredLanguageIdentifiers: { [previewLanguage.rawValue] })
        setLanguage(previewLanguage)
    }
    #endif

    public func setLanguageMode(_ languageMode: ClaudioLanguageMode) {
        let language = languageMode.resolvedLanguage(
            preferredLanguageIdentifiers: preferredLanguageIdentifiers())
        var next = snapshot
        next.languageMode = languageMode
        next.language = language
        next.recoveryIssues.remove(.invalidLanguageMode)
        guard next != snapshot else { return }
        defaults.set(languageMode.rawValue, forKey: ClaudioAppLanguage.defaultsKey)
        snapshot = next
    }

    /// Compatibility entry point for the existing compact language control. Choosing either
    /// product language there remains an explicit preference, never an implicit system value.
    public func setLanguage(_ language: ClaudioAppLanguage) {
        switch language {
        case .zhHans: setLanguageMode(.zhHans)
        case .english: setLanguageMode(.english)
        }
    }

    public func setLastSettingsDestination(_ destination: SettingsDestination) {
        guard availableSettingsDestinations.contains(destination) else { return }
        var next = snapshot
        next.lastSettingsDestination = destination
        next.recoveryIssues.remove(.invalidSettingsDestination)
        guard next != snapshot else { return }
        defaults.set(destination.rawValue, forKey: SettingsDestination.defaultsKey)
        snapshot = next
    }

    /// Persist only a product-visible Surface. Unknown, AX-only, and future diagnostic values
    /// fail closed and leave the stored value untouched; initialization likewise never repairs a
    /// damaged defaults entry behind the user's back.
    public func setLastIntegrationSurface(_ surface: HostSurfaceID) {
        guard HostID.productVisibleCases.contains(where: { $0.surfaceID == surface }) else {
            var next = snapshot
            next.recoveryIssues.insert(.invalidIntegrationSurface)
            guard next != snapshot else { return }
            snapshot = next
            return
        }
        var next = snapshot
        next.lastIntegrationSurface = surface
        next.recoveryIssues.remove(.invalidIntegrationSurface)
        guard next != snapshot else { return }
        defaults.set(surface.rawValue, forKey: Self.integrationSurfaceDefaultsKey)
        snapshot = next
    }

    public func setShowsEventSourcePrompts(_ showsPrompts: Bool) {
        var next = snapshot
        next.showsEventSourcePrompts = showsPrompts
        next.recoveryIssues.remove(.invalidEventSourcePromptVisibility)
        guard next != snapshot else { return }
        defaults.set(showsPrompts, forKey: Self.eventSourcePromptsDefaultsKey)
        snapshot = next
    }

    /// Only explicit user changes replace damaged or future stored data.
    public func setEventAnimation(_ animation: EventAnimationPreferences) {
        guard let data = try? JSONEncoder().encode(animation) else { return }
        var next = snapshot
        next.eventAnimation = animation
        next.recoveryIssues.remove(.invalidEventAnimation)
        guard next != snapshot else { return }
        defaults.set(data, forKey: EventAnimationPreferences.defaultsKey)
        snapshot = next
    }

    public func selectEventAnimationStyle(_ style: EventAnimationStyle) {
        var next = eventAnimation
        next.style = style
        next.showsCharacter = true
        setEventAnimation(next)
    }

    private func refreshSystemLanguage() {
        guard snapshot.languageMode == .system else { return }
        let language = snapshot.languageMode.resolvedLanguage(
            preferredLanguageIdentifiers: preferredLanguageIdentifiers())
        guard language != snapshot.language else { return }
        var next = snapshot
        next.language = language
        snapshot = next
    }

    public static let integrationSurfaceDefaultsKey = "Claudio.Settings.LastIntegrationSurface"
    public static let eventSourcePromptsDefaultsKey = "Claudio.Notifications.EventSourcePrompts"
}
