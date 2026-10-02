import ClaudioCore
import ClaudioLocalization
import Foundation

/// Historical installation identity is separate from binding activation evidence.
package enum IntegrationReceiptHistoryGeneration: Sendable, Equatable {
    case current
    case previous
    case unknown
}

/// Only the existing redacted receipt DTO crosses this presentation seam.
package struct IntegrationReceiptHistoryEntryPresentation: Identifiable, Sendable, Equatable {
    package let receipt: HostHookReceipt
    package let generation: IntegrationReceiptHistoryGeneration
    package var id: String {
        "\(receipt.installationID):\(receipt.bindingID.rawValue):\(receipt.timestamp.timeIntervalSince1970)"
    }

    package func text(language: ClaudioAppLanguage) -> String {
        let l10n = ClaudioL10n(language: language)
        let key: ClaudioL10nKey
        switch generation {
        case .current: key = .integrationsReceiptHistoryCurrent
        case .previous: key = .integrationsReceiptHistoryPrevious
        case .unknown: key = .integrationsReceiptHistoryUnknown
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(localizedEventName(receipt.semanticEvent, language: language))"
            + " (\(receipt.nativeEvent)) · \(formatter.string(from: receipt.timestamp)) · "
            + "\(l10n.text(key)) · "
            + localizedPlaybackResult(receipt.playbackResult, language: language)
    }
}

/// One Surface's bounded safe snapshot; history never changes current activation.
package struct IntegrationReceiptHistoryPresentation: Sendable, Equatable {
    package let entries: [IntegrationReceiptHistoryEntryPresentation]
    package let state: HostHookReceiptHistoryState

    package init(
        host: HostID,
        snapshot: HostIntegrationSnapshot?,
        history: HostHookReceiptHistorySnapshot
    ) {
        state = history.state
        let installationID = snapshot?.host == host ? snapshot?.installationID : nil
        entries = history.receipts.filter { $0.host == host }.map { receipt in
            IntegrationReceiptHistoryEntryPresentation(
                receipt: receipt,
                generation: installationID.map {
                    $0 == receipt.installationID ? .current : .previous
                } ?? .unknown)
        }
    }
}
