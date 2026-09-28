import ClaudioCore
import Foundation

@MainActor
func runHostProcessAncestrySuites() {
    func process(_ pid: Int32, parent: Int32? = nil, user: UInt32 = 501, start: UInt64 = 100)
        -> HostProcessSnapshot
    {
        HostProcessSnapshot(
            identity: HostProcessIdentity(pid: pid, startSeconds: start, startMicroseconds: 42),
            parentPID: parent ?? pid + 1, userID: user)
    }
    suite("Process ancestry：同用户、断链、循环、16 层边界") {
        let values = HostProcessAncestry.capture(startingAt: 10, userID: 501) { process($0) }
        expect(
            values.count == 16 && values.first?.pid == 10 && values.last?.pid == 25,
            "最多16层，只按最近祖先顺序")
        let disconnected = HostProcessAncestry.capture(startingAt: 10, userID: 501) {
            $0 < 12 ? process($0) : nil
        }
        expect(disconnected.map(\.pid) == [10, 11], "断链停止，不猜测祖先")
        let differentUser = HostProcessAncestry.capture(startingAt: 10, userID: 501) {
            process($0, user: $0 == 11 ? 502 : 501)
        }
        expect(differentUser.map(\.pid) == [10], "不同用户不越界")
        expect(
            HostProcessAncestry.capture(startingAt: 10, userID: 501) { process($0, parent: 10) }
                .isEmpty, "循环拒绝")
        expect(
            HostProcessAncestry.capture(startingAt: 1, userID: 501) { process($0) }.isEmpty,
            "不捕获launchd")
        expect(!HostProcessAncestry.isValid(values + [process(26).identity]), "超长wire拒绝")
        expect(!HostProcessAncestry.isValid([values[0], values[0]]), "重复PID拒绝")
    }
    suite("Process ancestry：复验 PID 复用、用户、父链和最近 App") {
        let identities = [process(10).identity, process(11).identity, process(12).identity]
        func resolve(
            _ read: (Int32) -> HostProcessSnapshot?,
            app: (HostProcessIdentity) -> Int32? = { $0.pid >= 11 ? $0.pid : nil }
        ) -> Int32? {
            HostProcessAncestry.nearestApplication(
                in: identities, userID: 501, readProcess: read, application: app)
        }
        expect(resolve({ process($0) }) == 11, "选择最近应用")
        expect(resolve({ process($0, start: $0 == 10 ? 101 : 100) }) == nil, "PID复用不能跳过到其他应用")
        expect(resolve({ process($0, user: $0 == 11 ? 502 : 501) }) == nil, "接收时再次校验用户")
        expect(resolve({ process($0, parent: 99) }) == nil, "父链变化拒绝")
        expect(resolve({ $0 == 10 ? nil : process($0) }) == nil, "已退出的链首不能跳过")
        expect(resolve({ process($0) }, app: { _ in nil }) == nil, "无可激活App诚实降级")
        var reads = 0
        expect(
            resolve({ pid in
                reads += 1
                return process(pid, start: reads > 2 ? 101 : 100)
            }) == nil, "App识别期间PID复用被二次复验拒绝")
        let live = HostProcessAncestry.read(ProcessInfo.processInfo.processIdentifier)
        expect(live?.identity.isValid == true, "真实OS进程启动身份可读")
    }
    suite("Process ancestry：旧消息兼容、8KiB 和仅最小字段") {
        let binding = HostCapabilityCatalog.binding(host: .codex, nativeEvent: "PermissionRequest")!
        let notice = HostEventNotice(
            receiverEpoch: UUID(), surface: .codex, bindingID: binding.id,
            installationID: UUID(), nativeEvent: "PermissionRequest", event: .notification,
            occurredAt: Date(), reason: .permission,
            processAncestors: (10..<26).map { process(Int32($0)).identity })
        guard let data = try? JSONEncoder().encode(notice),
            var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            expect(false, "wire编码成功"); return
        }
        expect(data.count < 8192, "16层身份仍在8KiB内")
        let identities = object["process_ancestors"] as? [[String: Any]]
        expect(
            Set(identities?.first?.keys.map { $0 } ?? []) == [
                "pid", "startSeconds", "startMicroseconds",
            ], "仅PID与OS启动时间上wire")
        expect((try? JSONDecoder().decode(HostEventNotice.self, from: data)) == notice, "新wire往返")
        object.removeValue(forKey: "process_ancestors")
        let oldData = try! JSONSerialization.data(withJSONObject: object)
        let old = try? JSONDecoder().decode(HostEventNotice.self, from: oldData)
        expect(old?.processAncestors == nil && old?.isSemanticallyValid == true, "旧wire正常接收")
        object["process_ancestors"] = Array(repeating: identities!.first!, count: 17)
        let malformed = try! JSONSerialization.data(withJSONObject: object)
        let decoded = try? JSONDecoder().decode(HostEventNotice.self, from: malformed)
        expect(
            decoded?.processAncestors == nil && decoded?.isSemanticallyValid == true,
            "无效可选身份只降级打开能力")
        expect(notice.removingProcessAncestors().processAncestors == nil, "解析后释放原始祖先列表")
    }
}
