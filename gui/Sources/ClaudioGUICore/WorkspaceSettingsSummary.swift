import ClaudioCore
import Foundation

/// The list reads the same complete profiles as the editor, without changing the selected scope.
package struct WorkspaceSettingsSummary: Equatable, Sendable {
    package let packID: String
    package let volume: Double
    package let enabledEventCount: Int
    package let applicableSurfaceCount: Int?

    package init?(scope: PanelSoundScopeID, config: ClaudioConfig) {
        let profile: WorkspaceSoundProfile
        switch scope {
        case .global:
            profile = WorkspaceSoundProfile(
                selectedPack: config.selectedPack,
                volume: config.masterVolume,
                events: Dictionary(
                    uniqueKeysWithValues: Event.allCases.map { ($0.cliName, config.isEnabled($0)) })
            )
            applicableSurfaceCount = nil
        case .workspace(let id):
            guard let rule = config.workspaceRules.first(where: { $0.id == id }),
                let completeProfile = rule.profile, completeProfile.isValid
            else { return nil }
            profile = completeProfile
            applicableSurfaceCount = rule.surfaces.count
        case .surface: return nil
        }
        packID = profile.selectedPack
        volume = profile.volume
        enabledEventCount = Event.allCases.filter { profile.events[$0.cliName] == true }.count
    }
}
