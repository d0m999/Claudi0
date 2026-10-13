import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Combine
import Foundation

@MainActor
private final class StackPresentationFixture {
    let clock = ManualEventNoticeScheduler()
    let model: EventNoticeModel
    let preferences = ClaudioPreferences(previewLanguage: .english)
    let navigation: SessionNavigationCoordinator
    let presentation: EventNoticeStackPresentation

    init(count: Int = 0, height: Double = 900, holdNavigation: Bool = false) {
        let clock = clock
        model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler(),
            resolveSourceApplication: { _, action in
                guard holdNavigation else { return nil }
                return SourceApplicationTarget(
                    action: action,
                    process: HostProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 1),
                    bundleIdentifier: "example.terminal",
                    applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
                    name: "Example")
            })
        navigation = SessionNavigationCoordinator(
            model: model, scheduler: clock.scheduler(), uptime: { clock.time },
            openApplication: { _, _, _ in EventNoticeCancellation {} })
        presentation = EventNoticeStackPresentation(
            model: model, preferences: preferences,
            navigation: navigation, scheduler: clock.scheduler())
        presentation.updateViewport(width: 440, availableHeight: height)
        for _ in 0..<count {
            _ = model.accept(
                attentionNotice(
                    epoch: model.receiverEpoch,
                    processAncestors: holdNavigation
                        ? [HostProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 1)]
                        : nil))
        }
        clock.advance(0)
    }

    func measure(
        _ height: (EventNoticeMeasurementRequest) -> Double = { request in
            switch request.token.role {
            case .card: return 100
            case .queueEntry(_, let expanded): return expanded ? 50 : 40
            case .capacityHint: return 60
            case .queueContent: return 1_000
            }
        }
    ) {
        // Supply measurements, not another implementation of layout. Each pass represents one
        // completed native measurement transaction; the collaborator itself schedules all work.
        for _ in 0..<8 {
            let requests = presentation.output.requests
            if requests.isEmpty { break }
            expect(requests.count <= 8, "最多八个隐藏测量副本")
            presentation.receiveMeasurements(
                Dictionary(uniqueKeysWithValues: requests.map { ($0.token, height($0)) }))
            clock.advance(0)
        }
    }
}

@MainActor
func runEventNoticeStackPresentationSuites() {
    suite("Stack presentation：零、一、三卡与 FIFO 未测量前项") {
        let empty = StackPresentationFixture()
        expect(
            !empty.presentation.output.isEligible && empty.presentation.output.requests.isEmpty,
            "空栈无窗口和测量")
        for count in [1, 3, 4] {
            let f = StackPresentationFixture(count: count)
            let first = f.model.stackSnapshot.candidates.first!.id
            let later = f.presentation.output.requests.filter { $0.token.role != .card(first) }
            f.presentation.receiveMeasurements(
                Dictionary(uniqueKeysWithValues: later.map { ($0.token, 50) }))
            f.clock.advance(0)
            expect(f.model.stackSnapshot.visible.isEmpty, "未测量 FIFO 前项不可被跨越")
            f.measure()
            expect(f.model.stackSnapshot.visible.count == min(3, count), "完整前缀最多三卡")
            expect(f.model.stackSnapshot.visible.first?.id == first, "首项仍在首位")
            expect(f.presentation.output.isEligible, "完成实测后窗口可显示")
            expect(f.presentation.output.height <= 900, "最终高度受可用高度限制")
        }
    }
    suite("Stack presentation：逐 k 队列两态、容量提示与剩余空间") {
        let f = StackPresentationFixture(count: 51, height: 416)
        f.measure { request in
            switch request.token.role {
            case .card: return 100
            case .queueEntry(let k, let expanded): return k == 3 ? (expanded ? 24 : 20) : 160
            case .capacityHint: return 60
            case .queueContent: return 1_000
            }
        }
        expect(
            f.model.stackSnapshot.totalCount == 50 && f.model.stackSnapshot.capacityHintCount == 1,
            "50 条上限且保留容量提示")
        expect(f.model.stackSnapshot.visible.count == 3, "不跨 k 取入口全局最大值")
        expect(f.presentation.output.queueEntryHeight == 24, "入口预留本 k 两态较高值")
        expect(
            f.presentation.output.showsCapacityHint && f.presentation.output.height == 416,
            "提示与间距纳入完整高度")
        f.model.setQueueExpanded(true); f.clock.advance(0)
        expect(f.model.stackSnapshot.visible.count == 3, "展开不会挤走卡片")
        expect(f.presentation.output.queueHeight == 0, "没有剩余空间时不分配列表")
        f.presentation.updateViewport(width: 440, availableHeight: 900); f.clock.advance(0)
        expect(f.presentation.output.queueHeight == 220, "列表最多 220pt")
        f.presentation.updateViewport(width: 440, availableHeight: 480); f.clock.advance(0)
        expect(f.presentation.output.queueHeight == 56, "列表只用剩余空间")
        f.presentation.updateViewport(width: 440, availableHeight: 170); f.clock.advance(0)
        expect(
            f.model.stackSnapshot.visible.isEmpty && f.presentation.output.isEligible, "零卡优先保留完整入口")
        expect(
            !f.presentation.output.showsCapacityHint
                && f.presentation.output.queueEntryHeight == 160, "入口优先于容不下的提示")
        f.presentation.updateViewport(width: 440, availableHeight: 10); f.clock.advance(0)
        expect(!f.presentation.output.isEligible, "入口也容不下则隐藏，提醒仍可在面板访问")
        expect(f.model.stackSnapshot.totalCount == 50, "隐藏不丢弃条目")
    }
    suite("Stack presentation：短队列自然高度不改变准入") {
        let f = StackPresentationFixture(count: 4)
        f.measure()
        let ids = f.model.stackSnapshot.visible.map(\.id)
        f.model.setQueueExpanded(true); f.clock.advance(0)
        f.measure { $0.token.role == .queueContent ? 70 : 100 }
        expect(f.presentation.output.queueHeight == 70, "短列表使用实测自然高度")
        expect(f.model.stackSnapshot.visible.map(\.id) == ids, "列表高度不改变卡片准入")
    }
    suite("Stack presentation：测量身份、A B A、乱序和非法回调") {
        let f = StackPresentationFixture(count: 1)
        let original = f.presentation.output.requests.first!.token
        f.presentation.updateViewport(width: 268, availableHeight: 900); f.clock.advance(0)
        let narrow = f.presentation.output.requests.first!.token
        f.presentation.updateViewport(width: 440, availableHeight: 900); f.clock.advance(0)
        let current = f.presentation.output.requests.first!.token
        expect(
            original.generation < narrow.generation && narrow.generation < current.generation,
            "A B A 使用递增代次")
        f.presentation.receiveMeasurements([original: 100, narrow: 100, current: .nan]);
        f.clock.advance(0)
        expect(f.model.stackSnapshot.visible.isEmpty, "旧代次及 NaN 无效")
        for height in [Double.infinity, -1, 0] {
            f.presentation.receiveMeasurements([current: height]); f.clock.advance(0)
            expect(f.model.stackSnapshot.visible.isEmpty, "无穷、负数、零无效")
        }
        let unknown = EventNoticeMeasurementToken(
            identity: UUID(), epoch: current.epoch,
            generation: current.generation, width: current.width, role: current.role)
        f.presentation.receiveMeasurements([unknown: 100]); f.clock.advance(0)
        expect(f.model.stackSnapshot.visible.isEmpty, "未知身份不准入")
        f.measure()
        let committed = f.presentation.output
        f.presentation.receiveMeasurements([current: 999]); f.clock.advance(0)
        expect(f.presentation.output == committed, "重复回调不覆盖已经接受的测量")
        f.preferences.setLanguage(.zhHans); f.clock.advance(0)
        expect(f.presentation.output.requests.first?.token != current, "语言变化绑定新内容 token")
        expect(f.presentation.output.isEligible, "同宽安全几何在语言重测时保留")
        f.measure()
        f.presentation.updateFontEnvironment("accessibility3"); f.clock.advance(0)
        expect(!f.presentation.output.requests.isEmpty, "字体环境改变需重测")
    }
    suite("Stack presentation：新版自身预算、原位更新与无效旧版本") {
        let f = StackPresentationFixture(count: 2)
        f.measure(); f.clock.advance(1)
        let before = f.model.stackSnapshot.visible
        let a = before[0], b = before[1]
        let remainingB = b.readingTime.fraction(at: f.clock.time) * 4
        let old = a.record.notice!
        _ = f.model.accept(
            attentionNotice(
                epoch: f.model.receiverEpoch,
                installation: old.installationID, source: old.source))
        f.clock.advance(0)
        expect(f.model.stackSnapshot.visible.map(\.id) == before.map(\.id), "同 ID 新版原位展示")
        expect(f.model.stackSnapshot.visible[0].readingTime.remaining == 4, "只有新版重获四秒")
        expect(f.model.stackSnapshot.visible[1].readingTime.remaining == remainingB, "其他条目预算不变")
        expect(f.model.stackSnapshot.visible[0].entrance == a.entrance, "重测不重播入场")
        expect(
            f.presentation.output.requests.first?.content?.version == a.record.version + 1,
            "测量捕获新版记录")
        _ = f.model.accept(attentionNotice(epoch: f.model.receiverEpoch))
        f.clock.advance(0)
        expect(f.model.stackSnapshot.visible.count == 2, "已显示项缺少当前高度时禁止准入新卡")
        f.measure()
        expect(f.model.stackSnapshot.visible.count == 3, "当前内容实测后才准入")
    }
    suite("Stack presentation：几何挂起、回队及暂停原因并集") {
        let f = StackPresentationFixture(count: 3)
        f.measure(); f.clock.advance(1)
        let before = f.model.stackSnapshot.visible
        let remaining = before.map { $0.readingTime.fraction(at: f.clock.time) * 4 }
        f.presentation.updateViewport(width: 268, availableHeight: 500)
        expect(!f.presentation.output.isEligible, "变窄立即挂起旧几何")
        expect(f.model.stackSnapshot.pauseReasons.contains(.geometryUnavailable), "独立几何暂停原因")
        f.clock.advance(10)
        expect(f.model.stackSnapshot.visible.map(\.id) == before.map(\.id), "挂起保持展示身份")
        expect(f.model.stackSnapshot.visible.map(\.readingTime.remaining) == remaining, "隐藏期间不消耗预算")
        f.model.setHovering(true)
        f.measure()
        expect(
            f.presentation.output.isEligible && f.model.stackSnapshot.pauseReasons.contains(.hover),
            "几何恢复保留其他暂停原因")
        expect(!f.model.stackSnapshot.pauseReasons.contains(.geometryUnavailable), "恢复只撤销几何暂停")
        expect(f.model.stackSnapshot.visible.map(\.entrance) == before.map(\.entrance), "恢复不重播入场")
        f.presentation.updateViewport(width: 268, availableHeight: 160); f.clock.advance(0)
        expect(f.model.stackSnapshot.visible.count == 1, "实测后小屏退回 FIFO 队列")
        expect(f.model.stackSnapshot.queued.first?.readingTime.remaining == remaining[1], "回队保留预算")
        f.presentation.updateViewport(width: 268, availableHeight: nil); f.clock.advance(0)
        f.measure(); f.clock.advance(EventNoticeModel.retentionDuration)
        expect(!f.model.stackSnapshot.hasPresentation, "几何暂停不延长保留期限")
    }
    suite("Stack presentation：原子发布、重复输入和订阅重入") {
        let f = StackPresentationFixture(count: 3)
        var invalid = false, publications = 0
        let subscription = f.model.$stackSnapshot.sink { stack in
            publications += 1
            for (index, item) in stack.visible.enumerated() {
                if item.positionY != Double(index) * 108 { invalid = true }
            }
        }
        f.measure(); f.clock.advance(0.5)
        expect(!invalid, "观察者从未收到新准入搭配旧位置")
        let before = f.model.stackSnapshot, count = publications
        f.presentation.updateViewport(width: 440, availableHeight: 900)
        f.presentation.refreshContent(); f.clock.advance(0)
        expect(f.model.stackSnapshot == before && publications == count, "完全相同输入不发布或重启预算与动效")
        var changed = false
        let reentrant = f.presentation.outputs.sink { value in
            if value.isEligible && !changed {
                changed = true
                f.preferences.setLanguage(.zhHans)
            }
        }
        f.clock.advance(0)
        expect(!f.presentation.output.requests.isEmpty, "订阅重入变化安排后续刷新")
        f.measure()
        subscription.cancel(); reentrant.cancel()
        let stale = f.model.stackSnapshot
        _ = f.model.accept(attentionNotice(epoch: f.model.receiverEpoch))
        expect(!f.model.commitStackLayout(expected: stale, capacity: 0, positions: [:]), "过期方案整体拒绝")
        expect(f.model.stackSnapshot.visible.count == 3, "拒绝不改变当前准入")
    }
    suite("Stack presentation：反馈重测与原始导航期限") {
        let f = StackPresentationFixture(count: 1, holdNavigation: true)
        f.measure(); f.clock.advance(0.5)
        let item = f.model.stackSnapshot.visible[0]
        f.navigation.navigateSource(
            item.record.action!, generation: f.navigation.capabilityGeneration, owner: item.id)
        f.clock.advance(0)
        let feedback = f.presentation.output.requests.first!
        expect(feedback.content?.feedback == .eventNoticeOpenStarted, "反馈属于测量内容身份")
        let remaining = f.model.stackSnapshot.visible[0].readingTime.fraction(at: f.clock.time) * 4
        f.presentation.updateViewport(width: 268, availableHeight: nil)
        f.clock.advance(3)
        expect(!f.navigation.isNavigating && f.navigation.result == .timedOut, "几何挂起不延长三秒导航预算")
        expect(
            f.model.stackSnapshot.visible[0].readingTime.remaining == remaining, "导航期限到达不消耗隐藏阅读预算")
        f.presentation.receiveMeasurements([feedback.token: 300]); f.clock.advance(0)
        expect(!f.presentation.output.isEligible, "旧反馈结果不能恢复几何")
        f.presentation.updateViewport(width: 440, availableHeight: 900); f.clock.advance(0)
        expect(
            f.presentation.output.requests.first?.content?.feedback == .eventNoticeOpenTimeout,
            "恢复测量当前超时反馈")
        f.measure { _ in 160 }
        expect(f.presentation.output.cardHeights[item.id] == 160, "完整反馈高度进入最终布局")
        f.model.hideBanner(for: .codex)
        expect(
            !f.presentation.output.isEligible && f.presentation.output.cardHeights.isEmpty,
            "来源关闭同步撤回展示与测量缓存")
        f.presentation.receiveMeasurements([feedback.token: 300]); f.clock.advance(0)
        expect(!f.presentation.output.isEligible, "来源撤回后的迟到结果不能重现")
    }
    suite("Stack presentation：小数位置也提交，亚像素调整不启动让位") {
        let f = StackPresentationFixture(count: 2)
        f.measure(); f.clock.advance(0.5)
        let snapshot = f.model.stackSnapshot
        let a = snapshot.visible[0], b = snapshot.visible[1]
        expect(
            f.model.commitStackLayout(
                expected: snapshot, capacity: 2,
                positions: [a.id: 0, b.id: b.positionY + 0.25]), "当前版本的小数位置方案可提交")
        expect(f.model.stackSnapshot.visible[1].positionY == b.positionY + 0.25, "位置写入不能被动效阈值吞掉")
        expect(f.model.stackSnapshot.visible[1].relocation == b.relocation, "保留原有亚像素不让位规则")
    }
    suite("Stack presentation：同代次反馈乱序与原子方案校验") {
        let f = StackPresentationFixture(count: 1, holdNavigation: true)
        f.measure(); f.clock.advance(0.5)
        let item = f.model.stackSnapshot.visible[0]
        f.navigation.navigateSource(
            item.record.action!, generation: f.navigation.capabilityGeneration, owner: item.id)
        f.clock.advance(0)
        let started = f.presentation.output.requests.first!.token
        f.clock.advance(3)
        let timeout = f.presentation.output.requests.first!.token
        expect(started.generation == timeout.generation && started != timeout, "同环境的反馈变化也有独立内容身份")
        f.presentation.receiveMeasurements([started: 800]); f.clock.advance(0)
        expect(f.presentation.output.cardHeights[item.id] == 100, "迟到旧反馈不能替换已提交高度")
        f.measure { _ in 160 }
        expect(f.presentation.output.cardHeights[item.id] == 160, "只采用当前超时反馈高度")
        let current = f.model.stackSnapshot
        for positions in [[item.id: Double.nan], [item.id: -1], [UUID(): 0]] {
            expect(
                !f.model.commitStackLayout(expected: current, capacity: 1, positions: positions),
                "非法位置整体拒绝")
            expect(f.model.stackSnapshot == current, "拒绝没有部分发布")
        }
        let old = item.record.notice!
        _ = f.model.accept(
            attentionNotice(
                epoch: f.model.receiverEpoch, installation: old.installationID, source: old.source))
        expect(
            !f.model.commitStackLayout(expected: current, capacity: 0, positions: [:]),
            "同 ID 旧记录版本方案不可提交")
    }
    suite("Stack presentation：输出重入改变几何仍暂停阅读") {
        let f = StackPresentationFixture(count: 1)
        var suspended = false
        let observation = f.presentation.outputs.sink { value in
            if value.isEligible && !suspended {
                suspended = true
                f.presentation.updateViewport(width: 268, availableHeight: nil)
            }
        }
        f.measure()
        expect(!f.presentation.output.isEligible, "重入几何撤回不会被外层提交覆盖")
        expect(f.model.stackSnapshot.pauseReasons.contains(.geometryUnavailable), "外层提交不能解除新几何暂停")
        f.clock.advance(10)
        expect(f.model.stackSnapshot.visible.count == 1, "重入后的隐藏时间不消耗预算")
        observation.cancel()
    }
    suite("Stack presentation：输出订阅者重入隐私清空") {
        let f = StackPresentationFixture(count: 1)
        var cleared = false
        let observation = f.presentation.outputs.sink { value in
            expect(f.presentation.output == value, "输出先提交后通知订阅者")
            if value.isEligible && !cleared {
                cleared = true
                f.model.clearForPrivacy()
                expect(!f.presentation.output.isEligible, "重入清空立即撤回输出")
            }
        }
        f.measure()
        expect(cleared && !f.presentation.output.isEligible, "外层发布不能覆盖重入清空")
        expect(f.presentation.output.requests.isEmpty, "重入不遗留旧测量")
        observation.cancel()
    }
    suite("Stack presentation：隐私和撤回同步失效、退场高度") {
        let f = StackPresentationFixture(count: 3)
        f.measure(); f.clock.advance(0.5)
        let last = f.model.stackSnapshot.visible.last!
        f.model.dismissBanner(id: last.id); f.clock.advance(0)
        expect(f.presentation.output.cardHeights[last.id] == 100, "退场保留最后实测高度")
        expect(f.presentation.output.retiredContent[last.id] != nil, "退场保留绘制内容快照")
        expect(f.presentation.output.height >= 316, "退场纳入最终窗口高度")
        f.presentation.updateViewport(width: 268, availableHeight: 900); f.clock.advance(0)
        let late = Dictionary(
            uniqueKeysWithValues: f.presentation.output.requests.map { ($0.token, 100.0) })
        f.model.clearForPrivacy()
        expect(
            !f.presentation.output.isEligible && f.presentation.output.cardHeights.isEmpty,
            "隐私清空同步撤回窗口与缓存")
        f.presentation.receiveMeasurements(late); f.clock.advance(0)
        expect(
            !f.presentation.output.isEligible && f.presentation.output.requests.isEmpty,
            "迟到任务和回调无法恢复旧内容")
    }
}
