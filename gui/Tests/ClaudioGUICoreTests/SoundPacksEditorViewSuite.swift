import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Combine
import Foundation
import SoundPacksWindow
import SwiftUI

@MainActor
func runSoundPacksEditorViewSuites() async {
    await runSoundPacksSettingsDetailIdentityRegressions()
    await suite("Sound editor view：compiled seam 只接受 owner presentation 与 native adapter") {
        await withTempDirectory { root in
            let status = SoundPacksWindowStatus(
                kind: .factoryRestore,
                severity: .failure,
                revision: 701,
                action: "Restore",
                message: "Retained",
                recovery: .retryFactoryRestores(packIDs: ["pack-a"]))
            let owner = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: "pack-a", masterVolume: 0.4),
                packCards: [
                    PackCard(
                        id: "pack-a",
                        name: "Pack A",
                        isCC0: false,
                        presentEvents: [.stop],
                        state: .partial(present: 1, total: Event.allCases.count),
                        isSelected: true)
                ],
                selectedPackID: "pack-a",
                selectedEventRows: Event.allCases.map {
                    EventRow(
                        event: $0,
                        coverage: $0 == .stop
                            ? .present(fileName: "stop.mp3") : .unmapped,
                        enabled: true)
                },
                windowStatuses: [status],
                environment: makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true)))

            guard case .sounds(let sounds) = owner.presentation.mode else {
                expect(false, "owner 必须发布 Sounds presentation")
                return
            }
            expect(
                sounds.windowStatuses == [status]
                    && sounds.recoveryActions.map(\.packID) == ["pack-a"],
                "持久可见 status 与 recovery action 必须同属 render-ready interface")
            expect(
                sounds.eventRows.first(where: { $0.event == .notification })?
                    .previewAvailability == .unmapped,
                "View 所需的试听可用性必须由 owner 以 render-ready semantic value 提供")

            let dispatcher = SoundPacksEditorNativeEffectsDispatcher(
                adapter: NoOpSoundPacksEditorNativeEffectsAdapter())
            let _: any ObservableObject = dispatcher
            let preferences = ClaudioPreferences(defaults: UserDefaults())
            let view = SoundPacksWindowView(
                editorOwner: owner,
                focusCoordinator: SoundPacksWindowFocusCoordinator(),
                languageStore: preferences,
                nativeEffects: dispatcher)
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
            hostingView.layoutSubtreeIfNeeded()
            expect(
                hostingView.fittingSize.width > 0 && hostingView.fittingSize.height > 0,
                "owner-only production view 必须可由真实 SwiftUI/AppKit seam 编译并挂载")

            let embedded = EmbeddedSoundPacksEditorView(
                editorOwner: owner,
                route: .overview,
                routeRequestRevision: 702,
                languageStore: preferences,
                nativeEffects: dispatcher)
            let embeddedHost = NSHostingView(rootView: embedded)
            embeddedHost.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
            embeddedHost.layoutSubtreeIfNeeded()
            expect(
                embeddedHost.fittingSize.width > 0 && embeddedHost.fittingSize.height > 0,
                "Settings embedded view 必须复用同一 owner/native interface")
        }
    }

    suite("Sound editor gallery：compiled production interface 不需要用户路径") {
        let gallery = SoundPacksWindowStateGalleryView(
            language: .english,
            textSize: .standard)
        let hostingView = NSHostingView(rootView: gallery)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        hostingView.layoutSubtreeIfNeeded()
        expect(
            hostingView.fittingSize.width > 0 && hostingView.fittingSize.height > 0,
            "Gallery 必须由 production view interface 编译并挂载")
    }

    suite("Sound editor overview：初始导航不抢统一设置标题焦点") {
        expect(
            soundPacksWindowDeepLinkFocusTarget(
                route: .overview, scopeAvailability: .available(.global), selectedPackID: "builtin",
                visibleEvents: Set(Event.allCases), fallback: .packList) == nil,
            "普通导航应保留设置壳的标题焦点，不自动聚焦包列表")
        expect(
            soundPacksWindowDeepLinkFocusTarget(
                route: .overview,
                scopeAvailability: .unavailable(scope: .global, reason: .scopeUnavailable),
                selectedPackID: "builtin", visibleEvents: Set(Event.allCases), fallback: .packList)
                == .managedScopeFailure,
            "失效声音作用域仍优先聚焦可见失败说明")
    }

    suite("Sound editor read-only deep link：缺声也定位目标事件") {
        let route = SoundPacksWindowRoute.editEvent(
            surface: nil, packID: "builtin", event: .stop)
        let fallback = SoundPacksWindowFocusTarget.packList
        expect(
            soundPacksWindowDeepLinkFocusTarget(
                route: route, scopeAvailability: .available(.global), selectedPackID: "builtin",
                visibleEvents: Set(Event.allCases), fallback: fallback)
                == .eventAudio(.stop),
            "只读包的缺声事件仍应聚焦目标映射行")
        expect(
            soundPacksWindowDeepLinkFocusTarget(
                route: route, scopeAvailability: .available(.global), selectedPackID: "builtin",
                visibleEvents: [], fallback: fallback) == fallback,
            "目标事件不在实际渲染行中时应回到安全焦点")
        expect(
            soundPacksWindowDeepLinkFocusTarget(
                route: route, scopeAvailability: .available(.global), selectedPackID: "other",
                visibleEvents: Set(Event.allCases), fallback: fallback) == fallback,
            "目标包尚未显示时不能把焦点交给其他包的同名事件")
    }

    suite("Sound editor stale workspace deep link：失效说明取得请求焦点") {
        withTempDirectory { root in
            let original = WorkspaceSoundRule(
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.appendingPathComponent("before").path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "pack-a", volume: 0.7))
            let replacement = WorkspaceSoundRule(
                id: original.id,
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.appendingPathComponent("after").path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "pack-a", volume: 0.7))
            var config = ClaudioConfig(selectedPack: "pack-a", masterVolume: 0.4)
            config.workspaceRules = [replacement]
            let owner = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: config,
                packCards: [
                    PackCard(
                        id: "pack-a", name: "Pack A", isCC0: false,
                        presentEvents: [.stop],
                        state: .partial(present: 1, total: Event.allCases.count),
                        isSelected: true)
                ],
                selectedPackID: "pack-a",
                selectedEventRows: [
                    EventRow(event: .stop, coverage: .present(fileName: "stop.mp3"), enabled: true)
                ],
                environment: makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true)),
                activation: nil)
            owner.configureWorkspacePackWriter { _, _ in .success(()) }
            let scope = PanelSoundScopeID.workspace(original.id)
            let route = SoundPacksWindowRoute.editEvent(
                scope: scope, packID: "pack-a", event: .stop,
                workspaceTarget: WorkspaceSoundWriteTarget(rule: original))
            _ = owner.send(.activate(.sounds(route: route, requestRevision: 803)))
            guard case .sounds(let sounds) = owner.presentation.mode else {
                expect(false, "失效工作区必须交付 Sounds presentation")
                return
            }
            expect(
                sounds.scope == .unavailable(scope: scope, reason: .scopeUnavailable),
                "同 UUID 新目录必须先由真实 editor owner 判为不可用")
            expect(
                soundPacksWindowDeepLinkFocusTarget(
                    route: route, scopeAvailability: sounds.scope,
                    selectedPackID: sounds.selectedPack?.id,
                    visibleEvents: Set(sounds.eventRows.map(\.event)), fallback: .packList)
                    == .managedScopeFailure,
                "包与事件仍可见时，旧工作区深链仍须优先聚焦失效说明")
            let focusScope = SoundPacksWindowFocusScope(
                packIDs: sounds.packs.map(\.id), selectedPackID: sounds.selectedPack?.id,
                hasManagedScopeFailure: true)
            expect(
                Array(soundPacksWindowFocusOrder(focusScope).prefix(2))
                    == [.managedScopeFailure, .packList],
                "失效说明须成为首个焦点，包列表仍可经键盘到达")
            var tracker = SoundPacksEditorFocusApplicationTracker()
            let available = SoundPacksEditorFocusProjection(
                requestRevision: sounds.requestRevision, routeState: sounds.routeState,
                scopeAvailability: .available(scope))
            let unavailable = SoundPacksEditorFocusProjection(
                requestRevision: sounds.requestRevision, routeState: sounds.routeState,
                scopeAvailability: sounds.scope)
            expect(
                tracker.recordAndShouldApply(available, force: false)
                    && tracker.recordAndShouldApply(unavailable, force: false),
                "同一路由的读回失效必须重新发出焦点请求")

            let reboundRoute = SoundPacksWindowRoute.editEvent(
                scope: scope, packID: "pack-a", event: .stop,
                workspaceTarget: WorkspaceSoundWriteTarget(rule: replacement))
            _ = owner.send(.activate(.sounds(route: reboundRoute, requestRevision: 804)))
            guard case .sounds(let rebound) = owner.presentation.mode else {
                expect(false, "新目录深链必须交付 Sounds presentation")
                return
            }
            expect(
                rebound.scope == .available(scope)
                    && soundPacksWindowDeepLinkFocusTarget(
                        route: reboundRoute, scopeAvailability: rebound.scope,
                        selectedPackID: rebound.selectedPack?.id,
                        visibleEvents: Set(rebound.eventRows.map(\.event)), fallback: .packList)
                        == .eventAudio(.stop),
                "新目录深链恢复目标事件焦点，不保留旧失败焦点")
        }
    }

    suite("Sound editor focus：同一 route request 只推进一次，settlement 与重新打开仍推进") {
        var tracker = SoundPacksEditorFocusApplicationTracker()
        let pending = SoundPacksEditorFocusProjection(
            requestRevision: 801,
            routeState: .pendingFreshSnapshot,
            scopeAvailability: .available(.global))
        let resolved = SoundPacksEditorFocusProjection(
            requestRevision: 801,
            routeState: .resolved(.overview),
            scopeAvailability: .available(.global))
        expect(
            tracker.recordAndShouldApply(pending, force: false),
            "新 route request 必须推进一次 focus")
        expect(
            !tracker.recordAndShouldApply(pending, force: false),
            "activate 后相同 projection 的 onChange 不得重复抢焦点")
        expect(
            tracker.recordAndShouldApply(resolved, force: false),
            "pending→resolved settlement 必须推进一次精确 route focus")
        expect(
            tracker.recordAndShouldApply(resolved, force: true),
            "窗口重新出现时即使 route 未变也必须恢复 initial focus")
    }

    await suite("Sound editor gallery：真实 owner busy fixture 不执行 writer 仍发布写入中状态") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a", "pack-b"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 802)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let useAction = sounds.packs.first(where: { $0.id == "pack-b" })?.useAction
            else {
                expect(false, "busy Gallery fixture 必须先取得真实 owner write capability")
                return
            }
            let configBefore = try? Data(contentsOf: fixture.configFile)
            let scansBefore = fixture.recorder.requests.count
            expect(
                owner.freezeAcceptedOperationForStateGalleryFixture(useAction),
                "Gallery 必须经真实 owner accepted transition 构造 deterministic busy")
            for _ in 0..<8 { await Task.yield() }
            expect(
                owner.presentation.activities.contains { $0.kind == .use && $0.phase == .busy },
                "Gallery busy fixture 必须保留 owner presentation 的真实 write-in-progress activity")
            guard case .sounds(let busy) = owner.presentation.mode else {
                expect(false, "busy fixture 必须保留 Sounds presentation")
                return
            }
            expect(
                busy.selectedPack?.id == "pack-a" && busy.selectedPack?.isActiveForScope == true
                    && (try? Data(contentsOf: fixture.configFile)) == configBefore
                    && fixture.recorder.requests.count == scansBefore,
                "同步取消 scheduled Task 后必须保持 selected/config facts 且零 writer、零 refresh")
        }
    }
}

/// Foundation-only path: this regression never mounts a view or creates an NSApplication.
@MainActor
func runSoundPacksSettingsDetailIdentityRegressions() async {
    await suite("Sound editor local detail：磁盘移除原包后保留身份并聚焦不可用原因") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root, packIDs: ["pack-a", "pack-b"],
                config: ClaudioConfig(selectedPack: "pack-b"))
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 805)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let initial) = owner.presentation.mode,
                let inspect = initial.packs.first(where: { $0.id == "pack-a" })?.inspectAction
            else { expect(false, "必须获得查看未使用包 A 的 capability"); return }
            _ = owner.send(.invoke(inspect))
            guard case .sounds(let inspected) = owner.presentation.mode else {
                expect(false, "查看必须保留 Sounds presentation"); return
            }
            let detail = SoundPacksSettingsDetail.event(packID: "pack-a", event: .stop)
            expect(
                inspected.selectedPack?.id == "pack-a" && detail.targetIsAvailable(in: inspected),
                "从普通 overview 进入详情必须捕获正在查看的包 A")
            var routeTracker = SoundPacksSettingsDetailRouteTracker()
            _ = routeTracker.detailAfterFocusRequest(
                route: .overview, sounds: inspected, currentDetail: .overview)
            var retainedDetail = detail
            let observation = owner.$presentation.sink { presentation in
                guard case .sounds(let sounds) = presentation.mode else { return }
                let focusRoute: SoundPacksWindowRoute
                if case .resolved(let route) = sounds.routeState {
                    focusRoute = route
                } else {
                    focusRoute = .overview
                }
                retainedDetail = routeTracker.detailAfterFocusRequest(
                    route: focusRoute, sounds: sounds, currentDetail: retainedDetail)
                retainedDetail = retainedDetail.reconciled(
                    with: presentation, copyTransition: nil)
            }
            defer { observation.cancel() }
            let configBefore = try? Data(contentsOf: fixture.configFile)
            try! FileManager.default.moveItem(
                at: root.appendingPathComponent("packs/pack-a"),
                to: root.appendingPathComponent("removed-pack-a"))
            _ = await fixture.library.refreshSnapshot(trigger: .retry)
            await waitForSoundEditorPackAbsence(owner, packID: "pack-a")
            guard case .sounds(let fallback) = owner.presentation.mode else {
                expect(false, "刷新必须保留 Sounds presentation"); return
            }
            let reconciled = detail.reconciled(with: owner.presentation, copyTransition: nil)
            expect(
                fallback.routeState == .resolved(.overview)
                    && fallback.selectedPack?.id == "pack-b",
                "复现必须经过真实库刷新和 overview 的自动选择回落 B")
            expect(reconciled == detail, "普通 selection 回落不得替换详情捕获的包 A 身份")
            expect(
                retainedDetail == detail,
                "库 pending／resolved 引发的同代次 overview 焦点请求不得关闭或重定向本地详情")
            expect(
                !reconciled.targetIsAvailable(in: fallback)
                    && reconciled.visibleEventRows(in: fallback).isEmpty,
                "原包失效后必须隐藏 B 的全部事件编辑和试听 capability")
            expect(
                reconciled.unavailableFocusTarget(in: fallback) == .managedScopeFailure,
                "原包失效必须把焦点路由到当前可见的不可用原因")
            expect(
                SoundPacksSettingsDetail.audio(packID: "pack-a").unavailableFocusTarget(
                    in: fallback)
                    == .managedScopeFailure,
                "音频详情必须遵守同一捕获身份和不可用焦点 gate")
            expect(
                (try? Data(contentsOf: fixture.configFile)) == configBefore,
                "查看、进入详情和磁盘刷新均不得改写当前使用组")
        }
    }

    await suite("Sound editor local detail：所用包缺失占位不能冒充空音频清单") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 806)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            try! FileManager.default.moveItem(
                at: root.appendingPathComponent("packs/pack-a"),
                to: root.appendingPathComponent("removed-pack-a"))
            _ = await fixture.library.refreshSnapshot(trigger: .retry)
            for _ in 0..<512 {
                if case .sounds(let sounds) = owner.presentation.mode,
                    sounds.selectedPack?.availability == .missingSelectedPlaceholder
                {
                    break
                }
                await Task.yield()
            }
            guard case .sounds(let missing) = owner.presentation.mode else {
                expect(false, "声音目的页必须继续存在")
                return
            }
            expect(
                missing.selectedPack?.availability == .missingSelectedPlaceholder,
                "复现必须保留配置实际引用的缺失包占位")
            for detail in [
                SoundPacksSettingsDetail.audio(packID: "pack-a"),
                .event(packID: "pack-a", event: .stop),
            ] {
                expect(
                    !detail.targetIsAvailable(in: missing)
                        && detail.unavailableFocusTarget(in: missing) == .managedScopeFailure,
                    "占位详情必须显示目标不可用并聚焦原因，不能显示空清单或编辑表单")
            }
        }
    }

    let copyCases: [(SoundPackEditorAction.Kind, Bool)] = [
        (.fork, false), (.copy, false), (.copyAndApply, false), (.copyAndApply, true),
    ]
    for (kind, failsApplying) in copyCases {
        await suite("Sound editor detail：\(kind.rawValue) applyFailure=\(failsApplying) 精确结果定向过渡") {
            await withTempDirectory { root in
                let fixture = makeSoundEditorFixture(
                    root: root, packIDs: ["factory-a"], builtinPackIDs: ["factory-a"])
                let factory = root.appendingPathComponent("factory-packs/factory-a")
                writeFixture(
                    #"{"id":"factory-a","name":"Factory A","events":{"stop":"stop.mp3"}}"#,
                    to: factory.appendingPathComponent("manifest.json"))
                writeFixture("audio", to: factory.appendingPathComponent("stop.mp3"))
                let owner = fixture.owner
                let route: SoundPacksWindowRoute =
                    kind == .copyAndApply
                    ? .copyAndApply(packID: "factory-a", event: .stop) : .overview
                _ = owner.send(.activate(.sounds(route: route, requestRevision: 806)))
                await waitForSoundEditorReady(owner, library: fixture.library)
                guard case .sounds(let sounds) = owner.presentation.mode,
                    let source = sounds.selectedPack
                else { expect(false, "复制必须先取得原包投影"); return }
                let action: SoundPackEditorAction?
                switch kind {
                case .fork: action = source.forkAction
                case .copy: action = source.copyAction
                default: action = source.copyAndApplyAction
                }
                let previous = owner.presentation
                let detail = SoundPacksSettingsDetail.event(packID: "factory-a", event: .stop)
                let configBefore = try? Data(contentsOf: fixture.configFile)
                let configLock = FileLock(path: root.appendingPathComponent("config.lock").path)
                if failsApplying { expect(configLock.tryLock(), "失败场景必须持有真实配置写入锁") }
                defer { configLock.unlock() }
                guard let action, case .accepted(let operationID) = owner.send(.invoke(action)),
                    let transition = SoundPacksSettingsDetailCopyTransition(
                        detail: detail, actionKind: action.kind, operationID: operationID,
                        previousPresentation: previous)
                else { expect(false, "复制必须产生显式 accepted operation 和详情过渡"); return }
                expect(
                    detail.reconciled(with: owner.presentation, copyTransition: transition)
                        == detail,
                    "busy 操作尚无副本结果时必须保留原包身份")
                await owner.waitForScheduledOperationExitForTesting(operationID)
                await owner.waitForMutationTransactionsToQuiesceForTesting()
                guard case .sounds(let copied) = owner.presentation.mode,
                    let copiedID = copied.selectedPack?.id, copiedID != "factory-a"
                else { expect(false, "实际复制须通过共享库收敛到已发布副本"); return }
                let result = detail.reconciled(with: owner.presentation, copyTransition: transition)
                expect(
                    transition.resultPackID(in: owner.presentation) == copiedID
                        && result == .event(packID: copiedID, event: .stop)
                        && result.targetIsAvailable(in: copied),
                    "成功结果的精确 packID 必须恢复同一事件详情的能力")
                expect(
                    detail.reconciled(with: owner.presentation, copyTransition: nil) == detail,
                    "仅看到新 selection 和旧终态结果不能授权任意详情重定向")
                let otherEvent = SoundPacksSettingsDetail.event(
                    packID: "factory-a", event: .notification)
                expect(
                    otherEvent.reconciled(with: owner.presentation, copyTransition: transition)
                        == otherEvent,
                    "离开原事件详情后迟到 copy 不得劫持新的详情")
                if kind != .copyAndApply || failsApplying {
                    expect(
                        (try? Data(contentsOf: fixture.configFile)) == configBefore,
                        "普通复制及应用失败均不得改变使用组")
                    if failsApplying {
                        expect(
                            owner.presentation.activities.contains {
                                $0.operationID == operationID
                                    && $0.phase == .failed(.mutationFailed)
                            },
                            "应用写入失败仍须保留实际已创建的副本结果和失败状态")
                    }
                } else {
                    expect(
                        loadClaudioConfig(from: fixture.configFile)?.selectedPack == copiedID,
                        "定向复制并应用仍必须保留原有配置写入能力")
                }
            }
        }
    }

    await suite("Sound editor detail：首个系统音成功发布草稿后保持捕获身份") {
        await withTempDirectory { root in
            let packs = root.appendingPathComponent("packs")
            writeFixture(
                #"{"id":"user","events":{}}"#,
                to: packs.appendingPathComponent("user/manifest.json"))
            writeFixture(validAIFFData(), to: root.appendingPathComponent("system/Basso.aiff"))
            var environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            environment.systemSoundCatalog = SystemSoundCatalog(
                directory: root.appendingPathComponent("system"))
            let config = root.appendingPathComponent("config.json")
            writeFixture(#"{"selected_pack":"user"}"#, to: config)
            let library = SoundPackLibrary(environment: environment)
            let owner = SoundPacksEditorOwner(
                configFile: config, lockFile: root.appendingPathComponent("config.lock"),
                environment: environment, soundPackLibrary: library,
                refreshCoordinator: SoundPacksRefreshCoordinator())
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 807)))
            await waitForSoundEditorReady(owner, library: library)
            expect(owner.beginAICuePackDraft(language: .english), "必须经既有 owner 创建未发布草稿")
            guard case .sounds(let draftSounds) = owner.presentation.mode,
                let draft = draftSounds.draft,
                let action = draftSounds.eventRows.first(where: { $0.event == .stop })?
                    .systemSoundChoices.first?.action
            else { expect(false, "草稿必须拥有安全系统音绑定 capability"); return }
            let detail = SoundPacksSettingsDetail.event(packID: draft.packID, event: .stop)
            expect(detail.targetIsAvailable(in: draftSounds), "未发布草稿必须可编辑捕获事件")
            guard case .accepted(let operationID) = owner.send(.invoke(action)) else {
                expect(false, "首个系统音必须经真实绑定事务发布"); return
            }
            await owner.waitForScheduledOperationExitForTesting(operationID)
            await owner.waitForMutationTransactionsToQuiesceForTesting()
            guard case .sounds(let published) = owner.presentation.mode else {
                expect(false, "已发布草稿必须保留 Sounds 投影"); return
            }
            expect(
                published.draft == nil && published.selectedPack?.id == draft.packID
                    && detail.reconciled(with: owner.presentation, copyTransition: nil) == detail
                    && detail.targetIsAvailable(in: published),
                "草稿首发必须使用原 packID，不能被任意 selectedPack 变化替换")
            expect(
                loadClaudioConfig(from: config)?.selectedPack == "user",
                "草稿发布仍只查看，不擅自应用声音组")
            expect(owner.beginAICuePackDraft(language: .english), "发布后仍能建立独立新草稿")
            guard case .sounds(let nextDraftSounds) = owner.presentation.mode,
                let nextDraft = nextDraftSounds.draft
            else { expect(false, "第二个未发布草稿必须提供独立身份"); return }
            let cancelledDetail = SoundPacksSettingsDetail.event(
                packID: nextDraft.packID, event: .stop)
            owner.cancelAICuePackDraft()
            guard case .sounds(let cancelled) = owner.presentation.mode else { return }
            expect(
                cancelledDetail.reconciled(with: owner.presentation, copyTransition: nil)
                    == cancelledDetail
                    && cancelledDetail.visibleEventRows(in: cancelled).isEmpty
                    && cancelledDetail.unavailableFocusTarget(in: cancelled)
                        == .managedScopeFailure,
                "取消未发布草稿不得串到现有包，并须移除事件能力和聚焦原因")
            expect(
                !FileManager.default.fileExists(
                    atPath: packs.appendingPathComponent(nextDraft.packID).path),
                "取消保持未发布草稿无目录")
        }
    }

    await suite("Sound editor detail route：首次 pending 深链收敛后才完成一次导航") {
        await withTempDirectory { root in
            let route = SoundPacksWindowRoute.editEvent(packID: "pack-a", event: .stop)
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: route, requestRevision: 808)))
            guard case .sounds(let pending) = owner.presentation.mode else {
                expect(false, "pending fixture 必须提供真实 route presentation"); return
            }
            var tracker = SoundPacksSettingsDetailRouteTracker()
            expect(
                tracker.detailAfterFocusRequest(
                    route: .overview, sounds: pending, currentDetail: .overview)
                    == .overview,
                "首次 pending 不得过早伪装成已解析事件详情")
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let resolved) = owner.presentation.mode else { return }
            expect(resolved.routeState == .resolved(route), "深链必须通过真实共享库解析原包")
            let target = tracker.detailAfterFocusRequest(
                route: route, sounds: resolved, currentDetail: .overview)
            expect(target == .event(packID: "pack-a", event: .stop), "首次深链解析必须保留原包和事件")
            expect(
                tracker.detailAfterFocusRequest(
                    route: .overview, sounds: resolved, currentDetail: target)
                    == target,
                "解析完成后的同代次 snapshot focus 不得再关闭详情")
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 809)))
            guard case .sounds(let explicitOverview) = owner.presentation.mode else { return }
            expect(
                tracker.detailAfterFocusRequest(
                    route: .overview, sounds: explicitOverview, currentDetail: target)
                    == .overview,
                "显式新的 overview 请求仍必须结束旧详情")
        }
    }
}

@MainActor
private final class NoOpSoundPacksEditorNativeEffectsAdapter:
    SoundPacksEditorNativeEffectsAdapter
{
    func selectAudioFiles(allowsMultipleSelection: Bool) -> [URL] { [] }
    func playAudio(fileURL: URL, volume: Double) -> TimeInterval? { nil }
    func stopAudio() {}
    func revealInFinder(fileURL: URL) {}
}
