import Foundation

package struct SettingsReadingBookmark: Equatable, Sendable {
    package var focusIdentifier: String?
    package var scrollAnchorIdentifier: String?
    /// Offset from the semantic anchor; a normalized fallback survives content resizing.
    package var anchorOffset: Double
    package var relativeScrollPosition: Double

    package init(
        focusIdentifier: String? = nil, scrollAnchorIdentifier: String? = nil,
        anchorOffset: Double = 0, relativeScrollPosition: Double = 0
    ) {
        self.focusIdentifier = focusIdentifier
        self.scrollAnchorIdentifier = scrollAnchorIdentifier
        self.anchorOffset = anchorOffset.isFinite ? anchorOffset : 0
        self.relativeScrollPosition =
            relativeScrollPosition.isFinite
            ? min(1, max(0, relativeScrollPosition)) : 0
    }
}

package struct SettingsNavigationStamp: Equatable, Sendable {
    package let entryID: UUID
    package let version: UInt64
    package init(entryID: UUID, version: UInt64) { self.entryID = entryID; self.version = version }
}

package struct SettingsNavigationEntry: Equatable, Sendable, Identifiable {
    package let id: UUID
    package var location: SettingsLocation
    package var bookmark: SettingsReadingBookmark
}

/// The retained presentation session owns this value for one window-open lifetime.
package struct SettingsNavigationHistory: Equatable, Sendable {
    package init() {}
    package static let capacity = 64
    package private(set) var entries: [SettingsNavigationEntry] = []
    package private(set) var cursor: Int = -1
    package private(set) var version: UInt64 = 0

    package var current: SettingsNavigationEntry? {
        entries.indices.contains(cursor) ? entries[cursor] : nil
    }
    package var canGoBack: Bool { cursor > 0 }
    package var canGoForward: Bool { cursor >= 0 && cursor + 1 < entries.count }
    package var stamp: SettingsNavigationStamp? {
        current.map { SettingsNavigationStamp(entryID: $0.id, version: version) }
    }

    /// Repeating an entry refreshes its request version without destroying Forward.
    @discardableResult
    package mutating func visit(_ location: SettingsLocation) -> Bool {
        version &+= 1
        guard current?.location != location else {
            entries[cursor].location = location
            return false
        }
        entries = Array(entries.prefix(cursor + 1))
        entries.append(
            SettingsNavigationEntry(
                id: UUID(), location: location, bookmark: SettingsReadingBookmark()))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        cursor = entries.count - 1
        return true
    }

    @discardableResult
    package mutating func move(by delta: Int) -> SettingsNavigationEntry? {
        guard delta == -1 || delta == 1, entries.indices.contains(cursor + delta) else {
            return nil
        }
        cursor += delta
        version &+= 1
        return current
    }

    package mutating func updateBookmark(
        _ bookmark: SettingsReadingBookmark, stamp: SettingsNavigationStamp
    ) {
        guard self.stamp == stamp else { return }
        entries[cursor].bookmark = bookmark
    }

    /// Refresh, hydration, or an accepted operation updates an entry without creating a visit.
    @discardableResult
    package mutating func replaceCurrent(
        _ location: SettingsLocation, matching stamp: SettingsNavigationStamp? = nil
    ) -> Bool {
        guard current != nil, stamp == nil || self.stamp == stamp else { return false }
        entries[cursor].location = location
        return true
    }

    package mutating func clear() {
        entries.removeAll()
        cursor = -1
        version &+= 1
    }
}
