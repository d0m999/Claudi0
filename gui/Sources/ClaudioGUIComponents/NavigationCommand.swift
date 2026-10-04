import Foundation

/// Only callers inside the host adapters supply fixed executable paths and arguments. No shell.
/// Output, lifetime and cancellation are bounded; pipe draining never blocks MainActor.
package enum NavigationCommand {
    package static func run(_ executable: String, _ arguments: [String], deadline: TimeInterval)
        async -> String?
    {
        let state = CommandState()
        return await withTaskCancellationHandler {
            await Task.detached {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard state.start(process, deadline: deadline) else { return nil }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { state.cancel(); return nil }
                DispatchQueue.global().asyncAfter(deadline: .now() + remaining) { state.cancel() }
                var data = Data()
                while let chunk = try? pipe.fileHandleForReading.read(upToCount: 1024),
                    !chunk.isEmpty
                {
                    data.append(chunk)
                    if data.count > 8192 { state.cancel(); break }
                }
                process.waitUntilExit()
                guard !state.isCancelled, process.terminationStatus == 0, data.count <= 8192,
                    ProcessInfo.processInfo.systemUptime < deadline
                else { return nil }
                return String(data: data, encoding: .utf8)?.trimmingCharacters(
                    in: .whitespacesAndNewlines)
            }.value
        } onCancel: {
            state.cancel()
        }
    }
}

package final class CommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    package func start(_ value: Process, deadline: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, ProcessInfo.processInfo.systemUptime < deadline else { return false }
        do { try value.run(); process = value; return true } catch { return false }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}
