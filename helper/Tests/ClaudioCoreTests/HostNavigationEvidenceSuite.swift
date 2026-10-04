import ClaudioCore
import Foundation

@MainActor
func runHostNavigationEvidenceSuites() {
    suite("Navigation evidence：旧消息、坏字段、超限字段都保留事件") {
        let process = HostProcessIdentity(pid: 12, startSeconds: 123, startMicroseconds: 0)
        let binding = HostCapabilityCatalog.binding(host: .codex, nativeEvent: "PermissionRequest")!
        let notice = HostEventNotice(
            receiverEpoch: UUID(), surface: .codex, bindingID: binding.id,
            installationID: UUID(), nativeEvent: "PermissionRequest", event: .notification,
            occurredAt: Date(), reason: .permission, processAncestors: [process],
            navigationEvidence: HostNavigationEvidence(
                process: process, terminalProcess: process,
                tty: "/dev/ttys001", itermSessionID: "w0t0p0:ABC-123"))
        let data = try! JSONEncoder().encode(notice)
        expect(data.count < 8192, "正常导航消息仍在8KiB内")
        expect((try? JSONDecoder().decode(HostEventNotice.self, from: data)) == notice, "类型化证据往返")
        var value = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        value.removeValue(forKey: "navigation_evidence")
        let old = try! JSONDecoder().decode(
            HostEventNotice.self,
            from: JSONSerialization.data(withJSONObject: value))
        expect(old.isSemanticallyValid && old.navigationEvidence == nil, "旧wire不要求导航字段")
        for malformed: Any in [
            "invalid", ["process": 12],
            [
                "process": ["pid": 12, "startSeconds": 123, "startMicroseconds": 0],
                "tty": "/tmp/anything",
            ],
            [
                "process": ["pid": 12, "startSeconds": 123, "startMicroseconds": 0],
                "itermSessionID": String(repeating: "a", count: 1024),
            ],
        ] {
            value["navigation_evidence"] = malformed
            let decoded = try! JSONDecoder().decode(
                HostEventNotice.self,
                from: JSONSerialization.data(withJSONObject: value))
            expect(decoded.isSemanticallyValid && decoded.navigationEvidence == nil, "非法可选字段只降级")
        }
        expect(notice.removingProcessAncestors().navigationEvidence == nil, "解析后释放原始证据")
        expect(!HostNavigationEvidence.validToken("x\"; run anything"), "拒绝脚本/命令片段")
        expect(!HostNavigationEvidence.validTTY("/dev/ttys001/../x"), "TTY不接受任意路径")
        expect(
            !TmuxNavigationEvidence(socketPath: "/tmp/x", server: process, paneID: "%1;kill")
                .isValid,
            "tmux只接受稳定paneID")
        expect(
            HostNavigationEvidence.capture(
                ancestors: [process], environment: ["SSH_CONNECTION": "yes"]) == nil,
            "SSH来源不进入本地导航")
    }
}
