import Darwin
import Foundation

/// Single-threaded side channel for metadata only; PTY bytes never enter this socket.
final class ZedPTYControlChannel {
    let fd: Int32
    let epoch: UUID
    private var input = Data()
    private var output = Data()
    private(set) var isAlive = true

    private init(fd: Int32, epoch: UUID) { self.fd = fd; self.epoch = epoch }
    deinit { Darwin.close(fd) }

    static func connect(descriptor: URL) -> ZedPTYControlChannel? {
        struct Descriptor: Decodable {
            let schema: Int; let epoch: UUID; let socketPath: String; let socketInode: UInt64
        }
        var status = stat()
        guard lstat(descriptor.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == getuid(), status.st_mode & 0o077 == 0,
            case .success(let data) = readRegularFileBounded(
                at: descriptor, maxBytes: 4096, followSymlink: false),
            let value = try? JSONDecoder().decode(Descriptor.self, from: data), value.schema == 1,
            value.socketPath.utf8.count < 104,
            lstat(value.socketPath, &status) == 0, status.st_mode & S_IFMT == S_IFSOCK,
            status.st_uid == getuid(), status.st_mode & 0o077 == 0,
            UInt64(status.st_ino) == value.socketInode
        else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: value.socketPath.utf8CString.map { UInt8(bitPattern: $0) })
        }
        // A same-machine private listener should complete immediately; nonblocking connect
        // avoids ever delaying the CLI behind a wedged receiver.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(fd); return nil }
        var uid: uid_t = 0, gid: gid_t = 0, noSignal: Int32 = 1
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            Darwin.close(fd); return nil
        }
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return ZedPTYControlChannel(fd: fd, epoch: value.epoch)
    }

    func send(_ frame: ZedPTYFrame) {
        guard isAlive, let data = try? JSONEncoder().encode(frame), data.count <= 8192,
            output.count + data.count < 65536
        else { isAlive = false; return }
        output.append(data); output.append(10); flush()
    }

    func flush() {
        guard isAlive, !output.isEmpty else { return }
        let count = output.withUnsafeBytes {
            Darwin.send(fd, $0.baseAddress, output.count, MSG_DONTWAIT)
        }
        if count > 0 {
            output.removeFirst(count)
        } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            isAlive = false
        }
    }

    func receive() -> [ZedPTYFrame] {
        guard isAlive else { return [] }
        var bytes = [UInt8](repeating: 0, count: 4096), frames: [ZedPTYFrame] = []
        for _ in 0..<4 {
            let count = recv(fd, &bytes, bytes.count, MSG_DONTWAIT)
            if count < 0 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { break }
            guard count > 0 else { isAlive = false; break }
            input.append(contentsOf: bytes.prefix(count))
            while let end = input.firstIndex(of: 10) {
                guard input.distance(from: input.startIndex, to: end) <= 8192,
                    let frame = try? JSONDecoder().decode(ZedPTYFrame.self, from: input[..<end]),
                    frame.schema == 1, frame.epoch == epoch
                else { isAlive = false; return [] }
                frames.append(frame); input.removeSubrange(...end)
            }
            if input.count > 8192 { isAlive = false; break }
        }
        return frames
    }
}
