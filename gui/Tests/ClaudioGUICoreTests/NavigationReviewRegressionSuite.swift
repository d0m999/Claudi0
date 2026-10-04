import ClaudioCore
import ClaudioGUICore
import Combine
import Darwin
import Foundation

@testable import ClaudioGUIComponents

@MainActor
func runNavigationReviewRegressionSuites() async {
    suite("Navigation review：过期预算在Process.run前拒绝，包括排队后过期") {
        let process = NavigationLaunchProbe()
        let state = CommandState()
        expect(
            !state.start(process, deadline: ProcessInfo.processInfo.systemUptime - 1),
            "已过期请求拒绝启动")
        expect(process.launches == 0, "过期请求不能调用Process.run")
        let queuedDeadline = ProcessInfo.processInfo.systemUptime + 0.002
        Thread.sleep(forTimeInterval: 0.004)
        let queued = NavigationLaunchProbe()
        expect(!CommandState().start(queued, deadline: queuedDeadline), "排队跨过deadline也拒绝")
        expect(queued.launches == 0, "在实际启动边界复验预算")
        let cancelled = CommandState()
        cancelled.cancel()
        let probe = NavigationLaunchProbe()
        expect(
            !cancelled.start(probe, deadline: ProcessInfo.processInfo.systemUptime + 1)
                && probe.launches == 0, "预先取消同样不启动")
    }

    await suite("Navigation review：焦点失效立即取消悬挂动作并发布cancelled") {
        let focus = NavigationFocusGuard(targetPID: 123, initialPID: 456)
        let suspension = NavigationSuspensionProbe()
        let task = Task { @MainActor in
            await withTaskCancellationHandler {
                await withCheckedContinuation { suspension.continuation = $0 }
            } onCancel: {
                Task { @MainActor in suspension.cancelled = true }
            }
        }
        var outcomes: [SessionNavigationActionResult] = []
        focus.cancelOnInvalidation(task) { outcomes.append($0) }
        while suspension.continuation == nil { await Task.yield() }
        focus.beginHandoff()
        focus.didActivate(123)
        expect(focus.isValid && !task.isCancelled, "预期交接不取消")
        focus.didActivate(789)
        expect(!focus.isValid && task.isCancelled, "第三应用激活时同步取消Task")
        focus.didActivate(790)
        expect(outcomes == [.cancelled], "立即且仅一次完成取消，无须等待IDE回包")
        let cancellationDeadline = ProcessInfo.processInfo.systemUptime + 0.1
        while !suspension.cancelled && ProcessInfo.processInfo.systemUptime < cancellationDeadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        expect(suspension.cancelled, "聚焦尚未返回就触发取消处理")
        suspension.continuation?.resume()
        await task.value
        focus.stop()
    }

    await suite("Navigation review：32条成批发布，慢解析保留余项并让出") {
        for slow in [false, true] {
            var resolutions = 0
            let model = EventNoticeModel(
                receiverEpoch: UUID(),
                resolveSourceApplication: { _, _ in
                    resolutions += 1
                    if slow { Thread.sleep(forTimeInterval: 0.006) }
                    return nil
                })
            let ingress = EventNoticeNavigationIngress(model: model)
            let notices = (0..<32).map { _ in
                attentionNotice(
                    epoch: model.receiverEpoch, native: "PermissionRequest",
                    source: nil,
                    processAncestors: [
                        HostProcessIdentity(
                            pid: 42, startSeconds: 100, startMicroseconds: 0)
                    ])
            }
            var publications = 0
            var interleavedCount: Int?
            let sink = model.$readingSnapshot.dropFirst().sink { _ in
                publications += 1
                if slow && publications == 1 {
                    Task { @MainActor in interleavedCount = resolutions }
                }
            }
            expect(ingress.acceptNotices(notices) == 32, "准备批次接管32条")
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while ingress.pendingBatchCount > 0 && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            expect(ingress.pendingBatchCount == 0 && resolutions == 32, "未消费事件全部归约一次")
            expect(model.resourceUsage.deduplicationEntries == 32, "余项不丢失")
            if slow {
                expect(interleavedCount.map { $0 < 32 } == true, "4ms预算之后允许其他MainActor任务执行")
            } else {
                expect(publications == 1, "32条只发布一次readingSnapshot")
            }
            withExtendedLifetime(sink) {}
        }
    }

    await suite("Navigation review：准备任务上限、取消与epoch隔离") {
        let model = EventNoticeModel(receiverEpoch: UUID())
        let ingress = EventNoticeNavigationIngress(model: model)
        let old = attentionNotice(epoch: model.receiverEpoch, source: nil)
        for _ in 0..<4 { _ = ingress.acceptNotices([old]) }
        expect(ingress.pendingBatchCount == 4, "至多四个准备批次")
        let fallback = attentionNotice(epoch: model.receiverEpoch, source: nil)
        expect(
            ingress.acceptNotices([fallback]) == 1 && ingress.pendingBatchCount == 4,
            "准备能力满时仍有界接受普通事件")
        ingress.clear()
        model.clearForPrivacy()
        let fresh = attentionNotice(epoch: model.receiverEpoch, source: nil)
        _ = ingress.acceptNotices([fresh])
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while ingress.pendingBatchCount > 0 && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        expect(
            model.snapshot.attentionReminders.map(\.notice?.id) == [fresh.id],
            "取消的旧批次不能跨epoch投递，新批次仍正常接受")
    }

    await suite("Navigation review：socket被新server占用时拒绝旧server证据") {
        guard
            let executable = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { print("  SKIP：tmux未安装，未运行真实server fixture"); return }
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(
            "tmux-review-" + UUID().uuidString)
        let path = root.appendingPathComponent("socket").path
        var identities: [HostProcessIdentity] = []
        defer {
            for identity in identities
            where HostProcessAncestry.read(identity.pid)?.identity == identity {
                _ = Darwin.kill(identity.pid, SIGTERM)
            }
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            func launchServer() -> HostProcessIdentity? {
                guard
                    tmuxFixtureCommand(
                        executable,
                        [
                            "-f", "/dev/null", "-S", path,
                            "new-session", "-d", "-s", "fixture", "/bin/sleep 60",
                        ]) != nil,
                    let text = tmuxFixtureCommand(
                        executable,
                        [
                            "-S", path,
                            "display-message", "-p", "#{pid}",
                        ]),
                    let pid = Int32(text), let identity = HostProcessAncestry.read(pid)?.identity
                else { return nil }
                identities.append(identity)
                return identity
            }
            guard let original = launchServer() else { expect(false, "启动原server"); return }
            let evidence = TmuxNavigationEvidence(socketPath: path, server: original, paneID: "%0")
            expect(
                await TmuxNavigationAdapter.pane(
                    evidence, deadline: ProcessInfo.processInfo.systemUptime + 1) != nil,
                "实际server匹配时接受pane")
            let reusedPID = TmuxNavigationEvidence(
                socketPath: path,
                server: HostProcessIdentity(
                    pid: original.pid, startSeconds: original.startSeconds + 1,
                    startMicroseconds: original.startMicroseconds), paneID: "%0")
            expect(
                await TmuxNavigationAdapter.pane(
                    reusedPID, deadline: ProcessInfo.processInfo.systemUptime + 1) == nil,
                "相同PID不同启动身份拒绝")
            guard unlink(path) == 0, let replacement = launchServer() else {
                expect(false, "启动同路径替代server"); return
            }
            expect(
                original != replacement
                    && HostProcessAncestry.read(original.pid)?.identity == original,
                "旧server仍存活，新server绑定同用户同路径socket")
            expect(
                await TmuxNavigationAdapter.pane(
                    evidence, deadline: ProcessInfo.processInfo.systemUptime + 1) == nil,
                "不得返回新server同名%0 pane")
            expect(
                await TmuxNavigationAdapter.pane(
                    TmuxNavigationEvidence(socketPath: path, server: replacement, paneID: "%0"),
                    deadline: ProcessInfo.processInfo.systemUptime + 1) != nil,
                "新server自身证据仍有效，未一概禁用tmux")
        } catch { expect(false, "tmux fixture创建失败") }
    }
}

private final class NavigationLaunchProbe: Process, @unchecked Sendable {
    var launches = 0
    override func run() throws { launches += 1 }
}

private func tmuxFixtureCommand(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

@MainActor
private final class NavigationSuspensionProbe {
    var cancelled = false
    var continuation: CheckedContinuation<Void, Never>?
}
