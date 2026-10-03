import ClaudioCore
import ClaudioGUICore
import Foundation

/// Keeps the production config-lock identity in the app composition layer while allowing the
/// retained event-settings window to use the same config read/write owner as the menu-bar panel.
/// C1：调用方（`MenuBarController`）注入 app 生命周期的 `SoundScopeSelection`，面板与设置窗口
/// 由此共享同一个选择事实；`nil` 只发生在测试，落一个隔离 fixture owner。
@MainActor
func makeEventSettingsConfigController(
    configFile: URL,
    environment: AudioImportEnvironment,
    soundPackLibrary: SoundPackLibrary,
    bundledHelper: URL?,
    soundPacksRefreshCoordinator: SoundPacksRefreshCoordinator,
    soundScopeSelection: SoundScopeSelection? = nil,
    afterFullReload: @escaping @MainActor (ClaudioConfig) -> Void
) -> PanelConfigController {
    PanelConfigController(
        configFile: configFile,
        lockFile: ClaudioPaths.configLockFile,
        environment: environment,
        soundPackLibrary: soundPackLibrary,
        afterFullReload: afterFullReload,
        soundPacksRefreshCoordinator: soundPacksRefreshCoordinator,
        soundScopeSelection: soundScopeSelection)
}
