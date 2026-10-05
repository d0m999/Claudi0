import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation
import SoundPacksWindow

@MainActor
func runIntegrationAutomationNativeSuites() async {
    await suite("集成原生三层：正式来源、双语、明暗与默认/最小窗口均挂载正确身份且无横向溢出") {
        for language in [ClaudioAppLanguage.zhHans, .english] {
            for size in [NSSize(width: 1240, height: 820), NSSize(width: 960, height: 640)] {
                for dark in [false, true] {
                    for host in HostIntegrationManager.automaticHosts {
                        for level in [IntegrationSettingsLevel.application, .diagnostics] {
                            let route = SettingsRoute.integrations(
                                .init(surface: host.surfaceID, level: level))
                            let fixture = SettingsPresentationFixtures.generalLogin(
                                language: language, route: route,
                                availability: PreviewFixtures.settingsRouteAvailability)
                            let probe = SettingsSoundsNativeLayoutProbe(
                                session: fixture.session, size: size,
                                appearance: dark ? .darkAqua : .aqua)
                            defer { probe.close() }
                            await probe.settle()
                            let frames = SoundPacksLayoutRecorder.frames
                            let expected =
                                level == .application
                                ? "integrations.reminders.\(host.rawValue)"
                                : "integrations.diagnostics.\(host.rawValue)"
                            let opposite =
                                level == .application
                                ? "integrations.diagnostics.\(host.rawValue)"
                                : "integrations.reminders.\(host.rawValue)"
                            expect(
                                fixture.session.integrationRequestedFocusTarget
                                    == (level == .application
                                        ? .agent(host) : .connectionRow(.connectionStatus)),
                                "详情/诊断焦点请求必须指向实际挂载的控件")
                            expect(
                                fixture.session.state.routeResolution.route == route, "保留来源和层级路由身份")
                            guard let section = frames[expected],
                                let reading = frames["settings.reading.integrations"]
                            else {
                                expect(
                                    false,
                                    "\(host) \(level) \(language) \(dark) 实际挂载缺失：\(frames.keys.sorted())"
                                )
                                continue
                            }
                            expect(frames[opposite] == nil, "详情和诊断有独立内容")
                            expect(
                                section.minX >= reading.minX - 1
                                    && section.maxX <= reading.maxX + 1,
                                "\(host) \(level) \(size) 内容不能横向溢出：\(section), \(reading)")
                            if level == .application {
                                expect(
                                    frames["integrations.agent.\(host.rawValue)"] != nil,
                                    "详情保留相同来源开关")
                            }
                        }
                    }
                }
            }
        }
    }
}
