import ClaudioCore
import ClaudioLocalization
import Foundation

public enum IntegrationAutomaticState: Sendable, Equatable {
    case notInstalled, disabled, preparing, updating, prepared, received
    case intentUnavailable
    case blocked(String)

    public init(snapshot: HostIntegrationSnapshot) {
        if snapshot.availability == .notInstalled { self = .notInstalled; return }
        if snapshot.intentUnavailable { self = .intentUnavailable; return }
        if snapshot.intent?.enabled == false { self = .disabled; return }
        if case .unavailable(let reason) = snapshot.availability { self = .blocked(reason); return }
        if case .failed(let reason) = snapshot.operation { self = .blocked(reason); return }
        if snapshot.runtime != .ready {
            switch snapshot.runtime {
            case .unavailable(let reason), .damaged(let reason): self = .blocked(reason)
            case .ready: self = .preparing
            }
            return
        }
        if snapshot.operation == .connecting {
            self = snapshot.installationID == nil ? .preparing : .updating
            return
        }
        if case .unreadable(let reason) = snapshot.configuration { self = .blocked(reason); return }
        if case .conflict(let reason) = snapshot.configuration { self = .blocked(reason); return }
        guard snapshot.intent?.enabled == true else { self = .disabled; return }
        guard snapshot.configuration == .configured else { self = .preparing; return }
        let received = HostCapabilityCatalog.bindings(for: snapshot.host).contains {
            if case .observed = snapshot.activation(for: $0) { return true }
            return false
        }
        self = received ? .received : .prepared
    }

    public func text(language: ClaudioAppLanguage) -> String {
        let l10n = ClaudioL10n(language: language)
        switch self {
        case .notInstalled: return l10n.text(.integrationsAutoNotInstalled)
        case .disabled: return l10n.text(.integrationsAutoDisabled)
        case .preparing: return l10n.text(.integrationsAutoPreparing)
        case .updating: return l10n.text(.integrationsAutoUpdating)
        case .prepared: return l10n.text(.integrationsAutoPrepared)
        case .received: return l10n.text(.integrationsAutoReceived)
        case .intentUnavailable: return l10n.text(.integrationsAutoIntentUnavailable)
        case .blocked(let reason): return reason
        }
    }
}
