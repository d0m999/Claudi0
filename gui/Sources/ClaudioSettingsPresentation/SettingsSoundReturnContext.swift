import ClaudioCore
import ClaudioGUICore

/// Presentation identity only. No config values or pack facts are cached across destinations.
package struct SettingsSoundReturnContext: Equatable {
    package let route: EventSettingsWindowRoute
}
