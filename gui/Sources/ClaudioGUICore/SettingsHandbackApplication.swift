import Foundation

package func resolveSettingsHandbackApplication<Application>(
    frontmostApplication: Application?,
    previousApplication: Application?,
    isCurrentApplication: (Application) -> Bool
) -> Application? {
    guard let frontmostApplication else { return nil }
    if isCurrentApplication(frontmostApplication) {
        return previousApplication
    }
    return frontmostApplication
}
