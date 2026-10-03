import ClaudioGUICore
import Combine
import Foundation

/// Harness coverage for the single focus handshake owner. The six migrated call sites keep
/// per-site coverage in their own suites; these checks pin the shared mechanics once:
/// issue → monotonic revision → consume exactly once → cancel, plus return-focus debt and
/// the projection application tracker.
@MainActor
func runFocusRequestCoordinatorSuites() {
    suite("FocusRequestCoordinator：issue 推进单调代次并携带精确目标，nil 表示默认焦点策略") {
        let coordinator = FocusRequestCoordinator<String>()
        expect(
            coordinator.requestRevision == 0 && coordinator.requestedTarget == nil,
            "初始不得携带陈旧请求")
        expect(
            coordinator.requestFocus("title") == 1
                && coordinator.requestRevision == 1
                && coordinator.requestedTarget == "title",
            "首次 issue 必须返回并发布代次 1")
        expect(
            coordinator.requestFocus("title") == 2,
            "相同目标重复 issue 也必须推进代次（重复深链要重新定位）")
        expect(
            coordinator.requestFocus(nil) == 3 && coordinator.requestedTarget == nil,
            "nil 目标是一次合法请求：视图改用自己的默认焦点策略")
    }

    suite("FocusRequestCoordinator：每个代次只消费一次，陈旧或未来代次不得抢焦点") {
        let coordinator = FocusRequestCoordinator<String>()
        _ = coordinator.requestFocus("agent")
        expect(
            coordinator.consumeRequest(1) && !coordinator.consumeRequest(1),
            "同一代次第二次消费必须失败，视图重算不能偷回焦点")
        expect(
            !coordinator.consumeRequest(2),
            "尚未发行的未来代次不得消费")
        _ = coordinator.requestFocus("toggle")
        _ = coordinator.requestFocus("row")
        expect(
            !coordinator.consumeRequest(2) && coordinator.consumeRequest(3),
            "只有最新代次可消费：被跳过的中间请求不得复活")
    }

    suite("FocusRequestCoordinator：同步发布回调内可消费新代次及其精确目标") {
        let coordinator = FocusRequestCoordinator<String>()
        var receivedRevisions: [UInt64] = []
        var receivedTargets: [String?] = []
        let subscription = coordinator.$requestRevision.dropFirst().sink { revision in
            receivedRevisions.append(revision)
            receivedTargets.append(coordinator.requestedTarget)
            expect(
                coordinator.consumeRequest(revision),
                "已挂载视图必须在同步发布回调内消费新请求")
            expect(
                !coordinator.consumeRequest(revision)
                    && !coordinator.consumeRequest(revision - 1)
                    && !coordinator.consumeRequest(revision + 1),
                "同步回调也必须拒绝重复、陈旧和未发行代次")
        }
        coordinator.requestFocus("agent")
        coordinator.requestFocus("agent")
        coordinator.requestFocus(nil)
        coordinator.requestFocus("editEvent")
        expect(
            receivedRevisions == [1, 2, 3, 4],
            "同目标深链和默认焦点请求都必须同步交付")
        expect(
            receivedTargets == ["agent", "agent", nil, "editEvent"],
            "回调消费到的目标必须属于本次发布的请求")
        expect(
            !coordinator.consumeRequest(4),
            "已在发布回调消费的请求不得在 requestFocus 返回后再次消费")
        withExtendedLifetime(subscription) {}
    }

    suite("FocusRequestCoordinator：同步发布回调内取消后不得复活该请求") {
        let coordinator = FocusRequestCoordinator<String>()
        let subscription = coordinator.$requestRevision.dropFirst().sink { revision in
            coordinator.cancelPendingRequest()
            expect(
                coordinator.requestedTarget == nil && !coordinator.consumeRequest(revision),
                "同步取消必须清除目标并消费正在发行的代次")
        }
        let first = coordinator.requestFocus("first")
        expect(
            !coordinator.consumeRequest(first),
            "发布完成后不得复活回调内取消的请求")
        let second = coordinator.requestFocus("second")
        expect(
            !coordinator.consumeRequest(second),
            "后续发布也必须取消本次请求而非上一代次")
        withExtendedLifetime(subscription) {}
    }

    suite("FocusRequestCoordinator：取消未消费请求与清除目标各有明确语义") {
        let coordinator = FocusRequestCoordinator<String>()
        _ = coordinator.requestFocus("stale")
        coordinator.cancelPendingRequest()
        expect(
            coordinator.requestedTarget == nil && !coordinator.consumeRequest(1),
            "取消必须清掉未消费的陈旧焦点且该代次不可再消费")
        _ = coordinator.requestFocus("fresh")
        coordinator.clearRequestedTarget()
        expect(
            coordinator.requestedTarget == nil && coordinator.consumeRequest(2),
            "清除目标不动代次：新路由的 fallback 规则仍可消费这次请求")
    }

    suite("FocusRequestCoordinator：与六个旧机制的去重语义等价") {
        // 旧 IntegrationDestinationFocusCoordinator 的完整握手序列（原 WorkBuddy suite 钉过）。
        let legacy = FocusRequestCoordinator<String>()
        _ = legacy.requestFocus("agent")
        expect(
            legacy.requestRevision == 1
                && legacy.requestedTarget == "agent"
                && legacy.consumeRequest(1)
                && !legacy.consumeRequest(1),
            "旧 Integrations 握手：一次性精确聚焦语义不变")
        _ = legacy.requestFocus("toggle")
        expect(legacy.consumeRequest(2), "旧 Integrations 握手：后续代次照常推进")
        _ = legacy.requestFocus("title")
        legacy.cancelPendingRequest()
        expect(
            legacy.requestedTarget == nil && !legacy.consumeRequest(3),
            "旧 Integrations 握手：取消请求语义不变")

        // 旧 SoundPacksWindowFocusCoordinator：两条命名路径（initial/route）本来就是同一件事。
        let window = FocusRequestCoordinator<String>()
        _ = window.requestFocus("overview")
        _ = window.requestFocus("editEvent")
        expect(
            window.requestRevision == 2 && window.consumeRequest(2)
                && !window.consumeRequest(1),
            "旧声音包窗口：代次单调且只有最新路由请求生效")

        // 旧 Settings focusDebt：发行 → 视图消费 → acknowledge 前重复消费被拒绝。
        let debt = FocusRequestCoordinator<String>()
        let debtRevision = debt.requestFocus(nil)
        expect(
            debt.consumeRequest(debtRevision) && !debt.consumeRequest(debtRevision),
            "旧 Settings focus debt：acknowledge 前的去重语义不变")
    }

    suite("FocusRequestCoordinator：return-focus debt 按压入顺序交付、只消费一次、可整体清除") {
        let coordinator = FocusRequestCoordinator<String>()
        expect(coordinator.pendingReturnFocus == nil, "初始不得有待归还焦点")
        coordinator.pushReturnFocus("remove-a")
        coordinator.pushReturnFocus("remove-b")
        expect(coordinator.pendingReturnFocus == "remove-a", "最旧的债务必须先交付")
        expect(
            !coordinator.popReturnFocus("remove-b"),
            "乱序消费必须失败：后面的债务不能插队")
        expect(
            coordinator.popReturnFocus("remove-a") && !coordinator.popReturnFocus("remove-a"),
            "同一笔债务只消费一次")
        expect(coordinator.pendingReturnFocus == "remove-b", "下一笔债务轮到它")
        coordinator.clearReturnFocus()
        expect(
            coordinator.pendingReturnFocus == nil && !coordinator.popReturnFocus("remove-b"),
            "路由变化整体清除后不得再交付旧债务")
    }

    suite("FocusApplicationTracker：首次、变化与强制各推进一次，未变投影不得重复抢焦点") {
        var tracker = FocusApplicationTracker<String>()
        expect(
            tracker.recordAndShouldApply("pending", force: false),
            "首次见到的投影必须推进")
        expect(
            !tracker.recordAndShouldApply("pending", force: false),
            "相同投影的重复发布不得重复抢焦点")
        expect(
            tracker.recordAndShouldApply("resolved", force: false),
            "pending→resolved settlement 必须推进一次精确焦点")
        expect(
            tracker.recordAndShouldApply("resolved", force: true),
            "窗口重新出现时即使投影未变也必须恢复 initial focus")
    }
}
