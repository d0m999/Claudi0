import ClaudioCore
import Darwin
import Foundation

@testable import ClaudioGUIComponents

@MainActor
func runIDENavigationSocketSuites() async {
    await suite("IDE socket：私有发现、真实peerPID、有界帧和关闭清理") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ide-test-" + UUID().uuidString)
        let descriptor = root.appendingPathComponent("discovery.json")
        let epoch = UUID()
        let frames = NavigationTestFrames()
        do {
            let server = try IDENavigationSocket(epoch: epoch, descriptor: descriptor) {
                fd, pid, data in
                frames.append(fd: fd, pid: pid, data: data)
            }
            server.start()
            defer { server.stop(); try? FileManager.default.removeItem(at: root) }
            let data = try Data(contentsOf: descriptor)
            let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            expect(
                Set(value.keys) == ["schema", "epoch", "socketPath", "socketInode"],
                "发现文件没有工作区/会话/terminal字段")
            let mode =
                try FileManager.default.attributesOfItem(atPath: descriptor.path)[.posixPermissions]
                as! Int
            expect(mode == 0o600, "描述文件0600")
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { Darwin.close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let path = value["socketPath"] as! String
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) })
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            expect(connected == 0, "真实本地socket连接")
            let payload = Data("{\"type\":\"fixture\"}\n".utf8)
            _ = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, payload.count, 0) }
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while frames.snapshot.isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            expect(frames.snapshot.first?.pid == getpid(), "peerPID来自内核")
            expect(frames.snapshot.first?.data == payload.dropLast(), "帧按换行有界拆分")
            let excessive = Data(repeating: 65, count: 8193)
            _ = excessive.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, excessive.count, 0) }
            while !frames.snapshot.contains(where: { $0.data == nil })
                && ProcessInfo.processInfo.systemUptime < deadline
            {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            expect(frames.snapshot.contains(where: { $0.data == nil }), "超限帧断开并使注册失效")
        } catch { expect(false, "私有socket fixture失败：\(error)") }
        expect(!FileManager.default.fileExists(atPath: descriptor.path), "关闭擦除自身epoch发现文件")
    }
}

private final class NavigationTestFrames: @unchecked Sendable {
    struct Frame { let fd: Int32; let pid: Int32; let data: Data? }
    private let lock = NSLock()
    private var frames: [Frame] = []
    var snapshot: [Frame] { lock.lock(); defer { lock.unlock() }; return frames }
    func append(fd: Int32, pid: Int32, data: Data?) {
        lock.lock(); defer { lock.unlock() }; frames.append(Frame(fd: fd, pid: pid, data: data))
    }
}
