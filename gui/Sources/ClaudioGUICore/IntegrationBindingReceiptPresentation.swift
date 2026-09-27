import ClaudioCore
import ClaudioLocalization

/// 只读逐绑定投影；能力覆盖与宿主 ready 不能代替这一绑定的回执。
public struct IntegrationBindingReceiptPresentation: Identifiable, Sendable, Equatable {
    public var id: HostEventBindingID { binding.id }
    public let binding: HostCapabilityBinding
    public let activation: HostActivationEvidence

    public init(binding: HostCapabilityBinding, snapshot: HostIntegrationSnapshot?) {
        self.binding = binding
        guard let snapshot, snapshot.configuration == .configured,
            let installationID = snapshot.installationID
        else {
            activation = .none
            return
        }
        if case .observed(let evidence) = snapshot.activation(for: binding),
            evidence.bindingID == binding.id, evidence.installationID == installationID,
            evidence.event == binding.event, evidence.nativeEvent == binding.nativeEvent
        {
            activation = .observed(evidence)
        } else {
            activation = .awaitingReceipt(installationID: installationID)
        }
    }

    public func text(language: ClaudioAppLanguage) -> String {
        let l10n = ClaudioL10n(language: language)
        let key: ClaudioL10nKey
        switch activation {
        case .none: key = .integrationsBindingNoReceipt
        case .awaitingReceipt: key = .integrationsBindingAwaitingReceipt
        case .observed: key = .integrationsBindingCurrentReceipt
        }
        let name =
            binding.qualification == .questionIntentOnly
            ? "\(l10n.text(.eventNoticeQuestionIntent)) (\(binding.nativeEvent ?? ""))"
            : binding.nativeEvent ?? binding.event.rawValue
        return l10n.format(key, name)
    }

    public func capabilityText(language: ClaudioAppLanguage) -> String {
        let l10n = ClaudioL10n(language: language)
        let supportKey: ClaudioL10nKey
        switch (binding.support, binding.implementation) {
        case (.supported, .implemented): supportKey = .panelCapabilitySupported
        case (.partial, .implemented): supportKey = .panelCapabilityPartial
        case (.unsupported, .implemented): supportKey = .panelCapabilityUnsupported
        case (.supported, .notImplemented): supportKey = .panelCapabilitySupportedNotImplemented
        case (.partial, .notImplemented): supportKey = .panelCapabilityPartialNotImplemented
        case (.unsupported, .notImplemented): supportKey = .panelCapabilityUnsupportedNotImplemented
        }
        let qualification = localizedQualification(
            binding.qualification.map(defaultQualificationText), language: language)
        return [l10n.text(supportKey), qualification].compactMap { $0 }.joined(separator: " · ")
    }
}
