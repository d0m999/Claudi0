import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runIntegrationAgentSectionSuites() {
    suite("集成 Agent 分组：桌面应用在前、命令行工具在后，组内保持 productVisibleCases 顺序") {
        let content = integrationDestinationTestContent()
        let sections = integrationAgentSections(agents: content.agents)
        expect(
            sections.map(\.kind) == [.desktop, .cli],
            "分组顺序必须固定为桌面应用 → 命令行工具")
        expect(
            sections.first(where: { $0.kind == .desktop })?.agents.map(\.host) == [.workBuddy],
            "桌面应用组只包含 WorkBuddy")
        expect(
            sections.first(where: { $0.kind == .cli })?.agents.map(\.host)
                == HostID.productVisibleCases.filter { $0 != .workBuddy },
            "命令行工具组包含其余全部产品宿主，顺序与 productVisibleCases 一致")
        expect(
            sections.flatMap(\.agents).map(\.host)
                == [.workBuddy] + HostID.productVisibleCases.filter { $0 != .workBuddy },
            "分组输出为桌面组 + 命令行组，组内保持既有顺序且不漏不重")
    }

    suite("集成 Agent 分组：空组不生成 section") {
        let content = integrationDestinationTestContent()
        let cliOnly = integrationAgentSections(
            agents: content.agents.filter { $0.host != .workBuddy })
        expect(
            cliOnly.map(\.kind) == [.cli],
            "没有桌面宿主时不得出现空的桌面应用组")
        let desktopOnly = integrationAgentSections(
            agents: content.agents.filter { $0.host == .workBuddy })
        expect(
            desktopOnly.map(\.kind) == [.desktop],
            "没有命令行宿主时不得出现空的命令行工具组")
    }

    suite("集成 Agent 分组标题：中英目录条目成对") {
        for language in ClaudioAppLanguage.allCases {
            let expected: (desktop: String, cli: String) =
                language == .zhHans
                ? (desktop: "桌面应用", cli: "命令行工具")
                : (desktop: "Desktop apps", cli: "CLI tools")
            expect(
                integrationAgentSectionTitle(for: .desktop, language: language)
                    == expected.desktop,
                "\(language.rawValue) 桌面应用组标题必须为 \(expected.desktop)")
            expect(
                integrationAgentSectionTitle(for: .cli, language: language) == expected.cli,
                "\(language.rawValue) 命令行工具组标题必须为 \(expected.cli)")
        }
    }

    suite("集成表面类型：host→kind 映射唯一归属，AX identity 归为桌面") {
        for host: HostID in [.workBuddy, .chatGPTDesktopAX, .claudeDesktopAX] {
            expect(
                integrationToolKind(for: host) == .desktop,
                "\(host) 必须归为桌面应用")
        }
        for host: HostID in [.claudeCode, .codex, .opencode, .kimiCode] {
            expect(
                integrationToolKind(for: host) == .cli,
                "\(host) 必须归为命令行工具")
        }
    }
}
