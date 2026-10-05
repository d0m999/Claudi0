import ClaudioCore
import ClaudioGUICore
import Combine
import Foundation

// Production library-failure announcements and spoken-sentence de-duplication.

private let H = "Claudio 面板，当前声音包 lofi"
private let libraryFailureNotice = "刷新失败，正在显示上次结果"

@MainActor
private final class PublishedLibraryState: ObservableObject {
    @Published var value: SoundPackLibraryPresentationState = .ready
}

@MainActor
private func flushPanelAnnouncementQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

private func libraryFacts(
    _ state: SoundPackLibraryPresentationState,
    topContent: PanelTopContent = .events,
    visible: Bool = true,
    openCount: Int = 1
) -> PanelLibraryAnnouncementFacts {
    PanelLibraryAnnouncementFacts(
        header: H,
        refreshFailedNotice: libraryFailureNotice,
        topContent: topContent,
        libraryState: state,
        panelIsVisible: visible,
        openCount: openCount)
}

@MainActor
func runPanelAnnouncementSuites() async {
    await suite("刷新失败播报：快速重试返回相同失败时，逐次发布路径仍会再次调度") {
        let published = PublishedLibraryState()
        let announcer = PanelAnnouncer()
        let failed = SoundPackLibraryPresentationState.refreshFailed(reason: "相同原因")
        var spoken: [String] = []
        announcer.observeLibraryTransitions(
            from: published.$value,
            facts: { libraryFacts(published.value) },
            onAnnounce: { spoken.append($0) })

        announcer.scheduleLibraryUpdate(
            opening: true,
            facts: { libraryFacts(published.value) },
            onAnnounce: { spoken.append($0) })
        await flushPanelAnnouncementQueue()
        expect(spoken == ["\(H)。"], "先消费当前打开的摘要")

        published.value = failed
        await flushPanelAnnouncementQueue()
        expect(spoken == ["\(H)。", "\(libraryFailureNotice)。"], "第一次失败应播报一次")

        // No SwiftUI update pass occurs between these publications; the final value is unchanged.
        published.value = .refreshing
        published.value = failed
        await flushPanelAnnouncementQueue()
        expect(
            spoken == ["\(H)。", "\(libraryFailureNotice)。", "\(libraryFailureNotice)。"],
            "快速重试再次失败，即使最终状态与上一帧相同，也必须再次播报")

        published.value = .refreshFailed(reason: "底层原因变了")
        await flushPanelAnnouncementQueue()
        expect(spoken.count == 3, "同一失败期间的后续发布不得重复播报")
    }

    await suite("刷新失败播报：订阅先于 SwiftUI 打开回调时合成一句") {
        let published = PublishedLibraryState()
        let coordinator = PanelFocusCoordinator()
        let announcer = PanelAnnouncer()
        let failed = SoundPackLibraryPresentationState.refreshFailed(reason: "扫描失败")
        var spoken: [String] = []
        let facts: @MainActor @Sendable () -> PanelLibraryAnnouncementFacts = {
            libraryFacts(
                published.value,
                visible: coordinator.isPanelVisible,
                openCount: coordinator.showCount)
        }
        announcer.observeLibraryTransitions(
            from: published.$value,
            facts: facts,
            onAnnounce: { spoken.append($0) })

        coordinator.requestFocus()  // popoverDidShow; SwiftUI has not handled showCount yet.
        published.value = failed
        await flushPanelAnnouncementQueue()
        expect(
            spoken == ["\(H)。\(libraryFailureNotice)。"],
            "新打开期间订阅先收到失败，也必须把摘要与提示合成一条播报")

        announcer.scheduleLibraryUpdate(
            opening: true, facts: facts, onAnnounce: { spoken.append($0) })
        await flushPanelAnnouncementQueue()
        expect(spoken.count == 1, "迟到的打开回调不得再截断刚播报的失败提示")
    }

    suite("刷新失败播报：打开摘要和首次提示合成一句，同一失败期间不重复") {
        let announcer = PanelAnnouncer()
        let failed = SoundPackLibraryPresentationState.refreshFailed(reason: "不应播报的磁盘原因")
        let combined = announcer.consumeLibraryUpdate(libraryFacts(failed), opening: true)
        expect(
            combined == "\(H)。\(libraryFailureNotice)。",
            "打开时必须把无 reason 提示接在摘要后，仅播报一次")
        expect(
            announcer.consumeLibraryUpdate(libraryFacts(failed), opening: false) == nil,
            "同一失败期间的重复发布不得重播")
        expect(
            announcer.consumeLibraryUpdate(
                libraryFacts(.refreshFailed(reason: "原因变了")), opening: false) == nil,
            "底层 reason 变化不能制造新的失败期间")
        expect(
            announcer.consumeLibraryUpdate(
                libraryFacts(failed, openCount: 2), opening: true) == "\(H)。",
            "重开仍播报面板摘要，但不得重复同一失败提示")
    }

    suite("刷新失败播报：隐藏时延后，首次可见时才说；被内容门禁挡住时不消费") {
        let announcer = PanelAnnouncer()
        let failed = SoundPackLibraryPresentationState.refreshFailed(reason: "私有原因")
        expect(
            announcer.consumeLibraryUpdate(
                libraryFacts(failed, visible: false), opening: false) == nil,
            "面板隐藏时不得播报")
        expect(
            announcer.consumeLibraryUpdate(
                libraryFacts(failed, topContent: .configFailure(reason: "坏配置")),
                opening: false) == nil,
            "没有显示提示的内容态不得提前消费播报")
        expect(
            announcer.consumeLibraryUpdate(libraryFacts(failed), opening: false)
                == "\(libraryFailureNotice)。",
            "提示首次可见时必须通过播报通道说出")
        expect(
            announcer.consumeLibraryUpdate(
                libraryFacts(failed, visible: false, openCount: 2), opening: true) == nil,
            "隐藏期间即使收到打开信号也不得播报")
    }

    suite("刷新失败播报：离开失败态后，相同文案的新失败仍需再播报") {
        let announcer = PanelAnnouncer()
        let failed = SoundPackLibraryPresentationState.refreshFailed(reason: "同一个原因")
        expect(
            announcer.consumeLibraryUpdate(libraryFacts(.ready), opening: true) == "\(H)。",
            "正常打开只说摘要")
        expect(
            announcer.consumeLibraryUpdate(libraryFacts(failed), opening: false)
                == "\(libraryFailureNotice)。",
            "打开后第一次失败要播报")
        expect(
            announcer.consumeLibraryUpdate(libraryFacts(.refreshing), opening: false) == nil,
            "重试刷新中不显示常驻播报，并结束上次失败期间")
        expect(
            announcer.consumeLibraryUpdate(libraryFacts(failed), opening: false)
                == "\(libraryFailureNotice)。",
            "同一次打开内新失败即使文案相同也必须再播报")
        expect(
            announcer.consumeLibraryUpdate(libraryFacts(.ready), opening: false) == nil,
            "成功后清除失败期间")
        expect(
            announcer.consumeLibraryUpdate(libraryFacts(failed), opening: false)
                == "\(libraryFailureNotice)。",
            "成功后再失败必须重新播报")
    }

    suite("双宿主面板播报：只消费已组合 header，并规范为一句完整播报") {
        expect(dualHostPanelAnnouncement(header: "") == nil, "空 header 不得打断 VoiceOver")
        expect(
            dualHostPanelAnnouncement(header: "Claudio 面板，2 个声音来源")
                == "Claudio 面板，2 个声音来源。",
            "双宿主运行面板不得再附加已被移除的 Claude onboarding 屏幕文案")
    }

    suite("T17g【拼句】没有子句 → nil，绝不是一个孤零零的句号（空串 = 一次打断 VoiceOver 却什么都不说的 post）") {
        expect(joinSpokenClauses([]) == nil, "空数组 → nil")
        expect(joinSpokenClauses(["", "。"]) == nil, "全是空子句 → nil，而不是「。」")
        expect(joinSpokenClauses(["Claudio 面板"]) == "Claudio 面板。", "补句号")
        expect(
            joinSpokenClauses(["Claudio 面板", "正在接管…"]) == "Claudio 面板。正在接管…",
            "省略号结尾不再补句号")
        expect(joinSpokenClauses(["A。", "B。"]) == "A。B。", "不许拼出「。。」")
    }

    suite("T17g【去重器】同一次打开里，一句话的后缀不许再 post 一遍（那只会截断用户正在听的话）") {
        let announcer = PanelAnnouncer()
        expect(
            announcer.consume("Claudio 面板。你的包被换了。", openCount: 1)
                == "Claudio 面板。你的包被换了。", "第一句必须说")
        expect(
            announcer.consume("你的包被换了。", openCount: 1) == nil,
            "它是刚说完那句的后缀 —— 面板重开时被推迟的 .onChange(of: actionState) 干的正是这件事")
        expect(
            announcer.consume("你的包被换了。", openCount: 2) == "你的包被换了。",
            "换了一次打开 → 去重不跨段")
    }

    suite("T17g【去重器】跨两次打开重复同一句面板句，必须照说 —— 否则重开面板就是一片死寂") {
        let announcer = PanelAnnouncer()
        expect(announcer.consume("Claudio 面板。", openCount: 1) == "Claudio 面板。", "第一次打开")
        expect(
            announcer.consume("Claudio 面板。", openCount: 2) == "Claudio 面板。",
            "第二次打开必须再说一遍 —— 全局按内容去重 = 重开面板一片死寂")
    }

    suite("T17g【去重器】nil / 空串不 post，也不污染「刚说过什么」") {
        let announcer = PanelAnnouncer()
        expect(announcer.consume("A。", openCount: 1) == "A。", "先说一句")
        expect(announcer.consume(nil, openCount: 1) == nil, "nil 不 post")
        expect(announcer.consume("", openCount: 1) == nil, "空串不 post")
        expect(announcer.consume("A。", openCount: 1) == nil, "nil / 空串不该把「刚说过 A」冲掉")
    }

}
