import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation
import SwiftUI

@MainActor
func runAICueDescriptionSuites() {
    suite("AI 提示音原生描述控件：生成时不挂载可编辑输入器") {
        for scenario in [PreviewFixtures.AICueGalleryScenario.generating, .editing] {
            let fixture = aiCueDescriptionPackFixture(scenario)
            let probe = SettingsSoundsNativeLayoutProbe(
                session: fixture.session,
                size: NSSize(width: 1_240, height: 820))
            probe.refresh()
            expect(probe.chooseSource(event: .stop, index: 0), "描述测试从事件显式打开 AI 表单")
            probe.refresh()
            expect(probe.hasAttachedSheet, "测试必须挂载真实附属表单")
            let inputs = probe.sheetContentView.map { aiCueNativeTextInputs(in: $0) } ?? []
            if scenario == .generating {
                expect(inputs.isEmpty, "生成中的生产树必须移除 NSTextView，不只禁用其 SwiftUI 外壳")
            } else {
                expect(inputs.contains(where: \.isEditable), "编辑态必须实际挂载可编辑输入器，不能空树假通过")
            }
            probe.close()
        }
    }
}

/// Opt-in key-window gate: unlike the default mounting suite, this starts AppKit's event loop
/// and yields the main actor so production focus lifecycle tasks can actually execute.
@MainActor
func runAICueDescriptionFocusSuites() async {
    await suite("AI 提示音原生描述焦点：附属表单初次打开与取消生成后可直接编辑") {
        for scenario in [PreviewFixtures.AICueGalleryScenario.editing, .generating] {
            let fixture = aiCueDescriptionPackFixture(scenario)
            let probe = SettingsSoundsNativeLayoutProbe(
                session: fixture.session,
                size: NSSize(width: 1_240, height: 820))
            defer { probe.close() }
            await probe.settle()
            NSApp.activate(ignoringOtherApps: true)
            expect(probe.chooseSource(event: .stop, index: 0), "从事件明确进入附属表单")
            await probe.settle()
            guard let window = probe.sheetWindow, let content = window.contentView else {
                expect(false, "必须在真实附属表单上检查焦点"); continue
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            expect(await aiCueWaitForKeyWindow(window), "焦点门禁必须在真正的 key sheet 上执行")
            let originalDescription = fixture.aiCueViewModel.soundDescription
            if scenario == .generating {
                expect(aiCueNativeTextInputs(in: content).isEmpty, "生成态不挂载可写输入器")
                expect(aiCueSendKey(to: window, keyCode: 11, characters: "b"), "生成期间经窗口派发普通按键")
                expect(fixture.aiCueViewModel.phase == .generating, "普通按键不能取消生成")
                expect(probe.pressControl("settings.sounds.generation.cancel"), "显式取消同一个后台任务")
                await probe.settle()
            }
            let deadline = Date(timeIntervalSinceNow: 2)
            while Date() < deadline,
                !aiCueNativeTextInputs(in: content).contains(where: {
                    $0.isEditable && window.firstResponder === $0
                })
            {
                try? await Task.sleep(nanoseconds: 10_000_000)
                content.layoutSubtreeIfNeeded()
            }
            expect(
                fixture.aiCueViewModel.phase == .editing
                    && fixture.aiCueViewModel.soundDescription == originalDescription,
                "取消保留描述并恢复编辑态")
            guard
                let editor = aiCueNativeTextInputs(in: content).first(where: {
                    $0.isEditable && window.firstResponder === $0
                })
            else {
                expect(
                    false,
                    "无需点击描述输入器即可成为 first responder：\(scenario.rawValue)；实际 \(String(describing: window.firstResponder))；输入器 \(aiCueNativeTextInputs(in: content).map { String(describing: $0.window) + String($0.isEditable) })"
                ); continue
            }
            expect(true, "实际 NSTextView 持有焦点")
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            expect(aiCueSendKey(to: window, keyCode: 49, characters: " "), "真实键盘空格进入描述")
            await probe.settle()
            expect(
                fixture.aiCueViewModel.soundDescription == originalDescription + " ", "空格不被旧取消处理器吞掉"
            )
            expect(
                aiCueSendKey(to: window, keyCode: 53, characters: "\u{001b}"), "Escape 经真实窗口关闭附属表单")
            await probe.settle()
            expect(
                !probe.hasAttachedSheet && fixture.aiCueViewModel.session == nil, "Escape 撤销采用上下文")
        }
    }
}

@MainActor
private func aiCueWaitForKeyWindow(_ window: NSWindow) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: 2)
    while Date() < deadline, !(NSApp.isActive && window.isKeyWindow) {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return NSApp.isActive && window.isKeyWindow
}

@MainActor
private func aiCueSendKey(
    to window: NSWindow,
    keyCode: UInt16,
    characters: String,
    modifiers: NSEvent.ModifierFlags = []
) -> Bool {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard
            let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode)
        else { return false }
        window.sendEvent(event)
    }
    return true
}

@MainActor
private func aiCueNativeTextInputs(in view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { aiCueNativeTextInputs(in: $0) }
}

@MainActor
private func aiCueDescriptionPackFixture(_ scenario: PreviewFixtures.AICueGalleryScenario)
    -> SettingsPresentationFixture
{
    let state = scenario.previewState()
    let viewModel = AICueGenerationViewModel(
        previewState: AICueGenerationPreviewState(
            providerProfileID: state.providerProfileID, credentialStatus: state.credentialStatus,
            phase: state.phase, soundDescription: state.soundDescription,
            session: AICueComposerSession(packID: "settings-fixture-pack", event: .stop)),
        registry: PreviewFixtures.aiCueEvidenceRegistry)
    return SettingsPresentationFixtures.generalLogin(
        route: .sounds(.editEvent(surface: nil, packID: "settings-fixture-pack", event: .stop)),
        aiCueViewModel: viewModel)
}
