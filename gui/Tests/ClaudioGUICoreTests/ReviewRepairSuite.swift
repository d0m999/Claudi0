import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioSettingsPresentation
import Foundation

@MainActor
func runReviewRepairSuites() async {
    suite("Review repair: removed and expired frozen rows expose refresh") {
        for expires in [false, true] {
            let clock = ManualEventNoticeScheduler()
            let model = EventNoticeModel(
                receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
            _ = model.accept(attentionNotice(epoch: model.receiverEpoch))
            model.openReading(.diagnostics)
            let action = model.readingSnapshot.records[0].action!
            if expires {
                clock.advance(EventNoticeModel.retentionDuration)
            } else {
                _ = model.remove(action)
            }
            expect(model.readingSnapshot.needsRefresh, "擦除的冻结记录必须提供刷新入口")
            model.refreshReading()
            expect(model.readingSnapshot.records.isEmpty, "显式刷新清除不可操作行")
        }
    }
    suite("Review repair: repeated diagnostics routing retains the shared freeze") {
        let clock = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.usage), eventNoticeModel: model)
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch))
        model.openReading(.diagnostics)
        let frozen = model.readingSnapshot.records
        _ = fixture.session.send(.route(.destination(.usage)))
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch, installation: UUID()))
        expect(
            model.readingSnapshot.isOpen && model.readingSnapshot.records == frozen,
            "重复点击当前页保持冻结集合")
        expect(model.readingSnapshot.needsRefresh, "新事件等待显式刷新")
        _ = fixture.session.send(.route(.destination(.general)))
        expect(!model.readingSnapshot.isOpen, "离开诊断页释放消费者")
    }
    suite("Review repair: a reader reopened after privacy starts a new freeze") {
        let clock = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch))
        model.openReading(.diagnostics)
        let oldAction = model.readingSnapshot.records[0].action!
        let oldEpoch = model.receiverEpoch
        model.clearForPrivacy()
        expect(
            model.receiverEpoch != oldEpoch && !model.readingSnapshot.isOpen
                && model.readingSnapshot.records.isEmpty && !model.isCurrent(oldAction),
            "隐私清空释放旧消费者、来源及操作身份")
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch))
        model.openReading(.diagnostics)
        let frozen = model.readingSnapshot.records
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch, installation: UUID()))
        expect(
            model.readingSnapshot.records == frozen && model.readingSnapshot.needsRefresh,
            "恢复后重新展开注册消费者，随后事件等待显式刷新")
        model.refreshReading()
        expect(
            model.readingSnapshot.records.count == 2 && !model.readingSnapshot.needsRefresh,
            "新 epoch 仍按刷新合同发布")
    }
    suite("Review repair: banner cancellation cannot cancel another entrance") {
        let clock = ManualEventNoticeScheduler()
        let identity = HostProcessIdentity(pid: 42, startSeconds: 1, startMicroseconds: 0)
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler(),
            resolveSourceApplication: { _, action in
                SourceApplicationTarget(
                    action: action, process: identity, bundleIdentifier: "fixture.app",
                    applicationURL: URL(fileURLWithPath: "/fixture.app"), name: "Fixture")
            })
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch, processAncestors: [identity]))
        let action = model.bannerSnapshot.current!.action!
        var valid: (@MainActor () -> Bool)?
        var finish: (@MainActor (SourceApplicationOpenResult) -> Void)?
        var feedbackCount = 0
        var cancellations = 0
        let navigation = SessionNavigationCoordinator(
            model: model, scheduler: clock.scheduler(),
            openApplication: { _, current, complete in
                valid = current; finish = complete
                return EventNoticeCancellation { cancellations += 1 }
            })
        let bannerOwner = UUID()
        navigation.navigateSource(
            action, generation: navigation.capabilityGeneration, owner: bannerOwner
        ) { _ in feedbackCount += 1 }
        expect(
            navigation.result == .started
                && EventNoticeView.preferredHeight(
                    for: model.bannerSnapshot, navigation: navigation)
                    > EventNoticeView.preferredHeight(for: model.bannerSnapshot),
            "反馈占用额外窗口高度")
        navigation.cancelSourceApplication(owner: UUID())
        expect(valid?() == true && cancellations == 0, "其他入口关闭不取消横幅请求")
        navigation.cancelSourceApplication(owner: bannerOwner)
        expect(valid?() == false && cancellations == 1, "关闭请求发起方取消激活资格")
        finish?(.opened)
        expect(
            feedbackCount == 0 && navigation.result == .cancelled,
            "迟到打开不更新反馈或调用完成动作")
        navigation.navigateSource(action, generation: navigation.capabilityGeneration)
        navigation.cancelSourceApplication(owner: bannerOwner)
        expect(
            valid?() == true && navigation.result == .started,
            "横幅关闭不影响无横幅所有者的面板请求")
        finish?(.failed)
        expect(
            navigation.result == .failed
                && EventNoticeView.preferredHeight(
                    for: model.bannerSnapshot, navigation: navigation)
                    > EventNoticeView.preferredHeight(for: model.bannerSnapshot),
            "失败原因占用额外窗口高度")
        navigation.navigateSource(action, generation: navigation.capabilityGeneration)
        clock.advance(SessionNavigationCoordinator.timeout)
        expect(
            navigation.result == .timedOut
                && EventNoticeView.preferredHeight(
                    for: model.bannerSnapshot, navigation: navigation)
                    > EventNoticeView.preferredHeight(for: model.bannerSnapshot),
            "超时原因占用额外窗口高度")
        navigation.navigateSource(action, generation: navigation.capabilityGeneration)
        finish?(.opened)
        expect(
            navigation.result == .applicationFallback && model.isCurrent(action),
            "面板请求正常完成且保留提醒")
    }
    await suite("Review repair: pack drift stops the remaining preview sequence") {
        let sequence = EventPreviewSequenceCoordinator()
        var packID = "first"
        var played: [Event] = []
        let captured = packID
        let result = await sequence.run(
            events: [.taskStart, .stop], isCurrent: { packID == captured }
        ) { event in
            played.append(event)
            packID = "second"
            return 0.1
        }
        expect(result == .cancelled && played == [.taskStart], "两声之间切包不能继续播放新包")
        let completed = await sequence.run(events: [.stop]) { _ in 0.1 }
        expect(completed == .completed, "下一次显式试听仍可启动")
    }
    suite("Review repair: native adapter wiring") {
        let root = guiTestRepositoryRoot()
        func source(_ path: String) -> String {
            (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
        }
        let banner = source("gui/Sources/ClaudioGUI/EventNoticeWindowController.swift")
        expect(
            banner.contains("EventNoticeStackLayout.resolve(")
                && banner.contains(
                    "onMeasurements: { [weak self] in self?.receiveMeasurements($0) }")
                && banner.contains("navigation.$feedback"),
            "窗口使用完整卡片测量并响应共享的逐动作导航反馈")
        expect(
            banner.contains("owner: owner")
                && banner.contains("navigation.cancelSourceApplication(owner: id)")
                && banner.contains("model.dismissBanner(id: id)"),
            "横幅关闭只取消自己发起的请求")
        let diagnostics = source(
            "gui/Sources/ClaudioSettingsPresentation/ActivityDiagnosticsView.swift")
        expect(
            diagnostics.contains(
                ".onReceive(eventNoticeModel.$readingSnapshot) { snapshot in\n                guard readingEpoch != snapshot.receiverEpoch else { return }\n                readingEpoch = snapshot.receiverEpoch\n                recordsExpanded = false\n                selectedNotice = nil"
            ),
            "新隐私 epoch 同步展开状态")
        let settings = source(
            "gui/Sources/ClaudioSettingsPresentation/EventSettingsWindowView.swift")
        expect(
            settings.contains(
                ".onChange(of: model.config.selectedPack) { _ in\n            previewSequence.cancel()\n            player.stop()"
            )
                && settings.contains("model.config.selectedPack == packID"),
            "包身份改变取消序列并停止播放器")
    }
}
