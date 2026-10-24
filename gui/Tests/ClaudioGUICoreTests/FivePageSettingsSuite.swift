import ClaudioCore
import ClaudioGUICore
import Foundation

@testable import ClaudioSettingsPresentation

@MainActor
func runFivePageSettingsSuites() {
    suite("Five-page settings：visible order is independent of compatibility routes") {
        let visible: [SettingsDestination] = [
            .eventsAndSounds, .sounds, .integrations, .notifications, .general,
        ]
        expect(SettingsDestination.sidebarCases == visible, "五项侧栏顺序固定")
        expect(
            settingsSidebarSections(availableDestinations: SettingsDestination.allCases)
                .map(\.destinations) == [Array(visible.prefix(4)), [.general]], "间距分组只分前四项和通用")
        expect(
            settingsWindowFocusOrder(selectedDestination: .usage).prefix(5)
                == visible.map(SettingsWindowFocusTarget.sidebar)[...], "焦点顺序共用五页投影")
        expect(
            settingsSidebarDestination(
                moving: .next, from: .usage,
                availableDestinations: SettingsDestination.allCases) == .notifications,
            "诊断的侧栏归属为连接")
        expect(
            (try? JSONDecoder().decode(SettingsDestination.self, from: Data("\"display\"".utf8)))
                == .general,
            "历史 display 请求解码进入通用")
        for old in [SettingsDestination.about, .shortcuts] {
            expect(
                resolveSettingsRoute(.destination(old), availability: .empty).route
                    == .destination(.general), "旧路由进入通用")
        }
    }
    suite("Five-page settings：legacy persisted values are projected without repair") {
        for raw in ["about", "shortcuts", "display", "usage"] {
            let defaults = SoundScopeSelectionFixtureDefaults()
            defaults.set(raw, forKey: SettingsDestination.defaultsKey)
            let preferences = ClaudioPreferences(defaults: defaults)
            expect(
                preferences.lastSettingsDestination == (raw == "usage" ? .usage : .general),
                "历史值恢复到实际页面")
            expect(preferences.recoveryIssues.isEmpty, "历史值不是配置损坏")
            expect(
                defaults.string(forKey: SettingsDestination.defaultsKey) == raw,
                "恢复不主动改写旧值")
        }
    }
    suite("Five-page settings：diagnostics retain real history and reading position") {
        let fixture = SettingsPresentationFixtures.generalLogin(route: .destination(.integrations))
        let session = fixture.session
        defer { session.send(.windowWillClose) }
        session.send(.route(.destination(.usage)))
        let bookmark = SettingsReadingBookmark(
            focusIdentifier: "diagnostics", relativeScrollPosition: 0.6)
        session.send(.rememberReading(bookmark, stamp: session.navigationHistory.stamp!))
        session.send(.route(.destination(.general)))
        session.send(.goBack)
        expect(session.state.routeResolution.destination == .usage, "后退保留真实诊断页")
        expect(session.navigationHistory.current?.bookmark == bookmark, "恢复诊断阅读位置")
        session.send(.goBack)
        expect(session.state.routeResolution.destination == .integrations, "再后退到连接")
        session.send(.goForward)
        expect(session.state.routeResolution.destination == .usage, "前进仍是诊断")
    }
    suite("Five-page settings：list history preserves the shared sound scope") {
        for restoringForward in [false, true] {
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: "/fixture/example"),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.4))
            let scope = PanelSoundScopeID.workspace(rule.id)
            let target = WorkspaceSoundWriteTarget(rule: rule)
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .destination(.eventsAndSounds), workspaceRules: [rule])
            let session = fixture.session
            defer { session.send(.windowWillClose) }
            let bookmark = SettingsReadingBookmark(
                focusIdentifier: "workspace.row.\(rule.id)", relativeScrollPosition: 0.6)
            session.send(.rememberReading(bookmark, stamp: session.navigationHistory.stamp!))
            session.send(.navigateWorkspace(.init(scope: scope, workspaceTarget: target)))
            expect(
                fixture.eventSettingsModel.selectedSoundScope == scope
                    && fixture.eventSettingsModel.selectedWorkspaceTarget == target,
                "显式工作区详情选中共享作用域并捕获写目标")
            if restoringForward {
                session.send(.selectSidebar(.eventsAndSounds))
                expect(
                    fixture.eventSettingsModel.selectedSoundScope == scope,
                    "侧栏返回列表保留共享选择")
                session.send(.rememberReading(bookmark, stamp: session.navigationHistory.stamp!))
                session.send(.goBack)
            }
            session.send(restoringForward ? .goForward : .goBack)
            expect(
                session.state.routeResolution.route == .destination(.eventsAndSounds)
                    && session.state.eventPresentation.route.detail == .workspaces,
                "历史恢复工作区列表而非打开默认组详情")
            expect(
                fixture.eventSettingsModel.selectedSoundScope == scope
                    && fixture.eventSettingsModel.selectedWorkspaceTarget == target,
                "\(restoringForward ? "前进" : "后退")恢复列表不得将共享写目标切回默认组")
            expect(
                session.state.navigationRestoration?.bookmark == bookmark,
                "恢复列表保留阅读书签")
            fixture.eventSettingsModel.selectSoundScope(.global)
            session.send(restoringForward ? .goBack : .goForward)
            expect(
                fixture.eventSettingsModel.selectedSoundScope == scope
                    && fixture.eventSettingsModel.selectedWorkspaceTarget == target
                    && session.state.eventPresentation.route.detail == .configuration,
                "历史恢复工作区详情仍显式选择捕获目标")
            session.send(.navigateWorkspace(.init(scope: .global)))
            expect(
                fixture.eventSettingsModel.selectedSoundScope == .global
                    && session.state.eventPresentation.route.detail == .configuration,
                "显式默认组详情仍能切换共享选择")
        }
    }
    suite("Five-page settings：About is a stamped modal attached to General") {
        let fixture = SettingsPresentationFixtures.generalLogin(route: .destination(.general))
        let session = fixture.session
        defer { session.send(.windowWillClose) }
        let count = session.navigationHistory.entries.count
        session.send(.route(.destination(.about)))
        guard let stamp = session.aboutPresentation else { expect(false, "显式关于请求展示表单"); return }
        expect(session.state.routeResolution.destination == .general, "关于没有独立目的页")
        expect(session.navigationHistory.entries.count == count, "关于不新增历史目的页")
        session.send(.route(.destination(.sounds)))
        expect(session.state.routeResolution.destination == .general, "表单阻断外层导航")
        session.send(.dismissAbout(stamp))
        session.send(.setNavigationBlocked(id: "native-sheet", blocked: false))
        expect(
            session.state.navigationRestoration?.bookmark.focusIdentifier
                == "settings.general.about",
            "原生 sheet 迟到解除阻断不能覆盖显式归焦")
        expect(session.destinationFocusRequests.requestedTarget == .aboutEntry, "关闭归焦关于入口")
        session.send(.route(.destination(.sounds)))
        session.send(.dismissAbout(stamp))
        expect(session.state.routeResolution.destination == .sounds, "迟到关闭不能覆盖新导航")
        session.send(.route(.destination(.shortcuts)))
        expect(
            session.state.routeResolution.destination == .general
                && session.aboutPresentation == nil,
            "旧快捷键请求只进入通用")
    }
    suite("Five-page settings：workspace summaries derive complete independent profiles") {
        var config = ClaudioConfig(selectedPack: "default", masterVolume: 0.4)
        let id = UUID()
        let profile = WorkspaceSoundProfile(
            selectedPack: "custom", volume: 0.7,
            events: Dictionary(
                uniqueKeysWithValues: Event.allCases.map { ($0.cliName, $0 != .stop) }))
        config.workspaceRules = [
            WorkspaceSoundRule(
                id: id,
                directory: WorkspaceDirectory(kind: .directory, path: "/fixture/example"),
                surfaces: [.codex], profile: profile)
        ]
        let summary = WorkspaceSettingsSummary(scope: .workspace(id), config: config)
        expect(
            summary?.packID == "custom" && summary?.volume == 0.7
                && summary?.enabledEventCount == 4 && summary?.applicableSurfaceCount == 1,
            "摘要包、音量、五事件与适用来源来自同一规则")
        config.workspaceRules.removeAll()
        expect(
            WorkspaceSettingsSummary(scope: .workspace(id), config: config) == nil,
            "失效规则不从默认组借用摘要")
    }
    suite("Five-page settings：retired global keys have no registration or persistence consumer") {
        let root = guiTestRepositoryRoot()
        for file in [
            "gui/Sources/ClaudioGUICore/GlobalShortcuts.swift",
            "gui/Sources/ClaudioGUI/CarbonGlobalShortcutAdapter.swift",
            "gui/Sources/ClaudioSettingsPresentation/ShortcutSettingsView.swift",
        ] {
            expect(
                !FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path),
                "退役模块必须移除")
        }
        for file in [
            "gui/Sources/ClaudioGUICore/PanelAppComposition.swift",
            "gui/Sources/ClaudioGUI/MenuBarController.swift",
        ] {
            let source = try! String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            expect(
                !source.contains("GlobalShortcut") && !source.contains("RegisterEventHotKey"),
                "组合根不再读取或注册旧绑定")
        }
    }
}
