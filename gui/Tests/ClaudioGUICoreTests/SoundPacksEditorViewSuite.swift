import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
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
                nativeEffects: dispatcher,
                detail: .overview,
                onDetailIntent: { _ in })
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
                nativeEffects: dispatcher,
                detail: .overview,
                onDetailIntent: { _ in })
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
                sounds.scope == .available(.global),
                "Sounds 包级编辑不由工作区目标决定")
            expect(
                soundPacksWindowDeepLinkFocusTarget(
                    route: route, scopeAvailability: sounds.scope,
                    selectedPackID: sounds.selectedPack?.id,
                    visibleEvents: Set(sounds.eventRows.map(\.event)), fallback: .packList)
                    == .eventAudio(.stop),
                "旧工作区链接转换为包详情并定位事件")
            let focusScope = SoundPacksWindowFocusScope(
                packIDs: sounds.packs.map(\.id), selectedPackID: sounds.selectedPack?.id,
                hasManagedScopeFailure: true)
            expect(
                Array(soundPacksWindowFocusOrder(focusScope).prefix(2))
                    == [.managedScopeFailure, .packList],
                "失效说明须成为首个焦点，包列表仍可经键盘到达")
            var tracker = FocusApplicationTracker<SoundPacksEditorFocusProjection>()
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
                rebound.scope == .available(.global)
                    && soundPacksWindowDeepLinkFocusTarget(
                        route: reboundRoute, scopeAvailability: rebound.scope,
                        selectedPackID: rebound.selectedPack?.id,
                        visibleEvents: Set(rebound.eventRows.map(\.event)), fallback: .packList)
                        == .eventAudio(.stop),
                "新目录深链恢复目标事件焦点，不保留旧失败焦点")
        }
    }

    suite("Sound editor focus：同一 route request 只推进一次，settlement 与重新打开仍推进") {
        var tracker = FocusApplicationTracker<SoundPacksEditorFocusProjection>()
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
            _ = owner.send(
                .activate(
                    .events(route: EventSettingsWindowRoute(scope: .global), requestRevision: 802)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .events(let sounds) = owner.presentation.mode,
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
            guard case .events(let busy) = owner.presentation.mode else {
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
/// The detail itself is arbitrated by the retained settings presentation session; these suites
/// drive that session seam and assert `session.state.soundsDetail`.
@MainActor
func runSoundPacksSettingsDetailIdentityRegressions() async {
    #if DEBUG
    await suite("Sound editor local detail：磁盘移除原包后保留身份并聚焦不可用原因") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root, packIDs: ["pack-a", "pack-b"],
                config: ClaudioConfig(selectedPack: "pack-b"))
            let sessionFixture = SettingsPresentationFixtures.generalLogin(
                route: .sounds(.overview),
                soundPacksEditor: fixture.owner)
            let session = sessionFixture.session
            await waitForSoundEditorReady(fixture.owner, library: fixture.library)
            guard case .sounds(let initial) = fixture.owner.presentation.mode,
                let inspect = initial.packs.first(where: { $0.id == "pack-a" })?.inspectAction
            else { expect(false, "必须获得查看未使用包 A 的 capability"); return }
            _ = fixture.owner.send(.invoke(inspect))
            guard case .sounds(let inspected) = fixture.owner.presentation.mode else {
                expect(false, "查看必须保留 Sounds presentation"); return
            }
            let detail = SoundPacksSettingsDetail.pack(packID: "pack-a")
            expect(
                inspected.selectedPack?.id == "pack-a" && detail.targetIsAvailable(in: inspected),
                "从普通 overview 进入详情必须捕获正在查看的包 A")
            expect(
                session.send(.requestSoundsDetail(.editEvent(packID: "pack-a", event: .stop)))
                    == .routed,
                "本地详情意图必须被 session 仲裁接受")
            expect(
                session.state.soundsDetail == detail
                    && session.state.routeResolution.route
                        == .sounds(.editEvent(packID: "pack-a", event: .stop)),
                "本地事件详情必须经 session 发布统一历史位置")
            let entryID = session.navigationHistory.current!.id
            let configBefore = try? Data(contentsOf: fixture.configFile)
            try! FileManager.default.moveItem(
                at: root.appendingPathComponent("packs/pack-a"),
                to: root.appendingPathComponent("removed-pack-a"))
            let libraryState = await fixture.library.refreshSnapshot(trigger: .retry)
            for _ in 0..<512 where session.state.routeResolution.failure == nil {
                await Task.yield()
            }
            if case .ready(let snapshot) = libraryState {
                expect(
                    !snapshot.facts.contains { $0.id == "pack-a" }
                        && snapshot.facts.contains { $0.id == "pack-b" }, "真实库刷新证明 A 删除、B 仍存在")
            } else {
                expect(false, "删除后必须获得真实库的终态快照")
            }
            expect(
                session.state.routeResolution.failure == .staleSoundPack("pack-a")
                    && session.navigationHistory.current?.id == entryID
                    && session.navigationHistory.current?.location.viewedPackID == "pack-a"
                    && fixture.owner.presentation.mode == .inactive,
                "刷新不追加历史；原包失效进入统一错误页，保留 A 身份并撤销 B 的全部编辑和试听能力")
            expect(session.state.chrome.canGoBack, "失效位置仍保留统一前后导航")
            expect(
                (try? Data(contentsOf: fixture.configFile)) == configBefore,
                "查看、进入详情和磁盘刷新均不得改写当前使用组")
        }
    }
    #endif

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
                .pack(packID: "pack-a"),
            ] {
                expect(
                    !detail.targetIsAvailable(in: missing)
                        && detail.unavailableFocusTarget(in: missing) == .managedScopeFailure,
                    "占位详情必须显示目标不可用并聚焦原因，不能显示空清单或编辑表单")
            }
        }
    }

    #if DEBUG
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
                let sessionFixture = SettingsPresentationFixtures.generalLogin(
                    route: .sounds(route),
                    soundPacksEditor: owner)
                let session = sessionFixture.session
                await waitForSoundEditorReady(owner, library: fixture.library)
                let detail = SoundPacksSettingsDetail.pack(packID: "factory-a")
                if kind == .copyAndApply {
                    await waitForSessionSoundsDetail(session, detail)
                    expect(
                        session.state.routeResolution.route
                            == .sounds(
                                SoundPacksWindowRoute(
                                    scope: .global, destination: .pack(packID: "factory-a"))),
                        "旧 copyAndApply 转换为只读浏览目标")
                } else {
                    expect(
                        session.send(
                            .requestSoundsDetail(.editEvent(packID: "factory-a", event: .stop)))
                            == .routed,
                        "本地详情意图必须被 session 仲裁接受")
                    expect(
                        session.state.routeResolution.route
                            == .sounds(.editEvent(packID: "factory-a", event: .stop)),
                        "本地事件详情发布统一历史位置")
                }
                expect(
                    session.state.soundsDetail == detail, "复制前必须打开原包事件详情")
                // The detail intent's leave effects republish the owner; read the signed
                // capability afterwards, exactly like a click rendered from that publication.
                guard case .sounds(let sounds) = owner.presentation.mode,
                    let source = sounds.selectedPack
                else { expect(false, "复制必须先取得原包投影"); return }
                if kind == .copyAndApply {
                    expect(
                        source.copyAndApplyAction == nil && source.useAction == nil,
                        "旧 copyAndApply 链接只浏览包，不签发应用能力")
                    expect(
                        loadClaudioConfig(from: fixture.configFile)?.selectedPack == "factory-a",
                        "旧链接不改变组选包")
                    return
                }
                let action: SoundPackEditorAction?
                switch kind {
                case .fork: action = source.forkAction
                case .copy: action = source.copyAction
                default: action = source.copyAndApplyAction
                }
                let configBefore = try? Data(contentsOf: fixture.configFile)
                let configLock = FileLock(path: root.appendingPathComponent("config.lock").path)
                if failsApplying { expect(configLock.tryLock(), "失败场景必须持有真实配置写入锁") }
                defer { configLock.unlock() }
                guard let action,
                    case .accepted(let operationID) = owner.send(.invoke(action))
                else { expect(false, "复制必须产生显式 accepted operation"); return }
                let acceptedEntryID = session.navigationHistory.current!.id
                let acceptedHistoryCount = session.navigationHistory.entries.count
                expect(
                    session.state.soundsDetail == detail,
                    "busy 操作尚无副本结果时必须保留原包身份")
                await owner.waitForScheduledOperationExitForTesting(operationID)
                await owner.waitForMutationTransactionsToQuiesceForTesting()
                guard case .sounds(let copied) = owner.presentation.mode,
                    let copiedID = copied.selectedPack?.id, copiedID != "factory-a"
                else { expect(false, "实际复制须通过共享库收敛到已发布副本"); return }
                await waitForSessionSoundsDetail(
                    session, .pack(packID: copiedID))
                expect(
                    session.state.soundsDetail.targetIsAvailable(in: copied),
                    "成功结果的精确 packID 必须恢复同一事件详情的能力")
                expect(
                    session.navigationHistory.current?.id == acceptedEntryID
                        && session.navigationHistory.entries.count == acceptedHistoryCount
                        && session.navigationHistory.current?.location.viewedPackID == copiedID,
                    "匹配的实际复制结果只转换当前历史条目，不增加浏览位置")
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

    await suite("Sound editor detail：离开原事件详情后迟到 copy 结果不得重定向新详情") {
        await withTempDirectory { root in
            let publicationGate = SettingsCopyPublicationGate()
            defer { publicationGate.release() }
            let fixture = makeSoundEditorFixture(
                root: root, packIDs: ["factory-a"], builtinPackIDs: ["factory-a"],
                beforeReadyPublication: { publicationGate.pauseNextPublication() })
            let factory = root.appendingPathComponent("factory-packs/factory-a")
            writeFixture(
                #"{"id":"factory-a","name":"Factory A","events":{"stop":"stop.mp3"}}"#,
                to: factory.appendingPathComponent("manifest.json"))
            writeFixture("audio", to: factory.appendingPathComponent("stop.mp3"))
            let owner = fixture.owner
            let sessionFixture = SettingsPresentationFixtures.generalLogin(
                route: .sounds(.overview),
                soundPacksEditor: owner)
            let session = sessionFixture.session
            await waitForSoundEditorReady(owner, library: fixture.library)
            expect(
                session.send(.requestSoundsDetail(.editEvent(packID: "factory-a", event: .stop)))
                    == .routed,
                "原事件详情必须先经 session 打开")
            // The detail intent's leave effects republish the owner; the signed capability must
            // be read from the publication the click would actually see.
            guard case .sounds(let sounds) = owner.presentation.mode,
                let copyAction = sounds.selectedPack?.copyAction
            else { expect(false, "必须先取得原包复制 capability"); return }
            guard case .accepted(let operationID) = owner.send(.invoke(copyAction)) else {
                expect(false, "复制必须产生显式 accepted operation"); return
            }
            publicationGate.arm()
            await owner.waitForScheduledOperationExitForTesting(operationID)
            expect(publicationGate.waitUntilPaused(), "实际磁盘复制结束后的库发布必须停在确定性边界")
            expect(
                session.send(
                    .requestSoundsDetail(.editEvent(packID: "factory-a", event: .notification)))
                    == .routed,
                "磁盘事务完成但库结果尚未发布时，新详情仍可进入")
            publicationGate.release()
            await owner.waitForMutationTransactionsToQuiesceForTesting()
            await fixture.library.waitUntilIdleForTesting()
            let terminalLibrary = await fixture.library.stateForTesting()
            guard case .ready(let snapshot) = terminalLibrary,
                snapshot.facts.contains(where: { $0.id != "factory-a" })
            else { expect(false, "真实磁盘复制必须完成并发布副本"); return }
            await Task.yield()
            expect(
                session.state.soundsDetail
                    == .pack(packID: "factory-a"),
                "离开原事件详情后迟到 copy 不得劫持新的详情")
            let diskPackIDs = snapshot.facts.map(\.id)
            let configBytes = try? Data(contentsOf: fixture.configFile)
            session.send(.goBack)
            session.send(.goForward)
            await owner.waitForMutationTransactionsToQuiesceForTesting()
            guard case .ready(let afterTraversal) = await fixture.library.stateForTesting() else {
                expect(false, "历史遍历后共享库仍须可读"); return
            }
            expect(
                afterTraversal.facts.map(\.id) == diskPackIDs
                    && (try? Data(contentsOf: fixture.configFile)) == configBytes
                    && session.state.soundsDetail
                        == .pack(packID: "factory-a"),
                "Back/Forward 不重放复制、应用或旧结果，磁盘与新详情保持不变")
        }
    }

    await suite("Sound editor detail：写入开始前的新导航保留 owner 的陈旧操作拒绝") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root, packIDs: ["factory-a"], builtinPackIDs: ["factory-a"])
            let factory = root.appendingPathComponent("factory-packs/factory-a")
            writeFixture(
                #"{"id":"factory-a","name":"Factory A","events":{"stop":"stop.mp3"}}"#,
                to: factory.appendingPathComponent("manifest.json"))
            writeFixture("audio", to: factory.appendingPathComponent("stop.mp3"))
            let owner = fixture.owner
            let sessionFixture = SettingsPresentationFixtures.generalLogin(
                route: .sounds(.overview),
                soundPacksEditor: owner)
            let session = sessionFixture.session
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let copyAction = sounds.selectedPack?.copyAction
            else { expect(false, "必须先取得原包复制 capability"); return }
            guard case .accepted(let operationID) = owner.send(.invoke(copyAction)) else {
                expect(false, "复制必须产生显式 accepted operation"); return
            }
            expect(
                session.send(.requestSoundsDetail(.editEvent(packID: "factory-a", event: .stop)))
                    == .routed,
                "busy 起点之后才打开的详情不携带过渡授权")
            await owner.waitForScheduledOperationExitForTesting(operationID)
            await owner.waitForMutationTransactionsToQuiesceForTesting()
            await fixture.library.waitUntilIdleForTesting()
            let terminalLibrary = await fixture.library.stateForTesting()
            guard case .ready(let snapshot) = terminalLibrary,
                snapshot.facts.map(\.id) == ["factory-a"],
                owner.presentation.activities.contains(where: {
                    $0.operationID == operationID && $0.phase == .failed(.staleAction)
                })
            else { expect(false, "进入写者前的导航保留原 freshness 校验及真实失败结果"); return }
            await Task.yield()
            expect(
                session.state.soundsDetail == .pack(packID: "factory-a"),
                "没有 busy 起点捕获的详情不得被迟到 selection 和终态结果重定向")
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
            let sessionFixture = SettingsPresentationFixtures.generalLogin(
                route: .sounds(.overview),
                soundPacksEditor: owner)
            let session = sessionFixture.session
            await waitForSoundEditorReady(owner, library: library)
            let named = try! await owner.createNamedDraft(AICuePackName("系统首音"))
            _ = session.send(.requestSoundsDetail(.draft(packID: named.packID)))
            await waitForSessionSoundsDetail(session, .draft(packID: named.packID))
            guard let selection = owner.beginSoundSelection(event: .stop) else {
                expect(false, "持久草稿须提供当前目标上下文"); return
            }
            expect(
                owner.useExistingSound(.systemSound("Basso"), selection: selection),
                "首个系统音通过独占发布事务安装")
            await owner.waitForMutationTransactionsToQuiesceForTesting()
            await waitForSessionSoundsDetail(session, .pack(packID: named.packID))
            expect(loadClaudioConfig(from: config)?.selectedPack == "user", "发布不改组选包")
            let next = try! await owner.createNamedDraft(AICuePackName("稍后继续"))
            _ = session.send(.requestSoundsDetail(.draft(packID: next.packID)))
            _ = session.send(.route(.sounds(.overview)))
            await owner.draftStore.refresh()
            expect(
                owner.draftStore.snapshot.drafts.contains { $0.packID == next.packID },
                "离页只结束查看，命名草稿仍持久存在")
            expect(
                !FileManager.default.fileExists(
                    atPath: packs.appendingPathComponent(next.packID).path),
                "未设置首音的草稿不发布为空安装包")
        }
    }

    await suite("Sound editor detail route：首次 pending 深链收敛后才完成一次导航") {
        await withTempDirectory { root in
            let route = SoundPacksWindowRoute.editEvent(packID: "pack-a", event: .stop)
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            let sessionFixture = SettingsPresentationFixtures.generalLogin(
                route: .sounds(route),
                soundPacksEditor: owner)
            let session = sessionFixture.session
            guard case .sounds(let pending) = owner.presentation.mode else {
                expect(false, "pending fixture 必须提供真实 route presentation"); return
            }
            expect(
                pending.routeState == .pendingFreshSnapshot
                    && session.state.soundsDetail == .overview,
                "首次 pending 不得过早伪装成已解析事件详情")
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let resolved) = owner.presentation.mode else { return }
            expect(resolved.routeState == .resolved(route), "深链必须通过真实共享库解析原包")
            await waitForSessionSoundsDetail(session, .pack(packID: "pack-a"))
            expect(
                session.state.routeResolution.route == .sounds(route),
                "深链目标必须保留在外层 route")
            _ = owner.send(
                .activate(.sounds(route: route, requestRevision: resolved.requestRevision)))
            await Task.yield()
            expect(
                session.state.soundsDetail == .pack(packID: "pack-a"),
                "解析完成后的同代次重发布不得再关闭详情")
            expect(
                session.send(.route(.sounds(.overview))) == .routed,
                "显式 overview 路由必须被 session 接受")
            expect(
                session.state.soundsDetail == .overview
                    && session.state.routeResolution.route == .sounds(.overview),
                "显式新的 overview 请求仍必须结束旧详情")
        }
    }
    #endif
}

/// Holds only the library's post-write publication. The original writer and capability checks
/// run unchanged, so navigation cannot turn an unstarted queued operation into disk evidence.
private final class SettingsCopyPublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let resumed = DispatchSemaphore(value: 0)
    private var armed = false
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func pauseNextPublication() {
        lock.lock()
        let pauses = armed
        armed = false
        lock.unlock()
        guard pauses else { return }
        entered.signal()
        _ = resumed.wait(timeout: .now() + 5)
    }
    func waitUntilPaused() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func release() { resumed.signal() }
}

#if DEBUG
@MainActor
@discardableResult
private func waitForSessionSoundsDetail(
    _ session: SettingsPresentationSession,
    _ expected: SoundPacksSettingsDetail
) async -> Bool {
    for _ in 0..<512 {
        if session.state.soundsDetail == expected { return true }
        await Task.yield()
    }
    expect(false, "等待 session soundsDetail 收敛到 \(expected) 超时")
    return false
}
#endif

@MainActor
private final class NoOpSoundPacksEditorNativeEffectsAdapter:
    SoundPacksEditorNativeEffectsAdapter
{
    func selectAudioFiles(allowsMultipleSelection: Bool) -> [URL] { [] }
    func playAudio(fileURL: URL, volume: Double) -> TimeInterval? { nil }
    func stopAudio() {}
    func revealInFinder(fileURL: URL) {}
}
