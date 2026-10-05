import ClaudioGUICore
import Foundation

@MainActor
func runBundledHelperResourcesSuites() {
    for hasHelper in [true, false] {
        suite("Bundled helper：真实 app bundle 定位，hasHelper=\(hasHelper)") {
            withTempDirectory { root in
                let contents = root.appendingPathComponent("Fixture.app/Contents")
                let gui = contents.appendingPathComponent("MacOS/claudi0-app")
                let helper = contents.appendingPathComponent("Resources/bin/claudi0")
                writeFixture("GUI fixture", to: gui)
                if hasHelper { writeFixture("helper fixture", to: helper) }
                writeFixture(
                    "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>"
                        + "<key>CFBundleIdentifier</key><string>com.claudio.resources.fixture</string>"
                        + "<key>CFBundleExecutable</key><string>claudi0-app</string>"
                        + "<key>CFBundlePackageType</key><string>APPL</string></dict></plist>",
                    to: contents.appendingPathComponent("Info.plist"))
                guard let bundle = Bundle(url: contents.deletingLastPathComponent()) else {
                    expect(false, "fixture 必须是真实 Bundle"); return
                }
                let resolved = bundledHelperBinary(in: bundle)
                expect(
                    resolved == (hasHelper ? helper : nil), "只解析 Resources/bin/claudi0；缺失时返回 nil")
                expect(
                    resolved != gui && resolved != bundle.executableURL,
                    "GUI executable 不能充当 helper")
                if let resolved {
                    expect(
                        try! String(contentsOf: resolved, encoding: .utf8) == "helper fixture",
                        "真实资源字节来自 helper")
                }
            }
        }
    }
}
