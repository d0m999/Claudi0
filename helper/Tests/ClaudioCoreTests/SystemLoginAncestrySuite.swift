import ClaudioCore
import Darwin
import Foundation

@MainActor
func runSystemLoginAncestrySuites() {
    suite("System login：官方 Zed 的完整祖先链与来源复验") {
        func process(_ pid: Int32, parent: Int32, effective: UInt32 = 501) -> HostProcessSnapshot {
            HostProcessSnapshot(
                identity: HostProcessIdentity(pid: pid, startSeconds: 100, startMicroseconds: 42),
                parentPID: parent, userID: effective, realUserID: 501)
        }
        let host = process(10, parent: 11)
        let shell = process(11, parent: 12)
        let login = process(12, parent: 13, effective: 0)
        let zed = process(13, parent: 1)
        let environment = HostProcessReadEnvironment(
            ordinaryProcess: { [10: host, 11: shell, 13: zed][$0] },
            kernelProcess: { $0 == 12 ? login : nil }, executablePath: { _ in "/usr/bin/login" },
            verifySystemLoginSignature: { _ in true })
        let read: (Int32) -> HostProcessSnapshot? = {
            HostProcessAncestry.read($0, userID: 501, environment: environment)
        }
        expect(read(12)?.kind == .systemLogin, "拒绝普通读取后，仅已验证系统login可通过")
        expect(
            read(12)?.userID == 0 && read(12)?.realUserID == 501,
            "本机快照保留有效/真实UID，不能把root伪装成普通用户")
        let ancestors = HostProcessAncestry.capture(startingAt: 10, userID: 501, readProcess: read)
        expect(ancestors.map(\.pid) == [10, 11, 12, 13], "保留login，不跳过任何祖先")
        let app = HostProcessAncestry.nearestApplication(
            in: [host, shell, login, zed].map(\.identity), userID: 501,
            readProcess: read, application: { $0.pid == 13 ? "Zed" : nil })
        expect(app == "Zed", "GUI同一读取路径能穿过已验证login解析Zed")
        let evidence = HostNavigationEvidence.capture(
            ancestors: ancestors, environment: [:], userID: 501, readProcess: read,
            readTTY: { $0 == 13 ? nil : "/dev/ttys001" })
        expect(evidence?.terminalProcess == shell.identity, "共享TTY的login不能替代存活shell")
        let wire =
            try! JSONSerialization.jsonObject(with: JSONEncoder().encode(ancestors))
            as! [[String: Any]]
        expect(
            wire.allSatisfy { Set($0.keys) == ["pid", "startSeconds", "startMicroseconds"] },
            "含系统login的wire仍只有原身份字段，没有类型、UID、路径或签名")
    }

    suite("System login：权限、身份、系统路径、签名与查询期间变化均停止识别") {
        for scenario in [
            "permission-denied", "wrong-pid", "invalid-start", "invalid-microseconds",
            "wrong-effective-user", "wrong-real-user", "missing-path", "non-system-path",
            "signature-failed", "pid-reused", "start-microseconds-changed", "parent-changed",
            "effective-user-changed", "real-user-changed", "path-changed", "exited",
        ] {
            func read(_ pid: Int32) -> HostProcessSnapshot? {
                var queries = 0, paths = 0
                let environment = HostProcessReadEnvironment(
                    ordinaryProcess: { pid in
                        guard pid != 12 else { return nil }
                        return HostProcessSnapshot(
                            identity: HostProcessIdentity(
                                pid: pid, startSeconds: 100, startMicroseconds: 42),
                            parentPID: pid == 13 ? 1 : pid + 1, userID: 501)
                    },
                    kernelProcess: { pid in
                        queries += 1
                        let second = queries > 1
                        if scenario == "permission-denied" || (scenario == "exited" && second) {
                            return nil
                        }
                        return HostProcessSnapshot(
                            identity: HostProcessIdentity(
                                pid: scenario == "wrong-pid" ? 99 : pid,
                                startSeconds: scenario == "invalid-start"
                                    ? 0 : scenario == "pid-reused" && second ? 101 : 100,
                                startMicroseconds: scenario == "invalid-microseconds"
                                    ? 1_000_000
                                    : scenario == "start-microseconds-changed" && second ? 43 : 42),
                            parentPID: scenario == "parent-changed" && second ? 99 : 13,
                            userID: scenario == "wrong-effective-user"
                                || (scenario == "effective-user-changed" && second) ? 501 : 0,
                            realUserID: scenario == "wrong-real-user"
                                || (scenario == "real-user-changed" && second) ? 502 : 501)
                    },
                    executablePath: { _ in
                        paths += 1
                        if scenario == "missing-path" { return nil }
                        return scenario == "non-system-path"
                            || (scenario == "path-changed" && paths > 1)
                            ? "/tmp/login" : "/usr/bin/login"
                    },
                    verifySystemLoginSignature: { _ in scenario != "signature-failed" })
                return HostProcessAncestry.read(pid, userID: 501, environment: environment)
            }
            expect(read(12) == nil, "系统login复验失败：\(scenario)")
            let ancestors = HostProcessAncestry.capture(
                startingAt: 10, userID: 501, readProcess: read)
            expect(ancestors.map(\.pid) == [10, 11], "断点不能被跳过：\(scenario)")
            let identities = (10...13).map {
                HostProcessIdentity(pid: Int32($0), startSeconds: 100, startMicroseconds: 42)
            }
            expect(
                HostProcessAncestry.nearestApplication(
                    in: identities, userID: 501, readProcess: read,
                    application: { $0.pid == 13 ? "Zed" : nil }) == nil,
                "GUI复验不能跨过不可信login：\(scenario)")
        }
    }

    suite("System login：普通读取不变，未知跨UID进程和其他用户仍拒绝") {
        let identity = HostProcessIdentity(pid: 12, startSeconds: 100, startMicroseconds: 42)
        let ordinary = HostProcessSnapshot(identity: identity, parentPID: 13, userID: 501)
        var fallbacks = 0
        var environment = HostProcessReadEnvironment(
            ordinaryProcess: { _ in ordinary },
            kernelProcess: { _ in
                fallbacks += 1; return nil
            },
            executablePath: { _ in
                fallbacks += 1; return nil
            },
            verifySystemLoginSignature: { _ in
                fallbacks += 1; return false
            })
        expect(
            HostProcessAncestry.read(12, userID: 501, environment: environment) == ordinary
                && fallbacks == 0, "普通进程不进行额外路径、内核或签名查询")
        let login = HostProcessSnapshot(
            identity: identity, parentPID: 13, userID: 0, realUserID: 501)
        environment.ordinaryProcess = { _ in login }
        environment.kernelProcess = { _ in login }
        environment.executablePath = { _ in "/usr/bin/login" }
        environment.verifySystemLoginSignature = { _ in true }
        expect(
            HostProcessAncestry.read(12, userID: 501, environment: environment)?.kind
                == .systemLogin,
            "普通API返回跨UID事实时也必须走完整login复验")
        expect(
            HostProcessAncestry.read(12, userID: 502, environment: environment) == nil,
            "已签名login仍不能跨真实用户")
        environment.executablePath = { _ in "/usr/local/bin/login" }
        expect(
            HostProcessAncestry.read(12, userID: 501, environment: environment) == nil,
            "同名非系统程序不能作为跨UID桥梁")
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let live = HostProcessReadEnvironment.live
        expect(
            live.kernelProcess(currentPID)?.identity
                == HostProcessAncestry.read(currentPID)?.identity,
            "真实sysctl与普通API返回同一OS启动身份")
        expect(!live.verifySystemLoginSignature(currentPID), "真实签名校验拒绝非Apple login进程")
    }

    suite("System login：计入16层上限，循环和后续其他用户仍拒绝") {
        func read(_ pid: Int32, parent: Int32? = nil, user: UInt32 = 501) -> HostProcessSnapshot {
            HostProcessSnapshot(
                identity: HostProcessIdentity(pid: pid, startSeconds: 100, startMicroseconds: 42),
                parentPID: parent ?? pid + 1, userID: pid == 12 ? 0 : user,
                realUserID: user, kind: pid == 12 ? .systemLogin : .ordinary)
        }
        let ancestors = HostProcessAncestry.capture(startingAt: 10, userID: 501) { read($0) }
        expect(
            ancestors.count == 16 && ancestors.last?.pid == 25
                && ancestors.contains(read(12).identity),
            "系统login占用一层，不延长采集上限")
        expect(
            HostProcessAncestry.capture(startingAt: 10, userID: 501) {
                read($0, parent: $0 == 12 ? 10 : nil)
            }.isEmpty, "含login的循环仍拒绝")
        expect(
            HostProcessAncestry.capture(startingAt: 10, userID: 501) {
                read($0, user: $0 == 13 ? 502 : 501)
            }.map(\.pid) == [10, 11, 12], "login之后的其他用户应用不能越界")
    }
}
