import ClaudioGUICore
import Combine
import CryptoKit
import Foundation
import ImageIO

/// Immutable decoded frames cross from the resource actor to the main-actor presentation.
public struct EventAnimationFrames: @unchecked Sendable {
    public let manifest: EventAnimationManifest
    private let images: [CGImage]

    public func image(action: String, frame: Int) -> CGImage? {
        guard let animation = manifest.animations[action], (0..<animation.frames).contains(frame)
        else { return nil }
        return images[animation.row * manifest.columns + frame]
    }

    fileprivate init(manifest: EventAnimationManifest, images: [CGImage]) {
        self.manifest = manifest
        self.images = images
    }
}

private struct AnimationProvenance: Decodable {
    struct Style: Decodable {
        let variant: String
        let timing: String
        let atlases: [String: String]
    }
    let schema: Int
    let sourceSHA256: String
    let styles: [String: Style]
    let files: [String: String]
}

/// Resource ownership stays in the executable. This actor only reads the injected directory.
private actor EventAnimationResourceLoader {
    let directory: URL?

    init(directory: URL?) { self.directory = directory }

    func load(style: EventAnimationStyle, dark: Bool) throws -> EventAnimationFrames {
        guard let directory else { throw EventAnimationResourceFailure.unavailable }
        do {
            let provenanceData = try Data(
                contentsOf: directory.appendingPathComponent("provenance.json"))
            guard provenanceData.count <= 65_536 else {
                throw EventAnimationResourceFailure.invalidManifest
            }
            let provenance = try JSONDecoder().decode(
                AnimationProvenance.self, from: provenanceData)
            guard provenance.schema == 1, provenance.sourceSHA256.count == 64,
                provenance.sourceSHA256.allSatisfy({ $0.isHexDigit }),
                let entry = provenance.styles[style.rawValue],
                let atlas = entry.atlases[dark ? "dark" : "light"],
                ["E", "G", "H"].contains(entry.variant),
                entry.timing == "\(entry.variant)/timing.json",
                ["\(entry.variant)/sprites.png", "\(entry.variant)/sprites-dark.png"].contains(
                    atlas)
            else { throw EventAnimationResourceFailure.invalidManifest }
            func checkedData(_ path: String) throws -> Data {
                let data = try Data(contentsOf: directory.appendingPathComponent(path))
                guard data.count <= 1_048_576 else {
                    throw EventAnimationResourceFailure.invalidManifest
                }
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard hash == provenance.files[path] else {
                    throw EventAnimationResourceFailure.checksumMismatch
                }
                return data
            }
            let manifest = try JSONDecoder().decode(
                EventAnimationManifest.self, from: checkedData(entry.timing))
            try manifest.validate()
            let data = try checkedData(atlas)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let sheet = CGImageSourceCreateImageAtIndex(
                    source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                sheet.width == manifest.frameWidth * manifest.columns,
                sheet.height == manifest.frameHeight * manifest.rows
            else { throw EventAnimationResourceFailure.invalidAtlas }
            var frames: [CGImage] = []
            for row in 0..<manifest.rows {
                for column in 0..<manifest.columns {
                    guard
                        let image = sheet.cropping(
                            to: CGRect(
                                x: column * manifest.frameWidth, y: row * manifest.frameHeight,
                                width: manifest.frameWidth, height: manifest.frameHeight))
                    else { throw EventAnimationResourceFailure.invalidAtlas }
                    frames.append(image)
                }
            }
            return EventAnimationFrames(manifest: manifest, images: frames)
        } catch let failure as EventAnimationResourceFailure {
            throw failure
        } catch is DecodingError {
            throw EventAnimationResourceFailure.invalidManifest
        } catch {
            throw EventAnimationResourceFailure.unavailable
        }
    }
}

@MainActor
public final class EventAnimationResources: ObservableObject {
    private struct Key: Hashable { let style: EventAnimationStyle; let dark: Bool }
    private let loader: EventAnimationResourceLoader
    private var frames: [Key: EventAnimationFrames] = [:]
    private var failures: [Key: EventAnimationResourceFailure] = [:]
    private var requests: [Key: UUID] = [:]
    @Published public private(set) var revision: UInt64 = 0

    public init(directory: URL? = nil) {
        loader = EventAnimationResourceLoader(directory: directory)
    }

    // Only the duck varies with appearance. The complete cache is bounded to four atlases,
    // each 64*64*16*7*4 bytes, with no disk access during playback.
    private func key(_ style: EventAnimationStyle, _ dark: Bool) -> Key {
        Key(style: style, dark: style == .mechanicalDuck && dark)
    }

    public func loaded(_ style: EventAnimationStyle, dark: Bool) -> EventAnimationFrames? {
        frames[key(style, dark)]
    }

    public func effectiveStyle(
        for preferences: EventAnimationPreferences, dark: Bool
    ) -> EventAnimationStyle {
        let selected = preferences.effectiveStyle
        return selected == .original || loaded(selected, dark: dark) == nil ? .original : selected
    }

    public func failure(_ style: EventAnimationStyle, dark: Bool) -> EventAnimationResourceFailure?
    {
        failures[key(style, dark)]
    }

    public func load(_ style: EventAnimationStyle, dark: Bool, retry: Bool = false) async {
        guard style != .original else { return }
        let key = key(style, dark)
        guard retry || (frames[key] == nil && failures[key] == nil && requests[key] == nil) else {
            return
        }
        let request = UUID()
        requests[key] = request
        failures[key] = nil
        if retry { frames[key] = nil; revision &+= 1 }
        do {
            let decoded = try await loader.load(style: style, dark: key.dark)
            guard requests[key] == request else { return }
            frames[key] = decoded
        } catch {
            guard requests[key] == request else { return }
            failures[key] = (error as? EventAnimationResourceFailure) ?? .unavailable
        }
        requests[key] = nil
        revision &+= 1
    }
}
