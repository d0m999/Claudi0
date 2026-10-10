import ClaudioCore
import ClaudioGUICore
import Foundation

/// App-lifetime owner of authenticated PTY connections. The notice model retains only identities.
@MainActor
public final class ZedPTYNavigationBridge {
    private struct Peer {
        let connection = UUID()
        let session: ZedPTYSessionIdentity
        let application: SourceApplicationTarget
        var focus: ZedPTYFocusState?
    }
    private struct Barrier {
        var waiting: Set<Int32>
        let application: HostProcessIdentity
        let complete: (ZedNavigationSnapshot?) -> Void
    }
    private let enabled: Bool
    private let descriptor: URL
    private var socket: IDENavigationSocket?
    private var epoch = UUID()
    private var peers: [Int32: Peer] = [:]
    private var inputRevision: UInt64 = 0
    private var barriers: [UUID: Barrier] = [:]

    public init(
        enabled: Bool = false,
        descriptor: URL = ClaudioPaths.root.appendingPathComponent("zed-navigation.json")
    ) {
        self.enabled = enabled; self.descriptor = descriptor
    }

    public func start() {
        guard enabled, socket == nil else { return }
        epoch = UUID()
        let generation = epoch
        socket = try? IDENavigationSocket(epoch: epoch, descriptor: descriptor) {
            [weak self] fd, pid, data in
            Task { @MainActor in
                guard let self, self.epoch == generation else { return }
                self.receive(fd: fd, pid: pid, data: data)
            }
        }
        socket?.start()
    }
    public func stop() {
        epoch = UUID()
        socket?.stop(); socket = nil; peers.removeAll(); inputRevision = 0
        let pending = barriers.values; barriers.removeAll()
        for barrier in pending { barrier.complete(nil) }
    }

    public func resolve(_ notice: HostEventNotice, application: SourceApplicationTarget?)
        -> SessionNavigationTarget?
    {
        guard enabled, socket != nil, let application else { return nil }
        let sessions = peers.values.filter {
            $0.application.process == application.process && live($0)
        }.map(\.session)
        return ZedManagedSession.resolve(notice, application: application, sessions: sessions)
    }

    public func navigate(
        _ session: ZedPTYSessionIdentity, application: SourceApplicationTarget,
        isCurrent: @escaping @MainActor () -> Bool, deadline: TimeInterval
    ) async -> SessionNavigationActionResult {
        guard enabled, socket != nil,
            peers.values.filter({
                $0.session == session && $0.application.process == application.process && live($0)
            }).count == 1
        else { return .unavailable }
        guard let connection = peers.values.first(where: { $0.session == session })?.connection
        else { return .unavailable }
        var initializationFailure: String?
        guard
            let driver = ZedNativeNavigation(
                application: application, deadline: deadline, current: isCurrent,
                onFailure: { initializationFailure = $0 })
        else {
            diagnostic(initializationFailure ?? "native_window_unavailable")
            return .unavailable
        }
        defer { driver.stop() }
        let generation = epoch
        let current: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.epoch == generation && driver.isCurrent
                && self.peers.values.filter({
                    $0.session == session && $0.application.process == application.process
                        && $0.connection == connection
                        && self.live($0)
                }).count == 1
        }
        var failureStage: String?
        #if DEBUG
        let tracing =
            ProcessInfo.processInfo.environment["CLAUDIO_ZED_NAVIGATION_DIAGNOSTICS"] == "1"
        let traceStart = ProcessInfo.processInfo.systemUptime
        var operations: [[String: Any]] = []
        func record(_ operation: String, since start: TimeInterval, result: Bool) {
            guard tracing, operations.count < 192 else { return }
            operations.append([
                "operation": operation, "seconds": ProcessInfo.processInfo.systemUptime - start,
                "elapsed": ProcessInfo.processInfo.systemUptime - traceStart, "result": result,
            ])
        }
        #endif
        let result = await ZedNavigationSearch.navigate(
            instance: session.instance, deadline: deadline,
            environment: ZedNavigationSearch.Environment(
                now: { ProcessInfo.processInfo.systemUptime }, isCurrent: current,
                windows: { driver.windows },
                selectWindow: {
                    #if DEBUG
                    let start = ProcessInfo.processInfo.systemUptime
                    #endif
                    let selected = await driver.selectWindow($0)
                    #if DEBUG
                    record(
                        "window-\(driver.windows.firstIndex(of: $0) ?? -1)", since: start,
                        result: selected)
                    #endif
                    if !selected { failureStage = driver.failureReason }
                    return selected
                },
                isWindowCurrent: {
                    let selected = driver.isWindowCurrent($0)
                    if !selected { failureStage = driver.failureReason }
                    return selected
                },
                step: {
                    #if DEBUG
                    let start = ProcessInfo.processInfo.systemUptime
                    #endif
                    let posted = await driver.step($0)
                    #if DEBUG
                    record(String(describing: $0), since: start, result: posted)
                    #endif
                    if !posted { failureStage = driver.failureReason }
                    return posted
                },
                snapshot: { [weak self] in
                    #if DEBUG
                    let start = ProcessInfo.processInfo.systemUptime
                    #endif
                    guard let self, current() else { return nil }
                    let snapshot = await self.snapshot(
                        application: application.process, deadline: deadline)
                    #if DEBUG
                    record(
                        "snapshot-focused-\(snapshot?.states.filter(\.focused).count ?? -1)",
                        since: start, result: snapshot != nil)
                    #endif
                    if snapshot == nil { failureStage = "snapshot_barrier_failed" }
                    return snapshot
                }, supportsDirections: { driver.supportsDirections }))
        #if DEBUG
        diagnostic(
            String(describing: result), stage: failureStage ?? driver.stopReason,
            operations: operations)
        #else
        diagnostic(String(describing: result), stage: failureStage ?? driver.stopReason)
        #endif
        return result
    }

    private func live(_ peer: Peer) -> Bool {
        ZedManagedSession.validate(
            peer.session, kernelPeerPID: peer.session.process.pid,
            application: peer.application, userID: getuid())
            && HostSessionNavigationAdapter.live(peer.application)
    }
    private func invalidate(_ fd: Int32) {
        peers.removeValue(forKey: fd)
        for id in Array(barriers.keys) where barriers[id]?.waiting.contains(fd) == true {
            barriers.removeValue(forKey: id)?.complete(nil)
        }
    }

    private func receive(fd: Int32, pid: Int32, data: Data?) {
        guard socket != nil else { return }
        guard let data else { invalidate(fd); return }
        guard data.count <= 8192,
            let frame = try? JSONDecoder().decode(ZedPTYFrame.self, from: data),
            frame.schema == 1, frame.epoch == epoch
        else { invalidate(fd); return }
        if frame.type == .register {
            guard let session = frame.session, session.instance == frame.instance,
                !peers.values.contains(where: {
                    $0.session.instance == session.instance || $0.session.process.pid == pid
                }),
                let application = SourceApplicationAdapter.resolve(
                    HostProcessAncestry.capture(startingAt: pid),
                    action: EventNoticeAction(
                        id: UUID(), version: 1, epoch: epoch, installationID: UUID())),
                ZedManagedSession.validate(
                    session, kernelPeerPID: pid, application: application, userID: getuid())
            else { invalidate(fd); return }
            peers[fd] = Peer(session: session, application: application)
            diagnostic("registered")
            return
        }
        guard var peer = peers[fd], peer.session.process.pid == pid,
            frame.instance == peer.session.instance, live(peer)
        else { invalidate(fd); return }
        if frame.type == .input { inputRevision &+= 1; return }
        guard frame.type == .state, let sequence = frame.sequence,
            let observed = frame.observedUptime, observed.isFinite,
            observed >= 0, observed <= ProcessInfo.processInfo.systemUptime,
            sequence == 0
                ? (frame.focused == nil && observed == 0) : (frame.focused != nil && observed > 0)
        else { invalidate(fd); return }
        let focus = ZedPTYFocusState(
            instance: frame.instance, sequence: sequence,
            focused: frame.focused ?? false, observedUptime: observed)
        if let old = peer.focus {
            guard sequence > old.sequence || focus == old else { invalidate(fd); return }
        }
        peer.focus = focus; peers[fd] = peer
        if let id = frame.request, var barrier = barriers[id] {
            guard frame.caughtUp == true else {
                barriers.removeValue(forKey: id)?.complete(nil); return
            }
            guard barrier.application == peer.application.process, barrier.waiting.remove(fd) != nil
            else { return }
            barriers[id] = barrier
            if barrier.waiting.isEmpty {
                barriers.removeValue(forKey: id)?.complete(
                    projection(application: barrier.application))
            }
        }
    }

    private func diagnostic(_ code: String, stage: String? = nil, operations: [[String: Any]] = [])
    {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["CLAUDIO_ZED_NAVIGATION_DIAGNOSTICS"] == "1"
        else { return }
        let file = ClaudioPaths.root.appendingPathComponent("zed-navigation-check.json")
        var fields: [String: Any] = ["code": code, "authenticatedPeers": peers.count]
        if let stage { fields["stage"] = stage }
        if !operations.isEmpty { fields["operations"] = operations }
        if let data = try? JSONSerialization.data(withJSONObject: fields) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        #endif
    }

    private func projection(application: HostProcessIdentity) -> ZedNavigationSnapshot? {
        let relevant = peers.values.filter { $0.application.process == application }
        guard !relevant.isEmpty, relevant.allSatisfy(live) else { return nil }
        return ZedNavigationSnapshot(
            epoch: epoch, inputRevision: inputRevision,
            states: relevant.compactMap(\.focus))
    }

    private func snapshot(application: HostProcessIdentity, deadline: TimeInterval) async
        -> ZedNavigationSnapshot?
    {
        let relevant = peers.filter { $0.value.application.process == application }
        guard let socket, !relevant.isEmpty, relevant.values.allSatisfy(live),
            ProcessInfo.processInfo.systemUptime < deadline
        else { return nil }
        let id = UUID(), generation = epoch
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                barriers[id] = Barrier(
                    waiting: Set(relevant.keys), application: application,
                    complete: { continuation.resume(returning: $0) })
                for (fd, peer) in relevant {
                    var frame = ZedPTYFrame(
                        type: .snapshot, epoch: epoch, instance: peer.session.instance)
                    frame.request = id
                    if let data = try? JSONEncoder().encode(frame) { socket.send(fd, data: data) }
                }
                Task { [weak self] in
                    let remaining = max(
                        0, min(0.09, deadline - ProcessInfo.processInfo.systemUptime))
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    guard let self, self.epoch == generation else { return }
                    self.barriers.removeValue(forKey: id)?.complete(nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.epoch == generation else { return }
                self.barriers.removeValue(forKey: id)?.complete(nil)
            }
        }
    }
}
