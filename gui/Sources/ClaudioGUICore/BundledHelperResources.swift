import Foundation

/// Packaged helper identity. The installed shared runtime keeps its existing claudio path.
public let claudioHelperBinaryName = "claudi0"
public let bundledHelperSubdirectory = "bin"

/// Resolve the CLI in Contents/Resources/bin, never the GUI in Contents/MacOS.
/// A development or damaged bundle without this resource returns nil.
/// ReleaseLayoutSuite guards the matching assembly-script paths.
public func bundledHelperBinary(in bundle: Bundle) -> URL? {
    bundle.url(
        forResource: claudioHelperBinaryName, withExtension: nil,
        subdirectory: bundledHelperSubdirectory)
}
