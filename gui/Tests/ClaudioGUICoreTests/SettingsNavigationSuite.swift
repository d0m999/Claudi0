import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Combine
import Foundation

@MainActor
func runSettingsNavigationSuites() {
    suite("Settings destinations：固定身份、顺序与双语名称") {
        let expected: [SettingsDestination] = [
            .eventsAndSounds, .sounds, .integrations, .notifications, .general,
            .shortcuts, .usage, .about,
        ]
        expect(
            SettingsDestination.allCases == expected,
            "设置侧栏必须固定为八项目顺序")
        expect(
            Set(expected.map(\.rawValue)).count == 8,
            "八个设置目的页必须有唯一稳定身份")

        let expectedNames: [(SettingsDestination, String, String)] = [
            (.general, "通用", "General"),
            (.integrations, "集成", "Integrations"),
            (.eventsAndSounds, "默认组／工作区", "Default Group & Workspaces"),
            (.notifications, "通知", "Notifications"),
            (.sounds, "声音", "Sounds"),
            (.usage, "活动与诊断", "Activity & Diagnostics"),
            (.shortcuts, "快捷键", "Shortcuts"),
            (.about, "关于", "About"),
        ]
        for (destination, chinese, english) in expectedNames {
            expect(
                destination.localizedName(language: .zhHans) == chinese,
                "\(destination.rawValue) 必须有稳定简体中文可访问名称")
            expect(
                destination.localizedName(language: .english) == english,
                "\(destination.rawValue) 必须有稳定英文可访问名称")
            expect(
                ClaudioL10nKey.allKnown.contains(destination.localizationKey),
                "\(destination.rawValue) 的名称必须注册进 localization catalog")
        }
    }

    suite("Settings routes：只携带稳定 ID，非法或陈旧目标不回退") {
        let availability = SettingsRouteAvailability(
            integrationSurfaces: [.workBuddy],
            eventScopes: [.global, .surface(.workBuddy)],
            soundScopes: [.global, .surface(.workBuddy)],
            soundPackIDs: ["orbit-pack"],
            events: Set(Event.allCases))

        let generic = SettingsRoute.destination(.notifications)
        expect(
            resolveSettingsRoute(generic, availability: availability).failure == nil,
            "generic destination 必须直接解析")
        expect(
            generic.stableIdentityComponents == ["notifications"],
            "generic route 只能携带稳定 ID")

        let integration = SettingsRoute.integrations(IntegrationsSettingsRoute(surface: .workBuddy))
        expect(
            integration.stableIdentityComponents == ["integrations", "workbuddy"],
            "Integrations 深链接必须携带 HostSurfaceID 而非展示名")
        expect(
            resolveSettingsRoute(integration, availability: availability).failure == nil,
            "已存在 Surface 必须保留 Integrations 深链接")

        let events = SettingsRoute.events(scope: .surface(.workBuddy), event: .notification)
        expect(
            events.stableIdentityComponents
                == ["events-and-sounds", "workbuddy", "notification"],
            "Events 深链接必须携带 Sound Scope 与 Event 稳定 ID")
        expect(
            resolveSettingsRoute(events, availability: availability).failure == nil,
            "已存在 Sound Scope/Event 必须解析")

        let sounds = SettingsRoute.sounds(
            .editEvent(surface: .workBuddy, packID: "orbit-pack", event: .stop))
        expect(
            sounds.stableIdentityComponents
                == ["sounds", "workbuddy", "orbit-pack", "stop"],
            "Sounds 深链接必须携带 scope、pack 与 event 稳定 ID")
        expect(
            resolveSettingsRoute(sounds, availability: availability).failure == nil,
            "已存在声音包深链接必须解析")

        let invalidSurface = resolveSettingsRoute(
            .integrations(IntegrationsSettingsRoute(surface: .chatGPTDesktopAX)),
            availability: availability)
        expect(
            invalidSurface.destination == .integrations,
            "非法 Surface 必须留在集成目的页")
        expect(
            invalidSurface.failure == .invalidSurface(.chatGPTDesktopAX),
            "诊断专用 Surface 不得被当成产品 Surface 或回退")

        let staleSurface = resolveSettingsRoute(
            .events(scope: .surface(.codex), event: .stopFailure),
            availability: availability)
        expect(
            staleSurface.destination == .eventsAndSounds,
            "陈旧 scope 必须留在事件目的页")
        expect(
            staleSurface.failure == .staleSurface(.codex),
            "陈旧事件 scope 不得静默选择 Global 或其他 Surface")

        let stalePack = resolveSettingsRoute(
            .sounds(.editEvent(surface: .workBuddy, packID: "removed-pack", event: .stop)),
            availability: availability)
        expect(stalePack.destination == .sounds, "陈旧 pack 必须留在声音目的页")
        expect(
            stalePack.failure == .staleSoundPack("removed-pack"),
            "陈旧声音包不得静默选择 overview 或其他 pack")

        let staleEventAvailability = SettingsRouteAvailability(
            integrationSurfaces: availability.integrationSurfaces,
            eventScopes: availability.eventScopes,
            soundScopes: availability.soundScopes,
            soundPackIDs: availability.soundPackIDs,
            events: Set(Event.allCases.filter { $0 != .stopFailure }))
        let staleEvent = resolveSettingsRoute(
            .events(scope: .surface(.workBuddy), event: .stopFailure),
            availability: staleEventAvailability)
        expect(
            staleEvent.destination == .eventsAndSounds,
            "陈旧 Event 必须留在事件目的页")
        expect(
            staleEvent.failure == .staleEvent(.stopFailure),
            "陈旧 Event 不得静默选择其他事件")

        let staleSoundEvent = resolveSettingsRoute(
            .sounds(
                .editEvent(
                    surface: .workBuddy,
                    packID: "orbit-pack",
                    event: .stopFailure)),
            availability: staleEventAvailability)
        expect(
            staleSoundEvent.destination == .sounds,
            "声音编辑的陈旧 Event 必须留在声音目的页")
        expect(
            staleSoundEvent.failure == .staleEvent(.stopFailure),
            "声音编辑的陈旧 Event 不得静默选择其他事件")
    }

    suite("Settings Sounds 详情路由：audio/service/panel 的稳定身份、校验与焦点让位") {
        let availability = SettingsRouteAvailability(
            integrationSurfaces: [.workBuddy],
            eventScopes: [.global, .surface(.workBuddy)],
            soundScopes: [.global, .surface(.workBuddy)],
            soundPackIDs: ["orbit-pack"],
            events: Set(Event.allCases))
        let audio = SettingsRoute.sounds(
            SoundPacksWindowRoute(
                scope: .surface(.workBuddy), destination: .audio(packID: "orbit-pack")))
        expect(
            audio.stableIdentityComponents == ["sounds", "workbuddy", "orbit-pack", "audio"],
            "音频详情深链接必须携带 scope、pack 与稳定 audio 段")
        expect(
            resolveSettingsRoute(audio, availability: availability).failure == nil,
            "已存在声音包的音频详情必须解析")

        let service = SettingsRoute.sounds(
            SoundPacksWindowRoute(scope: .surface(.workBuddy), destination: .service))
        let panel = SettingsRoute.sounds(
            SoundPacksWindowRoute(scope: .surface(.workBuddy), destination: .panel))
        expect(
            service.stableIdentityComponents == ["sounds", "workbuddy", "service"]
                && panel.stableIdentityComponents == ["sounds", "workbuddy", "panel"],
            "服务与面板详情必须携带各自的稳定身份段")
        expect(
            resolveSettingsRoute(service, availability: availability).failure == nil
                && resolveSettingsRoute(panel, availability: availability).failure == nil,
            "服务与面板详情不要求具体声音包")

        let staleAudio = resolveSettingsRoute(
            .sounds(
                SoundPacksWindowRoute(
                    scope: .surface(.workBuddy), destination: .audio(packID: "removed-pack"))),
            availability: availability)
        expect(
            staleAudio.destination == .sounds
                && staleAudio.failure == .staleSoundPack("removed-pack"),
            "音频详情的陈旧 pack 必须留在声音目的页且不得回退")

        let unfresh = SettingsRouteAvailability(
            integrationSurfaces: [.workBuddy],
            eventScopes: [.global, .surface(.workBuddy)],
            soundScopes: [.global, .surface(.workBuddy)],
            soundPackIDs: [],
            soundPackSnapshotIsFresh: false,
            events: Set(Event.allCases))
        expect(
            resolveSettingsRoute(
                .sounds(
                    SoundPacksWindowRoute(
                        scope: .surface(.workBuddy),
                        destination: .audio(packID: "removed-pack"))),
                availability: unfresh
            ).failure == nil,
            "快照尚未 fresh 时音频详情必须保持 pending 而非拒绝")

        let blankAudio = resolveSettingsRoute(
            .sounds(
                SoundPacksWindowRoute(
                    scope: .surface(.workBuddy), destination: .audio(packID: "  "))),
            availability: availability)
        expect(
            blankAudio.failure == .invalidSoundPackID,
            "空 pack 身份必须 fail closed")

        expect(
            resolveSoundPacksWindowRoute(
                SoundPacksWindowRoute(
                    scope: .surface(.workBuddy), destination: .audio(packID: "removed-pack")),
                availablePackIDs: [], libraryState: .ready)
                == .resolved(.overview(scope: .surface(.workBuddy))),
            "缺包音频详情降级仍须保留 scope 目标")

        for destination in [
            SoundPacksWindowRoute.Destination.audio(packID: "orbit-pack"), .service, .panel,
        ] {
            expect(
                settingsWindowRequestedFocusTarget(
                    resolution: resolveSettingsRoute(
                        .sounds(
                            SoundPacksWindowRoute(
                                scope: .surface(.workBuddy), destination: destination)),
                        availability: availability)) == nil,
                "非 overview 的 Sounds 详情焦点必须让位给嵌入编辑器")
        }
    }

    suite("Settings Integrations route：detailsHost 身份、路径组件与 fail-closed 解析") {
        let availability = SettingsRouteAvailability(
            integrationSurfaces: [.workBuddy, .codex],
            eventScopes: [.global],
            soundScopes: [.global],
            soundPackIDs: [],
            events: Set(Event.allCases))

        let overview = IntegrationsSettingsRoute(surface: .workBuddy)
        let details = IntegrationsSettingsRoute(surface: .workBuddy, detailsHost: .workBuddy)
        expect(
            overview == IntegrationsSettingsRoute(surface: .workBuddy, detailsHost: nil)
                && overview != details,
            "detailsHost 默认 nil 且必须参与 typed route 身份")
        expect(
            SettingsRoute.integrations(overview).stableIdentityComponents
                == ["integrations", "workbuddy"],
            "overview 路径组件必须只携带 Surface 稳定 ID")
        expect(
            SettingsRoute.integrations(details).stableIdentityComponents
                == ["integrations", "workbuddy", "workbuddy"],
            "details 路径组件必须在 Surface 之后追加 Host 稳定 raw value")

        let resolved = resolveSettingsRoute(
            .integrations(details), availability: availability)
        expect(
            resolved.failure == nil && resolved.route == .integrations(details),
            "surface 当前选中 Host 的 details 深链接必须原样解析")

        let mismatched = resolveSettingsRoute(
            .integrations(IntegrationsSettingsRoute(surface: .workBuddy, detailsHost: .codex)),
            availability: availability)
        expect(
            mismatched.failure == nil
                && mismatched.route == .integrations(overview),
            "指向其他 Host 的 detailsHost 必须 drop 到 nil，不得跨 Host 导航")

        let diagnostic = resolveSettingsRoute(
            .integrations(
                IntegrationsSettingsRoute(surface: .workBuddy, detailsHost: .chatGPTDesktopAX)),
            availability: availability)
        expect(
            diagnostic.failure == nil
                && diagnostic.route == .integrations(overview),
            "诊断身份的 detailsHost 必须 fail closed 丢弃，不得当成产品 Host")

        let staleSurfaceDetails = IntegrationsSettingsRoute(
            surface: .claudeCode, detailsHost: .claudeCode)
        let stale = resolveSettingsRoute(
            .integrations(staleSurfaceDetails), availability: availability)
        expect(
            stale.failure == .staleSurface(.claudeCode)
                && stale.route == .integrations(staleSurfaceDetails),
            "失败解析必须原样保留请求路由，detailsHost 不被重写")
    }

    suite("Settings Sounds route：只在共享库 fresh ready 后判定陈旧 pack") {
        let route = SettingsRoute.sounds(
            .editEvent(surface: .workBuddy, packID: "delayed-pack", event: .stop))
        let loading = SettingsRouteAvailability(
            integrationSurfaces: [],
            eventScopes: [.global],
            soundScopes: [.global, .surface(.workBuddy)],
            soundPackIDs: [],
            soundPackSnapshotIsFresh: false,
            events: Set(Event.allCases))
        expect(
            resolveSettingsRoute(route, availability: loading).failure == nil,
            "首次 hydration 的空投影不得把仍可能出现的 pack 判成陈旧")

        let readyMissing = SettingsRouteAvailability(
            integrationSurfaces: [],
            eventScopes: [.global],
            soundScopes: [.global, .surface(.workBuddy)],
            soundPackIDs: [],
            soundPackSnapshotIsFresh: true,
            events: Set(Event.allCases))
        expect(
            resolveSettingsRoute(route, availability: readyMissing).failure
                == .staleSoundPack("delayed-pack"),
            "fresh ready 快照确认缺失后必须显示 stale pack 失败")

    }

    suite("Settings failed deep links：请求可见失败说明，普通导航保留标题焦点") {
        let workspaceID = UUID(uuidString: "61E452D2-5895-4D4C-BF22-D8B0A8FEB2E7")!
        let staleWorkspace = PanelSoundScopeID.workspace(workspaceID)
        let availability = SettingsRouteAvailability(
            integrationSurfaces: [],
            eventScopes: [.global],
            soundScopes: [.global],
            soundPackIDs: ["valid-pack"],
            events: Set(Event.allCases))
        let failures: [(SettingsRoute, SettingsRouteFailure, SettingsWindowFocusTarget)] = [
            (
                .sounds(.editEvent(scope: .global, packID: "removed-pack", event: .stop)),
                .staleSoundPack("removed-pack"),
                .routeFailure(.sounds)
            ),
            (
                .sounds(.editEvent(scope: staleWorkspace, packID: "valid-pack", event: .stop)),
                .staleSoundScope(staleWorkspace),
                .routeFailure(.sounds)
            ),
            (
                .events(scope: staleWorkspace, event: .stop),
                .staleSoundScope(staleWorkspace),
                .routeFailure(.eventsAndSounds)
            ),
            (
                .integrations(IntegrationsSettingsRoute(surface: .workBuddy)),
                .staleSurface(.workBuddy),
                .routeFailure(.integrations)
            ),
        ]
        for (route, failure, target) in failures {
            let resolution = resolveSettingsRoute(route, availability: availability)
            expect(
                resolution.failure == failure
                    && settingsWindowRequestedFocusTarget(resolution: resolution) == target,
                "\(route) 失败后必须请求对应目的页的可见失败说明焦点")
        }
        expect(
            settingsWindowRequestedFocusTarget(
                resolution: resolveSettingsRoute(
                    .destination(.general), availability: availability)) == .firstAction(.general),
            "普通 Settings 内容导航请求首个动作，静态标题不占 Tab")
        for route in [SettingsRoute.destination(.sounds), .sounds(.overview)] {
            expect(
                settingsWindowRequestedFocusTarget(
                    resolution: resolveSettingsRoute(route, availability: availability))
                    == .firstAction(.sounds),
                "普通 Sounds 内容导航请求首个动作")
        }
        expect(
            settingsWindowRequestedFocusTarget(
                resolution: resolveSettingsRoute(
                    .sounds(.editEvent(scope: .global, packID: "valid-pack", event: .stop)),
                    availability: availability)) == nil,
            "显式 Sounds 事件深链接仍由嵌入编辑器定位，不被标题覆盖")
        expect(
            settingsWindowRequestedFocusTarget(
                resolution: resolveSettingsRoute(
                    .destination(.eventsAndSounds), availability: availability)) == nil,
            "普通 Events 内容导航交由嵌入页定位作用域")
    }

    suite("Settings Sounds 工作区路由：身份、缺包回退与失效拒绝") {
        let id = UUID(uuidString: "61E452D2-5895-4D4C-BF22-D8B0A8FEB2E7")!
        let route = SoundPacksWindowRoute.copyAndApply(
            scope: .workspace(id), packID: "source-pack", event: .stop)
        expect(
            SettingsRoute.sounds(route).stableIdentityComponents
                == ["sounds", "workspace:\(id.uuidString)", "source-pack", "stop"],
            "工作区 Sounds 深链必须携带 UUID，不能与默认组共用身份")
        expect(
            resolveSoundPacksWindowRoute(
                route, availablePackIDs: [], libraryState: .ready)
                == .resolved(.overview(scope: .workspace(id))),
            "缺包降级仍须保留工作区目标")
        let originalTarget = WorkspaceSoundWriteTarget(
            id: id, directory: WorkspaceDirectory(kind: .directory, path: "/tmp/workspace-a"))
        let reboundTarget = WorkspaceSoundWriteTarget(
            id: id, directory: WorkspaceDirectory(kind: .directory, path: "/tmp/workspace-b"))
        let anchored = SoundPacksWindowRoute.copyAndApply(
            scope: .workspace(id), packID: "source-pack", event: .stop,
            workspaceTarget: originalTarget)
        let rebound = SoundPacksWindowRoute.copyAndApply(
            scope: .workspace(id), packID: "source-pack", event: .stop,
            workspaceTarget: reboundTarget)
        expect(
            Set([anchored, rebound]).count == 2
                && resolveSoundPacksWindowRoute(
                    anchored, availablePackIDs: [], libraryState: .ready)
                    == .resolved(.overview(scope: .workspace(id), workspaceTarget: originalTarget))
                && SettingsRoute.sounds(anchored).stableIdentityComponents
                    == SettingsRoute.sounds(rebound).stableIdentityComponents,
            "同 UUID 的目录目标须独立哈希并在缺包回退中保留，不将本地路径放进稳定导航身份")
        let available = SettingsRouteAvailability(
            integrationSurfaces: [], eventScopes: [.global, .workspace(id)],
            soundScopes: [.global, .workspace(id)], soundPackIDs: ["source-pack"],
            events: Set(Event.allCases))
        expect(
            resolveSettingsRoute(.sounds(route), availability: available).failure == nil,
            "现存工作区 Sounds 路由应可解析")
        let removed = SettingsRouteAvailability(
            integrationSurfaces: [], eventScopes: [.global], soundScopes: [.global],
            soundPackIDs: ["source-pack"], events: Set(Event.allCases))
        expect(
            resolveSettingsRoute(.sounds(route), availability: removed).failure
                == .staleSoundScope(.workspace(id)),
            "工作区删除后不得回退默认组")
    }

    suite("Settings sound shell：inactive editor 通过一个 coherent projection 提供 route 事实") {
        withTempDirectory { root in
            let packID = "pack-a"
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true))
            let editor = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: packID),
                packCards: [
                    PackCard(
                        id: packID,
                        name: "Pack A",
                        isCC0: true,
                        presentEvents: Set(Event.allCases),
                        state: .complete,
                        isSelected: true)
                ],
                selectedPackID: packID,
                selectedEventRows: [],
                libraryPresentationState: .ready,
                environment: environment,
                activation: nil)
            let hostIntegrations = HostIntegrationPresentationStore(
                state: integrationDestinationTestState(
                    statuses: [.workBuddy: .notConnected]))
            var emissions: [SettingsSoundPackShellProjection] = []
            let cancellable = settingsSoundPackShellProjections(
                editor: editor,
                hostIntegrations: hostIntegrations
            ).sink { emissions.append($0) }

            guard emissions.count == 1, let projection = emissions.first else {
                expect(false, "订阅必须同步交付且只交付一个初始 Settings shell projection")
                return
            }
            let allSurfaceScopes: Set<PanelSoundScopeID> = [.global]
            expect(editor.presentation.mode == .inactive, "fixture 必须证明未挂载 Sounds view")
            expect(
                projection.availability.soundPackIDs == [packID]
                    && projection.availability.soundPackSnapshotIsFresh,
                "inactive editor 必须从同一 root 交付 installed identity 与 fresh 事实")
            expect(
                projection.availability.integrationSurfaces
                    == Set(HostID.productVisibleCases.map(\.surfaceID))
                    && projection.availability.eventScopes
                        == [.global]
                    && projection.availability.soundScopes == allSurfaceScopes,
                "host rows 必须保留全部 Integrations Surface，只过滤 Events scope")
            expect(
                projection.availability.events == Set(Event.allCases)
                    && projection.pendingAnnouncement == nil,
                "projection 必须提供完整 Event identity，且不得制造 announcement debt")
            expect(
                resolveSettingsRoute(
                    .sounds(.editEvent(surface: nil, packID: packID, event: .stop)),
                    availability: projection.availability
                ).failure == nil,
                "inactive owner 的已安装 pack deep link 必须立即解析")
            expect(
                resolveSettingsRoute(
                    .sounds(.editEvent(surface: nil, packID: "missing", event: .stop)),
                    availability: projection.availability
                ).failure == .staleSoundPack("missing"),
                "只有同一 projection 的 fresh root 才能确认 missing pack 已陈旧")
            withExtendedLifetime(cancellable) {}

            let staleEditor = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: packID),
                packCards: [
                    PackCard(
                        id: packID,
                        name: "Previous Pack A",
                        isCC0: true,
                        presentEvents: [.stop],
                        state: .complete,
                        isSelected: true)
                ],
                selectedPackID: packID,
                selectedEventRows: [],
                libraryPresentationState: .refreshFailed(reason: "fixture failure"),
                environment: environment,
                activation: nil)
            var staleProjection: SettingsSoundPackShellProjection?
            let staleCancellable = settingsSoundPackShellProjections(
                editor: staleEditor,
                hostIntegrations: hostIntegrations
            ).sink { staleProjection = $0 }
            expect(
                staleProjection?.availability.soundPackIDs == [packID]
                    && staleProjection?.availability.soundPackSnapshotIsFresh == false,
                "refresh failure 必须保留 previous installed identity，但不能冒充 fresh")
            expect(
                resolveSettingsRoute(
                    .sounds(
                        .editEvent(
                            surface: nil,
                            packID: "still-unknown",
                            event: .stop)),
                    availability: staleProjection?.availability ?? .empty
                ).failure == nil,
                "non-fresh previous 不得永久否定尚未出现的 pack deep link")
            withExtendedLifetime(staleCancellable) {}
        }
    }

    suite("Settings sound shell：无关 editor publication 不重复唤醒订阅") {
        withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true))
            let editor = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: "pack-a"),
                packCards: [
                    PackCard(
                        id: "pack-a",
                        name: "Pack A",
                        isCC0: true,
                        presentEvents: [.stop],
                        state: .complete,
                        isSelected: true)
                ],
                selectedPackID: "pack-a",
                selectedEventRows: [],
                libraryPresentationState: .ready,
                environment: environment,
                activation: nil)
            let hostIntegrations = HostIntegrationPresentationStore(
                state: integrationDestinationTestState())
            var emissions: [SettingsSoundPackShellProjection] = []
            let cancellable = settingsSoundPackShellProjections(
                editor: editor,
                hostIntegrations: hostIntegrations
            ).sink { emissions.append($0) }

            expect(emissions.count == 1, "订阅必须先同步交付初始 projection")
            expect(
                editor.send(.activate(.inactive)) == .applied,
                "fixture 必须触发 revision 改变但不改变 Settings shell 事实")
            expect(
                emissions.count == 1,
                "activity/mode/revision 等无关 editor publication 不得重复唤醒 Settings shell，实得 "
                    + "\(emissions.count) 次")
            withExtendedLifetime(cancellable) {}
        }
    }

    suite("Settings sound shell：host/editor transaction 与 announcement queue 保持同一投影") {
        withTempDirectory { root in
            let packID = "pack-a"
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true))
            let editor = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: packID),
                packCards: [
                    PackCard(
                        id: packID,
                        name: "Pack A",
                        isCC0: true,
                        presentEvents: [.stop],
                        state: .complete,
                        isSelected: true)
                ],
                selectedPackID: packID,
                selectedEventRows: [],
                libraryPresentationState: .ready,
                environment: environment,
                activation: nil)
            let hostIntegrations = HostIntegrationPresentationStore(
                state: integrationDestinationTestState())
            var emissions: [SettingsSoundPackShellProjection] = []
            let projectionCancellable = settingsSoundPackShellProjections(
                editor: editor,
                hostIntegrations: hostIntegrations
            ).sink { projection in
                emissions.append(projection)
            }

            expect(
                emissions.count == 1
                    && emissions[0].availability.soundPackIDs == [packID],
                "初始 coherent availability 必须同步投影 editor route facts")

            hostIntegrations.replace(
                state: integrationDestinationTestState(
                    statuses: [.workBuddy: .notConnected]))
            guard emissions.count == 1 else {
                expect(false, "host-only route 事实变化必须只交付一个新 projection")
                return
            }
            let hostOnly = emissions[0]
            expect(
                hostOnly.availability.eventScopes
                    == [.global]
                    && hostOnly.availability.soundPackIDs == [packID]
                    && hostOnly.availability.soundPackSnapshotIsFresh
                    && hostOnly.pendingAnnouncement == nil,
                "host-only publication 不得重建或损坏 editor identity/freshness/debt")

            expect(
                editor.send(
                    .activate(
                        .sounds(
                            route: .overview(surface: nil),
                            requestRevision: 132))) == .applied,
                "fixture 必须产生一个 owner semantic announcement head")
            guard let pending = emissions.last?.pendingAnnouncement else {
                expect(false, "editor-only debt 变化必须穿过同一个 shell projection")
                return
            }
            expect(
                emissions.last?.availability == hostOnly.availability,
                "editor-only debt 变化必须保留最新 host-derived availability")
            let countBeforeFailedPost = emissions.count
            expect(
                editor.send(.acknowledgeAnnouncement(id: pending.id, didPost: false)) == .unchanged
                    && editor.presentation.pendingAnnouncement?.id == pending.id
                    && emissions.count == countBeforeFailedPost,
                "native post 失败不得消费 queue head 或制造同义 shell publication")
            expect(
                editor.send(.acknowledgeAnnouncement(id: pending.id, didPost: true)) == .applied
                    && editor.presentation.pendingAnnouncement == nil
                    && emissions.last?.pendingAnnouncement == nil,
                "成功 ack 必须且只能消费 exact queue head，并通过同一 projection 交付")

            editor.publishLibraryStateForTesting(
                .failed(previous: nil, error: .scanFailed(reason: "fixture failure")))
            expect(
                emissions.last?.availability.soundPackIDs.isEmpty == true
                    && emissions.last?.availability.soundPackSnapshotIsFresh == false,
                "一次 owner publication 必须同时交付匹配的新 installed IDs 与 freshness")
            expect(
                !emissions.contains {
                    $0.availability.soundPackIDs.isEmpty
                        && $0.availability.soundPackSnapshotIsFresh
                },
                "订阅不得观察到 old/new 两组 raw publisher 撕裂出的不可能组合")
            withExtendedLifetime(projectionCancellable) {}
        }
    }

    suite("Settings shell：尺寸、单滚动、焦点序、DEBUG gallery 与生产通用页") {
        expect(
            SettingsWindowGeometry.defaultWidth == 1_240
                && SettingsWindowGeometry.defaultHeight == 820,
            "默认窗口尺寸必须匹配批准原型")
        expect(
            SettingsWindowGeometry.minimumWidth == 960
                && SettingsWindowGeometry.minimumHeight == 640,
            "最小窗口尺寸必须匹配批准原型")
        expect(
            settingsSidebarWidth(windowWidth: 960) == 210
                && settingsSidebarWidth(windowWidth: 1_240) == 252,
            "侧栏必须在最小窗口收紧，并在默认窗口保持批准宽度")
        let sidebarSections = settingsSidebarSections(
            availableDestinations: SettingsDestination.allCases)
        expect(
            sidebarSections.map(\.id) == [.primary, .advanced, .product]
                && sidebarSections.flatMap(\.destinations) == SettingsDestination.allCases,
            "侧栏必须恢复三组并保持批准的八页顺序")
        expect(
            sidebarSections.map(\.destinations) == [
                [.eventsAndSounds, .sounds, .integrations, .notifications],
                [.general, .shortcuts], [.usage, .about],
            ],
            "侧栏三组必须分别承载声音与连接、偏好、活动与产品信息")
        expect(
            settingsSidebarSections(availableDestinations: [.about, .general]) == [
                SettingsSidebarSection(id: .advanced, destinations: [.general]),
                SettingsSidebarSection(id: .product, destinations: [.about]),
            ] && settingsSidebarSections(availableDestinations: []).isEmpty,
            "过滤不可用页不得产生空组，剩余页仍按固定顺序")
        expect(
            settingsSidebarDestination(
                moving: .next, from: .notifications,
                availableDestinations: SettingsDestination.allCases) == .general
                && settingsSidebarDestination(
                    moving: .previous, from: .usage,
                    availableDestinations: SettingsDestination.allCases) == .shortcuts,
            "方向键必须跨过视觉分组留白而不改变顺序")
        expect(
            settingsSidebarDestination(
                moving: .next,
                from: .usage,
                availableDestinations: SettingsDestination.allCases) == .about
                && settingsSidebarDestination(
                    moving: .previous,
                    from: .eventsAndSounds,
                    availableDestinations: SettingsDestination.allCases) == .eventsAndSounds,
            "方向键导航必须跨分组连续，并在首尾停住")
        expect(
            settingsWindowFocusOrder(selectedDestination: .sounds)
                == SettingsDestination.allCases.map(SettingsWindowFocusTarget.sidebar)
                + [],
            "Sounds 先走 sidebar，再把编辑器内焦点交给同版本的内容请求")
        expect(
            settingsWindowFocusOrder(selectedDestination: .eventsAndSounds)
                == SettingsDestination.allCases.map(SettingsWindowFocusTarget.sidebar)
                + [],
            "Events 先走 sidebar，再把精确 scope/Event 焦点交给嵌入页")
        expect(
            settingsWindowFocusOrder(selectedDestination: .general)
                == SettingsDestination.allCases.map(SettingsWindowFocusTarget.sidebar)
                + [.firstAction(.general)],
            "非嵌入目的页保留 sidebar、首个动作焦点序，标题不占 Tab")
        expect(
            settingsWindowFocusOrder(selectedDestination: .integrations)
                == SettingsDestination.allCases.map(SettingsWindowFocusTarget.sidebar)
                + [],
            "Integrations 的 destination focus coordinator 接管 sidebar 之后的内容焦点序")

    }
}
