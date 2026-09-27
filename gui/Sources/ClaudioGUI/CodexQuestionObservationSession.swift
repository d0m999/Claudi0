#if DEBUG
import ClaudioCore
import ClaudioGUICore
import Foundation

/// The GUI's single development observer. File reads and audio preparation stay off MainActor;
/// the reader and timer are confined to one queue. A synchronously revoked run token guards
/// queued delivery and the final player launch across privacy/lifecycle changes.
final class CodexQuestionObservationSession: @unchecked Sendable {
    let runID = UUID()
    private let target: CodexRolloutObservationTarget
    private let queue = DispatchQueue(label: "claudio.codex-question-observation", qos: .utility)
    private let authorization = ObservationAuthorization()
    private var reader: CodexRolloutObservationReader?
    private var timer: DispatchSourceTimer?
    private let receive: @MainActor @Sendable (CodexQuestionObservation) -> EventNoticeAcceptance

    init(
        target: CodexRolloutObservationTarget,
        receive: @escaping @MainActor @Sendable (CodexQuestionObservation) -> EventNoticeAcceptance
    ) {
        self.target = target
        self.receive = receive
    }

    func start() {
        queue.async { [self] in
            guard authorization.isActive, reader == nil else { return }
            do {
                reader = try CodexRolloutObservationReader(target: target, runID: runID)
                Self.report("reader_started")
            } catch let failure as CodexQuestionObservationFailure {
                Self.report("reader_\(failure.rawValue)")
                authorization.revoke()
                return
            } catch {
                Self.report("reader_unavailable")
                authorization.revoke()
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now(), repeating: .milliseconds(200), leeway: .milliseconds(25))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        authorization.revoke()
        queue.async { [self] in retire() }
    }

    private func retire() {
        authorization.revoke()
        timer?.setEventHandler(handler: nil)
        timer?.cancel()
        timer = nil
        reader?.stop()
        reader = nil
    }

    private func poll() {
        guard authorization.isActive, let reader else { retire(); return }
        switch reader.poll() {
        case .failure(let failure):
            Self.report("reader_\(failure.rawValue)")
            retire()
        case .success(let observations):
            guard !observations.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, authorization.isActive else { return }
                for observation in observations {
                    guard authorization.isActive else { return }
                    let result = receive(observation)
                    Self.report("model_\(String(describing: result))")
                    // An occupied transient slot only limits presentation; a valid new request
                    // still gets its one sound attempt. Neither outcome can create Attention.
                    guard result == .accepted || result == .droppedCapacity else { continue }
                    queue.async { [authorization] in
                        guard authorization.isActive else { return }
                        let outcome = playConsumedQuestion(
                            environment: PlayEnvironment(
                                surfaceID: .codex, workingDirectory: nil,
                                playbackAuthorized: { authorization.isActive },
                                spawner: DevelopmentQuestionSoundSpawner(),
                                spawnResultObserver: { started in
                                    Self.report(started ? "player_started" : "player_failed")
                                }))
                        switch outcome {
                        case .played: break  // The spawn observer records the actual launch result.
                        case .disabled: Self.report("sound_disabled")
                        case .dynamicQuiet: Self.report("sound_quiet")
                        default: Self.report("sound_unavailable")
                        }
                    }
                }
            }
        }
    }

    /// Fixed development diagnostics only. Never include identities, paths, arguments or raw
    /// records, and never send these observations to the hook receipt/activity stores.
    fileprivate static func report(_ code: String) {
        FileHandle.standardError.write(Data("claudio.codex-question-observer \(code)\n".utf8))
    }
}

/// The development run records whether afplay actually exits successfully. Production playback
/// remains fire-and-forget; neither arguments nor the selected audio path enter diagnostics.
private struct DevelopmentQuestionSoundSpawner: ProcessSpawning {
    func spawn(executablePath: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { completed in
            let code =
                completed.terminationReason == .exit && completed.terminationStatus == 0
                ? "player_exited_successfully" : "player_exited_with_error"
            CodexQuestionObservationSession.report(code)
        }
        return (try? process.run()) != nil
    }
}

private final class ObservationAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func revoke() {
        lock.lock()
        active = false
        lock.unlock()
    }
}
#endif
