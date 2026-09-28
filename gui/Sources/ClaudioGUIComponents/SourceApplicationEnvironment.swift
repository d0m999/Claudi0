import AppKit
import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
public struct SourceApplicationEnvironment {
    public var userID: UInt32
    public var ownPID: Int32
    public var process: (Int32) -> HostProcessSnapshot?
    public var processExists: (Int32) -> Bool
    public var application: (Int32) -> SourceApplicationDescriptor?
    public var locationMatches: (SourceApplicationTarget) -> Bool
    public var activate: (Int32) -> Bool
    public var frontmost: () -> Int32?
    public var reopenInactive:
        (URL, @escaping @MainActor (SourceApplicationDescriptor?) -> Void) -> Void

    public init(
        userID: UInt32, ownPID: Int32,
        process: @escaping (Int32) -> HostProcessSnapshot?,
        processExists: @escaping (Int32) -> Bool = { _ in false },
        application: @escaping (Int32) -> SourceApplicationDescriptor?,
        locationMatches: @escaping (SourceApplicationTarget) -> Bool,
        activate: @escaping (Int32) -> Bool, frontmost: @escaping () -> Int32?,
        reopenInactive:
            @escaping (URL, @escaping @MainActor (SourceApplicationDescriptor?) -> Void) -> Void
    ) {
        self.userID = userID; self.ownPID = ownPID; self.process = process
        self.processExists = processExists
        self.application = application; self.locationMatches = locationMatches
        self.activate = activate; self.frontmost = frontmost; self.reopenInactive = reopenInactive
    }

    public static var live: Self {
        Self(
            userID: getuid(), ownPID: ProcessInfo.processInfo.processIdentifier,
            process: HostProcessAncestry.read,
            processExists: { kill($0, 0) == 0 || errno == EPERM },
            application: { pid in NSRunningApplication(processIdentifier: pid).flatMap(describe) },
            locationMatches: { target in
                // Fresh plist read avoids Bundle's cached identity after an app is replaced.
                let url = target.applicationURL
                guard url.isFileURL, url == url.standardizedFileURL.resolvingSymlinksInPath(),
                    let data = try? Data(
                        contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                    data.count <= 1_048_576,
                    let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                        as? [String: Any]
                else { return false }
                return plist["CFBundleIdentifier"] as? String == target.bundleIdentifier
                    && plist["CFBundlePackageType"] as? String == "APPL"
            },
            activate: { pid in
                NSRunningApplication(processIdentifier: pid)?.activate(
                    options: [.activateAllWindows, .activateIgnoringOtherApps]) == true
            },
            frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            reopenInactive: { url, complete in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) {
                    app, error in
                    Task { @MainActor in complete(error == nil ? app.flatMap(describe) : nil) }
                }
            })
    }

    private static func describe(_ app: NSRunningApplication) -> SourceApplicationDescriptor? {
        guard !app.isTerminated, app.activationPolicy == .regular,
            let bundleID = app.bundleIdentifier, !bundleID.isEmpty,
            let url = app.bundleURL, url.isFileURL,
            let name = app.localizedName, !name.isEmpty, name.unicodeScalars.count <= 128,
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return SourceApplicationDescriptor(
            pid: app.processIdentifier, bundleIdentifier: bundleID,
            url: url.standardizedFileURL.resolvingSymlinksInPath(), name: name)
    }
}
