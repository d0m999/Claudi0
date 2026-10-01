import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Foundation
import SwiftUI

@MainActor
private func makePresentationRecord(
    source: HostEventSource?,
    occurredAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)
) -> EventNoticeRecord {
    let binding = HostCapabilityCatalog.binding(host: .codex, nativeEvent: "Stop")!
    let epoch = UUID()
    let notice = HostEventNotice(
        receiverEpoch: epoch,
        surface: .codex,
        bindingID: binding.id,
        installationID: UUID(),
        nativeEvent: binding.nativeEvent!,
        event: binding.event,
        occurredAt: occurredAt ?? Date(),
        source: source)
    return EventNoticeRecord(
        id: notice.id,
        event: notice.event,
        occurredAt: occurredAt,
        notice: source == nil ? nil : notice,
        status: .displayed,
        isExpired: false)
}

@MainActor
func runEventNoticePresentationSuites() {
    suite("EventNoticeReadingView：面板和诊断共用的阅读内容在小窗口可滚动到达") {
        _ = NSApplication.shared
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for language in [ClaudioAppLanguage.english, .zhHans] {
                for count in [0, 1, 5, 7, 50] {
                    let clock = ManualEventNoticeScheduler()
                    let model = EventNoticeModel(
                        receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
                    let sessionID = String(repeating: "S", count: 256)
                    for _ in 0..<count {
                        _ = model.accept(
                            attentionNotice(
                                epoch: model.receiverEpoch,
                                source: HostEventSource(
                                    projectLabel: "project", sessionID: sessionID),
                                occurredAt: Date(timeIntervalSinceNow: -120)))
                    }
                    model.openReading(.panel)
                    let preferences = ClaudioPreferences(previewLanguage: language)
                    let selection = Binding<EventNoticeAction?>(
                        get: { model.snapshot.isDetail ? model.snapshot.current?.action : nil },
                        set: {
                            if let action = $0 {
                                _ = model.viewSource(action)
                            } else {
                                model.closeDetail()
                            }
                        })
                    let reader = EventNoticeReadingView(
                        model: model, preferences: preferences,
                        navigation: SessionNavigationCoordinator(model: model), selected: selection)
                    let hosting = NSHostingView(rootView: ScrollView { reader.padding(12) })
                    if #available(macOS 13, *) { hosting.sizingOptions = [] }
                    let window = NSWindow(
                        contentRect: NSRect(x: 0, y: 0, width: 312, height: 360),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView = hosting
                    window.orderFrontRegardless()
                    defer { window.orderOut(nil); window.close() }
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
                    hosting.layoutSubtreeIfNeeded()
                    let scrolls = descendants(hosting).compactMap { $0 as? NSScrollView }
                    expect(scrolls.count == 1, "阅读只借用消费者的一个滚动区域")
                    if count >= 7, let scroll = scrolls.first, let document = scroll.documentView {
                        expect(document.bounds.height > scroll.contentView.bounds.height, "长列表可滚动")
                        document.scrollToVisible(
                            NSRect(x: 0, y: document.bounds.maxY - 20, width: 100, height: 20))
                        expect(scroll.contentView.bounds.maxY >= document.bounds.maxY - 22, "末项可达")
                    }
                    guard let action = model.readingSnapshot.records.first?.action else { continue }
                    _ = model.viewSource(action)
                    window.setContentSize(NSSize(width: 312, height: 180))
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
                    hosting.layoutSubtreeIfNeeded()
                    guard
                        let scroll = descendants(hosting).compactMap({ $0 as? NSScrollView }).first,
                        let document = scroll.documentView,
                        let session = descendants(hosting).compactMap({ $0 as? NSTextField }).first(
                            where: { $0.stringValue == sessionID })
                    else {
                        expect(false, "详情实际挂载完整有效会话 ID"); continue
                    }
                    let frame = session.convert(session.bounds, to: document)
                    document.scrollToVisible(frame)
                    expect(scroll.contentView.bounds.intersects(frame), "最小窗口会话 ID 可滚动到达")
                    expect(model.readingSnapshot.records.count == count, "布局不改变冻结集合")
                }
            }
        }
    }

    suite("EventNoticeProjection：信息性通知不显示等待介入") {
        let clock = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
        _ = model.accept(
            attentionNotice(
                epoch: model.receiverEpoch, native: "Notification", host: .claudeCode,
                reason: .informational))
        guard let record = model.snapshot.current else { expect(false, "信息通知应有瞬时投影"); return }
        expect(
            EventNoticeProjection.primaryLine(for: record, language: .zhHans)
                == "Claude Code信息通知", "中文信息性通知不猜测等待介入")
        expect(
            EventNoticeProjection.primaryLine(for: record, language: .english)
                == "Claude Code Information", "英文与中文含义一致")
    }

    suite("EventNoticeProjection：瞬时横幅根标签中性，待接手与展开态保留紧迫语义") {
        for language in [ClaudioAppLanguage.english, .zhHans] {
            let transientClock = ManualEventNoticeScheduler()
            let transientModel = EventNoticeModel(
                receiverEpoch: UUID(), now: { transientClock.time },
                scheduler: transientClock.scheduler())
            _ = transientModel.accept(
                attentionNotice(epoch: transientModel.receiverEpoch, native: "Stop"))
            let transient = transientModel.snapshot.current!
            expect(
                EventNoticeProjection.accessibilityLabel(
                    for: transientModel.snapshot, language: language)
                    == EventNoticeProjection.accessibilitySummary(
                        for: transient, language: language),
                "未展开瞬时横幅必须使用当前事件的中性摘要：\(language.rawValue)")

            let needsYou = ClaudioL10n(language: language).text(.eventNoticeRecent)
            expect(
                EventNoticeProjection.accessibilityLabel(
                    for: transientModel.snapshot, language: language) != needsYou,
                "普通进展不得播报为需要用户处理：\(language.rawValue)")
            _ = transientModel.viewSource(transient.action!)
            expect(
                EventNoticeProjection.accessibilityLabel(
                    for: transientModel.snapshot, language: language) == needsYou,
                "详情态保留已有根标签：\(language.rawValue)")

            let attentionClock = ManualEventNoticeScheduler()
            let attentionModel = EventNoticeModel(
                receiverEpoch: UUID(), now: { attentionClock.time },
                scheduler: attentionClock.scheduler())
            _ = attentionModel.accept(attentionNotice(epoch: attentionModel.receiverEpoch))
            expect(
                EventNoticeProjection.accessibilityLabel(
                    for: attentionModel.snapshot, language: language) == needsYou,
                "待接手横幅继续播报 Needs You/需要你：\(language.rawValue)")
            attentionModel.openAttentionReminders()
            expect(
                EventNoticeProjection.accessibilityLabel(
                    for: attentionModel.snapshot, language: language) == needsYou,
                "展开列表继续播报 Needs You/需要你：\(language.rawValue)")
        }
    }

    suite("EventNoticePlacement：刘海与菜单栏共同决定顶部安全位置") {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // 刘海屏且菜单栏常驻：visibleFrame 已让出菜单栏（24pt），刘海 32pt 中 8pt 侵入可见区。
        let visibleWithBar = CGRect(x: 0, y: 0, width: 1512, height: 958)
        let insetWithBar = EventNoticePlacement.effectiveTopSafeInset(
            screenFrame: frame, visibleFrame: visibleWithBar, safeAreaTop: 32)
        expect(insetWithBar == 8, "刘海超出菜单栏的部分才需要额外下移，实得 \(insetWithBar)")

        // 菜单栏自动隐藏：visibleFrame 顶到屏幕顶，整个刘海高度都必须避让。
        let insetHiddenBar = EventNoticePlacement.effectiveTopSafeInset(
            screenFrame: frame, visibleFrame: frame, safeAreaTop: 32)
        expect(insetHiddenBar == 32, "菜单栏隐藏时刘海全高都必须避让，实得 \(insetHiddenBar)")

        let yNotch = EventNoticePlacement.topAnchorY(
            screenFrame: frame, visibleFrame: frame, safeAreaTop: 32, height: 92)
        expect(
            yNotch == 982 - 32 - 12 - 92,
            "刘海屏顶边必须落在 safeArea 交集下 12pt，实得 \(yNotch)")

        // 无刘海普通屏：不额外下移。
        let yPlain = EventNoticePlacement.topAnchorY(
            screenFrame: frame, visibleFrame: visibleWithBar, safeAreaTop: 0, height: 92)
        expect(
            yPlain == visibleWithBar.maxY - 12 - 92,
            "无刘海屏幕保持可见区顶向下 12pt，实得 \(yPlain)")

        // 窄屏：宽度夹取下限与左右 16pt 边距。
        let narrowVisible = CGRect(x: 0, y: 0, width: 300, height: 800)
        let narrowWidth = EventNoticePlacement.clampedWidth(visibleFrame: narrowVisible)
        expect(
            narrowWidth == 268,
            "窄屏必须优先保留双侧 16pt 边距，实得 \(narrowWidth)")
        let narrowX = EventNoticePlacement.clampedX(
            visibleFrame: narrowVisible, width: narrowWidth)
        expect(
            narrowX == 16,
            "窄屏无法居中时也必须保住左侧 16pt 边距，实得 \(narrowX)")
        let wideX = EventNoticePlacement.clampedX(visibleFrame: visibleWithBar, width: 440)
        expect(
            wideX == visibleWithBar.midX - 220,
            "宽屏必须水平居中，实得 \(wideX)")
    }

    suite("EventNoticeProjection：副行仅项目和年龄，会话及父会话留在详情") {
        let record = makePresentationRecord(
            source: HostEventSource(
                projectLabel: "same-name", projectKey: "project-key", sessionID: "12345678-abcdef"))
        let now = record.occurredAt!.addingTimeInterval(120)
        expect(
            EventNoticeProjection.secondaryLine(for: record, language: .english, now: now)
                == "same-name · 2m", "英文项目与年龄")
        expect(
            EventNoticeProjection.secondaryLine(for: record, language: .zhHans, now: now)
                == "same-name · 2分", "中文项目与年龄")
        let parent = makePresentationRecord(
            source: HostEventSource(
                projectLabel: nil, sessionID: "12345678-abcdef", isParentSession: true))
        expect(
            EventNoticeProjection.secondaryLine(for: parent, language: .zhHans, now: now) == "2分",
            "没有项目只显示已知年龄，不补会话短ID")
        expect(
            parent.source?.isParentSession == true && parent.sessionID == "12345678-abcdef",
            "父会话身份和完整ID保留在详情模型")
    }

    suite("EventNoticeProjection：可见文本与无障碍摘要同源，发生时间可读") {
        let record = makePresentationRecord(
            source: HostEventSource(
                projectLabel: "same-name",
                projectKey: "project-key",
                sessionID: "12345678-abcdef"))
        let primary = EventNoticeProjection.primaryLine(for: record, language: .zhHans)
        let secondary = EventNoticeProjection.secondaryLine(for: record, language: .zhHans)
        let summary = EventNoticeProjection.accessibilitySummary(
            for: record, language: .zhHans)
        expect(
            summary == "\(primary)，\(secondary)",
            "AX 摘要必须由同一投影的两行拼接，不得另造一份文案")
        expect(
            EventNoticeProjection.accessibilitySummary(for: nil, language: .english)
                == ClaudioL10n(language: .english).text(.eventNoticeUnknownSource),
            "空记录的无障碍摘要必须落在未知来源文案")

        let occurred = EventNoticeProjection.occurredAtText(for: record, language: .english)
        expect(occurred != nil && !occurred!.isEmpty, "发生时间必须生成可读文本")
        let noTime = EventNoticeRecord(
            id: UUID(), event: .stop, occurredAt: nil, notice: nil,
            status: .collapsed, isExpired: true)
        expect(
            EventNoticeProjection.occurredAtText(for: noTime, language: .english) == nil,
            "来源过期后不得伪造发生时间")
        let expired = EventNoticeRecord(
            id: record.id, event: record.event, occurredAt: record.occurredAt, notice: nil,
            status: .displayed, isExpired: true)
        for language in [ClaudioAppLanguage.english, .zhHans] {
            expect(
                EventNoticeProjection.occurredAtText(for: expired, language: language) == nil,
                "过期占位即使携带旧时间也不得继续生成可见时间文本")
        }
    }
}
