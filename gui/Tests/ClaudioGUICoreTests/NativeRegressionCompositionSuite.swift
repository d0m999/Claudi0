import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@testable import ClaudioSettingsPresentation

/// Crosses the same composition and fixture interfaces as the native regression executable.
/// External effects use the injected adapters; the dedicated bundle verifies executable wiring.
@MainActor
func runNativeRegressionCompositionSuites() async {
    await suite("Native regression composition：fixture 与 session 借用同一批核心 owner") {
        await withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{"selected_pack":"pack-a","master_volume":0.7}"#, to: configFile)
            writeFixture(
                #"{"id":"pack-a","name":"Before","events":{"stop":"stop.mp3"}}"#,
                to: root.appendingPathComponent("packs/pack-a/manifest.json"))
            writeFixture("audio", to: root.appendingPathComponent("packs/pack-a/stop.mp3"))
            let defaults = SettingsFixtureDefaults(
                file: root.appendingPathComponent("preferences.plist"))
            let builder = CompositionFixture(root: root, defaults: defaults)
            let composition = try! builder.build(
                integrationRefreshFeedback: .localized(
                    key: .feedbackHostStateUpdated, arguments: []))
            let fixture = SettingsPresentationFixtures.generalLogin(
                temporaryParent: root, route: .destination(.eventsAndSounds),
                eventSettingsModel: composition.eventSettingsModel,
                soundPacksEditor: composition.soundPacksEditorOwner,
                aiCueViewModel: composition.aiCueViewModel,
                hostIntegrations: composition.hostIntegrations,
                integrationsModel: composition.integrationsModel,
                preferences: composition.preferences,
                activityDiagnostics: composition.activityDiagnostics,
                globalShortcutSettings: composition.globalShortcutSettings,
                aboutSettings: composition.aboutSettings)
            defer { fixture.session.send(.windowWillClose) }
            let dependencies = fixture.session.dependencies
            expect(dependencies.preferences === composition.preferences, "偏好只借用组合根实例")
            expect(
                dependencies.eventSettingsModel === composition.eventSettingsModel,
                "配置 controller 只借用组合根实例")
            expect(
                dependencies.soundPacksEditorOwner === composition.soundPacksEditorOwner,
                "编辑 owner 只借用组合根实例")
            expect(dependencies.aiCueViewModel === composition.aiCueViewModel, "AI 模型只借用工厂返回实例")
            expect(
                dependencies.hostIntegrations === composition.hostIntegrations,
                "回执 presentation store 只借用组合根实例")
            expect(dependencies.integrationsModel === composition.integrationsModel, "集成模型只借用组合根实例")
            expect(
                dependencies.activityDiagnostics === composition.activityDiagnostics,
                "活动 owner 只借用工厂实例")
            expect(
                dependencies.globalShortcutSettings === composition.globalShortcutSettings,
                "快捷键不得被 gallery 默认模型替代")
            expect(
                dependencies.aboutSettings === composition.aboutSettings, "About 不得被 gallery 默认模型替代"
            )
            expect(
                dependencies.eventSettingsModel.soundScopeSelection
                    === composition.soundScopeSelection,
                "面板、设置与快捷键消费同一个声音作用域选择")

            await composition.integrationsModel.perform(.redetect)
            await composition.integrationsModel.perform(.redetect)
            expect(
                fixture.hostIntegrations.content == fixture.integrationsModel.content
                    && fixture.integrationsModel.feedback?.text
                        == .localized(
                            key: .feedbackHostStateUpdated, arguments: []),
                "未绑定 router 的 fixture 刷新使用同一 store 与类型化文案")
            await fixture.integrationsModel.perform(.connect(.claudeCode))
            expect(
                fixture.hostIntegrations.content == composition.integrationsModel.content,
                "受控连接动作继续通过同一发布回退")

            _ = await composition.soundPackLibrary.refreshSnapshot(trigger: .initial)
            await composition.soundPacksEditorOwner.waitForMutationTransactionsToQuiesceForTesting()
            expect(
                await nativeCompositionWait {
                    fixture.eventSettingsModel.selectedPackMetadata.displayName == "Before"
                }, "fixture 面板接收共享库初次结果")
            fixture.session.send(.route(.sounds(.editEvent(packID: "pack-a", event: .stop))))
            writeFixture(
                #"{"id":"pack-a","name":"After","events":{"stop":"stop.mp3"}}"#,
                to: root.appendingPathComponent("packs/pack-a/manifest.json"))
            composition.soundPackLibrary.invalidate(packIDs: ["pack-a"])
            _ = await composition.soundPackLibrary.refreshSnapshot(trigger: .retry)
            await composition.soundPacksEditorOwner.waitForMutationTransactionsToQuiesceForTesting()
            expect(
                await nativeCompositionWait {
                    guard case .sounds(let sounds) = fixture.soundPacksEditor.presentation.mode
                    else { return false }
                    return fixture.eventSettingsModel.selectedPackMetadata.displayName == "After"
                        && sounds.packs.first(where: { $0.id == "pack-a" })?.name == "After"
                }, "fixture/session 与面板接收同一次刷新")

            let missing = UUID()
            composition.soundScopeSelection.select(.workspace(missing))
            let bytes = try! Data(contentsOf: configFile)
            expect(fixture.eventSettingsModel.setMasterVolume(0.2) == nil, "共享失效工作区拒写")
            expect(try! Data(contentsOf: configFile) == bytes, "失效工作区不能写默认组")
            fixture.aiCueViewModel.begin(packID: "pack-a", event: .stop)
            fixture.session.send(.route(.destination(.general)))
            expect(fixture.aiCueViewModel.session == nil, "离页清理由共享 session 结束同一个 AI 模型")
        }
    }

    suite("Native regression composition：文件 defaults 使快捷键、作用域与偏好隔离并可重开") {
        withTempDirectory { root in
            let file = root.appendingPathComponent("preferences.plist")
            let defaults = SettingsFixtureDefaults(file: file)
            let workspace = UUID()
            var config = ClaudioConfig(selectedPack: "pack-a")
            config.workspaceRules = [
                WorkspaceSoundRule(
                    id: workspace,
                    directory: WorkspaceDirectory(
                        kind: .directory, path: root.appendingPathComponent("workspace").path),
                    surfaces: [.codex],
                    profile: WorkspaceSoundProfile(selectedPack: "pack-a", volume: 0.7))
            ]
            let configFile = root.appendingPathComponent("config.json")
            try! JSONEncoder().encode(config).write(to: configFile)
            let builder = CompositionFixture(root: root, defaults: defaults)
            let composition = try! builder.build()
            composition.preferences.setLanguage(.zhHans)
            composition.soundScopeSelection.select(.workspace(workspace))
            composition.globalShortcutSettings.replace(
                .togglePanel, keyCode: 40, modifiers: [.command, .option])
            let persisted = defaults.data(forKey: globalShortcutDefaultsKey(.togglePanel))
            expect(persisted != nil, "快捷键 Data 读取必须使用注入文件，不能读空的命名 domain")
            // 先持久化一个有效工作区，再让它在重开前失效；未知工作区的临时选择按合同不落盘。
            config.workspaceRules = []
            try! JSONEncoder().encode(config).write(to: configFile)
            let reopenedDefaults = SettingsFixtureDefaults(file: file)
            expect(
                reopenedDefaults.data(forKey: globalShortcutDefaultsKey(.togglePanel)) == persisted,
                "重开文件 defaults 保留快捷键 Data")
            let reopenedBuilder = CompositionFixture(root: root, defaults: reopenedDefaults)
            let reopened = try! reopenedBuilder.build()
            expect(reopened.preferences.language == .zhHans, "重开只读隔离语言值")
            expect(
                reopened.soundScopeSelection.projection.scope == .workspace(workspace),
                "重开保留失效作用域身份，不回落默认组")
            expect(
                reopened.globalShortcutSettings.state(for: .togglePanel).shortcut?.keyCode == 40,
                "快捷键恢复从同一隔离文件读取")
        }
    }

    suite("Native regression composition：未注入的画廊保持既有快捷键与 About 默认行为") {
        let fixture = SettingsPresentationFixtures.generalLogin()
        defer { fixture.session.send(.windowWillClose) }
        expect(
            fixture.session.dependencies.globalShortcutSettings.state(for: .togglePanel).shortcut
                == nil,
            "默认画廊快捷键仍为空")
        let expected = makeSettingsFixtureAboutSettings(for: nil)
        expect(
            fixture.session.dependencies.aboutSettings.bundleFacts == expected.bundleFacts,
            "默认画廊继续使用同一个 About fixture 工厂")
    }
}

@MainActor
private func nativeCompositionWait(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}
