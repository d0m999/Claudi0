import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation

@MainActor
func runSettingsNativeMigrationSuites() {
    suite("原生验收偏好：临时根读回、独立实例和策略值均隔离") {
        withTempDirectory { root in
            let file = root.appendingPathComponent("preferences.plist")
            let first = SettingsFixtureDefaults(file: file)
            let injected: UserDefaults = first
            let second = SettingsFixtureDefaults(file: root.appendingPathComponent("other.plist"))
            first.set("en", forKey: ClaudioAppLanguage.defaultsKey)
            injected.set(true, forKey: "fixture.enabled")
            expect(
                SettingsFixtureDefaults(file: file).string(forKey: ClaudioAppLanguage.defaultsKey)
                    == "en",
                "必须从临时文件读取实际保留值")
            expect(
                first.bool(forKey: "fixture.enabled") && !second.bool(forKey: "fixture.enabled"),
                "私有偏好不能跨实例继承")
            expect(
                SettingsFixtureDefaults(file: file).bool(forKey: "fixture.enabled"),
                "基类注入的 Bool 写入必须进入临时文件")
            first.removeObject(forKey: "fixture.enabled")
            expect(
                SettingsFixtureDefaults(file: file).object(forKey: "fixture.enabled") == nil,
                "清除值必须写回同一文件")
            let fixture = SettingsPresentationFixtures.generalLogin(
                temporaryParent: root, route: .destination(.notifications),
                experienceProfile: PreviewFixtures.SettingsExperienceScenario
                    .notificationsPermissionRequired.profile)
            let quiet = fixture.quietPresentation
            expect(
                quiet.focusIsEnabled && quiet.calendarIsEnabled
                    && quiet.focusAuthorization == .denied
                    && quiet.calendarAuthorization == .denied,
                "权限失败场景必须保留已开启策略，不能退回策略关闭")
        }
    }
    suite("设置迁移提示：沿用既有键且写入隔离偏好域") {
        let firstName = "ClaudioMigrationFirst.\(UUID())"
        let secondName = "ClaudioMigrationSecond.\(UUID())"
        guard let first = UserDefaults(suiteName: firstName),
            let second = UserDefaults(suiteName: secondName)
        else {
            expect(false, "必须创建隔离偏好域"); return
        }
        defer {
            first.removePersistentDomain(forName: firstName)
            second.removePersistentDomain(forName: secondName)
        }
        let firstOwner = ClaudioPreferences(defaults: first)
        let secondOwner = ClaudioPreferences(defaults: second)
        expect(
            !firstOwner.hasSeenWorkspaceMigration && !secondOwner.hasSeenWorkspaceMigration,
            "新域不继承日常设置中的迁移确认")
        firstOwner.acknowledgeWorkspaceMigration()
        expect(
            first.bool(forKey: "claudio.workspace-migration-notice-seen")
                && !secondOwner.hasSeenWorkspaceMigration, "确认只修改对应域内原有键")
        expect(
            ClaudioPreferences(defaults: first).hasSeenWorkspaceMigration,
            "重新挂载读取已保存确认")
    }

    suite("设置登录项：显式重新检测采用实际系统状态且不发起写入") {
        let observation = SettingsMigrationLoginObservation()
        let session = SettingsPresentationSession(
            dependencies: SettingsPresentationDependencies(
                preferences: ClaudioPreferences(defaults: UserDefaults()),
                loginItemSettings: LoginItemSettingsModel(
                    adapter: makeLoginItemServiceAdapter(
                        status: { observation.state },
                        setEnabled: { _ in
                            observation.writes += 1; return observation.state
                        }))),
            actions: SettingsPresentationActions { _ in .unavailable })
        observation.state = .requiresApproval
        _ = session.send(.refreshLoginItemState)
        expect(
            session.state.loginItemRegistration == .requiresApproval && observation.writes == 0,
            "检测不能把等待批准伪装成启用，也不能重复注册")
        observation.state = .unavailable
        _ = session.send(.refreshLoginItemState)
        expect(
            session.state.loginItemRegistration == .unavailable && observation.writes == 0,
            "不可用事实和恢复入口来自同一 owner")
        _ = session.send(.performPlatformAction(.openFocusSettings))
        expect(
            session.state.platformActionFailure == .openFocusSettings,
            "打开系统设置失败必须通过真实 typed result 呈现")
    }
}

@MainActor
private final class SettingsMigrationLoginObservation {
    var state: LoginItemRegistrationState = .disabled
    var writes = 0
}
