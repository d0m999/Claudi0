import AppKit
import ClaudioCore
import ClaudioGUICore
import Combine
import Foundation

/// App-lifetime triggers: independent of Settings visibility and notice preference/receiver.
@MainActor
final class HostIntegrationMaintenanceRuntime {
    private let manager: HostIntegrationManager
    private var observations: [NSObjectProtocol] = []
    private var sources: [DispatchSourceFileSystemObject] = []
    private var streamTask: Task<Void, Never>?
    private var timer: Timer?
    private var triggerTask: Task<Void, Never>?
    private var isStopped = false
    private var fileTask: Task<Void, Never>?
    private var previousFileFacts: [HostID: [String]] = [:]

    init(
        manager: HostIntegrationManager, bridge: HostIntegrationManagerBridge,
        receive: @escaping @MainActor (HostIntegrationPresentationState) -> Void
    ) {
        self.manager = manager
        streamTask = Task {
            for await state in await bridge.presentationStream() {
                guard !Task.isCancelled else { return }
                receive(state)
            }
        }
        for name in [
            NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            observations.append(
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in Task { @MainActor in self?.request(.wake) } })
        }
        observations.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.request(.activation) } })
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.watchFiles(); self?.request(.discoveryFallback)
            }
        }
        watchFiles()
    }

    private func request(_ trigger: HostMaintenanceTrigger) {
        guard !isStopped else { return }
        triggerTask?.cancel()
        triggerTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            _ = await manager.startAutomaticMaintenance(trigger: trigger)
            guard !Task.isCancelled, !isStopped else { return }
            await manager.requestMaintenance(trigger: trigger)
        }
    }

    private func watchFiles() {
        for source in sources { source.cancel() }
        sources.removeAll()
        let candidates =
            [
                ClaudioPaths.configFile, ClaudioPaths.claudeSettingsFile,
                ClaudioPaths.codexHooksFile, ClaudioPaths.codexConfigFile,
                ClaudioPaths.workBuddySettingsFile, ClaudioPaths.claudioBinary,
                ClaudioPaths.activeInstallationsDirectory,
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                    "Applications", isDirectory: true),
            ]
            + HostExecutableLocator.standard().searchDirectories
        var paths = Set<String>()
        for candidate in candidates {
            var directory =
                candidate.hasDirectoryPath ? candidate : candidate.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
                directory.deleteLastPathComponent()
            }
            guard paths.insert(directory.path).inserted else { continue }
            let fd = open(directory.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.checkRelevantFiles() }
            }
            source.setCancelHandler { close(fd) }
            sources.append(source)
            source.resume()
        }
        checkRelevantFiles()
    }

    private func checkRelevantFiles() {
        guard !isStopped else { return }
        fileTask?.cancel()
        fileTask = Task { [weak self] in
            let facts = await Task.detached(priority: .utility) {
                HostMaintenanceFileFacts.capture()
            }
            .value
            guard let self, !Task.isCancelled, !isStopped else { return }
            let changed = facts.keys.filter { facts[$0] != previousFileFacts[$0] }
            previousFileFacts = facts
            guard !changed.isEmpty else { return }
            _ = await manager.startAutomaticMaintenance(trigger: .fileChanged)
            guard !Task.isCancelled, !isStopped else { return }
            for host in changed {
                await manager.requestMaintenance(trigger: .fileChanged, surface: host.surfaceID)
            }
        }
    }

    func stop() {
        isStopped = true
        triggerTask?.cancel()
        fileTask?.cancel()
        streamTask?.cancel()
        timer?.invalidate()
        for source in sources { source.cancel() }
        sources.removeAll()
        for observer in observations {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observations.removeAll()
        // Synchronous revocation before the GUI begins terminating. A failed unlink still fails
        // closed after process death; no hook survives the kernel identity check.
        let registry = HostGUIRunRegistry()
        if let run = registry.current(), run.process.pid == getpid() {
            _ = registry.revoke(runID: run.runID)
        }
        Task { await manager.stopAutomaticMaintenance() }
    }
}
