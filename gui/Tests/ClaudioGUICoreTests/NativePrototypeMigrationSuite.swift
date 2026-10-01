import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation

@MainActor
func runNativePrototypeMigrationSuites() {
    suite("Native migration: malformed pack remains distinguishable from silent event mappings") {
        func card(_ state: PackCardState) -> PackCard {
            PackCard(
                id: "selected", name: nil, isCC0: false, presentEvents: [], state: state,
                isSelected: true)
        }
        expect(eventSettingsPackNeedsRepair(selectedPackID: "selected", cards: []), "缺包显示恢复原因")
        expect(
            eventSettingsPackNeedsRepair(
                selectedPackID: "selected", cards: [card(.broken(reason: "fixture"))]),
            "损坏 manifest 显示恢复原因")
        expect(
            !eventSettingsPackNeedsRepair(
                selectedPackID: "selected", cards: [card(.partial(present: 0, total: 5))]),
            "合法空映射不误报损坏")
        expect(
            !eventSettingsPackNeedsRepair(selectedPackID: "selected", cards: [card(.complete)]),
            "正常包不显示错误")
    }
    suite("Native migration: reader consumers never pause or reset the banner") {
        let clock = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
        let notice = attentionNotice(epoch: model.receiverEpoch)
        _ = model.accept(notice)
        clock.advance(0.18)
        clock.advance(1)
        model.openReading(.panel)
        let frozen = model.readingSnapshot.records
        model.openReading(.diagnostics)
        expect(model.readingSnapshot.records == frozen, "第二入口共享原冻结集合")
        expect(
            model.bannerSnapshot.remainingTime == 3 && model.bannerSnapshot.pauseReasons.isEmpty,
            "阅读不暂停横幅")
        clock.advance(1)
        model.closeReading(.panel)
        expect(model.readingSnapshot.isOpen && model.readingSnapshot.records == frozen, "末个入口前不释放")
        clock.advance(2.19)
        expect(
            model.bannerSnapshot.phase == .hidden
                && model.readingSnapshot.records.map(\.action) == frozen.map(\.action), "横幅收起不清阅读")
        model.closeReading(.diagnostics)
        expect(
            !model.readingSnapshot.isOpen && model.resourceUsage.readingVersions == 0, "末个关闭释放冻结源")
        expect(model.snapshot.totalCount == 1, "关闭所有阅读入口仍保留提醒")
    }
    suite("Native migration: freeze, explicit refresh, stale actions and privacy") {
        let clock = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
        let install = UUID()
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch, installation: install))
        model.openReading(.panel)
        let first = model.readingSnapshot.records[0].action!
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch, installation: install))
        expect(
            model.readingSnapshot.records[0].action == first && model.readingSnapshot.needsRefresh,
            "版本保留原顺序，显式提示刷新")
        expect(
            model.remove(first) == .stale && !model.copySessionID(first, write: { _ in true }),
            "旧版本拒绝动作")
        model.refreshReading()
        let updated = model.readingSnapshot.records[0].action!
        expect(
            updated.version == first.version + 1 && !model.readingSnapshot.needsRefresh, "刷新切换最新版本")
        clock.advance(EventNoticeModel.retentionDuration)
        expect(
            model.readingSnapshot.records[0].source == nil
                && model.readingSnapshot.records[0].occurredAt == nil, "TTL 擦除来源与绝对时间")
        model.clearForPrivacy()
        expect(
            model.readingSnapshot.records.isEmpty && model.bannerSnapshot.current == nil
                && !model.readingSnapshot.isOpen, "隐私同时擦除两投影")
    }
    suite("Native migration: banner failure and retry use the remaining reading budget") {
        let clock = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler(),
            resolveSourceApplication: { _, action in
                SourceApplicationTarget(
                    action: action,
                    process: HostProcessIdentity(pid: 42, startSeconds: 1, startMicroseconds: 0),
                    bundleIdentifier: "fixture.app",
                    applicationURL: URL(fileURLWithPath: "/fixture.app"), name: "Fixture")
            })
        _ = model.accept(
            attentionNotice(
                epoch: model.receiverEpoch,
                processAncestors: [
                    HostProcessIdentity(pid: 42, startSeconds: 1, startMicroseconds: 0)
                ]))
        let action = model.bannerSnapshot.current!.action!
        var attempts = 0
        let navigation = SessionNavigationCoordinator(
            model: model, scheduler: clock.scheduler(),
            openApplication: { _, current, complete in
                attempts += 1
                if current() { complete(attempts == 1 ? .failed : .opened) }
                return EventNoticeCancellation {}
            })
        clock.advance(0.18 + 1)
        navigation.openSourceApplication(action, generation: navigation.capabilityGeneration)
        expect(
            navigation.applicationResult == .failed
                && abs((model.bannerSnapshot.readingTime?.fraction(at: clock.time) ?? 0) - 0.75)
                    < 0.0001,
            "失败不重置")
        model.setHovering(true)
        model.setKeyboardFocused(true)
        clock.advance(10)
        model.setHovering(false)
        clock.advance(10)
        expect(model.bannerSnapshot.remainingTime == 3, "组合暂停须全部释放")
        model.setKeyboardFocused(false)
        navigation.openSourceApplication(action, generation: navigation.capabilityGeneration)
        expect(
            navigation.applicationResult == .opened && model.snapshot.totalCount == 1
                && model.lastRemovalReason != .exactReturnConfirmed, "应用成功不移除")
        clock.advance(3.18)
        expect(model.bannerSnapshot.phase == .hidden && model.snapshot.totalCount == 1, "累计四秒收起")
    }
    suite("Native migration: opening a retained reminder cannot dismiss a newer banner") {
        let clock = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time },
            scheduler: clock.scheduler(),
            resolveSourceApplication: { _, action in
                SourceApplicationTarget(
                    action: action,
                    process: HostProcessIdentity(pid: 42, startSeconds: 1, startMicroseconds: 0),
                    bundleIdentifier: "fixture.app",
                    applicationURL: URL(fileURLWithPath: "/fixture.app"),
                    name: "Fixture")
            })
        let ancestors = [HostProcessIdentity(pid: 42, startSeconds: 1, startMicroseconds: 0)]
        _ = model.accept(
            attentionNotice(
                epoch: model.receiverEpoch, installation: UUID(), processAncestors: ancestors))
        let old = model.bannerSnapshot.current!.action!
        model.dismiss(animated: false)
        _ = model.accept(
            attentionNotice(
                epoch: model.receiverEpoch, installation: UUID(), processAncestors: ancestors))
        let newer = model.bannerSnapshot.current!.action!
        clock.advance(0.18)
        let navigation = SessionNavigationCoordinator(
            model: model, scheduler: clock.scheduler(),
            openApplication: { _, isCurrent, complete in
                if isCurrent() { complete(.opened) }
                return EventNoticeCancellation {}
            })
        navigation.openSourceApplication(old, generation: navigation.capabilityGeneration)
        expect(navigation.applicationResult == .opened, "旧提醒来源仍可打开")
        expect(
            model.bannerSnapshot.current?.action == newer && model.bannerSnapshot.phase == .visible,
            "成功回调只消费对应横幅，不收起较新的另一条")
        expect(model.snapshot.totalCount == 2, "打开不删除任何提醒")
    }
    suite("Native migration: sidebar, traversal and Escape have one order") {
        let order: [SettingsDestination] = [
            .eventsAndSounds, .sounds, .integrations, .notifications, .general, .shortcuts, .usage,
            .about,
        ]
        expect(
            SettingsDestination.allCases == order && SettingsDestination.availableCases == order,
            "显示与可用列表一致")
        expect(
            settingsSidebarSections(availableDestinations: order).flatMap(\.destinations) == order,
            "侧栏一致")
        for pair in zip(order, order.dropFirst()) {
            expect(
                settingsSidebarDestination(
                    moving: .next, from: pair.0, availableDestinations: order) == pair.1, "键盘顺序一致")
        }
        let focus = PanelFocusCoordinator()
        let action = EventNoticeAction(
            id: UUID(), version: 1, epoch: UUID(), installationID: UUID())
        focus.requestNotice(action)
        expect(
            focus.consumeNoticeEscape() && focus.noticeSelection == nil && focus.noticeIsExpanded,
            "详情到列表")
        expect(focus.consumeNoticeEscape() && !focus.noticeIsExpanded, "列表到收起")
        expect(!focus.consumeNoticeEscape(), "下一次交给原生窗口关闭")
    }
    suite("Native migration: return context rejects missing scopes without a default write target")
    {
        let rule = WorkspaceSoundRule(
            id: UUID(), directory: WorkspaceDirectory(kind: .directory, path: "/fixture"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .events(scope: .workspace(rule.id), event: .stop), workspaceRules: [rule])
        let route = SoundPacksWindowRoute.editEvent(
            scope: .workspace(rule.id), packID: "settings-fixture-pack", event: .stop,
            workspaceTarget: WorkspaceSoundWriteTarget(rule: rule))
        fixture.session.editScopeSound(route)
        expect(fixture.session.soundReturnContext?.route.scope == .workspace(rule.id), "捕获真实作用域")
        expect(fixture.aiCueViewModel.session == nil, "编辑路由不触发生成")
        _ = fixture.session.returnToSoundScope()
        expect(fixture.eventSettingsSelection.route.scope == .workspace(rule.id), "恢复相同规则")
    }
    suite("Native migration: invalid return and DEBUG isolation fail closed") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .events(scope: .global, event: .stop))
        fixture.session.editScopeSound(
            .editEvent(scope: .global, packID: "settings-fixture-pack", event: .stop))
        fixture.session.replaceAvailabilityForTesting(
            SettingsRouteAvailability(
                integrationSurfaces: [], eventScopes: [], soundScopes: [.global],
                soundPackIDs: ["settings-fixture-pack"], events: Set(Event.allCases)))
        expect(
            fixture.session.returnToSoundScope() == .rejected(.staleSoundScope(.global)), "失效返回明确拒绝"
        )
        expect(
            fixture.session.state.routeResolution.failure != nil
                && fixture.session.soundReturnContext == nil, "拒绝后不落到可写默认组")
        let root = guiTestRepositoryRoot()
        let source =
            (try? String(
                contentsOf: root.appendingPathComponent(
                    "gui/Sources/ClaudioGUI/NativeUIRegressionController.swift"), encoding: .utf8))
            ?? ""
        expect(
            source.hasPrefix("#if DEBUG && CLAUDIO_UI_REGRESSION")
                && !source.contains("ClaudioPaths."), "原生 fixture 整文件 DEBUG，所有 I/O 均不依赖生产数据路径")
        let launch =
            (try? String(
                contentsOf: root.appendingPathComponent(
                    "gui/Sources/ClaudioGUI/ClaudioGUIApp.swift"), encoding: .utf8)) ?? ""
        expect(
            launch.contains("lazy var preferences")
                && launch.contains("com.claudio.app.ui-regression")
                && launch.contains("ClaudioUIRegressionFixture"), "生产 owner 创建前校验专用身份与 fixture 标记")
        expect(
            source.contains("UserDefaults(suiteName: defaultsName)")
                && source.contains("NativeRegressionCredentials()")
                && source.contains("NativeRegressionGenerator("), "defaults 与外部操作使用隔离组合")
    }

}
