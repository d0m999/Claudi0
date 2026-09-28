import Darwin
import Foundation

public enum HostProcessAncestry {
    public static let maximumCount = 16

    public static func read(_ pid: Int32) -> HostProcessSnapshot? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
            info.pbi_pid == UInt32(pid), info.pbi_uid == info.pbi_ruid
        else { return nil }
        let identity = HostProcessIdentity(
            pid: pid, startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec)
        guard identity.isValid else { return nil }
        return HostProcessSnapshot(
            identity: identity, parentPID: Int32(info.pbi_ppid), userID: info.pbi_uid)
    }

    public static func capture(
        startingAt parentPID: Int32 = getppid(), userID: UInt32 = getuid(),
        readProcess: (Int32) -> HostProcessSnapshot? = read
    ) -> [HostProcessIdentity] {
        var result: [HostProcessIdentity] = []
        var visited = Set<Int32>()
        var pid = parentPID
        while pid > 1 && result.count < maximumCount {
            guard visited.insert(pid).inserted else { return [] }
            guard let process = readProcess(pid), process.userID == userID,
                process.identity.pid == pid, process.identity.isValid
            else { break }
            result.append(process.identity)
            pid = process.parentPID
            if visited.contains(pid) { return [] }
        }
        return result
    }

    public static func isValid(_ identities: [HostProcessIdentity]) -> Bool {
        identities.count <= maximumCount && identities.allSatisfy(\.isValid)
            && Set(identities.map(\.pid)).count == identities.count
    }

    /// Fail closed at a broken link or reused PID; never skip across it to an unrelated app.
    public static func nearestApplication<T>(
        in identities: [HostProcessIdentity], userID: UInt32,
        readProcess: (Int32) -> HostProcessSnapshot? = read,
        application: (HostProcessIdentity) -> T?
    ) -> T? {
        guard isValid(identities) else { return nil }
        var expectedPID: Int32?
        for identity in identities {
            guard expectedPID == nil || expectedPID == identity.pid,
                let process = readProcess(identity.pid), process.identity == identity,
                process.userID == userID
            else { return nil }
            if let target = application(identity) {
                // AppKit lookup and kernel lookup must describe the same process instance.
                guard readProcess(identity.pid) == process else { return nil }
                return target
            }
            expectedPID = process.parentPID
        }
        return nil
    }
}
