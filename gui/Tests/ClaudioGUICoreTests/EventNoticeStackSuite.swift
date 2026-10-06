import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runEventNoticeStackSuites() {
    let process = HostProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 12)
    func model(_ clock: ManualEventNoticeScheduler) -> EventNoticeModel {
        EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler(),
            resolveSourceApplication: { _, action in
                SourceApplicationTarget(
                    action: action, process: process, bundleIdentifier: "com.apple.Terminal",
                    applicationURL: URL(fileURLWithPath: "/Applications/Utilities/Terminal.app"),
                    name: "Terminal")
            })
    }
    func notice(
        _ m: EventNoticeModel, installation: UUID = UUID(), native: String = "Stop",
        host: HostID = .codex, label: String = "project"
    ) -> HostEventNotice {
        attentionNotice(
            epoch: m.receiverEpoch, installation: installation,
            native: host == .claudeCode && native == "PermissionRequest" ? "Notification" : native,
            host: host,
            source: HostEventSource(
                projectLabel: label, projectKey: "key", sessionID: "session",
                mainSessionIsKnown: true),
            processAncestors: [process]
        ).replacingNavigationEvidence(
            HostNavigationEvidence(process: process, terminalProcess: process, tty: "/dev/ttys001"),
            ancestors: [process])
    }
    func remaining(_ item: EventNoticeBannerItem, _ clock: ManualEventNoticeScheduler) -> Double {
        item.readingTime.fraction(at: clock.time) * EventNoticeModel.displayDuration
    }

    suite("Banner Stack：ABC 同屏、D 排队、下一提交合并级联，FIFO 补位") {
        let clock = ManualEventNoticeScheduler(), m = model(clock)
        let notices = (0..<4).map { notice(m, label: "project-\($0)") }
        for n in notices { expect(m.accept(n) == .accepted, "合法进展接收") }
        expect(m.stackSnapshot.visible.map(\.record.id) == notices.prefix(3).map(\.id), "先到在上")
        expect(m.stackSnapshot.queued.map(\.record.id) == [notices[3].id], "D 在等待队列")
        expect(m.stackSnapshot.visible.allSatisfy { $0.entrance?.startedAt == nil }, "延迟期保持起始帧")
        clock.advance(0)
        expect(m.stackSnapshot.visible.map { $0.entrance?.delay } == [0, 0.09, 0.18], "同提交按新增序号级联")
        expect(m.stackSnapshot.visible.allSatisfy { $0.readingTime.isPaused }, "入场不消费预算")
        clock.advance(0.18)
        expect(
            m.stackSnapshot.visible[0].phase == .visible
                && m.stackSnapshot.visible[1].phase == .entering, "各条独立起读")
        clock.advance(0.18)
        expect(m.stackSnapshot.visible.allSatisfy { $0.phase == .visible }, "级联全部完成")
        expect(abs(remaining(m.stackSnapshot.visible[0], clock) - 3.82) < 0.001, "A 已独立读 180ms")
        let b = m.stackSnapshot.visible[1], a = m.stackSnapshot.visible[0]
        m.dismissBanner(id: a.id)
        expect(
            m.stackSnapshot.visible.map(\.record.id) == Array(notices.dropFirst()).map(\.id),
            "FIFO 补位不插队")
        expect(m.stackSnapshot.visible[0].id == b.id, "让位保留展示 ID")
        expect(abs(remaining(m.stackSnapshot.visible[0], clock) - 3.91) < 0.001, "让位保留预算")
        expect(m.stackSnapshot.exiting.first?.isInteractive == false, "退场立即移除交互资格")
        expect(m.stackSnapshot.exiting.first?.record == a.record, "退场冻结已绘制记录，普通进展不变成陈旧反馈")
        clock.advance(0)
        expect(m.stackSnapshot.visible[2].entrance?.delay == 0, "补位新批次从零开始")
        m.dismissStack(animated: false)
        clock.advance(1)
        expect(m.stackSnapshot.visible.isEmpty && m.stackSnapshot.queued.isEmpty, "Escape 无补播")
    }

    suite("Banner Stack：展示与等待合计 50，拒收不淘汰 FIFO，提醒独立保留") {
        let clock = ManualEventNoticeScheduler(), m = model(clock)
        let first = notice(m)
        _ = m.accept(first)
        for _ in 1..<50 { _ = m.accept(notice(m)) }
        let ids = (m.stackSnapshot.visible + m.stackSnapshot.queued).map(\.id)
        expect(m.stackSnapshot.visible.count == 3 && m.stackSnapshot.queued.count == 47, "上限含展示与等待")
        expect(m.accept(notice(m)) == .droppedCapacity, "新增普通展示满额拒收")
        expect(m.accept(notice(m, native: "PermissionRequest")) == .accepted, "合法提醒仍独立接收")
        expect(m.readingSnapshot.records.count == 1, "提醒在面板保留")
        expect((m.stackSnapshot.visible + m.stackSnapshot.queued).map(\.id) == ids, "溢出不改已有展示 FIFO")
        expect(
            m.stackSnapshot.capacityHintCount == 2 && m.stackSnapshot.overflowCount == 2, "连续溢出合并提示"
        )
        expect(m.readingSnapshot.droppedCount == 0, "展示溢出与提醒淘汰分开")
        let attentionClock = ManualEventNoticeScheduler(), attentionModel = model(attentionClock)
        let attentions = (0..<50).map { _ in notice(attentionModel, native: "PermissionRequest") }
        for n in attentions { _ = attentionModel.accept(n) }
        let waiting = attentionModel.stackSnapshot.queued[0]
        let fifo = (attentionModel.stackSnapshot.visible + attentionModel.stackSnapshot.queued).map(
            \.record.id)
        _ = attentionModel.accept(notice(attentionModel, native: "PermissionRequest"))
        expect(
            attentionModel.stackSnapshot.totalCount == 50
                && attentionModel.readingSnapshot.records.count == 50, "两种容量独立有界")
        expect(
            (attentionModel.stackSnapshot.visible + attentionModel.stackSnapshot.queued).map(
                \.record.id) == fifo, "提醒容量淘汰不能抢占展示队列")
        expect(
            attentionModel.stackSnapshot.overflowCount == 1
                && attentionModel.readingSnapshot.droppedCount == 1, "两种容量统计独立")
        expect(
            !attentionModel.readingSnapshot.records.contains { $0.id == waiting.record.id },
            "提醒淘汰后，已接受的待展示项仍保留")
        _ = attentionModel.accept(
            notice(
                attentionModel, installation: attentions[3].installationID,
                native: "PermissionRequest", label: "queued revision"))
        let revised = attentionModel.stackSnapshot.queued[0]
        expect(
            revised.id == waiting.id && revised.record.id == waiting.record.id
                && revised.record.version == 2, "已淘汰提醒的队列新版仍原位替换并递增版本")
        expect(!attentionModel.isCurrent(waiting.record.action!), "已淘汰提醒的旧展示动作也必须失效")
        expect(attentionModel.stackSnapshot.overflowCount == 1, "原位替换不计入展示溢出")
    }

    suite("Banner Stack：同提醒新版原位替换，重获四秒，旧动作与旧导航失效") {
        let clock = ManualEventNoticeScheduler(), m = model(clock), installation = UUID()
        _ = m.accept(notice(m, installation: installation, native: "PermissionRequest"))
        _ = m.accept(notice(m))
        clock.advance(1.3)
        let a = m.stackSnapshot.visible[0], b = m.stackSnapshot.visible[1]
        let bRemaining = remaining(b, clock)
        var callback: (@MainActor (SessionNavigationActionResult) -> Void)?
        var cancelled = 0
        let navigation = SessionNavigationCoordinator(
            model: m, scheduler: clock.scheduler(), uptime: { clock.time },
            navigateHost: { _, _, _, _, complete in
                callback = complete
                return EventNoticeCancellation { cancelled += 1 }
            })
        navigation.navigateSource(
            a.record.action!, generation: navigation.capabilityGeneration, owner: a.id)
        m.openReading(.panel)
        let frozen = m.readingSnapshot.records.first!
        _ = m.accept(
            notice(m, installation: installation, native: "PermissionRequest", label: "updated"))
        let updated = m.stackSnapshot.visible[0]
        expect(updated.id == a.id && updated.record.version == 2, "展示 ID 稳定，动作版本改变")
        expect(updated.entrance == a.entrance && updated.phase == .visible, "原位不重播入场")
        expect(remaining(updated, clock) == 4, "新版重新获得完整预算")
        expect(abs(remaining(m.stackSnapshot.visible[1], clock) - bRemaining) < 0.001, "其他预算保持")
        expect(
            !m.isCurrent(a.record.action!) && cancelled == 1 && !navigation.isNavigating, "旧版本请求取消")
        callback?(.exactReturnConfirmed)
        expect(m.isCurrent(updated.record.action!), "迟到旧结果不能消费新版本")
        expect(
            m.readingSnapshot.records.first?.version == frozen.version
                && m.readingSnapshot.needsRefresh, "冻结阅读仍保留旧版")
        m.dismissBanner(id: updated.id, animated: false)
        _ = m.accept(notice(m, installation: installation, native: "PermissionRequest"))
        expect(
            m.stackSnapshot.visible.last?.record.version == 3
                && m.stackSnapshot.visible.last?.id != a.id, "收起后的新版追加新展示")
    }

    suite("Banner Stack：排队新版不占位，独立预算、全栈暂停与模态交叠") {
        let clock = ManualEventNoticeScheduler(), m = model(clock), installation = UUID()
        for _ in 0..<3 { _ = m.accept(notice(m)) }
        _ = m.accept(notice(m, installation: installation, native: "PermissionRequest"))
        let queued = m.stackSnapshot.queued[0]
        _ = m.accept(
            notice(m, installation: installation, native: "PermissionRequest", label: "new"))
        expect(
            m.stackSnapshot.totalCount == 4 && m.stackSnapshot.queued[0].id == queued.id,
            "排队原位更新不增位")
        clock.advance(1.36)
        m.setHovering(true)
        m.setKeyboardFocused(true)
        m.setPauseReason(.modal, active: true)
        let saved = m.stackSnapshot.visible.map { remaining($0, clock) }
        clock.advance(30)
        m.setHovering(false); m.setKeyboardFocused(false)
        expect(m.stackSnapshot.visible.map { remaining($0, clock) } == saved, "模态仍暂停全部")
        expect(m.stackSnapshot.queued[0].readingTime.remaining == 4, "排队期间不消耗")
        m.setPauseReason(.modal, active: false)
        clock.advance(1)
        for (item, budget) in zip(m.stackSnapshot.visible, saved) {
            expect(abs(remaining(item, clock) - budget + 1) < 0.001, "恢复独立剩余预算")
        }
    }

    suite("Banner Stack：小屏回队列保存预算，重新展示与重绘不重置") {
        let clock = ManualEventNoticeScheduler(), m = model(clock)
        for _ in 0..<4 { _ = m.accept(notice(m)) }
        clock.advance(1.36)
        let b = m.stackSnapshot.visible[1], c = m.stackSnapshot.visible[2]
        let bRemaining = remaining(b, clock), cRemaining = remaining(c, clock)
        m.setVisibleCapacity(1)
        expect(m.stackSnapshot.queued.prefix(2).map(\.id) == [b.id, c.id], "缩小只退回 FIFO 后缀")
        clock.advance(1)
        expect(
            abs(m.stackSnapshot.queued[0].readingTime.remaining - bRemaining) < 0.001, "回队列暂停并保存")
        m.setVisibleCapacity(3)
        expect(
            m.stackSnapshot.visible[1].id == b.id && m.stackSnapshot.visible[1].phase == .visible,
            "重新展示不重播入场")
        expect(abs(remaining(m.stackSnapshot.visible[1], clock) - bRemaining) < 0.001, "B 不重置")
        expect(abs(remaining(m.stackSnapshot.visible[2], clock) - cRemaining) < 0.001, "C 不重置")
        let motion = m.stackSnapshot.visible[1].entrance
        m.expireNow(); m.setVisibleCapacity(3)
        expect(m.stackSnapshot.visible[1].entrance == motion, "重绘不重新创建入场")
        m.setVisibleCapacity(0)
        expect(m.stackSnapshot.visible.isEmpty && m.stackSnapshot.queued.count == 4, "极端屏幕保留待展示入口")
    }

    suite("Banner Stack：首次实测不让位，入场中补位共享计划，回队后原地展示") {
        let clock = ManualEventNoticeScheduler(), m = model(clock)
        for index in 0..<3 { _ = m.accept(notice(m, label: "position-\(index)")) }
        clock.advance(0)
        let ids = m.stackSnapshot.visible.map(\.id)
        m.updateDisplayPositions([ids[0]: 0, ids[1]: 108, ids[2]: 216])
        expect(m.stackSnapshot.visible.allSatisfy { $0.relocation == nil }, "首次完整测量只确定布局")
        clock.advance(0.1)
        m.dismissBanner(id: ids[0])
        m.updateDisplayPositions([ids[1]: 0, ids[2]: 108])
        let b = m.stackSnapshot.visible[0], c = m.stackSnapshot.visible[1]
        expect(b.phase == .entering && b.relocation?.fromY == 108, "入场中也按原绘制位置让位")
        expect(b.entrance?.delay == 0.09 && b.readingTime.isPaused, "让位不重启入场或抢跑阅读")
        expect(b.relocation?.delay == 0.045 && c.relocation?.delay == 0.045, "按目标索引安排让位延迟")
        clock.advance(0.3)
        let budget = remaining(m.stackSnapshot.visible[1], clock)
        m.setVisibleCapacity(1)
        clock.advance(0.5)
        m.setVisibleCapacity(3)
        m.updateDisplayPositions([ids[1]: 0, ids[2]: 108])
        expect(m.stackSnapshot.visible[1].relocation == nil, "回队再展示直接使用新布局，不从旧位置飞入")
        expect(abs(remaining(m.stackSnapshot.visible[1], clock) - budget) < 0.001, "回队和补位保留独立剩余预算")
    }

    suite("Banner Stack：完整实测卡高选择前缀，队列受剩余高度限制") {
        let layout = EventNoticeStackLayout.resolve(
            cardHeights: [75, 130, 75], totalCount: 5, availableHeight: 320,
            queueEntryHeight: 44, queueExpanded: true)
        expect(layout.visibleCapacity == 2 && layout.cardsHeight == 213, "长反馈卡必须完整容纳")
        expect(layout.queueHeight == 47 && layout.height == 320, "队列受剩余高度限制")
        let tiny = EventNoticeStackLayout.resolve(
            cardHeights: [75, 75, 75], totalCount: 3, availableHeight: 70, queueEntryHeight: 44)
        expect(tiny.visibleCapacity == 0 && tiny.height == 44, "不足单卡仅保留入口")
        let noMeasurement = EventNoticeStackLayout.resolve(
            cardHeights: [75, 0, 75], totalCount: 3, availableHeight: 800, queueEntryHeight: 44)
        expect(noMeasurement.visibleCapacity == 1, "未测量不得跳过 FIFO 前项")
        let tall = EventNoticeStackLayout.resolve(
            cardHeights: [75, 75, 75], totalCount: 50, availableHeight: 1000,
            queueEntryHeight: 44, queueExpanded: true)
        expect(tall.visibleCapacity == 3 && tall.queueHeight == 220, "最多三卡、队列最多220")
        let clock = ManualEventNoticeScheduler(), m = model(clock)
        m.setVisibleCapacity(3, measuredIDs: [])
        _ = m.accept(notice(m)); clock.advance(2)
        expect(
            m.stackSnapshot.visible.isEmpty && m.stackSnapshot.queued[0].readingTime.remaining == 4,
            "原生实测前无入场或预算抢跑")
        let id = m.stackSnapshot.queued[0].id
        m.setVisibleCapacity(3, measuredIDs: [id]); clock.advance(0.18)
        expect(m.stackSnapshot.visible[0].readingTime.remaining == 4, "测量放行后完整起读")
    }

    suite("Banner Stack：纯动效计划、让位延迟、纱层与中途 Reduce Motion") {
        let entrance = EventNoticeMotionPlan(kind: .entrance, startedAt: 100, index: 2)
        expect(
            entrance.offsetY(at: 100.1, reducedMotion: false) == -8
                && entrance.opacity(at: 100.1, reducedMotion: false) == 0, "延迟期保持初帧")
        expect(abs((entrance.completesAt ?? 0) - 100.36) < 0.001, "预算起点等于入场完成")
        let move = EventNoticeMotionPlan(kind: .relocation, startedAt: 100, index: 2, fromY: 83)
        expect(move.delay == 0.09 && move.duration == 0.26, "让位目标索引延迟")
        expect(move.offsetY(at: 100.05, reducedMotion: false) == 83, "让位延迟仍保持原位置")
        let row = EventNoticeMotionPlan(kind: .queueRow, startedAt: 100, index: 3)
        expect(row.delay == 0.165 && row.offsetY(at: 100, reducedMotion: false) == -5, "队列逐行延迟")
        expect(
            entrance.offsetY(at: 100, reducedMotion: true) == 0
                && entrance.opacity(at: 100, reducedMotion: true) == 1
                && entrance.spineScale(at: 100, reducedMotion: true) == 1, "Reduce Motion 全部归零")
        let clock = ManualEventNoticeScheduler(), m = model(clock)
        for _ in 0..<3 { _ = m.accept(notice(m)) }
        expect(m.stackSnapshot.visible.map(\.backgroundVeil) == [0, 0.2, 0.32], "首条无纱，后二条固定层级")
        clock.advance(0.20)
        let aRemaining = remaining(m.stackSnapshot.visible[0], clock)
        m.setReducedMotion(true)
        expect(
            m.stackSnapshot.visible.allSatisfy { $0.phase == .visible && $0.entrance == nil },
            "中途开启立即完成入场")
        expect(abs(remaining(m.stackSnapshot.visible[0], clock) - aRemaining) < 0.001, "正在阅读的条目不重置")
        expect(remaining(m.stackSnapshot.visible[1], clock) == 4, "延迟中的条目开始预算")
        clock.advance(4)
        expect(!m.stackSnapshot.hasPresentation, "Reduce Motion 预算仍有效且无退场延迟")
    }

    suite("Banner Stack：按动作保留反馈，关闭B不取消A，单在途原始三秒") {
        let clock = ManualEventNoticeScheduler(), m = model(clock)
        for _ in 0..<3 { _ = m.accept(notice(m, native: "PermissionRequest")) }
        clock.advance(0.36); m.setHovering(true)
        let a = m.stackSnapshot.visible[0], b = m.stackSnapshot.visible[1],
            c = m.stackSnapshot.visible[2]
        var callbacks: [@MainActor (SessionNavigationActionResult) -> Void] = []
        var cancelled = 0
        let navigation = SessionNavigationCoordinator(
            model: m, scheduler: clock.scheduler(), uptime: { clock.time },
            navigateHost: { _, _, _, _, complete in
                callbacks.append(complete); return EventNoticeCancellation { cancelled += 1 }
            },
            openApplication: { _, _, complete in
                complete(.failed); return EventNoticeCancellation {}
            })
        navigation.navigateSource(
            a.record.action!, generation: navigation.capabilityGeneration, owner: a.id)
        navigation.navigateSource(
            b.record.action!, generation: navigation.capabilityGeneration, owner: b.id)
        expect(callbacks.count == 1 && navigation.isNavigating, "全局单在途")
        m.dismissBanner(id: b.id)
        expect(navigation.isNavigating && cancelled == 0, "关闭B保留A请求")
        clock.advance(2.99)
        expect(navigation.isNavigating, "暂停阅读不改变原始导航预算")
        clock.advance(0.01)
        expect(navigation.result(for: a.record.action) == .timedOut, "三秒准时超时")
        navigation.navigateSource(
            c.record.action!, generation: navigation.capabilityGeneration, owner: c.id)
        expect(
            navigation.result(for: a.record.action) == .timedOut
                && navigation.result(for: c.record.action) == .started, "C开始不清除A反馈")
        callbacks[1](.failed)
        expect(
            navigation.result(for: c.record.action) == .failed
                && navigation.result(for: a.record.action) == .timedOut, "各条独立失败原因")
        let before = remaining(m.stackSnapshot.visible[0], clock)
        navigation.navigateSource(
            a.record.action!, generation: navigation.capabilityGeneration, owner: a.id)
        callbacks[2](.requestSent)
        expect(
            navigation.result(for: a.record.action) == .requestSent
                && m.isCurrent(a.record.action!), "requestSent保留横幅和提醒")
        expect(remaining(m.stackSnapshot.visible[0], clock) == before, "失败重试不重置阅读")
        navigation.navigateSource(
            a.record.action!, generation: navigation.capabilityGeneration, owner: a.id)
        m.dismissBanner(id: a.id)
        expect(!navigation.isNavigating, "收起所属横幅取消请求")
        callbacks[3](.exactReturnConfirmed)
        expect(m.isCurrent(a.record.action!), "迟到成功不能移除提醒")
        m.clearForPrivacy()
        expect(navigation.feedback.isEmpty, "隐私清空释放所有结果")
    }

    suite("Banner Stack：精确返回仅移除捕获版本，其他横幅与应用回退保留") {
        let clock = ManualEventNoticeScheduler(), m = model(clock)
        for _ in 0..<2 { _ = m.accept(notice(m, native: "PermissionRequest")) }
        clock.advance(0.4)
        let a = m.stackSnapshot.visible[0], b = m.stackSnapshot.visible[1]
        var callback: (@MainActor (SessionNavigationActionResult) -> Void)?
        let navigation = SessionNavigationCoordinator(
            model: m, scheduler: clock.scheduler(), uptime: { clock.time },
            navigateHost: { _, _, _, _, complete in
                callback = complete; return EventNoticeCancellation {}
            })
        navigation.navigateSource(
            b.record.action!, generation: navigation.capabilityGeneration, owner: b.id)
        callback?(.exactReturnConfirmed)
        expect(
            m.stackSnapshot.visible.map(\.id) == [a.id] && !m.isCurrent(b.record.action!),
            "精确返回只消费B")
        expect(m.isCurrent(a.record.action!) && m.readingSnapshot.records.count == 1, "A与提醒保留")
        expect(
            m.stackSnapshot.exiting.first?.id == b.id
                && m.stackSnapshot.exiting.first?.backgroundVeil == 0.2,
            "精确返回保留非交互退场帧的原层样式")
        navigation.navigateSource(
            a.record.action!, generation: navigation.capabilityGeneration, owner: a.id)
        callback?(.applicationFallback)
        expect(m.stackSnapshot.visible.first?.id == a.id && m.isCurrent(a.record.action!), "应用回退保留")
        m.dismissStack()
        expect(
            m.stackSnapshot.visible.isEmpty && m.stackSnapshot.queued.isEmpty
                && m.readingSnapshot.records.count == 1, "Escape保留提醒")
    }

    suite("Banner Stack：来源 OFF、TTL、静默、隐私包含队列退场与迟到回调") {
        let clock = ManualEventNoticeScheduler(), m = model(clock)
        _ = m.accept(notice(m, native: "PermissionRequest", host: .codex))
        _ = m.accept(notice(m, native: "PermissionRequest", host: .claudeCode))
        _ = m.accept(notice(m, native: "PermissionRequest", host: .codex))
        _ = m.accept(notice(m, native: "PermissionRequest", host: .codex))
        let a = m.stackSnapshot.visible[0]
        m.dismissBanner(id: a.id)
        m.hideBanner(for: .codex)
        expect(
            m.stackSnapshot.visible.allSatisfy { $0.record.host == .claudeCode }
                && m.stackSnapshot.queued.isEmpty && m.stackSnapshot.exiting.isEmpty, "OFF清除来源所有展示帧"
        )
        expect(
            m.isCurrent(a.record.action!) && m.readingSnapshot.records.count == 4, "OFF保留提醒与主动能力")
        m.setHovering(true); clock.advance(1800)
        expect(!m.stackSnapshot.hasPresentation && m.readingSnapshot.records.isEmpty, "TTL优先于暂停与排队")
        m.setAutomaticallySuppressed(true)
        _ = m.accept(notice(m)); _ = m.accept(notice(m, native: "PermissionRequest"))
        m.setAutomaticallySuppressed(false)
        expect(!m.stackSnapshot.hasPresentation && m.readingSnapshot.records.count == 1, "静默恢复无补播")
        _ = m.accept(notice(m)); m.dismissStack()
        expect(!m.stackSnapshot.exiting.isEmpty, "存在退场帧")
        m.setSystemPrivacy(.screenLocked, active: true)
        m.setSystemPrivacy(.sleeping, active: true)
        clock.advance(2000)
        expect(!m.stackSnapshot.hasPresentation && m.resourceUsage.timers == 0, "隐私即时清空计时和退场")
        m.setSystemPrivacy(.screenLocked, active: false)
        expect(!m.canReceive, "睡眠尚未恢复")
        m.setSystemPrivacy(.sleeping, active: false)
        expect(m.canReceive && !m.stackSnapshot.hasPresentation, "恢复无旧事件")
    }

    suite("Banner Stack：新增队列文案双语、参数与注册") {
        for language in [ClaudioAppLanguage.english, .zhHans] {
            let l10n = ClaudioL10n(language: language)
            expect(l10n.format(.eventNoticeQueueWaiting, 47).contains("47"), "队列计数参数")
            expect(l10n.format(.eventNoticeCapacityHint, 2).contains("2"), "容量计数参数")
            for key in [
                ClaudioL10nKey.eventNoticeStack, .eventNoticeQueueWaiting,
                .eventNoticeQueueCollapse, .eventNoticeQueueStatus, .eventNoticeCapacityHint,
            ] {
                expect(ClaudioL10nKey.allKnown.contains(key) && !l10n.text(key).isEmpty, "文案已注册")
            }
        }
    }

    suite("Banner Stack：迟到的旧提交不能启动或取消新展示批次") {
        let clock = ManualEventNoticeScheduler()
        let base = clock.scheduler()
        var commits: [@MainActor () -> Void] = []
        let scheduler = EventNoticeScheduler { delay, callback in
            if delay == 0 { commits.append(callback) }
            return base.schedule(after: delay, callback)
        }
        let m = EventNoticeModel(receiverEpoch: UUID(), now: { clock.time }, scheduler: scheduler)
        _ = m.accept(notice(m))
        m.dismissStack(animated: false)
        _ = m.accept(notice(m))
        expect(commits.count == 2, "旧批次取消后新批次有独立提交")
        commits[0]()
        expect(m.stackSnapshot.visible.first?.entrance?.startedAt == nil, "旧回调不提前播放新条目")
        clock.advance(0)
        expect(m.stackSnapshot.visible.first?.entrance?.startedAt == clock.time, "新提交仍能正常执行")
        m.clearForPrivacy()
        commits[1]()
        expect(!m.stackSnapshot.hasPresentation && m.resourceUsage.timers == 0, "旧提交不穿越隐私 epoch")
    }
}
