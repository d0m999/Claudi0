import AppKit
import UniformTypeIdentifiers

/// Shared picker allow-list. This narrows the chooser UX; the hardened Core import pipeline still
/// validates magic bytes, size, duration, path containment and publication independently.
private let audioOpenPanelContentTypes: [UTType] = [.wav, .mp3, .aiff, .mpeg4Audio]

/// Attached chooser for Sounds authoring. A directory choice is a complete pack preview;
/// audio bytes and directory structure are independently validated before any write.
@MainActor
package func chooseSoundAsset(attachedTo parent: NSWindow, directory: Bool) async -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = directory
    panel.canChooseFiles = !directory
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = directory
    if !directory { panel.allowedContentTypes = audioOpenPanelContentTypes }
    let response = await withCheckedContinuation { continuation in
        panel.beginSheetModal(for: parent.attachedSheet ?? parent) {
            continuation.resume(returning: $0)
        }
    }
    return response == .OK ? panel.url : nil
}

/// The one native audio-file picker used by the panel and the standard Sound Packs window.
@MainActor
public func runAudioOpenPanel(allowsMultipleSelection: Bool) -> [URL] {
    NotificationCenter.default.post(name: .claudioSettingsModalWillBegin, object: nil)
    defer { NotificationCenter.default.post(name: .claudioSettingsModalDidEnd, object: nil) }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = audioOpenPanelContentTypes
    panel.allowsMultipleSelection = allowsMultipleSelection
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    guard panel.runModal() == .OK else { return [] }
    return panel.urls
}

/// Directory-only chooser for a workspace scope; it never accepts audio files.
@MainActor
public func runWorkspaceDirectoryOpenPanel() -> URL? {
    NotificationCenter.default.post(name: .claudioSettingsModalWillBegin, object: nil)
    defer { NotificationCenter.default.post(name: .claudioSettingsModalDidEnd, object: nil) }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK else { return nil }
    return panel.url
}

extension Notification.Name {
    package static let claudioSettingsModalWillBegin = Notification.Name(
        "Claudio.Settings.ModalWillBegin")
    package static let claudioSettingsModalDidEnd = Notification.Name(
        "Claudio.Settings.ModalDidEnd")
}
