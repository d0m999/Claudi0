import Foundation

package enum SettingsNavigationFocus: Equatable, Sendable {
    case sidebar
    case content
    case restore
}

/// Shell and destination focus share this version. A delayed request cannot take newer focus.
package struct SettingsNavigationRestoration: Equatable, Sendable {
    package let stamp: SettingsNavigationStamp
    package let location: SettingsLocation
    package let bookmark: SettingsReadingBookmark
    package let focus: SettingsNavigationFocus
    package init(
        stamp: SettingsNavigationStamp, location: SettingsLocation,
        bookmark: SettingsReadingBookmark, focus: SettingsNavigationFocus
    ) {
        self.stamp = stamp; self.location = location; self.bookmark = bookmark; self.focus = focus
    }
}

package struct SettingsChromeProjection: Equatable, Sendable {
    package let destination: SettingsDestination
    package let title: String
    package let navigationEnabled: Bool
    package let canGoBack: Bool
    package let canGoForward: Bool
    package init(
        destination: SettingsDestination, title: String, navigationEnabled: Bool,
        canGoBack: Bool, canGoForward: Bool
    ) {
        self.destination = destination; self.title = title;
        self.navigationEnabled = navigationEnabled
        self.canGoBack = canGoBack; self.canGoForward = canGoForward
    }
}
