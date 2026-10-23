import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation
import Foundation

@MainActor
func runSettingsScopePickerSuites() async {
    await suite("Workspace list：native actions retain typed routes and the captured write target") {
        let rule = WorkspaceSoundRule(
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/scope-picker"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.eventsAndSounds), workspaceRules: [rule])
        let session = fixture.session
        let probe = SettingsSoundsNativeLayoutProbe(
            session: session, size: NSSize(width: 960, height: 640))
        defer { probe.close() }
        await probe.settle()
        let configuration = fixture.eventSettingsModel.configState
        for scope in [PanelSoundScopeID.workspace(rule.id), .global, .workspace(rule.id)] {
            session.send(.selectSidebar(.eventsAndSounds))
            await probe.settle()
            let version = session.navigationHistory.version
            expect(probe.pressControl("workspace.rule.\(scope.storedValue)"), "列表原生按钮可进入详情")
            await probe.settle()
            expect(
                session.state.eventPresentation.route.scope == scope
                    && fixture.eventSettingsModel.selectedSoundScope == scope,
                "列表进入详情使用同一个共享选择 owner")
            expect(session.navigationHistory.version == version + 1, "列表点击只提交一次路由")
            if scope.workspaceID != nil {
                expect(
                    session.state.eventPresentation.route.workspaceTarget
                        == WorkspaceSoundWriteTarget(rule: rule),
                    "详情捕获已浏览规则的写目标")
            }
        }
        expect(
            fixture.eventSettingsModel.configState == configuration
                && fixture.actionRecorder.actions.isEmpty,
            "列表浏览不改声音配置，不执行平台副作用")
        session.send(.selectSidebar(.sounds))
        await probe.settle()
        expect(
            probe.menuAccessibilityElement(identifier: "settings.sounds.management-scope") == nil,
            "声音包页面不显示工作区选择器")
        expect(
            fixture.eventSettingsModel.selectedSoundScope == .workspace(rule.id),
            "浏览声音包不应用其他组或声音包")
        session.send(
            .navigateWorkspace(
                EventSettingsWindowRoute(
                    scope: .workspace(rule.id),
                    workspaceTarget: WorkspaceSoundWriteTarget(rule: rule))))
        session.editScopeSound(
            .editEvent(
                scope: .workspace(rule.id), packID: "settings-fixture-pack", event: .stop,
                workspaceTarget: WorkspaceSoundWriteTarget(rule: rule)))
        await probe.settle()
        expect(
            probe.menuAccessibilityElement(identifier: "settings.sounds.workspace-origin") != nil,
            "包详情显示当前工作区与事件来源")
        expect(probe.pressControl("settings.sounds.return-to-workspace"), "声音包详情提供可操作返回工作区按钮")
        await probe.settle()
        expect(
            session.state.eventPresentation.route.scope == .workspace(rule.id)
                && session.state.eventPresentation.route.event == .stop,
            "返回同一捕获目标并定位原事件，不应用声音包")
    }
}
