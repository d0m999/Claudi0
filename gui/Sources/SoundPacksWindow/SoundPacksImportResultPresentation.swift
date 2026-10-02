import ClaudioGUICore
import ClaudioLocalization
import Foundation

/// Resolves the existing owner's terminal activity at display time. No disk reads or duplicate
/// operation state: the same result survives announcement acknowledgement and language changes.
@MainActor
package func soundPacksImportResultText(
    _ activity: SoundPackEditorActivityPresentation,
    language: ClaudioAppLanguage
) -> String? {
    guard activity.kind == .importAudio else { return nil }
    let completion: SoundPackEditorOperationCompletion
    switch activity.phase {
    case .busy: return nil
    case .succeeded: completion = .succeeded
    case .failed(let failure): completion = .failed(failure)
    case .partial(let accepted, let rejected):
        completion = .partial(accepted: accepted, rejected: rejected)
    case .orphan(_, let failure): completion = .orphan(failure)
    case .cancelled(let changed): completion = .cancelled(changedOnDisk: changed)
    }
    let l10n = ClaudioL10n(language: language)
    let summary = soundPacksEditorOperationAnnouncement(
        kind: .importAudio, completion: completion, language: language)
    var text = (activity.packID.map { $0 + ": " } ?? "") + summary
    if case .orphan(_, let failure) = activity.phase {
        switch failure {
        case .cancelled:
            text +=
                "\n"
                + l10n.format(
                    .soundPacksAnnouncementOperationCancelled, l10n.text(.soundPacksStatusAddAudio))
        case .targetChanged:
            text += "\n" + l10n.text(.soundPacksImportTargetChanged)
        default:
            text += "\n" + l10n.text(.soundPacksImportBindingFailed)
        }
    }
    if let outcome = activity.importOutcome {
        for file in outcome.accepted {
            text += "\n" + l10n.format(.soundPacksImportSaved, file.fileName)
        }
        for file in outcome.rejected {
            text += "\n" + file.sourceFileName + ": " + importRejectionText(file.reason, l10n: l10n)
        }
        if let event = outcome.boundEvent, let file = outcome.accepted.last {
            text += "\n" + localizedEventName(event, language: language) + " → " + file.fileName
        }
        if outcome.orphan != nil || (!outcome.accepted.isEmpty && outcome.boundEvent == nil) {
            text += "\n" + l10n.text(.soundPacksImportAssignSaved)
        }
    }
    return text
}

private func importRejectionText(_ reason: DropRejectionReason, l10n: ClaudioL10n) -> String {
    switch reason {
    case .oversize(let actual, let maximum):
        return l10n.format(.soundPacksImportOversize, "\(actual)", "\(maximum)")
    case .nonWhitelistFormat:
        return l10n.text(.soundPacksImportFormat)
    case .pathTraversal:
        return l10n.text(.soundPacksImportUnsafeName)
    case .overDuration(let actual, let maximum):
        guard let actual, actual.isFinite else {
            return l10n.text(.soundPacksImportUnknownDuration)
        }
        return l10n.format(
            .soundPacksImportDuration, String(format: "%.1f", actual),
            String(format: "%.1f", maximum))
    case .builtinReadOnly:
        return l10n.text(.soundPacksAudioErrorBuiltinReadOnly)
    case .copyFailed:
        return l10n.text(.soundPacksImportCopyFailed)
    case .lockBusy:
        return l10n.text(.soundPacksBindErrorLockBusy)
    case .lockFailed(let code):
        return l10n.format(.soundPacksBindErrorLockFailed, "\(code)")
    }
}
