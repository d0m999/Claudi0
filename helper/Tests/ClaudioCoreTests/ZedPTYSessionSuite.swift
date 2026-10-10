import ClaudioCore
import Foundation

@MainActor
func runZedPTYSessionSuites() {
    suite("Zed PTY：真实双层 PTY 的字节、尺寸、信号与退出恢复") {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("zed_pty_fixture.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, CommandLine.arguments[0]]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { expect(false, "真实 PTY fixture 不能启动"); return }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n")
        expect(
            process.terminationStatus == 0,
            "PTY fixture: \(String(decoding: output, as: UTF8.self))")
        for line in lines {
            guard let data = String(line).data(using: .utf8),
                let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let name = result["case"] as? String, let passed = result["passed"] as? Bool
            else { expect(false, "fixture 应只返回脱敏检查结果"); continue }
            expect(passed, "真实 PTY：\(name)")
        }
        expect(lines.count == 12, "运行全部 12 个真实 PTY 场景")
    }
}
