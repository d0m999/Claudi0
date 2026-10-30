import AppKit
import ApplicationServices
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import SwiftUI

@MainActor
func runSettingsFeedbackNativeSuites() async {
    await runMountedSemanticFeedbackSuites()
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
                    guard await probe.presentAndSettle() else { return }
                    fixture.session.send(.setLoginItemEnabled(true))
                    await probe.settle()
                    expect(
                        fixture.session.state.loginItemFailure != nil,
                        "The mounted adapter actually rejects this request")
                    expect(
                        feedbackPixelCount(
                            in: probe.shell.view,
                            color: NSColor(SettingsAppearance.error(dark ? .dark : .light))) > 3,
                        "Root FailureRow resolves the documented error color in its appearance")
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
                    guard await probe.presentAndSettle() else { return }
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
                        feedbackPixelCount(
                            in: content,
                            color: NSColor(SettingsAppearance.error(dark ? .dark : .light))) > 3,
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
                    .background(SettingsAppearance.background(dark ? .dark : .light))
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
                    feedbackPixelCount(
                        in: host,
                        color: NSColor(SettingsAppearance.error(dark ? .dark : .light))) > 3,
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
            expect(
                feedbackPixelCount(
                    in: host, color: NSColor(ClaudioTheme.secondaryText(dark ? .dark : .light))) > 3,
                "Default public FailureRow keeps the panel text-2 body, not the settings label")
        }
    }
}

@MainActor
private func runMountedSemanticFeedbackSuites() async {
    for language in [ClaudioAppLanguage.zhHans, .english] {
        for dark in [false, true] {
            for width: CGFloat in [960, 1240] {
                await suite(
                    "Settings feedback: actual success root and About sheet \(language)/\(dark)/\(width)"
                ) {
                    let fixture = SettingsPresentationFixtures.generalLogin(
                        language: language, route: .destination(.usage))
                    let probe = NativeSettingsShellProbe(
                        session: fixture.session, width: width, dark: dark)
                    defer { probe.close() }
                    guard await probe.presentAndSettle() else { return }
                    fixture.activityDiagnostics.clearActivity()
                    let completed = await settingsKeyboardWait {
                        fixture.activityDiagnostics.feedback != nil
                    }
                    expect(
                        completed, "The isolated clear operation returns actual success feedback")
                    await probe.settle()
                    _ = probe.scrollReading(to: probe.maximumReadingOffset ?? 0)
                    await probe.settle()
                    expect(
                        feedbackPixelCount(
                            in: probe.shell.view,
                            color: NSColor(SettingsAppearance.success(dark ? .dark : .light))) > 3,
                        "Root success icon uses the current appearance's semantic color")
                    captureFeedback(
                        probe.window, "success-root-\(language.rawValue)-\(dark)-\(Int(width))")
                    fixture.session.send(.selectSidebar(.general))
                    guard await probe.presentAndSettle() else { return }
                    let about = settingsKeyboardAXElements(probe.shell.view).first {
                        $0.accessibilityIdentifier?() == "settings.general.about"
                    }
                    expect(
                        about?.accessibilityPerformPress?() == true, "Open the actual About sheet")
                    let opened = await settingsKeyboardWait {
                        probe.window.attachedSheet?.isKeyWindow == true
                    }
                    guard opened, let sheet = probe.window.attachedSheet,
                        let content = sheet.contentView
                    else {
                        expect(false, "About is a key attached sheet"); return
                    }
                    fixture.aboutSettings.copyVersionInformation(language: language)
                    await probe.settle()
                    scrollFeedbackToEnd(content)
                    await probe.settle()
                    expect(
                        feedbackPixelCount(
                            in: content,
                            color: NSColor(SettingsAppearance.success(dark ? .dark : .light))) > 3,
                        "The actual About success icon inherits the settings appearance")
                    expect(
                        feedbackPixelCount(in: content, color: .secondaryLabelColor) > 20,
                        "The attached form retains neutral secondary body text")
                    captureFeedback(
                        sheet, "success-sheet-\(language.rawValue)-\(dark)-\(Int(width))")
                    settingsKeyboardPress(53, "\u{1b}", in: sheet)
                    await probe.settle()
                }
                await suite("Settings feedback: actual warning root \(language)/\(dark)/\(width)") {
                    let fixture = SettingsPresentationFixtures.generalLogin(
                        language: language, route: .events(scope: .workspace(UUID()), event: nil))
                    let probe = NativeSettingsShellProbe(
                        session: fixture.session, width: width, dark: dark)
                    defer { probe.close() }
                    guard await probe.presentAndSettle() else { return }
                    expect(
                        fixture.session.state.routeResolution.failure != nil,
                        "The stale workspace remains unavailable")
                    expect(
                        feedbackPixelCount(
                            in: probe.shell.view,
                            color: NSColor(SettingsAppearance.warning(dark ? .dark : .light))) > 3,
                        "Root warning icon uses the current appearance's semantic color")
                    expect(
                        feedbackPixelCount(in: probe.shell.view, color: .secondaryLabelColor) > 20,
                        "The warning body stays neutral")
                    captureFeedback(
                        probe.window, "warning-root-\(language.rawValue)-\(dark)-\(Int(width))")
                }
                await suite(
                    "Settings feedback: actual partial-candidate form \(language)/\(dark)/\(width)"
                ) {
                    let fixture = SettingsPresentationFixtures.generalLogin(
                        language: language, aiCueScenario: .senseAudioPartial)
                    let probe = NativeSettingsShellProbe(
                        session: fixture.session, width: width, dark: dark)
                    defer { probe.close() }
                    guard await probe.presentAndSettle() else { return }
                    @MainActor func views(_ view: NSView) -> [NSView] {
                        [view] + view.subviews.flatMap(views)
                    }
                    guard let event = fixture.aiCueViewModel.session?.event,
                        let control = views(probe.shell.view).compactMap({ $0 as? NSPopUpButton })
                            .first(where: {
                                $0.accessibilityIdentifier()
                                    == "settings.sounds.event.\(event.rawValue).source"
                            }), let menu = control.menu,
                        let index = menu.items.firstIndex(where: {
                            $0.accessibilityIdentifier() == "settings.sounds.source.ai"
                        })
                    else {
                        expect(false, "The actual event source menu exposes AI generation"); return
                    }
                    control.selectItem(at: index)
                    expect(
                        control.sendAction(control.action, to: control.target),
                        "Choose AI through the native menu action")
                    let opened = await settingsKeyboardWait {
                        probe.window.attachedSheet?.isKeyWindow == true
                    }
                    guard opened, let sheet = probe.window.attachedSheet,
                        let content = sheet.contentView
                    else {
                        expect(false, "The partial-candidate form attaches to Settings"); return
                    }
                    await probe.settle()
                    let partial = settingsKeyboardAXElements(content).filter {
                        $0.accessibilityIdentifier?() == "settings.sounds.ai.partial"
                    }
                    expect(!partial.isEmpty, "The current AI form mounts the partial result notice")
                    expect(
                        feedbackPixelCount(
                            in: content,
                            color: NSColor(SettingsAppearance.warning(dark ? .dark : .light))) > 3,
                        "The partial-candidate warning has the semantic icon color")
                    captureFeedback(
                        sheet, "warning-sheet-\(language.rawValue)-\(dark)-\(Int(width))")
                    settingsKeyboardPress(53, "\u{1b}", in: sheet)
                    await probe.settle()
                }
            }
        }
    }
}

@MainActor
private func scrollFeedbackToEnd(_ root: NSView) {
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    guard
        let scroll = views(root).compactMap({ $0 as? NSScrollView })
            .max(by: { $0.bounds.height < $1.bounds.height }), let document = scroll.documentView
    else { return }
    scroll.contentView.scroll(
        to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
    scroll.reflectScrolledClipView(scroll.contentView)
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
