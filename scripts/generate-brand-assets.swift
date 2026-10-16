#!/usr/bin/env swift

import AppKit
import Foundation

// 从 claudi0-basic-kit v1.0 的官方 App 图标素材派生仓库内运行资产：
// 1024px 母版 PNG 与 `claudi0.icns`（finder / Dock 使用同一图形）。
// 品牌包是唯一几何来源；本脚本只做缩放与容器封装，不重绘、不改色、不加效果。

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let outputDirectory = repositoryRoot.appendingPathComponent("assets/branding", isDirectory: true)
private let sourceIcon = outputDirectory
    .appendingPathComponent("claudi0-basic-kit", isDirectory: true)
    .appendingPathComponent("02-icons", isDirectory: true)
    .appendingPathComponent("app-icon-1024.png")
private let fileManager = FileManager.default

private let canvasSize = 1024

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    exit(1)
}

guard let sourceData = try? Data(contentsOf: sourceIcon),
    let sourceRep = NSBitmapImageRep(data: sourceData),
    let sourceImage = sourceRep.cgImage
else {
    fail("读不到品牌包 App 图标素材：assets/branding/claudi0-basic-kit/02-icons/app-icon-1024.png")
}

guard sourceRep.pixelsWide == canvasSize, sourceRep.pixelsHigh == canvasSize else {
    fail(
        "品牌包 App 图标素材必须是 \(canvasSize)×\(canvasSize)，实得 "
            + "\(sourceRep.pixelsWide)×\(sourceRep.pixelsHigh)")
}

private func downscaledPNG(to size: Int) -> Data? {
    guard
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let scaled = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: scaled)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// 1024px 母版与品牌包素材同字节，作为预览与商店素材来源。
let masterPNG = outputDirectory.appendingPathComponent("claudi0-app-icon.png")
try? fileManager.removeItem(at: masterPNG)
do {
    try sourceData.write(to: masterPNG, options: .atomic)
} catch {
    fail("写入 claudi0-app-icon.png 失败：\(error.localizedDescription)")
}

let temporaryRoot = fileManager.temporaryDirectory
    .appendingPathComponent("claudi0-branding-\(UUID().uuidString)", isDirectory: true)
let iconset = temporaryRoot.appendingPathComponent("claudi0.iconset", isDirectory: true)
do {
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch {
    fail("无法创建 iconset 目录：\(error.localizedDescription)")
}
defer { try? fileManager.removeItem(at: temporaryRoot) }

let iconsetFiles: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for (filename, size) in iconsetFiles {
    guard let png = downscaledPNG(to: size) else {
        fail("无法编码 \(size)×\(size) PNG")
    }
    do {
        try png.write(to: iconset.appendingPathComponent(filename), options: .atomic)
    } catch {
        fail("写入 \(filename) 失败：\(error.localizedDescription)")
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "--convert", "icns",
    iconset.path,
    "--output", outputDirectory.appendingPathComponent("claudi0.icns").path,
]
do {
    try iconutil.run()
} catch {
    fail("无法运行 iconutil：\(error.localizedDescription)")
}
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fail("iconutil 生成 claudi0.icns 失败（状态 \(iconutil.terminationStatus)）")
}

print("✓ 已从 claudi0-basic-kit 派生 assets/branding/claudi0-app-icon.png 与 claudi0.icns")
