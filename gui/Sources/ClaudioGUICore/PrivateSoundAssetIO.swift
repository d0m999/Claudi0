import ClaudioCore
import Darwin
import Foundation

/// Errors deliberately contain no description, credentials, provider URL or raw OS error text.
package enum SoundAssetStorageError: Error, Sendable, Equatable {
    case unavailable
    case unsafeEntry
    case corrupt
    case busy
    case changed
    case nameConflict
    case trashFailed
    case recoveryRequired(URL)
}

/// Small descriptor-based filesystem boundary shared by the two private sound asset stores.
/// Each directory component is opened with O_NOFOLLOW. Only Apple's fixed /var, /tmp, /etc
/// aliases are expanded, never user-controlled links. Callers serialize their own transactions.
package enum PrivateSoundAssetIO {
    package static func directory(_ url: URL) throws -> Int32 {
        var parts = url.standardizedFileURL.pathComponents
        guard parts.first == "/" else { throw SoundAssetStorageError.unsafeEntry }
        if parts.count > 1, ["var", "tmp", "etc"].contains(parts[1]) {
            let alias = "/" + parts[1]
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: alias))
                == "private/" + parts[1]
            {
                parts.insert("private", at: 1)
            }
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw SoundAssetStorageError.unavailable }
        for part in parts.dropFirst() {
            let next = part.withCString {
                openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(fd)
            guard next >= 0 else { throw SoundAssetStorageError.unsafeEntry }
            fd = next
        }
        return fd
    }

    package static func exists(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0 || errno != ENOENT
    }

    package static func read(_ url: URL, maximum: Int) throws -> Data {
        let parent = try directory(url.deletingLastPathComponent())
        defer { close(parent) }
        let fd = url.lastPathComponent.withCString {
            openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { throw SoundAssetStorageError.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size >= 0, info.st_size <= maximum
        else { throw SoundAssetStorageError.unsafeEntry }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw SoundAssetStorageError.unavailable }
            if count == 0 { break }
            guard bytes.count + count <= maximum else { throw SoundAssetStorageError.corrupt }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        return bytes
    }

    package static func write(_ data: Data, to url: URL) throws {
        let parent = try directory(url.deletingLastPathComponent())
        defer { close(parent) }
        let temporary = ".write-" + UUID().uuidString.lowercased()
        let fd = temporary.withCString {
            openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { throw SoundAssetStorageError.unavailable }
        defer {
            close(fd)
            _ = temporary.withCString { unlinkat(parent, $0, 0) }
        }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SoundAssetStorageError.unavailable }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw SoundAssetStorageError.unavailable }
        let renamed = temporary.withCString { source in
            url.lastPathComponent.withCString { renameat(parent, source, parent, $0) }
        }
        guard renamed == 0 else { throw SoundAssetStorageError.unavailable }
        _ = fsync(parent)
    }

    package static func moveExclusively(_ source: URL, to destination: URL) throws {
        let from = try directory(source.deletingLastPathComponent())
        defer { close(from) }
        let to = try directory(destination.deletingLastPathComponent())
        defer { close(to) }
        let result = source.lastPathComponent.withCString { name in
            destination.lastPathComponent.withCString {
                renameatx_np(from, name, to, $0, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else { throw SoundAssetStorageError.changed }
        _ = fsync(to)
    }

    package static func entries(_ directoryURL: URL) throws -> [URL] {
        let fd = try directory(directoryURL)
        defer { close(fd) }
        // The descriptor pins the inspected directory while names are enumerated. Each subsequent
        // read reopens every component, so enumeration never grants access through a replaced link.
        guard let stream = fdopendir(dup(fd)) else { throw SoundAssetStorageError.unavailable }
        defer { closedir(stream) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        guard errno == 0 else { throw SoundAssetStorageError.unavailable }
        return names.sorted().map { directoryURL.appendingPathComponent($0) }
    }

    package static func withLock<T>(at url: URL, _ operation: () throws -> T) throws -> T {
        let result = withNonBlockingLock(path: url.path) { Result { try operation() } }
        switch result {
        case .ran(let value): return try value.get()
        case .skipped: throw SoundAssetStorageError.busy
        case .failed: throw SoundAssetStorageError.unavailable
        }
    }

    package static func systemTrash(_ url: URL) throws {
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
    }

    /// Isolate before calling the system adapter; a failed move restores the exact original entry.
    /// Never recursively removes user assets, including when rollback itself fails.
    package static func trash(
        _ source: URL, using adapter: @Sendable (URL) throws -> Void
    ) throws {
        let parent = source.deletingLastPathComponent()
        let parentFD = try directory(parent)
        defer { close(parentFD) }
        var before = stat()
        guard fstatat(parentFD, source.lastPathComponent, &before, AT_SYMLINK_NOFOLLOW) == 0,
            [S_IFREG, S_IFDIR].contains(before.st_mode & S_IFMT)
        else { throw SoundAssetStorageError.unsafeEntry }
        let isolation = parent.appendingPathComponent(".trash-" + UUID().uuidString.lowercased())
        try ensurePrivateDirectoryExists(at: isolation)
        let isolated = isolation.appendingPathComponent(source.lastPathComponent)
        defer { _ = rmdir(isolation.path) }
        try moveExclusively(source, to: isolated)
        do {
            let currentParent = try directory(parent)
            defer { close(currentParent) }
            var pinnedParent = stat()
            var visibleParent = stat()
            guard fstat(parentFD, &pinnedParent) == 0, fstat(currentParent, &visibleParent) == 0,
                pinnedParent.st_dev == visibleParent.st_dev,
                pinnedParent.st_ino == visibleParent.st_ino
            else { throw SoundAssetStorageError.changed }
            var after = stat()
            guard lstat(isolated.path, &after) == 0,
                after.st_dev == before.st_dev, after.st_ino == before.st_ino
            else { throw SoundAssetStorageError.changed }
            try adapter(isolated)
            guard !exists(isolated) else { throw SoundAssetStorageError.trashFailed }
        } catch {
            do { try moveExclusively(isolated, to: source) } catch {
                throw SoundAssetStorageError.recoveryRequired(isolated)
            }
            throw SoundAssetStorageError.trashFailed
        }
    }
}
