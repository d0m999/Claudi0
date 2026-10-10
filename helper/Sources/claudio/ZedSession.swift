import ArgumentParser
import ClaudioCore
import Foundation

#if DEBUG
extension Claudio {
    struct ZedSession: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "zed-session", abstract: "实验：通过受管理 PTY 启动新的 Zed CLI 会话。")
        @Argument(parsing: .remaining, help: "-- 后的 CLI 及参数，不经过 shell 解释")
        var command: [String] = []

        func run() throws {
            guard !command.isEmpty else { throw ValidationError("需要 -- <command> [arguments]") }
            let code: Int32
            do {
                code = try ZedPTYSession.run(
                    command: command,
                    descriptor: ClaudioPaths.root.appendingPathComponent("zed-navigation.json"))
            } catch {
                throw ValidationError("受管理会话未能建立（TTY、焦点协议或进程不可用）。")
            }
            if code != 0 { throw ExitCode(code) }
        }
    }
}
#endif
