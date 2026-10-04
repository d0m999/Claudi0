import ClaudioCore
import Darwin
import Dispatch
import Foundation

/// Private same-user stream transport. The kernel peer PID, not a JSON PID, identifies a window
/// extension process. Descriptor contains only discovery data; no workspace/session receipt.
final class IDENavigationSocket: @unchecked Sendable {
    private let queue = DispatchQueue(label: "claudio.ide-navigation")
    private let listener: Int32
    private var stopped = false
    private var socketInode: UInt64 = 0
    private var source: DispatchSourceRead?
    private var peers: [Int32: (source: DispatchSourceRead, data: Data, pid: Int32)] = [:]
    private let directory: URL
    private let descriptor: URL
    private let epoch: UUID
    private let receive: @Sendable (Int32, Int32, Data?) -> Void

    init(
        epoch: UUID, descriptor: URL,
        receive: @escaping @Sendable (Int32, Int32, Data?) -> Void
    ) throws {
        self.epoch = epoch; self.descriptor = descriptor; self.receive = receive
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cl-ide-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { _ = rmdir(directory.path); throw SocketError.failed }
        let path = directory.appendingPathComponent("nav.sock").path
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(listener); _ = rmdir(directory.path); throw SocketError.failed
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) })
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            Darwin.close(listener); _ = unlink(path); _ = rmdir(directory.path);
            throw SocketError.failed
        }
        do {
            guard chmod(path, 0o600) == 0, fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else {
                throw SocketError.failed
            }
            var status = stat()
            guard lstat(path, &status) == 0 else { throw SocketError.failed }
            socketInode = UInt64(status.st_ino)
            try ensurePrivateDirectoryTree(at: descriptor.deletingLastPathComponent())
            let data = try JSONSerialization.data(withJSONObject: [
                "schema": 1, "epoch": epoch.uuidString,
                "socketPath": path, "socketInode": socketInode,
            ])
            try data.write(to: descriptor, options: [.atomic])
            guard chmod(descriptor.path, 0o600) == 0 else { throw SocketError.failed }
        } catch {
            Darwin.close(listener); _ = unlink(path); _ = rmdir(directory.path)
            throw error
        }
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        self.source = source
        source.setEventHandler { [weak self] in self?.acceptPeers() }
        source.resume()
    }
    private func acceptPeers() {
        guard !stopped else { return }
        for _ in 0..<16 {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0; var gid: gid_t = 0; var pid: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard peers.count < 32, getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
                getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 1
            else {
                Darwin.close(fd); continue
            }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var noSignal: Int32 = 1
            _ = setsockopt(
                fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            peers[fd] = (source, Data(), pid)
            source.setEventHandler { [weak self] in self?.drain(fd) }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
        }
    }
    private func drain(_ fd: Int32) {
        var bytes = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<8 {
            let count = recv(fd, &bytes, bytes.count, MSG_DONTWAIT)
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            guard count > 0, var peer = peers[fd] else { disconnect(fd); return }
            peer.data.append(contentsOf: bytes.prefix(count))
            guard peer.data.count <= 8192 else { disconnect(fd); return }
            while let end = peer.data.firstIndex(of: 10) {
                let frame = Data(peer.data[..<end]); peer.data.removeSubrange(...end)
                receive(fd, peer.pid, frame)
            }
            peers[fd] = peer
        }
    }
    func send(_ fd: Int32, data: Data) {
        queue.async { [weak self] in
            guard let self, self.peers[fd] != nil, data.count <= 8192 else { return }
            let framed = data + Data([10])
            let sent = framed.withUnsafeBytes { sendBytes in
                Darwin.send(fd, sendBytes.baseAddress, framed.count, MSG_DONTWAIT)
            }
            if sent != framed.count { self.disconnect(fd) }
        }
    }
    private func disconnect(_ fd: Int32) {
        guard let peer = peers.removeValue(forKey: fd) else { return }
        peer.source.cancel(); receive(fd, peer.pid, nil)
    }
    func stop() {
        let didStop = queue.sync {
            guard !stopped else { return false }
            stopped = true
            source?.cancel(); source = nil
            for fd in Array(peers.keys) { disconnect(fd) }
            Darwin.close(listener)
            return true
        }
        guard didStop else { return }
        if case .success(let data) = readRegularFileBounded(
            at: descriptor, maxBytes: 4096, followSymlink: false),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            value["epoch"] as? String == epoch.uuidString
        {
            try? FileManager.default.removeItem(at: descriptor)
        }
        let path = directory.appendingPathComponent("nav.sock").path
        var status = stat()
        if lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFSOCK,
            status.st_uid == getuid(), UInt64(status.st_ino) == socketInode
        {
            _ = unlink(path)
        }
        _ = rmdir(directory.path)
    }
    enum SocketError: Error { case failed }
}
