import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Foundation
import SwiftUI

@MainActor
func runEventBannerActionSuites() {
    let identity = HostProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 12)
    let appURL = URL(fileURLWithPath: "/Applications/Example Terminal.app")
    func target(_ action: EventNoticeAction) -> SourceApplicationTarget {
        SourceApplicationTarget(
            action: action, process: identity, bundleIdentifier: "example.terminal",
            applicationURL: appURL, name: "Example Terminal")
    }
    func model(_ clock: ManualEventNoticeScheduler) -> EventNoticeModel {
        EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler(),
            resolveSourceApplication: { _, action in target(action) })
    }
    func accept(
        _ model: EventNoticeModel, installation: UUID = UUID(), native: String = "PermissionRequest"
    ) -> EventNoticeAction {
        _ = model.accept(
            attentionNotice(
                epoch: model.receiverEpoch, installation: installation,
                native: native, processAncestors: [identity]))
        return model.snapshot.attentionReminders.first?.action ?? model.snapshot.current!.action!
    }

    suite("Event Banner：共享年龄向下取整，中英文边界与长式") {
        let model = model(ManualEventNoticeScheduler())
        _ = accept(model)
        let record = model.snapshot.current!
        let cases: [(Double, String, String)] = [
            (-10, "<1分", "<1m"), (0, "<1分", "<1m"),
            (59.999, "<1分", "<1m"), (60, "1分", "1m"), (179.99, "2分", "2m"),
            (3599.99, "59分", "59m"), (3600, "1时", "1h"), (10800, "3时", "3h"),
            (86399.99, "23时", "23h"), (86400, "1天", "1d"), (172800, "2天", "2d"),
        ]
        for (seconds, zh, en) in cases {
            let now = record.occurredAt!.addingTimeInterval(seconds)
            for (language, expected) in [(ClaudioAppLanguage.zhHans, zh), (.english, en)] {
                expect(
                    EventNoticeProjection.age(for: record, language: language, now: now)
                        == expected,
                    "年龄边界 \(seconds) \(language)")
                let secondary = EventNoticeProjection.secondaryLine(
                    for: record, language: language, now: now)
                expect(secondary == "project · \(expected)", "副行无会话短ID")
                expect(
                    EventNoticeProjection.accessibilitySummary(
                        for: record, language: language, now: now
                    )
                    .contains(secondary), "VoiceOver共用当前时间投影")
            }
        }
        expect(
            EventNoticeProjection.age(
                for: record, language: .zhHans,
                now: record.occurredAt!.addingTimeInterval(179), long: true) == "2 分钟前", "详情相对长式")
        expect(
            EventNoticeProjection.occurredAtText(for: record, language: .english)?.contains("2023")
                == true,
            "详情绝对时间包含日期")
    }

    suite("Event Banner：全部原因和瞬时事件使用行动文案，未知原因中性") {
        let cases: [(String, HostID, HostEventNoticeReason?, String, String)] = [
            ("PermissionRequest", .codex, .permission, "等你授权", "waiting for approval"),
            ("Notification", .claudeCode, .needsInput, "等你输入", "waiting for input"),
            ("Notification", .claudeCode, .review, "需要你查看", "needs your attention"),
            ("Notification", .claudeCode, nil, "需要你查看", "needs your attention"),
            ("Notification", .claudeCode, .informational, "信息通知", "Information"),
            ("StopFailure", .claudeCode, nil, "执行中断", "run interrupted"),
            ("Stop", .codex, nil, "本轮已结束", "turn finished"),
            ("SubagentStop", .codex, nil, "子任务已结束", "subagent finished"),
            ("UserPromptSubmit", .codex, nil, "开始执行", "run started"),
        ]
        for (native, host, reason, zh, en) in cases {
            let clock = ManualEventNoticeScheduler()
            let m = model(clock)
            _ = m.accept(
                attentionNotice(
                    epoch: m.receiverEpoch, native: native, host: host,
                    reason: reason, processAncestors: [identity]))
            guard let record = m.snapshot.current else {
                expect(false, "事件应展示：\(native)"); continue
            }
            expect(
                EventNoticeProjection.primaryLine(for: record, language: .zhHans) == host
                    .displayName + zh, "中文动词 \(native)")
            expect(
                EventNoticeProjection.primaryLine(for: record, language: .english) == host
                    .displayName + " " + en, "英文动词 \(native)")
            expect(
                EventNoticeView.preferredHeight(for: m.snapshot)
                    == (record.kind.isAttention ? 75 : 67), "折叠高度")
            expect(
                EventNoticeProjection.actionTitle(for: record, language: .zhHans) != "查看详情",
                "可靠来源有App动作")
        }
        let clock = ManualEventNoticeScheduler()
        let unknown = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
        _ = unknown.accept(attentionNotice(epoch: unknown.receiverEpoch, source: nil))
        expect(
            EventNoticeProjection.actionTitle(for: unknown.snapshot.current!, language: .zhHans)
                == "在面板查看", "无法识别应用时提供面板入口")
    }

    suite("Event Banner：4秒采样、交叠暂停、版本替代与隐私期限") {
        let clock = ManualEventNoticeScheduler()
        let m = model(clock)
        let installation = UUID()
        let action = accept(m, installation: installation)
        expect(!m.snapshot.current!.isSuperseded, "当前提醒版本不提示刷新")
        expect(m.sourceNotice(for: action)?.processAncestors == nil, "模型不保留原始进程列表")
        expect(m.sourceApplication(for: action)?.action == action, "来源绑定版本")
        clock.advance(0.18)
        let sample = m.snapshot.readingTime!
        expect(sample.fraction(at: clock.time + 1) == 0.75, "单调时钟绘制4秒预算")
        let before = m.snapshot
        _ = sample.fraction(at: clock.time + 2)
        expect(m.snapshot == before, "视觉投影不发布或重置计时器")
        clock.advance(1)
        m.setHovering(true); m.setKeyboardFocused(true)
        let paused = m.snapshot.readingTime!
        expect(abs(paused.fraction(at: clock.time + 100) - 0.75) < 0.0001, "暂停保持剩余预算")
        m.setHovering(false)
        expect(m.snapshot.readingTime?.isPaused == true, "剩余聚焦继续暂停")
        _ = m.viewSource(action)
        m.setKeyboardFocused(false)
        expect(m.bannerSnapshot.readingTime?.isPaused == false, "阅读展开不暂停横幅")
        _ = accept(m, installation: installation)
        let stale = m.snapshot.current!
        expect(
            !stale.isExpired && !stale.isActionable && stale.isSuperseded
                && stale.sourceApplication != nil,
            "新版本替代保留旧详情，禁用旧动作")
        expect(
            EventNoticeProjection.secondaryLine(for: stale, language: .zhHans).contains("已更新，请刷新"),
            "旧版本诚实显示刷新")
        clock.advance(1800)
        expect(
            m.snapshot.current?.isExpired == true && m.snapshot.current?.occurredAt == nil
                && m.snapshot.current?.sourceApplication == nil, "隐私期限覆盖展开与暂停，擦除应用与时间")
        m.clearForPrivacy()
        expect(
            m.sourceApplication(for: action) == nil && m.resourceUsage.readingVersions == 0,
            "隐私清空释放来源")
    }

    suite("Source App：打开保留提醒、重复点击保护、失败和超时") {
        let clock = ManualEventNoticeScheduler()
        let m = model(clock)
        let action = accept(m)
        var calls = 0
        var callbacks: [@MainActor (SourceApplicationOpenResult) -> Void] = []
        let navigation = SessionNavigationCoordinator(
            model: m, scheduler: clock.scheduler(),
            openApplication: { _, _, finish in
                calls += 1; callbacks.append(finish); return EventNoticeCancellation {}
            })
        navigation.openSourceApplication(action, generation: navigation.capabilityGeneration)
        navigation.openSourceApplication(action, generation: navigation.capabilityGeneration)
        expect(calls == 1 && navigation.applicationResult == .started, "一个在途请求")
        callbacks[0](.opened)
        expect(
            m.snapshot.totalCount == 1 && m.isCurrent(action)
                && navigation.result != .exactReturnConfirmed, "App打开不等于精确返回或移除")
        navigation.openSourceApplication(action, generation: navigation.capabilityGeneration)
        callbacks[1](.failed)
        expect(navigation.applicationResult == .failed && m.snapshot.totalCount == 1, "失败保留提醒")
        navigation.openSourceApplication(action, generation: navigation.capabilityGeneration)
        clock.advance(2.99)
        expect(navigation.applicationResult == .started, "未提前超时")
        clock.advance(0.01)
        expect(navigation.applicationResult == .timedOut, "3秒超时")
        callbacks[2](.opened)
        expect(navigation.applicationResult == .timedOut, "迟到结果不更新反馈")
        navigation.openSourceApplication(action, generation: navigation.capabilityGeneration)
        expect(navigation.copy(action, write: { _ in true }), "打开期间仍可复制有效会话ID")
        expect(navigation.applicationResult == .idle, "复制取消打开并恢复按钮状态")
        callbacks[3](.opened)
        expect(navigation.applicationResult == .idle, "复制后迟到打开结果失效")
        navigation.openSourceApplication(action, generation: navigation.capabilityGeneration)
        expect(calls == 5 && navigation.applicationResult == .started, "复制后可以重新打开")
        navigation.cancel()
    }

    suite("Source App：版本、目标、期限、隐私、取消和代次变化阻止迟到激活") {
        for change in ["version", "expiry", "privacy", "remove", "cancel", "generation"] {
            let clock = ManualEventNoticeScheduler()
            let m = model(clock)
            let installation = UUID()
            let action = accept(m, installation: installation)
            var current: (@MainActor () -> Bool)?
            var finish: (@MainActor (SourceApplicationOpenResult) -> Void)?
            var feedback = 0
            let navigation = SessionNavigationCoordinator(
                model: m, scheduler: clock.scheduler(),
                openApplication: { _, valid, callback in
                    current = valid; finish = callback; return EventNoticeCancellation {}
                })
            navigation.openSourceApplication(action, generation: navigation.capabilityGeneration) {
                _ in feedback += 1
            }
            switch change {
            case "version": _ = accept(m, installation: installation)
            case "expiry": clock.advance(1800)
            case "privacy": m.clearForPrivacy()
            case "remove": _ = m.remove(action)
            case "cancel": navigation.cancel()
            default: navigation.replaceCapabilityGeneration(UUID())
            }
            let previous = feedback
            expect(current?() == false, "失效动作在激活前重验：\(change)")
            finish?(.opened)
            expect(feedback == previous, "迟到结果不能反馈或重新抢焦点：\(change)")
        }
    }

    suite("Source App adapter：真实实例激活、退出后重开、路径变化与迟到回调") {
        for scenario in [
            "running", "failed", "reused", "different-user", "reopen", "moved", "wrong-bundle",
            "launch-failed", "timeout", "foreground-changed",
        ] {
            let action = EventNoticeAction(
                id: UUID(), version: 1, epoch: UUID(), installationID: UUID())
            let t = target(action)
            let running = ["running", "failed", "reused", "different-user"].contains(scenario)
            var valid = true
            var foreground: Int32? = 88
            var activations: [Int32] = []
            var launches = 0
            var callback: (@MainActor (SourceApplicationDescriptor?) -> Void)?
            var result = SourceApplicationOpenResult.idle
            let app = SourceApplicationDescriptor(
                pid: running ? 42 : 43, bundleIdentifier: "example.terminal", url: appURL,
                name: "Example Terminal")
            let environment = SourceApplicationEnvironment(
                userID: 501, ownPID: 1,
                process: { pid in
                    if pid == 42 && !running { return nil }
                    return HostProcessSnapshot(
                        identity: HostProcessIdentity(
                            pid: pid,
                            startSeconds: scenario == "reused" ? 101 : 100, startMicroseconds: 12),
                        parentPID: 1, userID: scenario == "different-user" ? 502 : 501)
                }, application: { _ in running ? app : nil },
                locationMatches: { _ in scenario != "moved" },
                activate: {
                    activations.append($0); return scenario != "failed"
                },
                frontmost: { foreground },
                reopenInactive: { _, completion in
                    launches += 1; callback = completion
                })
            let token = SourceApplicationAdapter.openApplication(
                t, isCurrent: { valid }, complete: { result = $0 }, environment: environment)
            if scenario == "timeout" { valid = false; token.cancel() }
            if scenario == "foreground-changed" { foreground = 99 }
            if scenario == "wrong-bundle" {
                callback?(
                    SourceApplicationDescriptor(
                        pid: 43, bundleIdentifier: "another.app", url: appURL, name: "Other"))
            } else {
                callback?(scenario == "launch-failed" ? nil : app)
            }
            if scenario == "running" || scenario == "reopen" {
                expect(result == .opened && activations == [app.pid], "有效应用打开：\(scenario)")
            } else if scenario == "failed" {
                expect(result == .failed && activations == [42], "激活失败反馈")
            } else {
                expect(activations.isEmpty && result != .opened, "不激活失效目标：\(scenario)")
            }
            expect(
                launches == (!running && scenario != "moved" ? 1 : 0), "只有已退出且位置身份确认才重开：\(scenario)"
            )
            token.cancel()
        }
    }

    suite("Event Banner：chip 实际浅染底的正文与描边对比度") {
        for dark in [false, true] {
            let panels =
                dark
                ? [ClaudioColorHex.panelDark, ClaudioColorHex.surface2Dark]
                : [ClaudioColorHex.panelLight, ClaudioColorHex.panelDeepLight]
            let text = dark ? ClaudioColorHex.textDark : ClaudioColorHex.textLight
            let chipBase = dark ? ClaudioColorHex.panelDark : ClaudioColorHex.panelLight
            let colors =
                dark
                ? [
                    ClaudioColorHex.notificationDark, ClaudioColorHex.stopFailureDark,
                    ClaudioColorHex.taskStartDark, ClaudioColorHex.stopDark,
                    ClaudioColorHex.subagentStopDark,
                ]
                : [
                    ClaudioColorHex.notificationLight, ClaudioColorHex.stopFailureLight,
                    ClaudioColorHex.taskStartLight, ClaudioColorHex.stopLight,
                    ClaudioColorHex.subagentStopLight,
                ]
            for panel in panels {
                for color in colors {
                    for opacity in [
                        EventNoticeActionStyle.fillOpacity,
                        EventNoticeActionStyle.interactionOpacity,
                    ] {
                        let background = compositedHex(color, over: chipBase, alpha: opacity)!
                        expect(contrastRatio(text, background) >= 4.5, "chip正文≥4.5")
                        expect(contrastRatio(color, background) >= 3, "chip边界≥3")
                        expect(contrastRatio(color, panel) >= 3, "事件脊柱≥3")
                    }
                }
            }
        }
    }
}
