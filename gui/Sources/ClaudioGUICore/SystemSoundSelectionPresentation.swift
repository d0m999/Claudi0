import ClaudioCore
import ClaudioLocalization
import Foundation

public func localizedSystemSoundSelectionError(
    _ error: SystemSoundSelectionError, language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    let reason: String
    switch error {
    case .unavailable(let name):
        reason = l10n.format(.eventSettingsSystemSoundUnavailable, name)
    case .outdatedHelper:
        return l10n.text(.eventSettingsCurrentHelperRequired)
    case .configFailure:
        reason = l10n.text(.workspaceSaveFailed)
    case .publishedConflict:
        reason = l10n.text(.eventSettingsSoundChoiceConflict)
    case .lockBusy:
        reason = l10n.text(.panelErrorLockBusy)
    case .lockFailed:
        reason = l10n.text(.panelErrorLockFailed)
    }
    return l10n.format(.eventSettingsSoundChoiceFailed, reason)
}
