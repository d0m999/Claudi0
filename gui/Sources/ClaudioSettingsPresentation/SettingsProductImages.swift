import AppKit
import ClaudioCore
import ClaudioGUICore

/// The executable owns resources; Settings consumes images without a reverse target dependency.
@MainActor
package struct SettingsProductImages {
    package let image: @MainActor (HostID, Bool) -> NSImage?

    package init(image: @escaping @MainActor (HostID, Bool) -> NSImage?) { self.image = image }

    package static var empty: Self { Self { _, _ in nil } }
}
