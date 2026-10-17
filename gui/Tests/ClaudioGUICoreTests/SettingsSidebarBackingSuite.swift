import AppKit
import ClaudioGUIComponents
import ClaudioSettingsPresentation
import Foundation
import SwiftUI

@MainActor
func runSettingsSidebarBackingSuites() async {
    await suite("Settings sidebar: wordmark ink aligns on 1x and 2x backing grids") {
        for scale: CGFloat in [1, 2] {
            for width: CGFloat in [960, 1240] {
                let fixture = SettingsPresentationFixtures.generalLogin()
                let shell = SettingsNativeShellController(session: fixture.session)
                let window = SidebarBackingFixtureWindow(
                    contentRect: NSRect(x: 0, y: 0, width: width, height: 640),
                    styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                    backing: .buffered, defer: false)
                window.fixtureScale = scale
                window.isReleasedWhenClosed = false
                window.contentViewController = shell
                shell.install(in: window)
                window.setContentSize(NSSize(width: width, height: 640))
                defer {
                    fixture.session.send(.windowWillClose)
                    window.contentViewController = nil
                    window.close()
                }
                for _ in 0..<4 {
                    await Task.yield()
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.pumpRunLoop()
                }
                let sidebar = shell.sidebarController
                let backingOrigin = sidebar.view.convertToBacking(.zero as NSPoint)
                let backingUnit = sidebar.view.convertToBacking(NSPoint(x: 1, y: 0))
                expect(
                    abs(backingUnit.x - backingOrigin.x - scale) < 0.01,
                    "The controlled native window must exercise the requested \(scale)x backing grid"
                )
                guard
                    let brand = sidebar.view.subviews.first(where: {
                        $0 is NSHostingView<ClaudioT2Wordmark>
                    }),
                    let cell = sidebar.table.view(atColumn: 0, row: 0, makeIfNecessary: true),
                    let icon = cell.subviews.first
                else {
                    expect(false, "The real sidebar must mount its brand and destination icon")
                    continue
                }
                let glyph = ClaudioT2Geometry.wordmarkGlyphPath(
                    extraTransform: ClaudioT2Geometry.designTransform(for: brand.bounds)
                ).boundingBoxOfPath
                let brandX = brand.convert(glyph, to: sidebar.view).minX
                let iconX = icon.convert(icon.bounds, to: sidebar.view).minX
                expect(
                    abs(brandX - iconX) < 0.5,
                    "\(scale)x/\(width): brand ink x=\(brandX) must align with icon x=\(iconX); host frame=\(brand.frame), bounds=\(brand.bounds)"
                )
                print(
                    "  Sidebar backing \(scale)x/\(width): brand=\(brandX), icon=\(iconX), host=\(brand.frame)"
                )
                if let directory = ProcessInfo.processInfo.environment[
                    "CLAUDIO_SIDEBAR_BACKING_CAPTURE_DIR"],
                    let bitmap = sidebar.view.bitmapImageRepForCachingDisplay(
                        in: sidebar.view.bounds)
                {
                    sidebar.view.cacheDisplay(in: sidebar.view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        do {
                            let folder = URL(fileURLWithPath: directory, isDirectory: true)
                            try FileManager.default.createDirectory(
                                at: folder, withIntermediateDirectories: true)
                            try data.write(
                                to: folder.appendingPathComponent(
                                    "sidebar-\(Int(scale))x-\(Int(width)).png"))
                        } catch {
                            expect(
                                false, "Requested native sidebar capture must be written: \(error)")
                        }
                    }
                }
            }
        }
    }
}

/// Controls AppKit's backing-grid layout without changing the developer's display.
/// This is a mounted native fixture; the CI's actual display remains a separate check.
@MainActor
private final class SidebarBackingFixtureWindow: NSPanel {
    var fixtureScale: CGFloat = 2
    override var backingScaleFactor: CGFloat { fixtureScale }

    func pumpRunLoop() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.015))
    }
}
