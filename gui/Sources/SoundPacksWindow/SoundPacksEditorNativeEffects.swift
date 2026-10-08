import AppKit
import ClaudioGUIComponents
import ClaudioGUICore
import Combine
import Foundation
import UniformTypeIdentifiers

/// The native seam for semantic effects already validated by `SoundPacksEditorOwner`.
/// Implementations execute the supplied values verbatim; target derivation remains in the owner.
@MainActor
package protocol SoundPacksEditorNativeEffectsAdapter: AnyObject {
    var previewDuration: TimeInterval? { get }
    func selectAudioFiles(allowsMultipleSelection: Bool) -> [URL]
    func playAudio(fileURL: URL, volume: Double) -> TimeInterval?
    func playAudio(
        fileURL: URL, volume: Double,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Bool
    func stopAudio()
    func revealInFinder(fileURL: URL)
}

extension SoundPacksEditorNativeEffectsAdapter {
    package var previewDuration: TimeInterval? { nil }

}

/// Native lifecycle signals whose reliability differs between retained AppKit windows and their
/// transient SwiftUI destinations.
package enum SoundPacksEditorNativeLifecycleEvent: Sendable {
    case settingsWindowWillClose
    case soundsViewDisappeared
    case eventsViewDisappeared
}

/// Exhaustively translates the Foundation-only owner effect into one native side effect. Picker
/// selections become the only async domain operation the view needs to feed back to the owner.
@MainActor
package final class SoundPacksEditorNativeEffectsDispatcher: ObservableObject {
    package let previewSession: ManualAudioPreviewSession
    package let previewOrigin = ManualPreviewOrigin(.settings)
    package var playingSoundID: String? { previewSession.playing?.target }
    package var previewFailed: Bool { previewSession.failedOrigin?.category == .settings }
    private let compatibilityPlayer: NativeEffectsPreviewPlayer
    private var previewObservation: AnyCancellable?
    private let adapter: any SoundPacksEditorNativeEffectsAdapter
    private var operationTasks: [UUID: Task<Void, Never>] = [:]

    package init(
        adapter: any SoundPacksEditorNativeEffectsAdapter,
        previewSession: ManualAudioPreviewSession? = nil
    ) {
        self.adapter = adapter
        let player = NativeEffectsPreviewPlayer(adapter: adapter)
        compatibilityPlayer = player
        self.previewSession = previewSession ?? ManualAudioPreviewSession(player: player)
        previewObservation = self.previewSession.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    package func toggleSoundPreview(
        id: String, fileURL: URL, origin: ManualPreviewOrigin? = nil
    ) {
        guard let token = previewSession.prepare(origin: origin ?? previewOrigin, target: id) else {
            return
        }
        _ = previewSession.start(token, fileURL: fileURL, volume: 1)
    }

    package func toggleSoundPreview(
        id: String, action: SoundPackEditorAction, owner: SoundPacksEditorOwner,
        origin: ManualPreviewOrigin? = nil
    ) {
        guard let token = previewSession.prepare(origin: origin ?? previewOrigin, target: id) else {
            return
        }
        guard case .nativeEffect(.playAudio(let url, _)) = owner.send(.invoke(action)) else {
            previewSession.fail(token)
            return
        }
        _ = previewSession.start(token, fileURL: url, volume: 1)
    }

    package func dispatch(
        _ effect: SoundPackEditorNativeEffect
    ) -> SoundPacksEditorOperation? {
        switch effect {
        case .selectAudioFiles(let permit, let bindTo):
            let sources = adapter.selectAudioFiles(
                allowsMultipleSelection: bindTo == nil)
            return .importAudio(permit: permit, sources: sources, bindTo: bindTo)
        case .playAudio(let fileURL, let volume):
            _ = playAudio(fileURL: fileURL, volume: volume)
            return nil
        case .stopAudio:
            stopActiveAudio()
            return nil
        case .reveal(let fileURL):
            adapter.revealInFinder(fileURL: fileURL)
            return nil
        }
    }

    /// Resolves one opaque action through the owner and executes only an exact audio effect. The
    /// caller receives playback duration for sequencing but never gains filesystem identity.
    package func playPreview(
        _ action: SoundPackEditorAction,
        owner: SoundPacksEditorOwner
    ) -> TimeInterval? {
        guard
            case .nativeEffect(.playAudio(let fileURL, let volume)) =
                owner.send(.invoke(action))
        else { return nil }
        return playAudio(fileURL: fileURL, volume: volume)
    }

    /// AI candidates are validated temporary assets, not Sound Pack mappings. They still execute
    /// through the retained native adapter so Events audio has exactly one playback owner.
    package func playAICueCandidate(
        _ candidate: AICueCandidate,
        volume: Double
    ) -> TimeInterval? {
        playAudio(fileURL: candidate.asset.fileURL, volume: volume)
    }

    /// Stops whichever Event or AI preview the retained adapter currently owns. Resolving the
    /// stop action directly from the owner avoids route-filtered view getters and never retires a
    /// newly activated context.
    package func stopPreview(owner: SoundPacksEditorOwner, origin: ManualPreviewOrigin? = nil) {
        previewSession.stop(origin: origin ?? previewOrigin)
    }

    /// Consumes only the instantaneous native-effect branch. Async owner operations are retained
    /// here so SwiftUI callers never own mutation Tasks or duplicate busy state.
    package func consume(
        _ result: SoundPacksEditorCommandResult,
        owner: SoundPacksEditorOwner
    ) {
        guard case .nativeEffect(let effect) = result,
            let operation = dispatch(effect)
        else { return }
        perform(operation, owner: owner)
    }

    /// Stops preview through the owner's single-use capability before retiring the relevant
    /// editor context. A late Sounds disappearance must not retire an Events context that has
    /// already taken over the shared owner; closing the retained Settings window retires either.
    package func handleLifecycle(
        _ event: SoundPacksEditorNativeLifecycleEvent,
        owner: SoundPacksEditorOwner
    ) {
        switch event {
        case .soundsViewDisappeared:
            guard case .sounds = owner.presentation.mode else { return }
            stopPreview(owner: owner)
            _ = owner.send(.activate(.inactive))
        case .eventsViewDisappeared:
            guard case .events = owner.presentation.mode else { return }
            stopPreview(owner: owner)
            _ = owner.send(.activate(.inactive))
        case .settingsWindowWillClose:
            stopPreview(owner: owner)
            if owner.presentation.mode != .inactive {
                _ = owner.send(.activate(.inactive))
            }
        }
    }

    private func playAudio(fileURL: URL, volume: Double) -> TimeInterval? {
        guard
            let token = previewSession.prepare(
                origin: previewOrigin, target: "effect.\(UUID().uuidString)"),
            previewSession.start(token, fileURL: fileURL, volume: volume)
        else { return nil }
        return compatibilityPlayer.duration ?? 3
    }

    private func stopActiveAudio() { previewSession.stop(origin: previewOrigin) }

    /// Captures the owner-signed Event permit before the item-provider suspension. A provider
    /// cancellation performs the empty operation exactly once, returning typed `cancelled`,
    /// consuming that permit, and re-signing only the replacement capability.
    package func consumeDrop(
        _ providers: [NSItemProvider],
        action: SoundPackEditorAction,
        owner: SoundPacksEditorOwner
    ) {
        guard case .importPermit(let permit, let bindTo) = owner.send(.prepareDrop(action))
        else { return }
        let provider = providers.first {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        let operationID = UUID()
        let task = Task { @MainActor in
            let source: URL?
            if let provider {
                source = await loadSoundPacksDropURL(from: provider)
            } else {
                source = nil
            }
            let result = await owner.perform(
                .importAudio(
                    permit: permit,
                    sources: source.map { [$0] } ?? [],
                    bindTo: bindTo))
            consumeFollowUp(from: result, owner: owner)
            self.operationTasks.removeValue(forKey: operationID)
        }
        operationTasks[operationID] = task
    }

    private func perform(
        _ operation: SoundPacksEditorOperation,
        owner: SoundPacksEditorOwner
    ) {
        let operationID = UUID()
        let task = Task { @MainActor in
            let result = await owner.perform(operation)
            consumeFollowUp(from: result, owner: owner)
            self.operationTasks.removeValue(forKey: operationID)
        }
        operationTasks[operationID] = task
    }

    private func consumeFollowUp(
        from result: SoundPacksEditorOperationResult,
        owner: SoundPacksEditorOwner
    ) {
        if case .sounds = owner.presentation.mode { return }
        let action: SoundPackEditorAction?
        switch result {
        case .imported(let outcome):
            action = outcome.previewAction
        case .adopted(let outcome):
            action = outcome.previewAction
        case .adoptionOrphan, .rejected:
            action = nil
        }
        guard let action else { return }
        consume(owner.send(.invoke(action)), owner: owner)
    }

    #if DEBUG
    package func waitForOperationsToFinishForTesting() async {
        while !operationTasks.isEmpty {
            let tasks = Array(operationTasks.values)
            for task in tasks { await task.value }
        }
    }
    #endif
}

/// Production AppKit adapter. `NSSoundAudioPreviewPlayer` retains one active sound and stops it
/// before replacing it, while picker and Finder calls stay on the MainActor.
@MainActor
package final class SystemSoundPacksEditorNativeEffectsAdapter:
    SoundPacksEditorNativeEffectsAdapter
{
    package init() {}

    package func selectAudioFiles(allowsMultipleSelection: Bool) -> [URL] {
        runAudioOpenPanel(allowsMultipleSelection: allowsMultipleSelection)
    }
    package func playAudio(fileURL: URL, volume: Double) -> TimeInterval? { nil }
    package func playAudio(
        fileURL: URL, volume: Double,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Bool { false }
    package func stopAudio() {}

    package func revealInFinder(fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}

/// Only isolated legacy fixtures use this adapter-backed session. Production injects the shared
/// app session and the native adapter above owns picker/Finder effects only.
@MainActor
private final class NativeEffectsPreviewPlayer: AudioPreviewPlaying {
    let adapter: any SoundPacksEditorNativeEffectsAdapter
    var duration: TimeInterval?
    init(adapter: any SoundPacksEditorNativeEffectsAdapter) { self.adapter = adapter }
    func play(fileAt url: URL, volume: Float) -> Bool {
        duration = adapter.playAudio(fileURL: url, volume: Double(volume))
        return duration != nil
    }
    func play(
        fileAt url: URL, volume: Float,
        onCompletion: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Bool {
        // Isolated fixture adapters expose their measured duration separately.
        duration = adapter.previewDuration
        return adapter.playAudio(fileURL: url, volume: Double(volume), completion: onCompletion)
    }
    func stop() { adapter.stopAudio() }
}
