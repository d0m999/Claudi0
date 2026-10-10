import Darwin
import Foundation

public enum HostProcessAncestry {
    public static let maximumCount = 16

    public static func read(_ pid: Int32) -> HostProcessSnapshot? {
        read(pid, userID: getuid(), environment: .live)
    }

    public static func read(
        _ pid: Int32, userID: UInt32, environment: HostProcessReadEnvironment
    ) -> HostProcessSnapshot? {
        guard pid > 1 else { return nil }
        if let process = environment.ordinaryProcess(pid),
            process.identity.pid == pid, process.identity.isValid,
            process.kind == .ordinary, process.userID == process.realUserID
        {
            return process
        }
        // A root-effective login is the only supported cross-UID link. No name/argv guessing.
        guard environment.executablePath(pid) == "/usr/bin/login",
            let before = environment.kernelProcess(pid),
            before.identity.pid == pid, before.identity.isValid, before.kind == .ordinary,
            before.userID == 0, before.realUserID == userID,
            environment.verifySystemLoginSignature(pid),
            environment.kernelProcess(pid) == before,
            environment.executablePath(pid) == "/usr/bin/login"
        else { return nil }
        return HostProcessSnapshot(
            identity: before.identity, parentPID: before.parentPID,
            userID: before.userID, realUserID: before.realUserID, kind: .systemLogin)
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
            guard let process = readProcess(pid), process.isOwned(by: userID),
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
                process.isOwned(by: userID)
            else { return nil }
            if process.kind == .ordinary, let target = application(identity) {
                // AppKit lookup and kernel lookup must describe the same process instance.
                guard readProcess(identity.pid) == process else { return nil }
                return target
            }
            expectedPID = process.parentPID
        }
        return nil
    }
}
