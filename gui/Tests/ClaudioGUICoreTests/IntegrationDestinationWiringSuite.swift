import Foundation

private func integrationDestinationSource(_ relativePath: String) -> String? {
    try? String(
        contentsOf: guiTestRepositoryRoot().appendingPathComponent(relativePath),
        encoding: .utf8)
}

@MainActor
func runIntegrationDestinationWiringSuites() {
    suite("集成 destination executable wiring：系统 adapter 留在 ClaudioGUI，核心 owner 由唯一组合根持有") {
        guard
            let menu = integrationDestinationSource(
                "gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let composition = integrationDestinationSource(
                "gui/Sources/ClaudioGUICore/PanelAppComposition.swift")
        else {
            expect(false, "缺少 MenuBar composition source")
            return
        }
        let stripped = strippingComments(menu)
        let composed = strippingComments(composition)
        expect(
            stripped.unmodeledConstructs.isEmpty && composed.unmodeledConstructs.isEmpty,
            "MenuBar 与核心组合根 source scanner 必须完成解析")
        let code = stripped.codeWithoutStringLiterals
        let composedCode = composed.codeWithoutStringLiterals
        expect(
            composedCode.components(separatedBy: "IntegrationDestinationModel(").count - 1 == 1
                && code.components(separatedBy: "PanelAppComposition(").count - 1 == 1
                && !code.contains("IntegrationDestinationModel(")
                && code.contains("IntegrationDestinationClipboardAdapter.system")
                && !code.contains("IntegrationsWindowController"),
            "唯一构造与系统 adapter 普查保留；refresh/action 和 store 发布由组合行为检查保护")
        expect(
            menu.contains("ClaudioPaths.claudeSettingsFile.path")
                && menu.contains("ClaudioPaths.codexHooksFile.path")
                && menu.contains("ClaudioPaths.workBuddySettingsFile.path"),
            "宿主配置路径只能由 executable composition root 注入")
    }

    suite("固定基线门禁：脚本、harness 与文档使用当前 Integration Destination suites") {
        guard
            let gate = integrationDestinationSource("scripts/verify-settings-experience.sh"),
            let harness = integrationDestinationSource(
                "gui/Tests/ClaudioGUICoreTests/main.swift"),
            let acceptance = integrationDestinationSource(
                "docs/settings-experience-acceptance.md")
        else {
            expect(false, "缺少固定基线门、GUI harness 或验收文档")
            return
        }
        let currentSuites = [
            (
                entrypoint: "runIntegrationDestinationPresentationSuites",
                documented: "IntegrationDestinationPresentationSuite"
            ),
            (
                entrypoint: "runIntegrationDestinationModelSuites",
                documented: "IntegrationDestinationModelSuite"
            ),
            (
                entrypoint: "runIntegrationDestinationWiringSuites",
                documented: "IntegrationDestinationWiringSuite"
            ),
            (
                entrypoint: "runEventSettingsWindowSelectionSuites",
                documented: "EventSettingsWindowSelectionSuite"
            ),
            (
                entrypoint: "runSettingsPresentationLifecycleSuites",
                documented: "SettingsPresentationLifecycleSuite"
            ),
            (
                entrypoint: "runSettingsPresentationTargetSuites",
                documented: "SettingsPresentationTargetSuite"
            ),
            (
                entrypoint: "runSettingsPresentationSliceSuites",
                documented: "SettingsPresentationTargetSuite"
            ),
        ]
        for suiteName in currentSuites {
            expect(
                gate.contains(suiteName.entrypoint),
                "固定基线门必须要求 \(suiteName.entrypoint)")
            expect(
                harness.contains("\(suiteName.entrypoint)()"),
                "GUI harness 必须注册 \(suiteName.entrypoint)")
            expect(
                acceptance.contains(suiteName.documented),
                "验收文档必须列出 \(suiteName.documented)")
        }
        expect(
            !gate.contains("runIntegrationsWindowWiringSuites")
                && !gate.contains("runEventSettingsDestinationCoordinatorSuites")
                && !acceptance.contains("IntegrationsWindowWiringSuite")
                && !acceptance.contains("EventSettingsDestinationCoordinatorSuite")
                && !acceptance.contains("SettingsPresentationCharacterizationSuite"),
            "已删除的 Window/Coordinator/Characterization suite 不得残留在门禁或当前验收文档")
    }
}
