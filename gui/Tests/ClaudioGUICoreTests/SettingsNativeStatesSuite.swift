import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation
import SoundPacksWindow

/// Every gallery state mounts the production root/session/dependency seam. These assertions and
/// captures establish native presentation of fixture facts, not real credentials or permissions.
@MainActor
func runSettingsNativeStatesSuites() async {
    let cancelOnly = CommandLine.arguments.contains("--settings-native-cancel-only")
    for language in [ClaudioAppLanguage.zhHans, .english] {
        for scenario in PreviewFixtures.settingsExperienceScenarios where !cancelOnly {
            let fixture = SettingsPresentationFixtures.generalLogin(
                language: language, route: .destination(scenario.destination),
                experienceProfile: scenario.profile)
            await suite("设置原生状态：\(scenario.id) \(language.rawValue)") {
                SettingsMountRecorder.reset()
                let probe = SettingsSoundsNativeLayoutProbe(
                    session: fixture.session, size: NSSize(width: 960, height: 640))
                defer { probe.close() }
                try? await Task.sleep(nanoseconds: 60_000_000)
                probe.refresh()
                let title = "settings.title.\(scenario.destination.rawValue)"
                expect(SoundPacksLayoutRecorder.frames[title] != nil, "必须挂载对应原生页面标题")
                expect(!probe.hasAttachedSheet, "普通状态不得意外打开 sheet")
                recordNativeState(probe, name: "\(scenario.id)-\(language.rawValue)")
            }
        }
        for scenario in PreviewFixtures.aiCueGalleryScenarios
        where !cancelOnly || scenario == .generating {
            let fixture = SettingsPresentationFixtures.generalLogin(
                language: language, aiCueScenario: scenario)
            await suite("AI 原生状态：\(scenario.id) \(language.rawValue)") {
                SettingsMountRecorder.reset()
                let probe = SettingsSoundsNativeLayoutProbe(
                    session: fixture.session, size: NSSize(width: 960, height: 640))
                defer { probe.close() }
                try? await Task.sleep(nanoseconds: 120_000_000)
                probe.refresh()
                expect(
                    fixture.session.state.routeResolution.destination == .sounds,
                    "全部 AI 状态必须进入声音页的包级详情")
                let expectsCredentialSheet =
                    scenario.rendersCredentialSheet
                    && fixture.aiCueViewModel.providerIsAdmitted
                    && fixture.aiCueViewModel.providerCredentialAccessAllowed
                expect(
                    probe.hasAttachedSheet == expectsCredentialSheet,
                    "凭据 sheet 必须遵守 Provider 准入与存储能力")
                if scenario.rendersCredentialSheet && !expectsCredentialSheet {
                    expect(
                        !SettingsMountRecorder.identifiers.contains(
                            "event-settings.ai-cue.credential-sheet")
                            && !fixture.session.state.eventPresentation.credentialSheetIsPresented
                            && fixture.session.state.chrome.navigationEnabled,
                        "被拒绝的凭据入口不得挂载表单或阻塞外层导航")
                } else {
                    let expectedID =
                        expectsCredentialSheet
                        ? "event-settings.ai-cue.credential-sheet"
                        : "event-settings.ai-cue.composer"
                    expect(
                        SettingsMountRecorder.identifiers.contains(expectedID),
                        "必须出现原生状态内容 \(expectedID)")
                }
                if fixture.session.state.routeResolution.failure == nil,
                    case .sounds(let route) = fixture.session.state.routeResolution.route,
                    let target = route.editTarget
                {
                    if case .sounds(let sounds) = fixture.soundPacksEditor.presentation.mode {
                        expect(
                            sounds.routeState == .resolved(route)
                                && sounds.selectedPack?.id == target.packID
                                && sounds.eventRows.contains(where: { $0.event == target.event }),
                            "有效事件详情必须匹配同一已解析包与事件身份")
                    } else {
                        expect(false, "有效声音路线必须存在真实编辑器投影")
                    }
                    let serviceID = "settings.sounds.ai-cue.service"
                    expect(
                        SettingsMountRecorder.identifiers.contains(serviceID),
                        "有效事件详情必须持续挂载同一服务与凭据上下文，包括生成和候选阶段")
                    if let serviceFrame = SoundPacksLayoutRecorder.frames[serviceID],
                        let detailFrame = SoundPacksLayoutRecorder.frames[
                            "sound-packs.event-detail"]
                    {
                        expect(
                            !serviceFrame.isEmpty && !serviceFrame.isNull
                                && !serviceFrame.isInfinite
                                && serviceFrame.width > 0 && serviceFrame.height > 0
                                && detailFrame.insetBy(dx: -1, dy: -1).contains(serviceFrame),
                            "服务上下文必须实际布局在事件详情内，不能只挂服务子页或隐藏 identifier")
                    } else {
                        expect(false, "有效事件详情必须存在服务上下文与详情的真实布局")
                    }
                }
                if expectsCredentialSheet {
                    let before = probe.renderedSheetText()
                    expect(
                        before?.contains(language == .english ? "Cancel" : "取消") == true,
                        "sheet 位图必须包含当前语种的取消按钮")
                    _ = fixture.session.send(
                        .setLanguageMode(language == .english ? .zhHans : .english))
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    probe.refresh()
                    let after = probe.renderedSheetText()
                    expect(
                        after?.contains(language == .english ? "取消" : "Cancel") == true,
                        "打开的 sheet 位图必须立即翻译；真实 AX 名称另经 CUA 验证")
                    _ = fixture.session.send(
                        .setLanguageMode(language == .english ? .english : .zhHans))
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    probe.refresh()
                }
                if scenario == .generating {
                    expect(probe.scrollToEnd(), "生成中必须能滚动到取消按钮")
                    let cancel = language == .english ? "Cancel" : "取消"
                    let rendered = probe.renderedButtonText(title: cancel)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    expect(
                        rendered == cancel,
                        "原生取消按钮自身位图必须绘制完整的 \(cancel)，不能压成省略号或误匹配说明句；实际文本 \(rendered as Any)，布局 \(probe.buttonLayout(title: cancel) as Any)"
                    )
                }
                recordNativeState(probe, name: "\(scenario.id)-\(language.rawValue)")
                if expectsCredentialSheet {
                    let stamp = fixture.session.navigationHistory.stamp
                    expect(
                        fixture.session.send(.route(.destination(.general))) == .unchanged
                            && fixture.session.navigationHistory.stamp == stamp,
                        "credential sheet disables outer navigation without changing history")
                    fixture.eventSettingsSelection.dismissCredentialSheet()
                    await probe.settle()
                    expect(
                        !probe.hasAttachedSheet && fixture.session.state.chrome.navigationEnabled
                            && fixture.session.navigationHistory.stamp == stamp,
                        "cancelling the sheet restores navigation and leaves the cursor unchanged")
                }
                _ = fixture.session.send(.route(.destination(.general)))
                expect(
                    !fixture.session.state.eventPresentation.credentialSheetIsPresented
                        && fixture.session.state.eventPresentation.playingCandidateID == nil
                        && fixture.aiCueViewModel.session == nil
                        && fixture.aiCueViewModel.generation == nil,
                    "离开声音页必须清理 sheet、试听与临时候选")
            }
        }
        for scenario in PreviewFixtures.hostIntegrationScenarios where !cancelOnly {
            for host in HostID.productVisibleCases {
                let fixture = SettingsPresentationFixtures.generalLogin(
                    language: language,
                    route: .integrations(IntegrationsSettingsRoute(surface: host.surfaceID)),
                    integrationScenario: scenario)
                await suite("集成原生状态：\(scenario.id) \(host.rawValue) \(language.rawValue)") {
                    SettingsMountRecorder.reset()
                    let probe = SettingsSoundsNativeLayoutProbe(
                        session: fixture.session, size: NSSize(width: 960, height: 640))
                    defer { probe.close() }
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    probe.refresh()
                    expect(
                        fixture.integrationsModel.selectedHost == host,
                        "明确来源路线不得串到其它宿主")
                    expect(
                        SettingsMountRecorder.identifiers.contains(
                            "settings.destination.integrations")
                            && SoundPacksLayoutRecorder.frames["settings.reading.integrations"]
                                != nil,
                        "接入事实必须在原生单列页面挂载")
                    expect(!probe.hasAttachedSheet, "查看接入状态不得自动确认连接或断开")
                    recordNativeState(
                        probe,
                        name: "integration-\(scenario.id)-\(host.rawValue)-\(language.rawValue)")
                }
            }
        }
    }
}

@MainActor
private func recordNativeState(
    _ probe: SettingsSoundsNativeLayoutProbe, name: String
) {
    guard let directory = ProcessInfo.processInfo.environment["CLAUDIO_NATIVE_STATE_CAPTURE_DIR"]
    else { return }
    let base = URL(fileURLWithPath: directory).appendingPathComponent(name)
    expect(probe.saveScreenshot(to: base.appendingPathExtension("png")), "状态截图必须保存")
    if probe.hasAttachedSheet {
        expect(
            probe.saveSheetScreenshot(to: base.appendingPathExtension("sheet.png")), "sheet 截图必须保存")
    }
    let data = try? JSONSerialization.data(
        withJSONObject: [
            "mountedIdentifiers": SettingsMountRecorder.identifiers,
            "layoutIdentifiers": SoundPacksLayoutRecorder.frames.keys.sorted(),
        ],
        options: [.sortedKeys, .prettyPrinted])
    expect((try? data?.write(to: base.appendingPathExtension("mount.json"))) != nil, "挂载状态必须保存")
}
