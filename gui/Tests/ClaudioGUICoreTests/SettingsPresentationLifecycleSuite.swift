import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation
import Combine
import Foundation
import SoundPacksWindow
import SwiftUI

@MainActor
func runSettingsPresentationLifecycleSuites() async {
    suite("Settings executable deletion contract：controller 与 menu 不恢复第二 owner") {
        let root = guiTestRepositoryRoot()
        let controllerURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/SettingsWindowController.swift")
        let navigationURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUICore/SettingsNavigation.swift")
        let menuBarURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/MenuBarController.swift")
        guard
            let controller = try? String(contentsOf: controllerURL, encoding: .utf8),
            let navigation = try? String(contentsOf: navigationURL, encoding: .utf8),
            let menuBar = try? String(contentsOf: menuBarURL, encoding: .utf8)
        else {
            expect(false, "读不到 Settings controller/navigation/menu composition source")
            return
        }
        let scans = [controller, navigation, menuBar].map(strippingComments)
        guard scans.allSatisfy({ $0.unmodeledConstructs.isEmpty }) else {
            expect(false, "Settings executable source audit 遇到无法建模的构造")
            return
        }
        let controllerCode = scans[0].codeWithoutStringLiterals
        let navigationCode = scans[1].codeWithoutStringLiterals

        let forbiddenControllerOwners = [
            "SettingsWindowPresentationModel",
            "SoundPacksEditorOwner",
            "PanelConfigController",
            "EventSettingsWindowSelection",
            "HostIntegrationPresentationStore",
            "IntegrationDestinationModel",
            "AICueGenerationViewModel",
            "settingsSoundPackShellProjections(",
        ]
        expect(
            forbiddenControllerOwners.allSatisfy { !controllerCode.contains($0) },
            "AppKit controller 不得持有 destination model/publisher 或 raw Sound Pack owner")
        expect(
            controllerCode.contains(
                "SettingsNativeShellController(session: settingsPresentationSession)")
                && controllerCode.contains("window.contentViewController = content")
                && !controllerCode.contains("SettingsWindowView"),
            "唯一 native Settings controller 必须挂会话投影的原生外壳，不得回退旧树")
        expect(
            !navigationCode.contains("SettingsWindowPresentationModel<")
                && !navigationCode.contains("pendingHandback")
                && !navigationCode.contains("SettingsWindowLifecycle")
                && !navigationCode.contains("SettingsWindowPresentation"),
            "ClaudioGUICore 不得恢复旧泛型 handback 或 lifecycle facade")
        let mutation = menuBar.replacingOccurrences(
            of: "let selectedHost = host ?? integrationsModel.selectedHost ?? .claudeCode",
            with:
                "_ = integrationsModel.selectHost(.claudeCode)\n"
                + "        let selectedHost = host ?? integrationsModel.selectedHost ?? .claudeCode"
        )
        expect(
            settingsMenuRequestOwnsOnlyTypedRoute(menuBar)
                && !settingsMenuRequestOwnsOnlyTypedRoute(mutation),
            "MenuBar 只能构造 typed route；Host 选择 mutation 必须由 session 单事务拥有")
    }

    suite("Settings executable gallery：所有场景只经 target-owned production root mount") {
        let galleryURL = guiTestRepositoryRoot().appendingPathComponent(
            "gui/Sources/ClaudioGUI/StateGalleryView.swift")
        guard let gallery = try? String(contentsOf: galleryURL, encoding: .utf8) else {
            expect(false, "读不到 executable StateGalleryView.swift")
            return
        }
        let scanned = strippingComments(gallery)
        guard scanned.unmodeledConstructs.isEmpty else {
            expect(false, "State gallery source audit 遇到无法建模的构造")
            return
        }
        let code = scanned.codeWithoutStringLiterals
        let forbiddenDirectMounts = [
            "EventSettingsWindowView(",
            "EventSettingsAICueServiceCard(",
            "EventSettingsAICueCredentialSheet(",
            "EventSettingsAICueComposerView(",
            "IntegrationsSettingsDestinationView(",
            "EventSettingsWindowSelection(",
            "SoundPacksWindowModel(",
        ]
        expect(
            code.components(separatedBy: "SettingsStateGalleryView(").count - 1 == 1
                && forbiddenDirectMounts.allSatisfy { !code.contains($0) },
            "gallery 必须只组合 target-owned SettingsStateGalleryView，不得直接重建 destination/model")
    }

    suite("Settings native announcement adapter：deferred exact-head post/ack 与 key retry") {
        let controllerURL = guiTestRepositoryRoot().appendingPathComponent(
            "gui/Sources/ClaudioGUI/SettingsWindowController.swift")
        guard let controller = try? String(contentsOf: controllerURL, encoding: .utf8) else {
            expect(false, "读不到唯一 Settings native announcement adapter")
            return
        }
        let missingLatchGuard = controller.replacingOccurrences(
            of: "guard !settingsPresentationAnnouncementDeliveryScheduled else { return }",
            with: "")
        let eagerHeadRead = controller.replacingOccurrences(
            of:
                "settingsPresentationAnnouncementDeliveryScheduled = true\n"
                + "        DispatchQueue.main.async",
            with:
                "settingsPresentationAnnouncementDeliveryScheduled = true\n"
                + "        _ = settingsPresentationSession.state.pendingAnnouncement\n"
                + "        DispatchQueue.main.async")
        let missingKeyGate = controller.replacingOccurrences(
            of: "window.isKeyWindow\n        else { return }",
            with: "true\n        else { return }")
        let missingNativePost = controller.replacingOccurrences(
            of: "NSAccessibility.post(",
            with: "settingsNativePostWasDeleted(")
        let missingKeyRetry = settingsReplacingFirstOccurrence(
            in: controller,
            of:
                "_ = settingsPresentationSession.send(.windowPhaseChanged(.key))\n"
                + "        scheduleSettingsPresentationAnnouncementDelivery()",
            with: "_ = settingsPresentationSession.send(.windowPhaseChanged(.key))")

        expect(
            settingsNativeAnnouncementAdapterIsSound(controller)
                && !settingsNativeAnnouncementAdapterIsSound(missingLatchGuard)
                && !settingsNativeAnnouncementAdapterIsSound(eagerHeadRead)
                && !settingsNativeAnnouncementAdapterIsSound(missingKeyGate)
                && !settingsNativeAnnouncementAdapterIsSound(missingNativePost)
                && !settingsNativeAnnouncementAdapterIsSound(missingKeyRetry),
            "窄 adapter contract 必须 fail closed，并杀死 latch/head/gate/post/key-retry mutations")
    }

    #if DEBUG
    suite("Settings sound entrance session：首次默认、手选工作区与失效目标") {
        let first = SettingsPresentationFixtures.generalLogin(
            route: .destination(.integrations))
        let firstSession = first.session
        expect(
            firstSession.state.eventPresentation.route.scope == .global
                && firstSession.send(.route(.destination(.eventsAndSounds))) == .routed
                && firstSession.state.routeResolution.route == .destination(.eventsAndSounds)
                && firstSession.state.eventPresentation.route.scope == .global
                && first.eventSettingsModel.selectedSoundScope == .global,
            "首次从集成进入声音设置应使用默认组")

        let rule = WorkspaceSoundRule(
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/sound-entrance"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.eventsAndSounds), workspaceRules: [rule])
        let session = fixture.session
        let selected = PanelSoundScopeID.workspace(rule.id)
        fixture.eventSettingsSelection.select(EventSettingsWindowRoute(scope: selected))
        fixture.eventSettingsModel.selectSoundScope(selected)
        let configBefore = fixture.eventSettingsModel.configState

        expect(
            session.send(.route(.events(scope: selected, event: .stop))) == .routed
                && session.state.eventPresentation.focusTarget == .event(.stop),
            "显式事件深链必须聚焦所选工作区的事件")
        _ = session.send(.route(.destination(.integrations)))
        expect(
            session.send(.route(.destination(.eventsAndSounds))) == .routed
                && session.state.eventPresentation.route.event == .stop
                && session.state.eventPresentation.focusTarget == .scope(selected)
                && settingsWindowRequestedFocusTarget(resolution: session.state.routeResolution)
                    == nil,
            "旧事件深链后从集成通用入口返回必须聚焦当前作用域")
        expect(
            session.send(.route(.events(scope: selected, event: nil))) == .routed
                && session.state.eventPresentation.focusTarget == .scope(selected),
            "显式工作区深链必须聚焦该工作区行")

        for host in HostID.productVisibleCases {
            expect(
                session.send(
                    .route(.integrations(IntegrationsSettingsRoute(surface: host.surfaceID))))
                    == .routed
                    && fixture.integrationsModel.selectedHost == host,
                "应能分别从每个 Host 的集成页测试声音入口")
            expect(
                session.send(.route(.destination(.eventsAndSounds))) == .routed
                    && session.state.routeResolution.route == .destination(.eventsAndSounds)
                    && session.state.eventPresentation.route.scope == selected
                    && fixture.integrationsModel.selectedHost == host
                    && fixture.eventSettingsModel.selectedSoundScope == selected
                    && session.state.eventPresentation.focusTarget == .scope(selected)
                    && fixture.eventSettingsModel.configState == configBefore,
                "集成所选 Host 不得重选或写入手动声音作用域")
        }

        session.replaceAvailabilityForTesting(
            SettingsRouteAvailability(
                integrationSurfaces: Set(HostID.productVisibleCases.map(\.surfaceID)),
                eventScopes: [.global], soundScopes: [.global], soundPackIDs: [],
                events: Set(Event.allCases)))
        _ = session.send(.route(.integrations(IntegrationsSettingsRoute(surface: .codex))))
        expect(
            session.send(.route(.destination(.eventsAndSounds)))
                == .rejected(.staleSoundScope(selected))
                && session.state.eventPresentation.route.scope == selected
                && session.state.eventPresentation.route
                    .unavailableRequestedScopeStoredValue == selected.storedValue
                && settingsWindowRequestedFocusTarget(resolution: session.state.routeResolution)
                    == .routeFailure(.eventsAndSounds)
                && fixture.eventSettingsModel.selectedSoundScope == selected
                && fixture.eventSettingsModel.configState == configBefore,
            "失效工作区由普通入口保留为不可用目标，不静默切到可写默认组")
        expect(
            session.send(.route(.events(scope: selected, event: .stop)))
                == .rejected(.staleSoundScope(selected))
                && session.state.eventPresentation.route.scope == selected
                && settingsWindowRequestedFocusTarget(resolution: session.state.routeResolution)
                    == .routeFailure(.eventsAndSounds),
            "显式工作区／事件深链接仍必须按可用性拒绝")
    }

    suite("Settings shared sound selection：已打开页面跟随面板切换并结束旧目标活动") {
        let rule = WorkspaceSoundRule(
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/shared-selection"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.eventsAndSounds), workspaceRules: [rule])
        let session = fixture.session
        let selection = fixture.eventSettingsSelection
        let model = fixture.eventSettingsModel
        let workspace = PanelSoundScopeID.workspace(rule.id)
        let target = WorkspaceSoundWriteTarget(rule: rule)
        let focusDebt = session.state.focusDebt
        let routeRevision = session.state.explicitRouteRequestRevision
        let configBefore = model.configState
        fixture.beginEventTransientActivity()

        // The menu panel changes this same app-lifetime controller, without navigating Settings.
        model.selectSoundScope(workspace)

        expect(
            model.selectedSoundScope == workspace && selection.route.scope == workspace
                && selection.route.workspaceTarget == target
                && session.state.eventPresentation.route == selection.route
                && selection.unavailableRequestedScopeStoredValue == nil,
            "面板选择现有工作区后，已打开页面必须同步共享选择与钉定写目标，不能留下不可写的默认组")
        expect(
            selection.presentationState.previewState == .idle
                && selection.presentationState.aiSessionState == .idle
                && fixture.aiCueViewModel.session == nil,
            "共享作用域切换必须结束旧目标的试听与 AI 会话")
        if case .events(let editor) = fixture.soundPacksEditor.presentation.mode {
            expect(editor.route == selection.route, "已激活 Events editor 必须跟随新作用域")
        } else {
            expect(false, "面板切换作用域后必须保留 Events editor")
        }
        expect(
            session.state.focusDebt == focusDebt
                && session.state.explicitRouteRequestRevision == routeRevision
                && model.configState == configBefore,
            "共享选择投影不能伪造导航、抢焦点或写入声音配置")

        _ = session.send(.route(.events(scope: workspace, event: .stop)))
        model.selectSoundScope(.global)
        expect(
            selection.route == EventSettingsWindowRoute(scope: .global)
                && session.state.eventPresentation.route == selection.route
                && session.state.routeResolution.route == .events(scope: .global, event: nil),
            "从工作区事件深链切回默认组时，保留页面与外壳路由都必须跟随共享选择")
    }

    suite("Settings Sounds AI：面板换组保留包级凭据弹窗与候选试听") {
        for scenario in [PreviewFixtures.AICueGalleryScenario.elevenLabsMissing, .playing] {
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: "/fixture/sounds-ai-scope"),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
            let adapter = SettingsLifecycleAudioAdapter()
            let nativeEffects = SoundPacksEditorNativeEffectsDispatcher(adapter: adapter)
            let fixture = SettingsPresentationFixtures.generalLogin(
                workspaceRules: [rule], aiCueScenario: scenario, nativeEffects: nativeEffects)
            let session = fixture.session
            let before = session.state
            let aiSession = fixture.aiCueViewModel.session
            let generationID = fixture.aiCueViewModel.generation?.id
            let configBefore = fixture.eventSettingsModel.configState
            expect(
                before.activeDestination == .sounds
                    && (before.eventPresentation.credentialSheetIsPresented
                        || before.eventPresentation.playingCandidateID != nil),
                "回归必须先建立声音页的真实凭据弹窗或候选试听状态")
            if let candidateID = before.eventPresentation.playingCandidateID {
                let candidate = fixture.aiCueViewModel.generation?.candidates.first {
                    $0.id == candidateID
                }
                guard let candidate else {
                    expect(false, "试听候选必须属于当前包级 generation")
                    continue
                }
                expect(
                    nativeEffects.playAICueCandidate(candidate, volume: 0.7) == 0.25,
                    "候选试听必须经 retained native effects seam 启动")
            }

            fixture.eventSettingsModel.selectSoundScope(.workspace(rule.id))

            expect(
                session.state.eventPresentation.route.scope == .workspace(rule.id)
                    && session.state.eventPresentation.route.workspaceTarget
                        == WorkspaceSoundWriteTarget(rule: rule),
                "声音页保持打开时，隐藏事件页仍须跟随共享作用域")
            expect(
                session.state.eventPresentation.credentialSheetIsPresented
                    == before.eventPresentation.credentialSheetIsPresented
                    && session.state.eventPresentation.playingCandidateID
                        == before.eventPresentation.playingCandidateID
                    && adapter.stopCount == 0,
                "面板换组不能关闭声音页凭据弹窗，或清空仍在播放的包级候选标识")
            expect(
                session.state.activeDestination == .sounds
                    && session.state.routeResolution == before.routeResolution
                    && session.state.focusDebt == before.focusDebt
                    && session.state.explicitRouteRequestRevision
                        == before.explicitRouteRequestRevision
                    && fixture.aiCueViewModel.session == aiSession
                    && fixture.aiCueViewModel.generation?.id == generationID
                    && fixture.eventSettingsModel.configState == configBefore,
                "切换使用作用域不改变包级 AI 目标、候选、设置导航或配置")

            var damaged = configBefore.resolvedConfig
            damaged.workspaceRules[0].profile = nil
            fixture.eventSettingsModel.soundScopeSelection.applyConfig(damaged)
            expect(
                session.state.eventPresentation.route.unavailableRequestedScopeStoredValue
                    == PanelSoundScopeID.workspace(rule.id).storedValue
                    && session.state.eventPresentation.credentialSheetIsPresented
                        == before.eventPresentation.credentialSheetIsPresented
                    && session.state.eventPresentation.playingCandidateID
                        == before.eventPresentation.playingCandidateID
                    && adapter.stopCount == 0
                    && fixture.aiCueViewModel.session == aiSession
                    && fixture.aiCueViewModel.generation?.id == generationID,
                "使用作用域失效只更新隐藏事件页，不能终止健康用户包的 AI 交互")
            fixture.eventSettingsModel.soundScopeSelection.applyConfig(configBefore.resolvedConfig)
            expect(
                session.state.eventPresentation.route.unavailableRequestedScopeStoredValue == nil
                    && session.state.eventPresentation.credentialSheetIsPresented
                        == before.eventPresentation.credentialSheetIsPresented
                    && session.state.eventPresentation.playingCandidateID
                        == before.eventPresentation.playingCandidateID,
                "使用作用域恢复也不能重新选择或清理包级 AI 交互")

            if scenario == .playing {
                _ = session.send(.route(.destination(.general)))
            } else {
                _ = session.send(.windowWillClose)
            }
            expect(
                !session.state.eventPresentation.credentialSheetIsPresented
                    && session.state.eventPresentation.playingCandidateID == nil
                    && fixture.aiCueViewModel.session == nil
                    && fixture.aiCueViewModel.generation == nil
                    && adapter.stopCount == (scenario == .playing ? 1 : 0),
                "真正离开声音页或关闭窗口仍须清理弹窗和候选，并恰好一次停止试听")
        }
    }

    suite("Settings shared sound selection：同目录配置修复后保留页面恢复可用") {
        withTempDirectory { root in
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: root.path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
            let workspace = PanelSoundScopeID.workspace(rule.id)
            let target = WorkspaceSoundWriteTarget(rule: rule)
            var config = ClaudioConfig(selectedPack: "settings-fixture-pack", masterVolume: 0.2)
            config.workspaceRules = [rule]
            var damaged = config
            damaged.workspaceRules[0].profile = nil
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(try! JSONEncoder().encode(damaged), to: configFile)
            let model = PanelConfigController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"),
                environment: makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true)))
            let fixture = SettingsPresentationFixtures.generalLogin(
                temporaryParent: root, route: .destination(.eventsAndSounds),
                workspaceRules: [rule], eventSettingsModel: model)
            let session = fixture.session
            let selection = fixture.eventSettingsSelection
            model.selectSoundScope(workspace)
            let unavailableProjection = model.soundScopeSelection.projection
            expect(
                unavailableProjection.staleness == .invalidRule
                    && unavailableProjection.isAvailable && model.workspaceError == .invalidRule
                    && selection.route.workspaceTarget == target
                    && selection.unavailableRequestedScopeStoredValue == workspace.storedValue,
                "先证明设置正在跟随共享选择的损坏工作区，而不是显式失效深链")
            let focusDebt = session.state.focusDebt
            let routeRevision = session.state.explicitRouteRequestRevision

            let repairedBytes = try! JSONEncoder().encode(config)
            writeFixture(repairedBytes, to: configFile)
            // Reopening the menu panel reloads this same app-lifetime controller from disk.
            model.reload()
            let restored = model.soundScopeSelection.projection
            expect(
                restored.scope == workspace && restored.writeTarget == target
                    && restored.staleness == .current && restored.isAvailable
                    && restored.persistedStoredValue == unavailableProjection.persistedStoredValue
                    && model.workspaceError == nil && model.config.masterVolume == 0.7,
                "同目录配置修复须由共享 owner 恢复可用，不重新选择或重钉目标")
            expect(
                selection.unavailableRequestedScopeStoredValue == nil
                    && session.state.eventPresentation.route == selection.route
                    && session.state.eventPresentation.route
                        .unavailableRequestedScopeStoredValue == nil,
                "共享选择恢复后，设置必须立即清除旧不可用标记，不能仍禁止编辑")
            expect(
                selection.route.scope == workspace && selection.route.workspaceTarget == target
                    && session.state.focusDebt == focusDebt
                    && session.state.explicitRouteRequestRevision == routeRevision
                    && (try? Data(contentsOf: configFile)) == repairedBytes,
                "恢复投影保留工作区目标，不伪造导航、抢焦点或修改修复后的配置")
            model.selectSoundScope(workspace)
            expect(
                model.soundScopeSelection.projection == restored
                    && selection.unavailableRequestedScopeStoredValue == nil,
                "面板同项选择仍为 no-op，设置恢复不能依赖重新发布")

            let detailRoute = EventSettingsWindowRoute(
                scope: workspace, event: .stop, detail: .scope(target))
            _ = session.send(.present(.eventShortcut(detailRoute)))
            let detailFocusDebt = session.state.focusDebt
            let detailRouteRevision = session.state.explicitRouteRequestRevision
            writeFixture(try! JSONEncoder().encode(damaged), to: configFile)
            model.reload()
            expect(
                model.soundScopeSelection.projection.staleness == .invalidRule
                    && selection.route.event == .stop && selection.route.workspaceTarget == target
                    && selection.route.detail == .scope(target)
                    && selection.unavailableRequestedScopeStoredValue == workspace.storedValue,
                "合法入口捕获当前目录；共享状态失效不能丢失事件与目录详情")
            writeFixture(repairedBytes, to: configFile)
            model.reload()
            expect(
                model.soundScopeSelection.projection.staleness == .current
                    && selection.route
                        == EventSettingsWindowRoute(
                            scope: workspace, event: .stop,
                            workspaceTarget: target, detail: .scope(target))
                    && session.state.eventPresentation.route == selection.route
                    && session.state.focusDebt == detailFocusDebt
                    && session.state.explicitRouteRequestRevision == detailRouteRevision
                    && (try? Data(contentsOf: configFile)) == repairedBytes,
                "同目标恢复须保留事件与目录详情，不把健康更新变成新导航")

            let otherRule = WorkspaceSoundRule(
                id: rule.id,
                directory: WorkspaceDirectory(kind: .directory, path: root.path + "/old"),
                surfaces: [.codex], profile: rule.profile!)
            selection.showScopeDetail(WorkspaceSoundWriteTarget(rule: otherRule))
            let staleDetailRoute = selection.route
            writeFixture(try! JSONEncoder().encode(damaged), to: configFile)
            model.reload()
            writeFixture(repairedBytes, to: configFile)
            model.reload()
            expect(
                model.soundScopeSelection.projection.staleness == .current
                    && selection.route == staleDetailRoute
                    && !selection.route.workspaceTargetIsCurrent(
                        in: model.configState.resolvedConfig),
                "显式目录详情捕获另一目录时，共享恢复不能重新授权旧详情")
        }
    }

    suite("Settings shared sound selection：配置重读不替换显式失效深链") {
        let id = UUID(uuidString: "9E1E41B5-B256-4BE0-B6FC-F778E06086CB")!
        let original = WorkspaceSoundRule(
            id: id,
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/selection-old"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
        let replacement = WorkspaceSoundRule(
            id: id,
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/selection-new"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.eventsAndSounds), workspaceRules: [replacement])
        let model = fixture.eventSettingsModel
        model.selectSoundScope(.workspace(id))
        _ = fixture.session.send(
            .present(
                .eventShortcut(
                    EventSettingsWindowRoute(
                        scope: .workspace(id), event: .stop,
                        workspaceTarget: WorkspaceSoundWriteTarget(rule: original)))))
        let unavailableRoute = fixture.eventSettingsSelection.route
        let availableConfig = model.configState.resolvedConfig
        var config = availableConfig
        config.workspaceRules = []
        model.soundScopeSelection.applyConfig(config)

        expect(
            unavailableRoute.unavailableRequestedScopeStoredValue != nil
                && fixture.eventSettingsSelection.route == unavailableRoute
                && fixture.session.state.eventPresentation.route == unavailableRoute,
            "同一选择的配置失效发布必须保留显式深链捕获的原目标与不可用原因")
        model.soundScopeSelection.applyConfig(availableConfig)
        expect(
            model.soundScopeSelection.projection.staleness == .current
                && fixture.eventSettingsSelection.route == unavailableRoute
                && fixture.session.state.eventPresentation.route == unavailableRoute,
            "共享目标恢复健康也不能清除显式深链捕获的不同目录与不可用原因")
    }

    suite("Settings panel workspace shortcut：同 UUID 换绑保留旧目录并定位不可用说明") {
        let id = UUID(uuidString: "5DA1F0E5-488F-4EE1-8F20-EC0B75A3A74D")!
        let original = WorkspaceSoundRule(
            id: id,
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/panel-before"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
        let replacement = WorkspaceSoundRule(
            id: id,
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/panel-after"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.integrations), workspaceRules: [replacement])
        let oldTarget = WorkspaceSoundWriteTarget(rule: original)
        let delayed = EventSettingsWindowRoute(
            scope: .workspace(id), event: .stop, workspaceTarget: oldTarget)
        expect(
            fixture.session.send(.present(.eventShortcut(delayed)))
                == .rejected(.staleSoundScope(delayed.scope))
                && fixture.session.state.eventPresentation.route.workspaceTarget == oldTarget
                && fixture.session.state.eventPresentation.route
                    .unavailableRequestedScopeStoredValue == delayed.scope.storedValue
                && settingsWindowRequestedFocusTarget(
                    resolution: fixture.session.state.routeResolution)
                    == .routeFailure(.eventsAndSounds)
                && fixture.eventSettingsModel.selectedSoundScope == .global,
            "面板旧目录快捷入口不能把新目录选成可写目标，并须聚焦可见失败说明")

        let currentTarget = WorkspaceSoundWriteTarget(rule: replacement)
        let current = EventSettingsWindowRoute(
            scope: .workspace(id), workspaceTarget: currentTarget)
        expect(
            fixture.session.send(.present(.eventShortcut(current)))
                == .presented(wasAlreadyPresented: true)
                && fixture.session.state.eventPresentation.route == current
                && fixture.session.state.eventPresentation.focusTarget == .scope(.workspace(id))
                && fixture.eventSettingsModel.selectedWorkspaceTarget == currentTarget,
            "新目录的显式入口才可选择该工作区并请求工作区焦点")
        fixture.eventSettingsSelection.markCurrentScopeUnavailable()
        expect(
            fixture.eventSettingsSelection.route.workspaceTarget == currentTarget,
            "后续失效标记仍须保留原目录身份")
    }

    suite("Settings panel workspace shortcut：先读回磁盘再判断有效新目录") {
        withTempDirectory { root in
            let id = UUID(uuidString: "984815F5-E8E6-4C13-89F2-818457A29756")!
            let original = WorkspaceSoundRule(
                id: id,
                directory: WorkspaceDirectory(kind: .directory, path: "/fixture/cached-before"),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(
                    selectedPack: "settings-fixture-pack", volume: 0.7))
            let replacement = WorkspaceSoundRule(
                id: id,
                directory: WorkspaceDirectory(kind: .directory, path: "/fixture/on-disk-after"),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(
                    selectedPack: "settings-fixture-pack", volume: 0.7))
            let configFile = root.appendingPathComponent("config.json")
            var config = ClaudioConfig(selectedPack: "settings-fixture-pack")
            config.workspaceRules = [original]
            writeFixture(try! JSONEncoder().encode(config), to: configFile)
            let model = PanelConfigController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"),
                environment: makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true)))
            model.selectSoundScope(.workspace(id))
            expect(
                model.configState.resolvedConfig.workspaceRules.first?.directory
                    == original.directory
                    && model.selectedWorkspaceTarget == WorkspaceSoundWriteTarget(rule: original),
                "夹具须先证明 Events 模型仍选中并缓存旧目录")
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .destination(.integrations), workspaceRules: [replacement],
                eventSettingsModel: model)
            config.workspaceRules = [replacement]
            let newBytes = try! JSONEncoder().encode(config)
            writeFixture(newBytes, to: configFile)
            let current = EventSettingsWindowRoute(
                scope: .workspace(id), workspaceTarget: WorkspaceSoundWriteTarget(rule: replacement)
            )
            expect(
                fixture.session.send(.present(.eventShortcut(current)))
                    == .presented(wasAlreadyPresented: true)
                    && fixture.session.state.eventPresentation.route == current
                    && fixture.session.state.eventPresentation.focusTarget == .scope(.workspace(id))
                    && model.selectedWorkspaceTarget == current.workspaceTarget
                    && model.configState.resolvedConfig.workspaceRules.first?.directory
                        == replacement.directory
                    && (try? Data(contentsOf: configFile)) == newBytes,
                "有效新目录入口须先刷新缓存、进入原目标且不写配置")
        }
    }

    await suite("Settings mounted sound entrance：失效工作区显示重选入口") {
        let rule = WorkspaceSoundRule(
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/stale-entrance"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.eventsAndSounds), workspaceRules: [rule])
        let selected = PanelSoundScopeID.workspace(rule.id)
        fixture.eventSettingsSelection.select(EventSettingsWindowRoute(scope: selected))
        fixture.eventSettingsModel.selectSoundScope(selected)
        _ = fixture.session.send(.route(.integrations(IntegrationsSettingsRoute(surface: .codex))))
        fixture.session.replaceAvailabilityForTesting(
            SettingsRouteAvailability(
                integrationSurfaces: Set(HostID.productVisibleCases.map(\.surfaceID)),
                eventScopes: [.global], soundScopes: [.global], soundPackIDs: [],
                events: Set(Event.allCases)))
        let hostingView = NSHostingView(rootView: SettingsRootView(session: fixture.session))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_240, height: 820)
        hostingView.layoutSubtreeIfNeeded()
        SettingsMountRecorder.reset()
        _ = fixture.session.send(.route(.destination(.eventsAndSounds)))
        for _ in 0..<3 {
            await Task.yield()
            hostingView.layoutSubtreeIfNeeded()
            settingsPumpLayoutRunLoop()
        }
        expect(
            SettingsMountRecorder.identifiers.contains("settings.route.failure.events-and-sounds")
                && SettingsMountRecorder.identifiers.contains("workspace.choose-default-group")
                && fixture.session.state.eventPresentation.route.scope == selected,
            "production root 应挂载不可写说明与显式默认组重选按钮")
        _ = fixture.session.send(.route(.events(scope: selected, event: .stop)))
        for _ in 0..<3 {
            await Task.yield()
            hostingView.layoutSubtreeIfNeeded()
            settingsPumpLayoutRunLoop()
        }
        expect(
            SettingsMountRecorder.identifiers.contains("settings.route.failure.events-and-sounds"),
            "失效显式深链必须挂载与焦点请求同身份的可见失败说明")

        let soundFailures: [(SettingsRoute, SettingsRouteFailure)] = [
            (
                .sounds(.editEvent(scope: .global, packID: "missing-pack", event: .stop)),
                .staleSoundPack("missing-pack")
            ),
            (
                .sounds(.editEvent(scope: selected, packID: "settings-fixture-pack", event: .stop)),
                .staleSoundPack("settings-fixture-pack")
            ),
        ]
        // The failure row stays mounted when a second Sounds request replaces its message.
        SettingsMountRecorder.reset()
        for (route, failure) in soundFailures {
            let result = fixture.session.send(.route(route))
            for _ in 0..<3 {
                hostingView.layoutSubtreeIfNeeded()
                settingsPumpLayoutRunLoop()
            }
            let requestedFocus = settingsWindowRequestedFocusTarget(
                resolution: fixture.session.state.routeResolution)
            let failureIsMounted = SettingsMountRecorder.identifiers.contains(
                "settings.route.failure.sounds")
            expect(
                result == .rejected(failure)
                    && requestedFocus == .routeFailure(.sounds) && failureIsMounted,
                "\(route) 必须请求并挂载 Sounds 失败说明：\(result), \(String(describing: requestedFocus)), mounted=\(failureIsMounted)"
            )
        }
        withExtendedLifetime(hostingView) {}
    }

    suite("Settings session route：generic、explicit 与 repeated 请求保持单事务") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.usage),
            availability: PreviewFixtures.settingsRouteAvailability)
        let session = fixture.session
        _ = session.send(.windowWillClose)
        let closedRevision = session.state.explicitRouteRequestRevision

        expect(
            session.send(.present(.route(nil))) == .presented(wasAlreadyPresented: false)
                && session.state.routeResolution.route == .destination(.usage)
                && session.state.activeDestination == .usage
                && session.state.explicitRouteRequestRevision == closedRevision + 1,
            "closed generic open 必须恢复最新 top-level destination 并形成新 focus debt")
        let visibleState = session.state
        expect(
            session.send(.present(.route(nil))) == .presented(wasAlreadyPresented: true)
                && session.state == visibleState,
            "visible generic reopen 必须完全幂等，不改 route、revision 或 focus debt")

        let explicit = SettingsRoute.events(
            scope: .surface(.workBuddy), event: .notification)
        expect(
            session.send(.route(explicit)) == .routed
                && session.state.routeResolution.route == explicit
                && session.state.activeDestination == .eventsAndSounds
                && session.state.focusDebt?.destination == .eventsAndSounds,
            "explicit deep link 必须覆盖 generic destination 并发布精确 focus debt")
        let firstExplicitRevision = session.state.explicitRouteRequestRevision
        let firstFocusRevision = session.state.focusDebt!.revision
        expect(
            session.send(.route(explicit)) == .routed
                && session.state.explicitRouteRequestRevision == firstExplicitRevision + 1
                && session.state.focusDebt?.revision == firstFocusRevision + 1,
            "相同 explicit deep link 每次仍必须只推进一个 request/focus revision")
    }

    suite("Settings session rejection：invalid/stale 保留 requested destination 且零 target mutation") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .integrations(IntegrationsSettingsRoute(surface: .workBuddy)),
            availability: PreviewFixtures.settingsRouteAvailability)
        let session = fixture.session
        _ = session.send(.windowPhaseChanged(.key))
        let priorHost = fixture.integrationsModel.selectedHost
        let priorSurface = fixture.eventSettingsModel.selectedSurface
        let priorSoundMode = fixture.soundPacksEditor.presentation.mode
        let firstFailedRoute = SettingsRoute.integrations(
            IntegrationsSettingsRoute(surface: .chatGPTDesktopAX))
        let beforeInvalid = session.state
        let historyBeforeInvalid = session.navigationHistory
        for _ in 0..<2 {
            expect(
                session.send(.route(firstFailedRoute))
                    == .rejected(.invalidSurface(.chatGPTDesktopAX))
                    && session.state == beforeInvalid
                    && session.navigationHistory == historyBeforeInvalid
                    && fixture.integrationsModel.selectedHost == priorHost
                    && fixture.eventSettingsModel.selectedSurface == priorSurface
                    && fixture.soundPacksEditor.presentation.mode == priorSoundMode,
                "不可解析的输入及重复请求保持路由、历史、焦点和领域 owner 不变")
        }

        _ = session.send(.route(.integrations(IntegrationsSettingsRoute(surface: .workBuddy))))
        _ = session.send(
            .acknowledgeFocus(revision: session.state.focusDebt!.revision))
        let explicitRevision = session.state.explicitRouteRequestRevision
        fixture.session.replaceAvailabilityForTesting(
            SettingsRouteAvailability(
                integrationSurfaces: [],
                eventScopes: [.global],
                soundScopes: [.global],
                soundPackIDs: [],
                events: Set(Event.allCases)))
        expect(
            session.state.routeResolution.route
                == .integrations(IntegrationsSettingsRoute(surface: .workBuddy))
                && session.state.routeResolution.failure == .staleSurface(.workBuddy)
                && session.state.activeDestination == .integrations
                && session.state.explicitRouteRequestRevision == explicitRevision
                && session.state.focusDebt == nil
                && fixture.integrationsModel.selectedHost == priorHost,
            "availability 只可重解析当前 route；不得抢焦点、改 destination 或重做 domain mutation")

        let staleSoundRoute = SettingsRoute.sounds(
            .editEvent(surface: nil, packID: "missing-pack", event: .stop))
        let staleRevision = session.state.explicitRouteRequestRevision
        expect(
            session.send(.route(staleSoundRoute))
                == .rejected(.staleSoundPack("missing-pack"))
                && session.state.routeResolution
                    == SettingsRouteResolution(
                        route: staleSoundRoute,
                        failure: .staleSoundPack("missing-pack"))
                && session.state.activeDestination == .sounds
                && session.state.explicitRouteRequestRevision == staleRevision + 1
                && session.state.focusDebt?.destination == .sounds
                && fixture.integrationsModel.selectedHost == priorHost
                && fixture.eventSettingsModel.selectedSurface == priorSurface
                && fixture.soundPacksEditor.presentation.mode == priorSoundMode,
            "visible stale deep link 必须挂载 requested Sounds failure，且不得激活 Sound owner")

        _ = session.send(.windowWillClose)
        let invalidWhileClosed = SettingsRoute.sounds(
            .editEvent(surface: nil, packID: "   ", event: .stop))
        let closedState = session.state
        let closedHistory = session.navigationHistory
        for _ in 0..<2 {
            expect(
                session.send(.present(.route(invalidWhileClosed))) == .rejected(.invalidSoundPackID)
                    && session.state == closedState && session.navigationHistory == closedHistory
                    && fixture.integrationsModel.selectedHost == priorHost
                    && fixture.eventSettingsModel.selectedSurface == priorSurface
                    && fixture.soundPacksEditor.presentation.mode == priorSoundMode,
                "关闭期间不可解析输入不能创建窗口会话或历史位置，也不能触碰领域 owner")
        }

        _ = session.send(.windowWillClose)
        expect(
            session.send(.present(.route(nil))) == .presented(wasAlreadyPresented: false)
                && session.state.routeResolution.route == .destination(.integrations)
                && session.state.activeDestination == .integrations
                && session.state.routeResolution.failure == nil
                && fixture.integrationsModel.selectedHost == priorHost
                && fixture.eventSettingsModel.selectedSurface == priorSurface
                && fixture.soundPacksEditor.presentation.mode == priorSoundMode,
            "failed explicit route 不得写入偏好；下次 generic open 必须恢复最近合法 top-level destination"
        )
    }

    suite("Settings integrations details：typed detailsHost 经 session 单事务，host 变更由 owner 清空") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.integrations),
            availability: PreviewFixtures.settingsRouteAvailability)
        let session = fixture.session
        let details = IntegrationsSettingsRoute(surface: .workBuddy, detailsHost: .workBuddy)
        expect(
            session.send(.route(.integrations(details))) == .routed
                && session.state.routeResolution.route == .integrations(details)
                && fixture.integrationsModel.selectedHost == .workBuddy,
            "合法 details 深链接必须保留 detailsHost 并选中对应 Host")

        _ = fixture.integrationsModel.selectHost(.codex)
        expect(
            session.state.routeResolution.route
                == .integrations(IntegrationsSettingsRoute(surface: .codex))
                && session.state.routeResolution.failure == nil,
            "Host 选择变更必须由 session 跟随并清空旧 detailsHost")

        let mismatched = IntegrationsSettingsRoute(surface: .codex, detailsHost: .workBuddy)
        expect(
            session.send(.route(.integrations(mismatched))) == .routed
                && session.state.routeResolution.route
                    == .integrations(IntegrationsSettingsRoute(surface: .codex))
                && fixture.integrationsModel.selectedHost == .codex,
            "陈旧 detailsHost 必须被 validator 丢弃，且不得改变选中 Host")

        let codexDetails = IntegrationsSettingsRoute(surface: .codex, detailsHost: .codex)
        expect(
            session.send(.route(.integrations(codexDetails))) == .routed
                && session.state.routeResolution.route == .integrations(codexDetails),
            "当前 Host 的 details 深链接必须原样进入 session state")
        expect(
            session.send(.route(.destination(.integrations))) == .routed
                && session.state.routeResolution.route == .destination(.integrations),
            "通用入口回到 overview，details 不跨 destination 泄漏")
    }

    suite("Settings session failure matrix：Surface、scope、pack、Event 均只发布 typed failure") {
        let allSurfaces = Set(HostID.productVisibleCases.map(\.surfaceID))
        let allScopes = Set(
            [PanelSoundScopeID.global]
                + HostID.productVisibleCases.map { .surface($0.surfaceID) })
        let cases:
            [(
                route: SettingsRoute,
                availability: SettingsRouteAvailability,
                failure: SettingsRouteFailure,
                destination: SettingsDestination
            )] = [
                (
                    .integrations(IntegrationsSettingsRoute(surface: .chatGPTDesktopAX)),
                    SettingsRouteAvailability(
                        integrationSurfaces: allSurfaces,
                        eventScopes: allScopes,
                        soundScopes: allScopes,
                        soundPackIDs: ["settings-fixture-pack"],
                        events: Set(Event.allCases)),
                    .invalidSurface(.chatGPTDesktopAX),
                    .integrations
                ),
                (
                    .integrations(IntegrationsSettingsRoute(surface: .workBuddy)),
                    SettingsRouteAvailability(
                        integrationSurfaces: [],
                        eventScopes: allScopes,
                        soundScopes: allScopes,
                        soundPackIDs: ["settings-fixture-pack"],
                        events: Set(Event.allCases)),
                    .staleSurface(.workBuddy),
                    .integrations
                ),
                (
                    .events(scope: .global, event: .stop),
                    SettingsRouteAvailability(
                        integrationSurfaces: allSurfaces,
                        eventScopes: [],
                        soundScopes: allScopes,
                        soundPackIDs: ["settings-fixture-pack"],
                        events: Set(Event.allCases)),
                    .staleSoundScope(.global),
                    .eventsAndSounds
                ),
                (
                    .sounds(
                        .editEvent(
                            surface: nil,
                            packID: "missing-pack",
                            event: .stop)),
                    SettingsRouteAvailability(
                        integrationSurfaces: allSurfaces,
                        eventScopes: allScopes,
                        soundScopes: allScopes,
                        soundPackIDs: [],
                        events: Set(Event.allCases)),
                    .staleSoundPack("missing-pack"),
                    .sounds
                ),
                (
                    .sounds(
                        .editEvent(
                            surface: nil,
                            packID: "   ",
                            event: .stop)),
                    SettingsRouteAvailability(
                        integrationSurfaces: allSurfaces,
                        eventScopes: allScopes,
                        soundScopes: allScopes,
                        soundPackIDs: ["settings-fixture-pack"],
                        events: Set(Event.allCases)),
                    .invalidSoundPackID,
                    .sounds
                ),
                (
                    .events(scope: .global, event: .stopFailure),
                    SettingsRouteAvailability(
                        integrationSurfaces: allSurfaces,
                        eventScopes: allScopes,
                        soundScopes: allScopes,
                        soundPackIDs: ["settings-fixture-pack"],
                        events: Set(Event.allCases).subtracting([.stopFailure])),
                    .staleEvent(.stopFailure),
                    .eventsAndSounds
                ),
            ]

        for testCase in cases {
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .destination(.general),
                availability: testCase.availability)
            let session = fixture.session
            let initialHost = fixture.integrationsModel.selectedHost
            let initialHostVisibility = fixture.integrationsModel.isWindowVisible
            let initialHostKeyState = fixture.integrationsModel.isWindowKey
            let initialEventSurface = fixture.eventSettingsModel.selectedSurface
            let initialEventPresentation = session.state.eventPresentation
            let initialSoundPresentation = fixture.soundPacksEditor.presentation
            let initialPreference = fixture.lastSettingsDestination
            let initialRevision = session.state.explicitRouteRequestRevision

            let stateBefore = session.state
            let historyBefore = session.navigationHistory
            let result = session.send(.route(testCase.route))
            if testCase.failure == .invalidSoundPackID
                || testCase.failure == .invalidSurface(.chatGPTDesktopAX)
            {
                expect(
                    result == .rejected(testCase.failure) && session.state == stateBefore
                        && session.navigationHistory == historyBefore
                        && fixture.integrationsModel.selectedHost == initialHost
                        && fixture.eventSettingsModel.selectedSurface == initialEventSurface
                        && fixture.soundPacksEditor.presentation == initialSoundPresentation
                        && fixture.lastSettingsDestination == initialPreference,
                    "格式错误请求保留当前页面和历史，领域状态与偏好均不变")
                continue
            }
            expect(
                result == .rejected(testCase.failure)
                    && session.state.routeResolution
                        == SettingsRouteResolution(
                            route: testCase.route,
                            failure: testCase.failure)
                    && session.state.activeDestination == testCase.destination
                    && session.state.explicitRouteRequestRevision == initialRevision + 1
                    && session.state.focusDebt?.destination == testCase.destination
                    && fixture.integrationsModel.selectedHost == initialHost
                    && fixture.integrationsModel.isWindowVisible == initialHostVisibility
                    && fixture.integrationsModel.isWindowKey == initialHostKeyState
                    && fixture.eventSettingsModel.selectedSurface == initialEventSurface
                    && (session.state.eventPresentation == initialEventPresentation
                        || (testCase.failure == .staleSoundScope(.global)
                            && session.state.eventPresentation.route.scope == .global
                            && session.state.eventPresentation.route
                                .unavailableRequestedScopeStoredValue
                                == PanelSoundScopeID.global.storedValue
                            && session.navigationHistory.current?.location.workspaceRoute?.scope
                                == .global))
                    && fixture.soundPacksEditor.presentation == initialSoundPresentation
                    && fixture.lastSettingsDestination == initialPreference,
                "\(testCase.failure) 必须保留 requested destination/failure，同时保持 Host/Event/Sound/preference 零 mutation"
            )
        }
    }

    suite("Settings failed route：错误页卸载旧 lifecycle，后续 success/close 不重复 cleanup") {
        let availability = SettingsRouteAvailability(
            integrationSurfaces: Set(HostID.productVisibleCases.map(\.surfaceID)),
            eventScopes: [.global],
            soundScopes: [.global],
            soundPackIDs: ["settings-fixture-pack"],
            events: Set(Event.allCases))
        let failedRoute = SettingsRoute.sounds(
            .editEvent(surface: nil, packID: "missing-pack", event: .stop))

        for exitsThroughClose in [false, true] {
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .events(scope: .global, event: .stop),
                availability: availability)
            fixture.beginEventTransientActivity()
            let beforeFailure = fixture.session.state.eventPresentation

            expect(
                fixture.session.send(.route(failedRoute))
                    == .rejected(.staleSoundPack("missing-pack"))
                    && fixture.session.state.activeDestination == .sounds
                    && fixture.session.state.eventPresentation.previewStopRequestRevision
                        == beforeFailure.previewStopRequestRevision + 1
                    && fixture.soundPacksEditor.presentation.mode == .inactive
                    && fixture.aiCueViewModel.session == nil,
                "已知失效目标进入错误页，卸载旧 Events 并清理试听与 AI 会话"
            )

            if exitsThroughClose {
                _ = fixture.session.send(.windowWillClose)
            } else {
                _ = fixture.session.send(.route(.destination(.general)))
            }
            let afterExit = fixture.session.state.eventPresentation
            expect(
                afterExit.previewStopRequestRevision
                    == beforeFailure.previewStopRequestRevision + 1
                    && afterExit.aiSessionEndRequestRevision
                        == beforeFailure.aiSessionEndRequestRevision + 1
                    && afterExit.previewState == .idle
                    && afterExit.aiSessionState == .idle
                    && fixture.aiCueViewModel.session == nil
                    && fixture.soundPacksEditor.presentation.mode == .inactive,
                "failed route 后的 \(exitsThroughClose ? "close" : "successful route") 必须恰好一次 cleanup retained Events lifecycle"
            )
        }
    }

    suite("Settings session event shortcut：未知 raw scope 可见且不授权 Global fallback") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .events(scope: .surface(.workBuddy), event: .stop),
            availability: PreviewFixtures.settingsRouteAvailability)
        let previousSurface = fixture.eventSettingsModel.selectedSurface
        let unavailable = EventSettingsWindowRoute(
            scope: .global,
            event: .notification,
            unavailableRequestedScopeStoredValue: "future-surface")

        expect(
            fixture.session.send(.present(.eventShortcut(unavailable)))
                == .presented(wasAlreadyPresented: true)
                && fixture.session.state.activeDestination == .eventsAndSounds
                && fixture.session.state.eventPresentation.route == unavailable
                && fixture.session.state.eventPresentation.route
                    .unavailableRequestedScopeStoredValue == "future-surface"
                && fixture.eventSettingsModel.selectedSurface == previousSurface,
            "shortcut 必须原样保留 unavailable raw scope，绝不能把展示用 Global 变成写目标")
        guard case .events(let editor) = fixture.soundPacksEditor.presentation.mode else {
            expect(false, "event shortcut 必须应用到 shared editor owner")
            return
        }
        expect(
            editor.route == unavailable,
            "同 destination 的新 event route 也必须原样更新 editor context")
    }

    suite("Settings session lifecycle：old inactive 先于 new active 且每次 route 只发布一次") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .integrations(IntegrationsSettingsRoute(surface: .workBuddy)),
            availability: PreviewFixtures.settingsRouteAvailability)
        let session = fixture.session
        _ = session.send(.windowPhaseChanged(.key))
        var routePublications = 0
        var eventActivatedAfterIntegrationHidden = false
        let stateCancellable = session.$state.dropFirst().sink { _ in
            routePublications += 1
        }
        let soundCancellable = fixture.soundPacksEditor.$presentation.dropFirst().sink {
            presentation in
            if case .events = presentation.mode {
                eventActivatedAfterIntegrationHidden = !fixture.integrationsModel.isWindowVisible
            }
        }

        _ = session.send(.route(.events(scope: .global, event: .stop)))
        expect(
            eventActivatedAfterIntegrationHidden && routePublications == 1,
            "transaction 必须先结束旧 Integrations lifecycle，再激活 Events，并只发布一个 coherent state")
        routePublications = 0
        _ = session.send(.route(.integrations(IntegrationsSettingsRoute(surface: .workBuddy))))
        expect(
            session.state.activeDestination == .integrations
                && fixture.integrationsModel.isWindowVisible
                && fixture.integrationsModel.isWindowKey
                && routePublications == 1,
            "Events→Integrations 返回路径也必须只发布一次并恢复真实 key lifecycle")
        let soundsRoute = SoundPacksWindowRoute.overview(surface: .workBuddy)
        _ = session.send(.route(.sounds(soundsRoute)))
        guard case .sounds(let sounds) = fixture.soundPacksEditor.presentation.mode else {
            expect(false, "Sounds route 必须激活 shared editor owner")
            return
        }
        expect(
            sounds.route == soundsRoute,
            "Sounds typed route 必须逐字应用到 owner，而不是只切换 top-level destination")
        withExtendedLifetime((stateCancellable, soundCancellable)) {}
    }

    suite("Settings Sounds detail lifecycle：本地意图经 session 仲裁且离开 destination 重置") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .sounds(.overview),
            availability: PreviewFixtures.settingsRouteAvailability)
        let session = fixture.session
        expect(
            session.state.soundsDetail == .overview
                && session.state.routeResolution.route == .sounds(.overview),
            "初始 Sounds 呈现必须从 overview 详情开始")
        expect(
            session.send(
                .requestSoundsDetail(
                    .editEvent(packID: "settings-fixture-pack", event: .stop))) == .routed,
            "本地事件详情意图必须被 session 仲裁接受")
        expect(
            session.state.soundsDetail
                == .pack(packID: "settings-fixture-pack")
                && session.state.routeResolution.route
                    == .sounds(.editEvent(packID: "settings-fixture-pack", event: .stop))
                && session.navigationHistory.entries.count == 2,
            "本地详情发布统一路由与历史位置")
        expect(
            session.send(.requestSoundsDetail(.audio(packID: "missing-pack")))
                == .rejected(.staleSoundPack("missing-pack"))
                && session.state.routeResolution.route
                    == .sounds(
                        SoundPacksWindowRoute(
                            scope: .global, destination: .audio(packID: "missing-pack")))
                && session.navigationHistory.current?.location.viewedPackID == "missing-pack"
                && fixture.soundPacksEditor.presentation.mode == .inactive,
            "已知失效包进入统一错误页，保留身份和历史并撤销编辑能力")
        _ = fixture.soundPacksEditor.send(.activate(.sounds(route: .overview, requestRevision: 1)))
        expect(
            session.state.routeResolution.failure == .staleSoundPack("missing-pack")
                && session.navigationHistory.current?.location.viewedPackID == "missing-pack",
            "旧 owner 发布不能覆盖当前历史错误页的捕获身份")
        _ = session.send(.route(.destination(.general)))
        expect(
            session.state.soundsDetail == .overview,
            "离开 Sounds destination 必须重置详情")
        _ = session.send(.route(.sounds(.overview)))
        expect(
            session.state.soundsDetail == .overview
                && session.state.routeResolution.route == .sounds(.overview),
            "返回 Sounds 必须从新 route request 重新推导详情")
    }

    await suite("Settings mounted root：visible explicit route 必须消费 emitted focus debt") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.general),
            availability: PreviewFixtures.settingsRouteAvailability)
        let hostingView = NSHostingView(rootView: SettingsRootView(session: fixture.session))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_240, height: 820)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        hostingView.layoutSubtreeIfNeeded()
        _ = fixture.session.send(.windowPhaseChanged(.key))
        if let initialDebt = fixture.session.state.focusDebt {
            _ = fixture.session.send(.acknowledgeFocus(revision: initialDebt.revision))
        }

        let priorRevision = fixture.session.state.explicitRouteRequestRevision
        _ = fixture.session.send(.route(.destination(.notifications)))
        hostingView.layoutSubtreeIfNeeded()
        let deadline = Date(timeIntervalSinceNow: 2)
        while fixture.session.state.focusDebt != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
            hostingView.layoutSubtreeIfNeeded()
        }
        expect(
            fixture.session.state.activeDestination == .notifications
                && fixture.session.state.explicitRouteRequestRevision == priorRevision + 1
                && fixture.session.state.focusDebt == nil,
            "mounted root 必须在页面渲染后移交目标焦点并 exact-ack visible route debt")
        withExtendedLifetime(hostingView) {}
    }

    suite("Settings mounted Events：离开 destination 的 preview/AI cleanup 必须恰好一次") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .events(scope: .global, event: .stop),
            availability: PreviewFixtures.settingsRouteAvailability)
        let hostingView = NSHostingView(rootView: SettingsRootView(session: fixture.session))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_240, height: 820)
        hostingView.layoutSubtreeIfNeeded()
        fixture.beginEventTransientActivity()
        let before = fixture.session.state.eventPresentation
        var previewStopPublications = 0
        let cancellable = fixture.previewStopRequestRevisions.dropFirst().sink { _ in
            previewStopPublications += 1
        }
        _ = fixture.session.send(.route(.destination(.general)))
        hostingView.layoutSubtreeIfNeeded()
        let after = fixture.session.state.eventPresentation
        expect(
            previewStopPublications == 1
                && after.previewStopRequestRevision == before.previewStopRequestRevision + 1
                && after.aiSessionEndRequestRevision == before.aiSessionEndRequestRevision + 1
                && after.previewState == .idle
                && after.aiSessionState == .idle
                && fixture.aiCueViewModel.session == nil
                && fixture.soundPacksEditor.presentation.mode == .inactive,
            "真实 mounted Events view 必须无递归地恰好一次消费 leave cleanup debt")
        withExtendedLifetime((hostingView, cancellable)) {}
    }

    await suite("Settings Events AI generation：emitted tuple 必须签发当前 candidate adoption permit") {
        let generationFixture = SettingsPresentationFixtures.generalLogin(
            aiCueScenario: .candidates)
        let generation = generationFixture.aiCueViewModel.generation!
        let aiCueViewModel = AICueGenerationViewModel(
            credentialManager: SettingsLifecycleCredentialManager(),
            generator: SettingsLifecycleGenerator(generation: generation),
            providerProfileID: generation.profileID,
            providerPreferences: AICueProviderPreferences(defaults: UserDefaults()))
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .events(scope: .surface(.workBuddy), event: .stop),
            availability: PreviewFixtures.settingsRouteAvailability,
            aiCueViewModel: aiCueViewModel)
        aiCueViewModel.begin(scope: .surface(.workBuddy), event: .stop)
        aiCueViewModel.updateDescription("short completion cue")
        aiCueViewModel.startGeneration(locale: "en")
        for _ in 0..<200 where aiCueViewModel.generation?.id != generation.id {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        guard case .events(let presentation) = fixture.soundPacksEditor.presentation.mode else {
            expect(false, "AI generation 后 shared owner 必须保持 Events presentation")
            return
        }
        expect(
            aiCueViewModel.generation?.id == generation.id,
            "deterministic AI generator 必须先发布当前 generation")
        expect(
            presentation.route
                == EventSettingsWindowRoute(
                    scope: .surface(.workBuddy),
                    event: .stop),
            "AI session emitted route 必须保持当前 Surface/Event")
        expect(presentation.adoptionPermit == nil, "已退役 Surface route 不能签发 AI 写许可")
        expect(
            presentation.eventAccess.allSatisfy { $0.adoptionAvailability != .eligible },
            "来源声音路由不借默认包恢复写权限；包级 composer 由 Sounds 目的页管理")

    }

    suite("Settings session close：Events transient cleanup 恰好一次且 close 幂等") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .events(scope: .global, event: .stop),
            availability: PreviewFixtures.settingsRouteAvailability)
        fixture.beginEventTransientActivity()
        let before = fixture.session.state.eventPresentation
        guard case .events(let activeEditor) = fixture.soundPacksEditor.presentation.mode else {
            expect(false, "AI transient state 必须经 session 激活 shared editor")
            return
        }
        expect(
            before.previewState != .idle && before.aiSessionState != .idle
                && fixture.aiCueViewModel.session != nil
                && activeEditor.route == EventSettingsWindowRoute(scope: .global, event: .stop),
            "fixture 必须先建立真实 preview/AI transient state")

        expect(fixture.session.send(.windowWillClose) == .closed, "首次 close 必须消费窗口 lifecycle")
        let after = fixture.session.state.eventPresentation
        expect(
            after.previewState == .idle
                && after.aiSessionState == .idle
                && after.previewStopRequestRevision == before.previewStopRequestRevision + 1
                && after.aiSessionEndRequestRevision == before.aiSessionEndRequestRevision + 1
                && fixture.aiCueViewModel.session == nil
                && fixture.soundPacksEditor.presentation.mode == .inactive
                && fixture.session.state.windowPhase == .hidden
                && fixture.session.state.activeDestination == nil,
            "close 必须恰好一次结束 sequence、AI session 与 active editor")
        expect(
            fixture.session.send(.windowWillClose) == .unchanged
                && fixture.session.state.eventPresentation == after,
            "retained window 的重复 close callback 不得二次 cleanup")
        let closedState = fixture.session.state
        expect(
            fixture.session.send(.windowPhaseChanged(.visibleNonKey)) == .unchanged
                && fixture.session.send(.windowPhaseChanged(.key)) == .unchanged
                && fixture.session.state == closedState,
            "close 后迟到的 native phase callback 不得把 hidden session 重新推进为 visible/key")
    }

    suite("Settings session announcement：key/active gate 与 post→exact ack 顺序") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .sounds(.overview),
            availability: PreviewFixtures.settingsRouteAvailability)
        let ownerHead = fixture.soundPacksEditor.presentation.pendingAnnouncement?.id
        expect(
            ownerHead != nil && fixture.session.state.pendingAnnouncement == nil,
            "hidden Sounds 可以保留 owner semantic debt，但 session 不得提前交付")
        _ = fixture.session.send(.windowPhaseChanged(.visibleNonKey))
        expect(
            fixture.session.state.pendingAnnouncement == nil,
            "visible non-key 仍不得消费或包装 announcement")
        _ = fixture.session.send(.windowPhaseChanged(.key))
        guard let delivery = fixture.session.state.pendingAnnouncement else {
            expect(false, "key + active Sounds 必须生成唯一 native delivery debt")
            return
        }
        var nativePostResults = [false, true]
        var attemptedDeliveryIDs: [UInt64] = []
        @MainActor
        func attemptNativeDelivery() -> Bool {
            guard let current = fixture.session.state.pendingAnnouncement else { return false }
            return SettingsAnnouncementDelivery.attempt(
                current,
                post: {
                    attemptedDeliveryIDs.append(current.id)
                    return nativePostResults.removeFirst()
                },
                acknowledgeSuccess: { id in
                    _ = fixture.session.send(
                        .acknowledgeAnnouncement(id: id, didPost: true))
                })
        }

        expect(!attemptNativeDelivery(), "native adapter 报告失败时 delivery 必须如实返回 false")
        expect(
            fixture.session.state.pendingAnnouncement?.id == delivery.id
                && fixture.soundPacksEditor.presentation.pendingAnnouncement?.id == ownerHead,
            "post false 必须同时保留 session debt 与 owner exact head")
        expect(attemptNativeDelivery(), "下一次合法重试成功时 delivery 必须返回 true")
        expect(
            attemptedDeliveryIDs == [delivery.id, delivery.id]
                && fixture.session.state.pendingAnnouncement == nil
                && fixture.soundPacksEditor.presentation.pendingAnnouncement == nil,
            "失败不得消费 revision；同一 exact head 补发成功后才清空 session 与 owner debt"
        )
    }

    suite("Settings session effects：event audibility 与 Calendar privacy 各走一次 typed seam") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            platformActionResult: .performed)
        expect(
            fixture.session.send(.eventAudibilityInputsChanged) == .routed
                && fixture.actionRecorder.eventAudibilityChangeCount == 1,
            "一次 event audibility command 必须只触发一次既有 domain refresh effect")
        expect(
            fixture.session.send(
                .performPlatformAction(.openCalendarPrivacySettings))
                == .platformAction(.performed)
                && fixture.actionRecorder.actions == [.openCalendarPrivacySettings],
            "Calendar privacy 必须经 closed typed platform effect 恰好一次")

        let revealURL = URL(fileURLWithPath: "/tmp/claudio-settings/config.json.recovery")
        expect(
            fixture.session.send(.performPlatformAction(.revealInFinder(revealURL)))
                == .platformAction(.performed)
                && fixture.actionRecorder.actions == [
                    .openCalendarPrivacySettings, .revealInFinder(revealURL),
                ],
            "recovery/config reveal 必须经同一 typed seam 携带精确 URL 恰好一次")
        expect(
            fixture.session.send(.performPlatformAction(.copyToPasteboard("session-1")))
                == .platformAction(.performed)
                && fixture.actionRecorder.actions.last == .copyToPasteboard("session-1"),
            "copy session 必须经同一 typed seam 携带精确 session 字符串")

        let failed = SettingsPresentationFixtures.generalLogin(platformActionResult: .failed)
        expect(
            failed.session.send(.performPlatformAction(.copyToPasteboard("session-1")))
                == .platformAction(.failed)
                && failed.session.state.platformActionFailure == .copyToPasteboard("session-1"),
            "copy 失败必须经 seam 如实投影 failed；copySession 的 result == .performed 映射随之得到 false")
    }

    suite("Settings platform effect wiring：reveal 与 copy 视图只经 typed seam") {
        let root = guiTestRepositoryRoot()
        let eventsURL = root.appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/EventSettingsWindowView.swift")
        let activityURL = root.appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/ActivityDiagnosticsView.swift")
        let rootViewURL = root.appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/SettingsRootView.swift")
        guard
            let events = try? String(contentsOf: eventsURL, encoding: .utf8),
            let activity = try? String(contentsOf: activityURL, encoding: .utf8),
            let rootView = try? String(contentsOf: rootViewURL, encoding: .utf8)
        else {
            expect(false, "读不到 Settings presentation platform effect view source")
            return
        }
        expect(
            settingsPlatformEffectViewWiringIsSound(events: events, activity: activity)
                && !settingsPlatformEffectViewWiringIsSound(
                    events: events.replacingOccurrences(
                        of: "performPlatformAction(.revealInFinder(currentTarget))",
                        with: "NSWorkspace.shared.activateFileViewerSelecting([currentTarget])"),
                    activity: activity)
                && !settingsPlatformEffectViewWiringIsSound(
                    events: events,
                    activity: activity.replacingOccurrences(
                        of: "performPlatformAction(.copyToPasteboard(session))",
                        with: "NSPasteboard.general.setString(session, forType: .string)")),
            "reveal/copy 必须经 typed seam；退回直接 AppKit 调用的 mutation 必须被识破")
        expect(
            rootView.components(
                separatedBy: "settingsPresentationSession.send(.performPlatformAction($0))"
            ).count - 1 == 2,
            "events 与 usage 两处 mount 必须把同一 session typed seam 注入视图")
    }
    #endif
}

private actor SettingsLifecycleCredentialManager: AICueCredentialManaging {
    func status(for _: AICueProviderProfileID) async -> AICueCredentialStatus {
        .stored(verification: .verified, hasPendingReplacement: false)
    }

    func save(
        _: SensitiveCredentialInput,
        for _: AICueProviderProfileID
    ) async throws -> AICueCredentialStatus {
        .stored(verification: .verified, hasPendingReplacement: false)
    }

    func delete(for _: AICueProviderProfileID) async throws {}
    func cancelPendingReplacement(for _: AICueProviderProfileID) async throws {}
}

private actor SettingsLifecycleGenerator: AICueGenerating {
    let generation: AICueGeneration

    init(generation: AICueGeneration) {
        self.generation = generation
    }

    func generate(
        description _: String,
        locale _: String,
        providerProfileID _: AICueProviderProfileID,
        deadline _: AICueGenerationDeadline
    ) async throws -> AICueGeneration {
        generation
    }

    func discard(generationID _: UUID) async {}
    func discardAll() async {}
}

private func settingsLifecycleBracedBlock(after marker: String, in source: String) -> String? {
    guard let markerRange = source.range(of: marker),
        let openingBrace = source[markerRange.upperBound...].firstIndex(of: "{")
    else { return nil }
    var depth = 0
    var index = openingBrace
    while index < source.endIndex {
        switch source[index] {
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return String(source[openingBrace...index])
            }
        default:
            break
        }
        index = source.index(after: index)
    }
    return nil
}

private func settingsMenuRequestOwnsOnlyTypedRoute(_ source: String) -> Bool {
    let scanned = strippingComments(source)
    guard scanned.unmodeledConstructs.isEmpty,
        let request = settingsLifecycleBracedBlock(
            after: "fileprivate func requestIntegrationsSettingsPresentation(",
            in: scanned.code)
    else { return false }
    let compact = request.filter { !$0.isWhitespace }
    return compact.contains("host??integrationsModel.selectedHost??.claudeCode")
        && compact.contains(
            ".route(.integrations(IntegrationsSettingsRoute(surface:selectedHost.surfaceID)))")
        && !compact.contains("integrationsModel.selectHost")
}

private func settingsPlatformEffectViewWiringIsSound(events: String, activity: String) -> Bool {
    let scannedEvents = strippingComments(events)
    let scannedActivity = strippingComments(activity)
    guard scannedEvents.unmodeledConstructs.isEmpty,
        scannedActivity.unmodeledConstructs.isEmpty
    else { return false }
    let eventsCode = scannedEvents.codeWithoutStringLiterals
    let activityCode = scannedActivity.codeWithoutStringLiterals
    guard
        let recovery = settingsLifecycleBracedBlock(
            after: "private func recoveryFileButtons(", in: eventsCode),
        let configReveal = settingsLifecycleBracedBlock(
            after: "private var configRevealButton", in: eventsCode)
    else { return false }
    return recovery.contains("performPlatformAction(.revealInFinder(currentTarget))")
        && configReveal.contains("performPlatformAction(.revealInFinder(currentTarget))")
        && !eventsCode.contains("NSWorkspace")
        && activityCode.contains("performPlatformAction(.copyToPasteboard(session))")
        && activityCode.contains("== .platformAction(.performed)")
        && !activityCode.contains("NSPasteboard")
}

private func settingsNativeAnnouncementAdapterIsSound(_ source: String) -> Bool {
    let scanned = strippingComments(source)
    guard scanned.unmodeledConstructs.isEmpty,
        let scheduler = settingsLifecycleBracedBlock(
            after: "private func scheduleSettingsPresentationAnnouncementDelivery()",
            in: scanned.code),
        let delivery = settingsLifecycleBracedBlock(
            after: "private func deliverPendingSettingsPresentationAnnouncement()",
            in: scanned.code),
        let nativePost = settingsLifecycleBracedBlock(
            after: "private static func postAccessibilityAnnouncement(",
            in: scanned.code),
        let didBecomeKey = settingsLifecycleBracedBlock(
            after: "func windowDidBecomeKey(",
            in: scanned.code),
        let showWindow = settingsLifecycleBracedBlock(
            after: "func showWindow(",
            in: scanned.code),
        let dispatch = scheduler.range(of: "DispatchQueue.main.async"),
        let latchGuard = scheduler.range(
            of: "guard !settingsPresentationAnnouncementDeliveryScheduled"),
        let latchSet = scheduler.range(
            of: "settingsPresentationAnnouncementDeliveryScheduled = true"),
        let latchClear = scheduler.range(
            of: "settingsPresentationAnnouncementDeliveryScheduled = false"),
        let deliver = scheduler.range(of: "deliverPendingSettingsPresentationAnnouncement()"),
        latchGuard.lowerBound < latchSet.lowerBound,
        latchSet.lowerBound < dispatch.lowerBound,
        dispatch.lowerBound < latchClear.lowerBound,
        latchClear.lowerBound < deliver.lowerBound,
        !scheduler[..<dispatch.lowerBound].contains(
            "settingsPresentationSession.state.pendingAnnouncement"),
        let phaseGate = delivery.range(
            of: "settingsPresentationSession.state.windowPhase == .key"),
        let currentHead = delivery.range(
            of: "settingsPresentationSession.state.pendingAnnouncement"),
        let visibleGate = delivery.range(of: "window.isVisible"),
        let keyGate = delivery.range(of: "window.isKeyWindow"),
        let deliveryAttempt = delivery.range(of: "SettingsAnnouncementDelivery.attempt("),
        let postAdapter = delivery.range(of: "postAccessibilityAnnouncement("),
        let exactAck = delivery.range(
            of: ".acknowledgeAnnouncement(id: id, didPost: true)"),
        phaseGate.lowerBound < currentHead.lowerBound,
        currentHead.lowerBound < visibleGate.lowerBound,
        visibleGate.lowerBound < keyGate.lowerBound,
        keyGate.lowerBound < deliveryAttempt.lowerBound,
        deliveryAttempt.lowerBound < postAdapter.lowerBound,
        postAdapter.lowerBound < exactAck.lowerBound,
        let nativePostCall = nativePost.range(of: "NSAccessibility.post("),
        let nativeSuccess = nativePost.range(of: "return true"),
        nativePostCall.lowerBound < nativeSuccess.lowerBound
    else { return false }

    return didBecomeKey.contains(".windowPhaseChanged(.key)")
        && didBecomeKey.contains("scheduleSettingsPresentationAnnouncementDelivery()")
        && showWindow.contains("presentedWindow.presentForUserRequest()")
        && showWindow.contains("scheduleSettingsPresentationAnnouncementDelivery()")
}

@MainActor
private final class SettingsLifecycleAudioAdapter: SoundPacksEditorNativeEffectsAdapter {
    private(set) var stopCount = 0
    var previewDuration: TimeInterval? { 0.25 }

    func selectAudioFiles(allowsMultipleSelection _: Bool) -> [URL] { [] }
    func playAudio(fileURL _: URL, volume _: Double) -> TimeInterval? { 0.25 }
    private var completion: (@MainActor @Sendable (Bool) -> Void)?
    func playAudio(
        fileURL: URL, volume: Double,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Bool {
        self.completion = completion
        return playAudio(fileURL: fileURL, volume: volume) != nil
    }

    func stopAudio() { stopCount += 1 }
    func revealInFinder(fileURL _: URL) {}
}

private func settingsReplacingFirstOccurrence(
    in source: String,
    of target: String,
    with replacement: String
) -> String {
    guard let range = source.range(of: target) else { return source }
    var result = source
    result.replaceSubrange(range, with: replacement)
    return result
}

@MainActor
private func settingsPumpLayoutRunLoop() {
    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
}
