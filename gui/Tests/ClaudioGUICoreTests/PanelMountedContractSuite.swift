import AppKit
import ApplicationServices
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import ClaudioPanelPresentation
import Foundation
import SwiftUI

@MainActor
func runPanelMountedContractSuites() async {
    suite("Mounted Panel activity：单行双语统计省去正常态说明并保留异常") {
        for language in ClaudioAppLanguage.allCases {
            withTempDirectory { root in
                seedMountedPanelFiles(root)
                let builder = CompositionFixture(root: root)
                defer { builder.cleanup() }
                let composition = try! builder.build()
                composition.preferences.setLanguage(language)
                let now = Date()
                let dates = LocalActivitySummaryStore.dateKeys(today: now, timeZone: .current)
                let key = LocalActivityCounterKey.make(host: .claudeCode, event: .stop)
                let document = LocalActivitySummaryDocument(
                    updatedAt: now,
                    buckets: [
                        LocalActivityDayBucket(localDate: dates[0], counts: [key: 148]),
                        LocalActivityDayBucket(localDate: dates[1], counts: [key: 725]),
                    ])
                let l10n = ClaudioL10n(language: language)
                for readState: ActivityOverviewReadState in [.ready, .unavailable] {
                    let projection = ActivityOverviewProjector.project(
                        document: readState == .ready ? document : nil,
                        readState: readState, integrationStatuses: [:], now: now,
                        timeZone: .current)
                    let presentation = ActivityDiagnosticsPresentation(
                        projection: projection,
                        log: ActivityDiagnosticLogSnapshot(path: "", state: .missing, failures: []))
                    let diagnostics = ActivityDiagnosticsModel(
                        previewPresentation: presentation,
                        previewLoadResult: ActivityDiagnosticsLoadResult(
                            readResult: LocalActivitySummaryReadResult(
                                state: readState == .ready ? .ready(document) : .unavailable),
                            log: presentation.log))
                    let probe = PanelMountedContractProbe(
                        composition: composition, root: root, activityDiagnostics: diagnostics)
                    defer { probe.close() }
                    let expected = l10n.format(
                        .panelActivitySummary,
                        (readState == .ready ? "148" : "—") as NSString,
                        (readState == .ready ? "873" : "—") as NSString)
                    let expectedReading =
                        readState == .ready
                        ? expected
                        : expected + ", " + l10n.text(.settingsActivityStatusUnavailable)
                    let reading = probe.valueDescription("panel.activity.totals")
                    expect(
                        reading == expectedReading,
                        "实际挂载摘要使用原型单行文案，异常时合并播报真实原因与未知次数")
                    expect(
                        reading?.contains(l10n.text(.settingsActivityStatusReady)) == false
                            && reading?.contains(l10n.text(.workspaceAllSources)) == false,
                        "菜单栏不常驻数据完整或所有来源说明")
                }
            }
        }
    }
    await suite("Mounted Panel AX：两种语言的动作、身份、音量草稿与固定退出 footer") {
        for language in ClaudioAppLanguage.allCases {
            await withTempDirectory { root in
                seedMountedPanelFiles(root)
                let builder = CompositionFixture(root: root)
                defer { builder.cleanup() }
                let composition = try! builder.build()
                composition.preferences.setLanguage(language)
                _ = await composition.soundPackLibrary.refreshSnapshot(trigger: .initial)
                for _ in 0..<100 { await Task.yield() }
                let probe = PanelMountedContractProbe(composition: composition, root: root)
                defer { probe.close() }
                let l10n = ClaudioL10n(language: language)
                expect(
                    !probe.containsStaticText(l10n.text(.workspacePreviewNote)),
                    "试听边界不再作为面板常驻文字")
                expect(
                    probe.element("panel.event.stop.preview")?.accessibilityHelp?()
                        == l10n.text(.eventPreviewHint) + "\n" + l10n.text(.workspacePreviewNote),
                    "可用试听按钮通过实际 AX Help 保留试听边界")
                expect(
                    probe.element("panel.settings")?.accessibilityLabel?()
                        == l10n.text(.panelOpenSettings),
                    "挂载生产设置入口必须有精确本地化 AX 名称")
                expect(
                    probe.press("panel.settings") && probe.actions.settings == 1,
                    "从真实 AX Button 入口调用注入设置动作一次")
                expect(
                    probe.element("panel.quit")?.accessibilityLabel?()
                        == l10n.text(.panelQuitApplication),
                    "退出 AX 名称必须表明退出应用")
                expect(
                    probe.element("panel.quit")?.accessibilityHelp?()
                        == l10n.text(.panelQuitApplicationHint),
                    "退出按钮的实际 AX Help 必须说明面板与应用都将关闭")
                let quitFrame = probe.element("panel.quit")?.accessibilityFrame?()
                let scroll = probe.allElements.first { element in
                    element.accessibilityRole?() == .scrollArea
                        && (element.accessibilityFrame?().height ?? 0) > 100
                }
                if let quitFrame, let scrollFrame = scroll?.accessibilityFrame?() {
                    expect(
                        quitFrame.maxY <= scrollFrame.minY + 1
                            && probe.visibleFrame.contains(quitFrame),
                        "真实 footer 在主滚动视口下方且完整处于可见窗口内")
                    expect(probe.scrollToEnd(), "从实际 NSScrollView 入口滚动生产主内容")
                    let landed = probe.element("panel.quit")?.accessibilityFrame?()
                    expect(landed == quitFrame, "滚动内容后 footer 的原生 AX frame 保持固定")
                } else {
                    expect(false, "挂载的退出按钮与原生滚动区必须有可测 AX frame")
                }
                expect(
                    probe.press("panel.quit") && probe.actions.quit == 1,
                    "退出的真实 AX Button 只转发一次注入意图")
                expect(
                    probe.allElements.filter { $0.accessibilityLabel?() == "power" }.isEmpty,
                    "装饰 power 图标不能成为额外 AX 停靠点")

                let id = "panel.master-volume"
                expect(
                    probe.element(id)?.accessibilityLabel?() == l10n.text(.panelMasterVolume),
                    "生产滑块有明确主音量 AX 名称")
                expect(probe.valueDescription(id) == "70%", "AX 数值描述来自实际已挂载的初值")
                let bytes = try! Data(contentsOf: root.appendingPathComponent("config.json"))
                _ = SharedVolumeMountRecorder.edit(true, identifier: id)
                _ = SharedVolumeMountRecorder.setValue(0.55, identifier: id)
                probe.settle()
                expect(probe.valueDescription(id) == "55%", "拖动中的 AX 数值描述必须读取 draft，不能读旧磁盘值")
                expect(
                    try! Data(contentsOf: root.appendingPathComponent("config.json")) == bytes,
                    "AX 草稿更新仍不能提前写配置")
                expect(
                    probe.allElements.filter {
                        guard $0.accessibilityRole?() == .staticText else { return false }
                        let value: String? = $0.accessibilityValue?()
                        return value == l10n.text(.panelMasterVolume)
                    }.isEmpty,
                    "可见主音量标签隐藏，不能在 AX 树里再念一遍")
                _ = SharedVolumeMountRecorder.edit(false, identifier: id)
                probe.settle()
                expect(
                    probe.element("panel.master-volume") != nil
                        && probe.element("panel.quit") != nil,
                    "写后刷新保留稳定控件身份")
                expect(probe.press("panel.event.stop.mute"), "从挂载的 stop 静音 Button 入口投递动作")
                expect(
                    loadClaudioConfig(from: root.appendingPathComponent("config.json"))?.isEnabled(
                        .stop) == false,
                    "真实 Button 接线必须翻转真实配置文件")
                expect(probe.actions.audibility >= 2, "音量与静音动作均转发共享可听性更新")
            }
        }
    }
    await suite("Mounted Panel workspace：精简呈现仍定向打开当前工作区设置") {
        for language in ClaudioAppLanguage.allCases {
            await withTempDirectory { root in
                seedMountedPanelFiles(root)
                let rule = WorkspaceSoundRule(
                    id: UUID(),
                    directory: WorkspaceDirectory(kind: .directory, path: root.path),
                    surfaces: [.claudeCode, .codex],
                    profile: WorkspaceSoundProfile(selectedPack: "pack-a", volume: 0.4))
                let configFile = root.appendingPathComponent("config.json")
                var config = loadClaudioConfig(from: configFile)!
                config.workspaceRules = [rule]
                try! JSONEncoder().encode(config).write(to: configFile)
                let builder = CompositionFixture(root: root)
                defer { builder.cleanup() }
                let composition = try! builder.build()
                composition.preferences.setLanguage(language)
                _ = await composition.soundPackLibrary.refreshSnapshot(trigger: .initial)
                for _ in 0..<100 { await Task.yield() }
                composition.soundScopeSelection.select(.workspace(rule.id))
                let before = try! Data(contentsOf: configFile)
                let probe = PanelMountedContractProbe(composition: composition, root: root)
                defer { probe.close() }
                let l10n = ClaudioL10n(language: language)
                expect(
                    probe.element("panel.workspace.edit") == nil,
                    "工作区面板不再挂载工作区设置快捷入口")
                expect(
                    !probe.containsStaticText(
                        l10n.text(.workspaceSurfaces) + ": Claude Code, Codex")
                        && !probe.containsStaticText(l10n.text(.workspacePreviewNote)),
                    "工作区面板不再常驻来源名单与试听边界")
                expect(
                    probe.valueDescription("panel.master-volume") == "40%",
                    "音量仍来自当前工作区")
                expect(probe.press("panel.settings"), "齿轮仍可打开统一设置")
                expect(
                    probe.actions.workspaceRoutes.isEmpty && probe.actions.settings == 1,
                    "齿轮使用统一设置入口，不发送工作区快捷路由")
                expect(
                    try! Data(contentsOf: configFile) == before,
                    "查看工作区设置不改写声音配置")
            }
        }
    }
    await suite("Mounted Panel state：未选包、损坏配置与失效工作区展示诚实且不可写的控件") {
        for bytes in [
            #"{"selected_pack":"","master_volume":0.7}"#,
            #"{"selected_pack":"pack-a","master_volume":"broken"}"#,
        ] {
            await withTempDirectory { root in
                seedMountedPanelFiles(root)
                writeFixture(bytes, to: root.appendingPathComponent("config.json"))
                let builder = CompositionFixture(root: root)
                defer { builder.cleanup() }
                let composition = try! builder.build()
                _ = await composition.soundPackLibrary.refreshSnapshot(trigger: .initial)
                for _ in 0..<100 { await Task.yield() }
                let probe = PanelMountedContractProbe(composition: composition, root: root)
                defer { probe.close() }
                expect(probe.element("panel.event.stop.mute") == nil, "非运行态不挂载事件写按钮")
                switch composition.eventSettingsModel.configState {
                case .needsPack:
                    let l10n = ClaudioL10n(language: composition.preferences.language)
                    expect(
                        probe.containsText(
                            l10n.text(.panelSelectPack), identifier: "panel.needs-pack")
                            && probe.containsText(
                                l10n.text(.panelNeedsPackSettingsMessage),
                                identifier: "panel.needs-pack"),
                        "未选包从生产分支显示实际空态名称与恢复指引")
                    expect(
                        probe.element("panel.master-volume")?.isAccessibilityEnabled?() == false,
                        "未选包保留音量上下文并禁用控件")
                case .malformed:
                    let l10n = ClaudioL10n(language: composition.preferences.language)
                    let category = composition.eventSettingsModel.configState.errorCopyCategory!
                    expect(
                        probe.containsText(
                            l10n.text(category.key), identifier: "panel.config-failure"),
                        "损坏配置从生产分支显示实际失败说明")
                    expect(probe.element("panel.master-volume") == nil, "损坏配置不显示可写滑块")
                    expect(
                        probe.element("panel.config-failure", role: .button)?.accessibilityLabel?()
                            == l10n.text(.panelRevealConfig)
                            && probe.press("panel.config-failure")
                            && probe.actions.revealed == [
                                root.appendingPathComponent("config.json")
                            ],
                        "真实修复按钮读回并转发当前配置位置")
                default: expect(false, "前提：真实配置加载必须产生相应非运行态")
                }
            }
        }
        await withTempDirectory { root in
            seedMountedPanelFiles(root)
            let builder = CompositionFixture(root: root)
            defer { builder.cleanup() }
            let composition = try! builder.build()
            _ = await composition.soundPackLibrary.refreshSnapshot(trigger: .initial)
            for _ in 0..<100 { await Task.yield() }
            composition.soundScopeSelection.select(.workspace(UUID()))
            let before = try! Data(contentsOf: root.appendingPathComponent("config.json"))
            let probe = PanelMountedContractProbe(composition: composition, root: root)
            defer { probe.close() }
            expect(
                probe.element("panel.master-volume")?.isAccessibilityEnabled?() == false,
                "共享失效作用域使真实挂载滑块不可写")
            expect(!probe.press("panel.event.stop.mute"), "失效目标没有可执行 AX 静音入口")
            expect(
                try! Data(contentsOf: root.appendingPathComponent("config.json")) == before,
                "不可执行 AX 入口保持真实配置字节")
        }
    }
}

@MainActor
private func seedMountedPanelFiles(_ root: URL) {
    writeFixture(
        #"{"selected_pack":"pack-a","master_volume":0.7}"#,
        to: root.appendingPathComponent("config.json"))
    writeFixture(
        #"{"id":"pack-a","events":{"task_start":"tone.mp3","stop":"tone.mp3","stop_failure":"tone.mp3","notification":"tone.mp3","subagent_stop":"tone.mp3"}}"#,
        to: root.appendingPathComponent("packs/pack-a/manifest.json"))
    writeFixture("audio", to: root.appendingPathComponent("packs/pack-a/tone.mp3"))
}

@MainActor
private final class PanelMountedActions {
    var settings = 0
    var quit = 0
    var audibility = 0
    var revealed: [URL] = []
    var workspaceRoutes: [EventSettingsWindowRoute] = []
}

@MainActor
private final class PanelMountedContractProbe {
    private static var preparedAX = false
    let actions = PanelMountedActions()
    private let window: NSWindow
    private let host: NSHostingView<PanelView>

    init(
        composition: PanelAppComposition, root: URL,
        activityDiagnostics: ActivityDiagnosticsModel? = nil
    ) {
        let actions = actions
        let panel = PanelView(
            audioEnvironment: composition.audioEnvironment,
            configFile: root.appendingPathComponent("config.json"),
            panelModel: composition.eventSettingsModel,
            previewSession: composition.manualPreview,
            soundScopeSelection: composition.soundScopeSelection,
            hostIntegrations: composition.hostIntegrations, languageStore: composition.preferences,
            activityDiagnostics: activityDiagnostics ?? composition.activityDiagnostics,
            eventNoticeModel: EventNoticeModel(receiverEpoch: UUID()),
            onAudibilityInputsChanged: { actions.audibility += 1 },
            onOpenSettings: { actions.settings += 1 },
            onEditSoundScope: { actions.workspaceRoutes.append($0) }, onOpenRecentNotices: {},
            onOpenIntegration: { _ in },
            onQuit: { actions.quit += 1 }, onRevealConfig: { actions.revealed.append($0) },
            onAnnounce: { _ in })
        SharedVolumeMountRecorder.reset()
        host = NSHostingView(rootView: panel)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 312, height: 740), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host;
        window.orderFrontRegardless()
        settle()
        if !Self.preparedAX {
            Self.preparedAX = true
            NSApp.finishLaunching()
            let completed = DispatchSemaphore(value: 0)
            let process = ProcessInfo.processInfo.processIdentifier
            DispatchQueue.global().async {
                let app = AXUIElementCreateApplication(process)
                AXUIElementSetMessagingTimeout(app, 1)
                var children: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children)
                completed.signal()
            }
            let deadline = Date().addingTimeInterval(2)
            while completed.wait(timeout: .now()) != .success && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.025))
            }
            settle()
        }
    }
    var visibleFrame: CGRect { window.convertToScreen(host.bounds) }
    func scrollToEnd() -> Bool {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for child in view.subviews { if let scroll = find(child) { return scroll } }
            return nil
        }
        guard let scroll = find(host), let document = scroll.documentView else { return false }
        let clip = scroll.contentView
        let y = document.isFlipped ? max(0, document.bounds.height - clip.bounds.height) : 0
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        settle()
        return true
    }
    var allElements: [AnyObject] {
        var found: [AnyObject] = []; var seen: Set<ObjectIdentifier> = []
        func visit(_ element: AnyObject) {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return }
            found.append(element)
            for child in element.accessibilityChildren?() ?? [] { visit(child as AnyObject) }
        }
        visit(host); return found
    }
    func element(_ id: String, role: NSAccessibility.Role? = nil) -> AnyObject? {
        let matching = allElements.filter {
            $0.accessibilityIdentifier?() == id
                && (role == nil || $0.accessibilityRole?() == role)
        }
        return matching.count == 1 ? matching[0] : nil
    }
    func containsText(_ text: String, identifier: String) -> Bool {
        allElements.contains {
            guard $0.accessibilityRole?() == .staticText,
                $0.accessibilityIdentifier?() == identifier
            else { return false }
            let value: String? = $0.accessibilityValue?()
            return value == text
        }
    }
    func containsStaticText(_ text: String) -> Bool {
        allElements.contains {
            guard $0.accessibilityRole?() == .staticText else { return false }
            let value: String? = $0.accessibilityValue?()
            return value == text
        }
    }
    func valueDescription(_ id: String) -> String? {
        if let description = element(id)?.accessibilityValueDescription?() { return description }
        let value: String? = element(id)?.accessibilityValue?()
        return value
    }
    func press(_ id: String) -> Bool {
        guard let element = element(id, role: .button), element.isAccessibilityEnabled?() != false,
            element.responds(to: #selector(NSAccessibilityButton.accessibilityPerformPress))
        else { return false }
        _ = element.accessibilityPerformPress?(); settle(); return true
    }
    func settle() {
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded();
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
    }
    func close() {
        window.orderOut(nil); window.contentView = nil; window.close();
        SharedVolumeMountRecorder.stopRecording()
    }
}
