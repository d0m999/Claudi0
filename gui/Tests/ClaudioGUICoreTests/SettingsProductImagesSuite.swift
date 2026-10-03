import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation
import Foundation

@MainActor
func runSettingsProductImagesSuites() {
    suite("设置产品图标：非对称透明留白不改变主体方向或比例") {
        let source = productImageFixture(width: 13, height: 10) { x, y in
            guard (4..<9).contains(x), (1..<5).contains(y) else { return [0, 0, 0, 0] }
            return y == 1 ? [255, 0, 0, 255] : [0, 255, 0, 255]
        }
        let normalized = SettingsProductImages.normalized(source)
        expect(normalized.size == NSSize(width: 5, height: 4), "归一化只移除透明留白，保留非方形主体比例")
        let bitmap = productImageBitmap(normalized)
        let top = bitmap?.colorAt(x: 0, y: 0)
        let bottom = bitmap?.colorAt(x: 4, y: 3)
        expect(
            top?.redComponent == 1 && top?.alphaComponent == 1
                && bottom?.greenComponent == 1 && bottom?.alphaComponent == 1,
            "主体上下边缘必须完整保留，不得因 CGContext 与 CGImage 坐标差异翻转或错裁")
        expect(source.size == NSSize(width: 13, height: 10), "不得原地修改传入图像尺寸")
    }

    suite("设置产品图标：淡阴影不扩大尺寸，半透明主体边缘仍保留") {
        let source = productImageFixture(width: 11, height: 10) { x, y in
            (3..<8).contains(x) && (2..<7).contains(y)
                ? [255, 255, 255, 128] : [64, 64, 64, 64]
        }
        let normalized = SettingsProductImages.normalized(source)
        expect(normalized.size == NSSize(width: 5, height: 5), "低 alpha 阴影不得成为可见产品主体的外边界")
        let bitmap = productImageBitmap(normalized)
        let corners = [(0, 0), (4, 0), (0, 4), (4, 4)].compactMap {
            bitmap?.colorAt(x: $0.0, y: $0.1)?.alphaComponent
        }
        expect(
            corners.count == 4 && corners.allSatisfy { abs($0 - 128.0 / 255.0) < 0.005 },
            "alpha 128 的四个主体角点必须保留")
        expect(!normalized.isTemplate, "产品图标必须保留原色")
    }

    suite("设置产品图标：全透明输入安全回退") {
        let transparent = productImageFixture(width: 9, height: 7) { _, _ in [0, 0, 0, 0] }
        let normalized = SettingsProductImages.normalized(transparent)
        expect(normalized === transparent, "没有可见主体时返回原图，不得制造空裁剪或越界")
        expect(normalized.size == NSSize(width: 9, height: 7), "透明回退保留原始尺寸")
    }

    var images: [String: NSImage] = [:]
    suite("设置产品图标：四张原始资源按可见主体归一化") {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("gui/Sources/ClaudioGUI/Resources/SettingsHostIcons")
        let expectedDimensions = [
            "claude-light": 256, "codex-light": 824, "codex-dark": 824, "workbuddy-light": 820,
        ]
        for (name, dimension) in expectedDimensions.sorted(by: { $0.key < $1.key }) {
            guard let source = NSImage(contentsOf: resources.appendingPathComponent("\(name).png"))
            else { expect(false, "必须能加载真实设置产品图标 \(name)"); continue }
            let normalized = SettingsProductImages.normalized(source)
            images[name] = normalized
            let bitmap = productImageBitmap(normalized)
            expect(
                normalized.size == NSSize(width: dimension, height: dimension)
                    && bitmap?.pixelsWide == dimension && bitmap?.pixelsHigh == dimension,
                "\(name) 必须去除原始 PNG 留白，可见主体应为 \(dimension)×\(dimension)，实际 \(normalized.size)")
            expect(!normalized.isTemplate, "\(name) 必须保持品牌原色")
        }
        expect(
            images["codex-light"]?.size == images["codex-dark"]?.size,
            "Codex 明暗变体必须占用同样的可见尺寸")
    }

    guard images.count == 4 else { return }
    suite("设置产品图标：真实集成页挂载三款产品的明暗图片") {
        for dark in [false, true] {
            var requested: [HostID: Bool] = [:]
            let provider = SettingsProductImages { host, isDark in
                requested[host] = isDark
                switch host {
                case .claudeCode: return images["claude-light"]
                case .codex: return images[isDark ? "codex-dark" : "codex-light"]
                case .workBuddy: return images["workbuddy-light"]
                default: return nil
                }
            }
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .destination(.integrations), productImages: provider)
            let probe = SettingsSoundsNativeLayoutProbe(
                session: fixture.session, size: NSSize(width: 1_240, height: 820),
                appearance: dark ? .darkAqua : .aqua)
            defer { probe.close() }
            expect(
                HostID.productVisibleCases.allSatisfy { requested[$0] == dark },
                "集成页必须实际请求三款产品的当前外观图片")
            if let directory = ProcessInfo.processInfo.environment[
                "CLAUDIO_PRODUCT_ICON_CAPTURE_DIR"]
            {
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(
                        at: output, withIntermediateDirectories: true)
                } catch {
                    expect(false, "无法创建产品图标截图目录：\(error)")
                    continue
                }
                expect(
                    probe.saveScreenshot(
                        to: output.appendingPathComponent(
                            "integrations-product-icons-\(dark ? "dark" : "light").png")),
                    "集成页真实产品图标必须可保存截图")
            }
        }
    }
}

@MainActor
private func productImageFixture(
    width: Int, height: Int, pixel: (Int, Int) -> [UInt8]
) -> NSImage {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
        bytesPerRow: width * 4, bitsPerPixel: 32)!
    let bytes = bitmap.bitmapData!
    for y in 0..<height {
        for x in 0..<width {
            let rgba = pixel(x, y)
            for channel in 0..<4 { bytes[y * bitmap.bytesPerRow + x * 4 + channel] = rgba[channel] }
        }
    }
    return NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: width, height: height))
}

@MainActor
private func productImageBitmap(_ image: NSImage) -> NSBitmapImageRep? {
    image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(
        NSBitmapImageRep.init(cgImage:))
}
