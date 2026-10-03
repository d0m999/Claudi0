import AppKit
import ClaudioCore
import ClaudioGUICore

/// The executable owns resources; Settings consumes images without a reverse target dependency.
@MainActor
package struct SettingsProductImages {
    package let image: @MainActor (HostID, Bool) -> NSImage?

    package init(image: @escaping @MainActor (HostID, Bool) -> NSImage?) { self.image = image }

    package static var empty: Self { Self { _, _ in nil } }

    /// Trim the product tile's transparent padding once at resource load, before view scaling.
    /// Half opacity excludes faint outer shadows so light and dark variants share a footprint.
    package static func normalized(_ image: NSImage) -> NSImage {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let width = source.width
        let height = source.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bounds: CGRect? = pixels.withUnsafeMutableBytes { bytes in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            var minX = width
            var minY = height
            var maxX = -1
            var maxY = -1
            for y in 0..<height {
                for x in 0..<width where bytes[y * bytesPerRow + x * 4 + 3] >= 128 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return CGRect(
                x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        guard let bounds, let cropped = source.cropping(to: bounds) else { return image }
        let normalized = NSImage(
            cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        normalized.isTemplate = false
        return normalized
    }
}
