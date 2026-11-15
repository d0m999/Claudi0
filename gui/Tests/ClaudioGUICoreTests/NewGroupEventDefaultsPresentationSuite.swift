import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - 新建组默认开关在界面投影里必须是三个（2026-11-15）
//
// helper 侧的 `NewGroupEventDefaultsSuite` 已经钉住落盘形状与切包不重置。这里只补用户**看得见**的
// 那一层：设置页「默认组／工作区」摘要显示的开启数，以及用户能把默认关闭的事件重新打开。
// `WorkspaceSettingsSummary.enabledEventCount` 是这条投影的唯一出口，别在视图里另算一份。

@MainActor
private func makeDefaultSwitchPack(at url: URL, id: String) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    writeFixture(
        #"{"id":"\#(id)","name":"\#(id)","events":{}}"#,
        to: url.appendingPathComponent("manifest.json"))
}

@MainActor
func runNewGroupEventDefaultsPresentationSuites() {
    suite(
        "new group defaults: the settings summary projects three enabled events for a fresh group"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            makeDefaultSwitchPack(
                at: packs.appendingPathComponent("pika", isDirectory: true), id: "pika")
            expect(
                selectPack(
                    "pika", configFile: configFile, userPacksDirectory: packs,
                    lockFile: root.appendingPathComponent("config.lock"))
                    == .success(.selected(packID: "pika")),
                "fixture: fresh config")

            let summary = WorkspaceSettingsSummary(
                scope: .global, config: loadPanelConfig(from: configFile).resolvedConfig)
            expect(
                summary?.enabledEventCount == 3,
                "新建组在界面上必须只显示三个开启事件，got"
                    + " \(String(describing: summary?.enabledEventCount))")
        }
    }

    suite("new group defaults: the workspace create form calls the explicit creation seam") {
        // `AddWorkspaceSoundRuleView` 是 private SwiftUI 视图，harness 无法 import 它来断言接线；
        // 这条跨文件契约只能用剥注释后的源码文本钉住。正向断言（不含负向）：代码被删掉会变红。
        let url = guiTestRepositoryRoot().appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/EventSettingsWindowView.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            expect(false, "读不到 EventSettingsWindowView.swift")
            return
        }
        let scanned = strippingComments(source)
        expect(
            scanned.unmodeledConstructs.isEmpty,
            "源码扫描器必须能完整建模创建表单，got \(scanned.unmodeledConstructs)")
        expect(
            scanned.code.contains(
                "profile: .newGroup(selectedPack: selectedPack, volume: volume)"),
            "新建工作区表单必须走 WorkspaceSoundProfile.newGroup 创建 seam，"
                + "不得依赖通用构造器的默认参数")
    }

    suite("new group defaults: the panel can still turn the two muted events back on") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            makeDefaultSwitchPack(
                at: packs.appendingPathComponent("pika", isDirectory: true), id: "pika")
            expect(
                selectPack(
                    "pika", configFile: configFile, userPacksDirectory: packs,
                    lockFile: root.appendingPathComponent("config.lock"))
                    == .success(.selected(packID: "pika")),
                "fixture: fresh config")

            let controller = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: AudioImportEnvironment(
                    userPacksDirectory: packs,
                    bundledPacksDirectory: nil,
                    durationProbe: StubDurationProbe(fixedDuration: 1.0),
                    packsLockFile: injectedPacksLock(besideUserPacks: packs)))
            expect(
                controller.eventRows.first(where: { $0.event == .taskStart })?.enabled == false,
                "前提：task_start 那行初始必须是关的")

            controller.toggleMute(.taskStart)

            let onDisk = loadPanelConfig(from: configFile).resolvedConfig
            expect(
                onDisk.eventsEnabled == [
                    "task_start": true, "stop": true, "stop_failure": true,
                    "notification": true, "subagent_stop": false,
                ],
                "用户打开 task_start 后必须只翻这一位、其余四键原样，got"
                    + " \(onDisk.eventsEnabled)")
            expect(
                WorkspaceSettingsSummary(scope: .global, config: onDisk)?.enabledEventCount == 4,
                "摘要必须跟着变成四个开启事件")
        }
    }
}
