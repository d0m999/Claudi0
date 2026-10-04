import AppKit
import ClaudioCore
import ClaudioGUICore
import Combine
import Foundation

public enum IDENavigationConnectionState: Sendable { case notConnected, connected, unsupported }

@MainActor
public final class IDENavigationBridge: ObservableObject {
    @Published public private(set) var state: IDENavigationConnectionState = .notConnected
    private struct Window {
        let instance: UUID
        let peer: HostProcessIdentity
        let application: HostProcessIdentity
        let shells: [HostProcessIdentity]
        let supported: Bool
    }
    private struct Pending {
        let fd: Int32
        let instance: UUID
        let shell: HostProcessIdentity
        let deadline: TimeInterval
        let current: @MainActor () -> Bool
        let complete: (SessionNavigationActionResult) -> Void
    }
    private var socket: IDENavigationSocket?
    private var epoch = UUID()
    private var windows: [Int32: Window] = [:]
    private var requests: [UUID: Pending] = [:]
    public init() {}

    public func start() {
        guard socket == nil else { return }
        epoch = UUID()
        let generation = epoch
        socket = try? IDENavigationSocket(
            epoch: epoch,
            descriptor: ClaudioPaths.root.appendingPathComponent("ide-navigation.json")
        ) { [weak self] fd, pid, data in
            Task { @MainActor in
                guard let self, self.epoch == generation else { return }
                self.receive(fd: fd, pid: pid, data: data)
            }
        }
        socket?.start()
    }
    public func stop() {
        socket?.stop(); socket = nil; windows.removeAll()
        let pending = requests.values; requests.removeAll()
        for request in pending { request.complete(.cancelled) }
        state = .notConnected
    }
    private func receive(fd: Int32, pid: Int32, data: Data?) {
        guard socket != nil else { return }
        guard let data else {
            windows.removeValue(forKey: fd)
            let ids = requests.filter { $0.value.fd == fd }.map(\.key)
            for id in ids { requests.removeValue(forKey: id)?.complete(.unavailable) }
            projectState(); return
        }
        guard data.count <= 8192,
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            value["epoch"] as? String == epoch.uuidString
        else { return }
        if value["type"] as? String == "register" {
            guard value["schema"] as? Int == 1,
                let instance = (value["instance"] as? String).flatMap(UUID.init(uuidString:)),
                let pids = value["shells"] as? [Int32], pids.count <= 64,
                let peer = HostProcessAncestry.read(pid), peer.userID == getuid(),
                let app = SourceApplicationAdapter.resolve(
                    HostProcessAncestry.capture(startingAt: pid),
                    action: EventNoticeAction(
                        id: UUID(), version: 1, epoch: epoch, installationID: UUID())),
                ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"].contains(
                    app.bundleIdentifier)
            else { return }
            let shells = pids.compactMap { shell -> HostProcessIdentity? in
                guard let process = HostProcessAncestry.read(shell), process.userID == getuid(),
                    HostProcessAncestry.capture(startingAt: shell).contains(app.process)
                else { return nil }
                return process.identity
            }
            windows[fd] = Window(
                instance: instance, peer: peer.identity, application: app.process,
                shells: shells, supported: value["supported"] as? Bool == true)
            // Terminal removal or window reload invalidates already dispatched requests too.
            let ids = requests.filter {
                $0.value.fd == fd
                    && ($0.value.instance != instance || !shells.contains($0.value.shell))
            }.map(\.key)
            for id in ids { requests.removeValue(forKey: id)?.complete(.unavailable) }
            send(
                fd: fd,
                value: [
                    "type": "registered", "schema": 1,
                    "epoch": epoch.uuidString, "instance": instance.uuidString,
                    "supported": value["supported"] as? Bool == true,
                ])
            projectState()
        } else if value["type"] as? String == "result",
            let id = (value["request"] as? String).flatMap(UUID.init(uuidString:)),
            let pending = requests[id], pending.fd == fd,
            let window = windows[fd], window.instance == pending.instance,
            value["instance"] as? String == window.instance.uuidString,
            value["shell"] as? Int32 == pending.shell.pid
        {
            requests.removeValue(forKey: id)
            guard pending.current(), ProcessInfo.processInfo.systemUptime < pending.deadline,
                HostProcessAncestry.read(window.peer.pid)?.identity == window.peer,
                HostProcessAncestry.read(pending.shell.pid)?.identity == pending.shell,
                window.shells.contains(pending.shell)
            else { pending.complete(.cancelled); return }
            let exact =
                value["outcome"] as? String == "confirmed"
                && NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == window.application.pid
            pending.complete(exact ? .exactReturnConfirmed : .unavailable)
        }
    }
    private func projectState() {
        state =
            windows.isEmpty
            ? .notConnected
            : windows.values.contains(where: \.supported) ? .connected : .unsupported
    }
    private func send(fd: Int32, value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        socket?.send(fd, data: data)
    }
    public func navigate(
        shells: [HostProcessIdentity], application: SourceApplicationTarget,
        isCurrent: @escaping @MainActor () -> Bool, deadline: TimeInterval
    )
        async -> SessionNavigationActionResult
    {
        guard isCurrent() else { return .cancelled }
        let matches = windows.flatMap { fd, window in
            window.shells.filter { shells.contains($0) }.map { (fd, window, $0) }
        }.filter {
            $0.1.supported && $0.1.application == application.process
                && HostProcessAncestry.read($0.1.peer.pid)?.identity == $0.1.peer
                && HostProcessAncestry.read($0.2.pid)?.identity == $0.2
        }
        guard matches.count == 1 else { return .unavailable }
        let (fd, window, shell) = matches[0]
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard isCurrent(), ProcessInfo.processInfo.systemUptime < deadline else {
                    continuation.resume(returning: .cancelled); return
                }
                requests[id] = Pending(
                    fd: fd, instance: window.instance, shell: shell,
                    deadline: deadline, current: isCurrent,
                    complete: { continuation.resume(returning: $0) })
                send(
                    fd: fd,
                    value: [
                        "type": "navigate", "schema": 1, "epoch": epoch.uuidString,
                        "instance": window.instance.uuidString, "request": id.uuidString,
                        "shell": shell.pid,
                        "remainingMs": Int(
                            max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1000),
                    ])
                Task { @MainActor [weak self] in
                    try? await Task.sleep(
                        nanoseconds: UInt64(
                            max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1e9))
                    self?.cancel(id, outcome: .timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id, outcome: .cancelled) }
        }
    }
    private func cancel(_ id: UUID, outcome: SessionNavigationActionResult) {
        guard let request = requests.removeValue(forKey: id) else { return }
        send(
            fd: request.fd,
            value: [
                "type": "cancel", "epoch": epoch.uuidString,
                "instance": request.instance.uuidString, "request": id.uuidString,
            ])
        request.complete(outcome)
    }
}
