import AppKit
import ApplicationServices
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import SwiftUI

@MainActor
func runSettingsFeedbackNativeSuites() async {
    for language in ClaudioAppLanguage.allCases {
        for dark in [false, true] {
            for width: CGFloat in [960, 1240] {
                await suite("Settings feedback: mounted system error \(language)/\(dark)/\(width)")
                {
                    let fixture = SettingsPresentationFixtures.generalLogin(
                        language: language,
                        experienceProfile: PreviewFixtures.SettingsExperienceScenario
                            .generalWriteFailed.profile)
                    let probe = NativeSettingsShellProbe(
                        session: fixture.session, width: width, dark: dark)
                    defer { probe.close() }
                    await probe.presentAndSettle()
                    fixture.session.send(.setLoginItemEnabled(true))
                    await probe.settle()
                    expect(
                        fixture.session.state.loginItemFailure != nil,
                        "The mounted adapter actually rejects this request")
                    expect(
                        feedbackPixelCount(in: probe.shell.view, color: .systemRed) > 3,
                        "Root FailureRow resolves systemRed in its effective appearance")
                    let retry = settingsKeyboardAXElements(probe.shell.view).first {
                        $0.accessibilityRole?() == .button
                            && $0.accessibilityLabel?()
                                == ClaudioL10n(language: language).text(.commonRetry)
                    }
                    expect(
                        retry?.isAccessibilityEnabled?() == true,
                        "The existing recovery action stays reachable")
                    expect(
                        retry?.accessibilityPerformPress?() == true,
                        "The existing recovery action still runs")
                    await probe.settle()
                    expect(
                        feedbackPixelCount(
                            in: probe.shell.view, color: .secondaryLabelColor, group: true) > 20,
                        "Failure body uses the composited secondary label color")
                    expect(
                        fixture.actionRecorder.actions.isEmpty,
                        "Rendering errors performs no platform action")
                    captureFeedback(
                        probe.window, "login-\(language.rawValue)-\(dark)-\(Int(width))")
                }
            }
        }
    }
    for language in ClaudioAppLanguage.allCases {
        for dark in [false, true] {
            for width: CGFloat in [960, 1240] {
                await suite("Settings feedback: root to naming sheet \(language)/\(dark)/\(width)")
                {
                    let fixture = SettingsPresentationFixtures.generalLogin(
                        language: language, route: .destination(.sounds))
                    let probe = NativeSettingsShellProbe(
                        session: fixture.session, width: width, dark: dark)
                    defer { probe.close() }
                    await probe.presentAndSettle()
                    let add = settingsKeyboardAXElements(probe.shell.view).first {
                        $0.accessibilityIdentifier?() == "settings.sounds.new-pack"
                    }
                    expect(
                        add?.accessibilityPerformPress?() == true,
                        "Open the actual attached name form")
                    await probe.settle()
                    guard let sheet = probe.window.attachedSheet, let content = sheet.contentView
                    else {
                        expect(false, "Name form attaches to the root window"); return
                    }
                    sheet.makeKey()
                    guard let editor = sheet.firstResponder as? NSTextView else {
                        expect(false, "Name input owns the native field editor"); return
                    }
                    editor.insertText(
                        String(repeating: "x", count: 65),
                        replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    await probe.settle()
                    let save = settingsKeyboardAXElements(content).first {
                        $0.accessibilityIdentifier?() == "settings.sounds.sheet.use"
                    }
                    expect(
                        save?.accessibilityPerformPress?() == true,
                        "Submit invalid input exactly once")
                    await probe.settle()
                    let error = settingsKeyboardAXElements(content).first {
                        $0.accessibilityIdentifier?() == "settings.sounds.error"
                    }
                    expect(error != nil, "The complete form error retains its AX identity")
                    let accessibleNames = feedbackAXNames(
                        identifier: "settings.sounds.error")
                    expect(
                        accessibleNames.contains(
                            ClaudioL10n(language: language).text(.soundsNameInvalid)),
                        "The selectable form error exposes static text with its complete localized message"
                    )
                    expect(
                        feedbackPixelCount(in: content, color: .systemRed) > 3,
                        "Sheet FailureRow inherits the root settings environment")
                    captureFeedback(sheet, "name-error-\(language.rawValue)-\(dark)-\(Int(width))")
                    settingsKeyboardPress(53, "\u{1b}", in: sheet)
                    await probe.settle()
                    expect(probe.window.attachedSheet == nil, "Escape cancels the failed form")
                    expect(
                        fixture.actionRecorder.actions.isEmpty,
                        "Validation and cancel cause no platform effect")
                }
            }
        }
    }
    for dark in [false, true] {
        for increased in [false, true] {
            suite("Settings feedback: long selectable message \(dark)/\(increased)") {
                let message = String(
                    repeating: "完整错误消息 Long failure message with recovery. ", count: 5)
                let row = FailureRow(message: message).textSelection(.enabled)
                    .environment(\.usesSettingsAppearance, true)
                    .padding(16).frame(width: 350, alignment: .leading)
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: row)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 350, height: 220),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(
                    named: increased
                        ? (dark
                            ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                        : (dark ? .darkAqua : .aqua))
                window.contentView = host
                defer { window.close() }
                feedbackSettle(host)
                expect(host.fittingSize.height > 60, "Long errors wrap vertically")
                let elements = settingsKeyboardAXElements(host)
                expect(
                    elements.contains {
                        let value: String? = $0.accessibilityValue?()
                        return $0.accessibilityLabel?() == message || value == message
                    },
                    "AX exposes the full error without truncation")
                expect(
                    feedbackPixelCount(in: host, color: .systemRed) > 3,
                    "Error icon follows effective appearance and contrast")
                expect(
                    feedbackPixelCount(in: host, color: .secondaryLabelColor) > 40,
                    "The wrapped body remains neutral")
            }
        }
    }
    for dark in [false, true] {
        suite("Settings feedback: panel default isolation \(dark)") {
            let row = FailureRow(message: "Panel failure").padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: row)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 350, height: 80),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            defer { window.close() }
            feedbackSettle(host)
            let hex = dark ? ClaudioColorHex.errorDark : ClaudioColorHex.errorLight
            var value: UInt64 = 0
            Scanner(string: hex).scanHexInt64(&value)
            let expected = NSColor(
                srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
            expect(
                feedbackPixelCount(in: host, color: expected) > 3,
                "Default public FailureRow keeps its panel palette")
        }
    }
}

@MainActor
func feedbackSettle(_ view: NSView) {
    for _ in 0..<8 {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    }
}

/// Count fully covered pixels after resolving the semantic color in the actual drawing appearance.
/// Alpha is composited over the window and (when requested) the translucent system group.
@MainActor
func feedbackPixelCount(in view: NSView, color: NSColor, group: Bool = false) -> Int {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let bitmap = rep.converting(to: .sRGB, renderingIntent: .default) else { return 0 }
    var expected: [CGFloat] = []
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        guard let ink = color.usingColorSpace(.sRGB),
            let page = NSColor.windowBackgroundColor.usingColorSpace(.sRGB),
            let surface = (group ? NSColor.underPageBackgroundColor : NSColor.windowBackgroundColor)
                .usingColorSpace(.sRGB)
        else { return }
        let bg = zip(
            [surface.redComponent, surface.greenComponent, surface.blueComponent],
            [page.redComponent, page.greenComponent, page.blueComponent]
        ).map {
            $0 * surface.alphaComponent + $1 * (1 - surface.alphaComponent)
        }
        expected = zip([ink.redComponent, ink.greenComponent, ink.blueComponent], bg).map {
            $0 * ink.alphaComponent + $1 * (1 - ink.alphaComponent)
        }
    }
    guard expected.count == 3 else { return 0 }
    var count = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            guard let pixel = bitmap.colorAt(x: x, y: y) else { continue }
            if zip([pixel.redComponent, pixel.greenComponent, pixel.blueComponent], expected)
                .allSatisfy({ abs($0 - $1) <= 0.025 })
            {
                count += 1
            }
        }
    }
    return count
}

@MainActor
private func captureFeedback(_ window: NSWindow, _ name: String) {
    guard
        let directory = ProcessInfo.processInfo.environment[
            "CLAUDIO_SETTINGS_FEEDBACK_CAPTURE_DIR"],
        let view = window.contentView?.superview,
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try? bitmap.representation(using: .png, properties: [:])?.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
}

/// Read the public AX attributes on MainActor: self-process AX calls dispatch directly into AppKit.
@MainActor
private func feedbackAXNames(identifier: String) -> [String] {
    let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 2)
    var messages: [String] = []
    var budget = 500
    func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else {
            return nil
        }
        return value
    }
    func visit(_ element: AXUIElement) {
        guard budget > 0 else { return }
        budget -= 1
        if attribute(element, kAXIdentifierAttribute) as? String == identifier,
            attribute(element, kAXRoleAttribute) as? String == kAXStaticTextRole
        {
            for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let message = attribute(element, key) as? String { messages.append(message) }
            }
        }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            visit(child)
        }
    }
    visit(app)
    return messages
}
