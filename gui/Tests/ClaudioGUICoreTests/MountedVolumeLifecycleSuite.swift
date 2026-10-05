import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioPanelPresentation
import Foundation
import SwiftUI

@MainActor
func runMountedVolumeLifecycleSuites() async {
    await suite("Mounted volume：生产 Panel 的输入、磁盘重基、隐藏冲刷与失败回滚") {
        await withTempDirectory { root in
            writeFixture(
                #"{"selected_pack":"pack-a","master_volume":0.7}"#,
                to: root.appendingPathComponent("config.json"))
            writeFixture(
                #"{"id":"pack-a","events":{"stop":"stop.mp3"}}"#,
                to: root.appendingPathComponent("packs/pack-a/manifest.json"))
            writeFixture("audio", to: root.appendingPathComponent("packs/pack-a/stop.mp3"))
            let builder = CompositionFixture(root: root)
            defer { builder.cleanup() }
            let composition = try! builder.build()
            _ = await composition.soundPackLibrary.refreshSnapshot(trigger: .initial)
            for _ in 0..<100 { await Task.yield() }
            let probe = MountedVolumeProbe(composition: composition, root: root)
            defer { probe.close() }
            let id = "panel.master-volume"
            expect(SharedVolumeMountRecorder.draft(identifier: id) == 0.7, "挂载生产滑块读取实际初始 Binding")

            writeFixture(
                #"{"selected_pack":"pack-a","master_volume":0.3}"#,
                to: probe.configFile)
            composition.eventSettingsModel.reloadConfigOnly()
            probe.settle()
            expect(
                SharedVolumeMountRecorder.draft(identifier: id) == 0.3,
                "外部磁盘重读必须通过真实 onChange 重基已挂载滑块")
            expect(probe.records.volumes.isEmpty, "外部重基不能反写或触发可听性更新")
            expect(SharedVolumeMountRecorder.setValue(0.4, identifier: id), "挂载滑块的非拖动输入可投递")
            expect(
                probe.diskVolume == 0.4 && probe.records.volumes == [0.4],
                "真实 Panel onCommit 先落盘，再调用共享可听性回调")
            probe.settle()

            expect(SharedVolumeMountRecorder.edit(true, identifier: id), "开始真实 Slider 编辑回调")
            _ = SharedVolumeMountRecorder.setValue(0.6, identifier: id)
            _ = SharedVolumeMountRecorder.setValue(0.7, identifier: id)
            expect(probe.diskVolume == 0.4 && probe.records.volumes == [0.4], "拖动草稿不得逐次写盘")
            probe.focus.notePanelHidden()
            probe.settle()
            expect(
                probe.diskVolume == 0.7 && probe.records.volumes == [0.4, 0.7],
                "生产 MasterVolumeRow 借用 hideCount，使一次隐藏只冲刷一次")
            _ = SharedVolumeMountRecorder.edit(false, identifier: id)
            expect(probe.records.volumes.count == 2, "隐藏后的编辑结束不能重复写入")

            let holder = FileLock(path: root.appendingPathComponent("config.lock").path)
            guard holder.tryLock() else { expect(false, "前提：取得同一配置锁"); return }
            defer { holder.unlock() }
            _ = SharedVolumeMountRecorder.edit(true, identifier: id)
            _ = SharedVolumeMountRecorder.setValue(0.2, identifier: id)
            NotificationCenter.default.post(
                name: NSApplication.willTerminateNotification, object: NSApp)
            expect(
                probe.diskVolume == 0.7 && SharedVolumeMountRecorder.draft(identifier: id) == 0.7,
                "终止通知的真实订阅必须同步尝试写入，并按 nil 回滚 Binding")
            expect(probe.records.volumes == [0.4, 0.7, 0.7], "失败后回调读取原磁盘值，顺序不能提前")
            holder.unlock()
            probe.settle()
            _ = SharedVolumeMountRecorder.edit(true, identifier: id)
            _ = SharedVolumeMountRecorder.setValue(0.35, identifier: id)
            NotificationCenter.default.post(
                name: NSApplication.willTerminateNotification, object: NSApp)
            expect(
                probe.diskVolume == 0.35 && probe.records.volumes.last == 0.35,
                "终止成功必须在 post 返回前落盘，无需隐藏计数器或下一帧")
            expect(
                SharedVolumeMountRecorder.draft(identifier: id) == 0.35,
                "终止成功的已挂载 Binding 保留真实 landed 值")
        }
    }
}

@MainActor
private final class MountedVolumeRecords {
    var volumes: [Double] = []
}

@MainActor
private final class MountedVolumeProbe {
    let focus = PanelFocusCoordinator()
    let configFile: URL
    let records = MountedVolumeRecords()
    private let window: NSWindow
    private let host: NSHostingView<PanelView>
    var diskVolume: Double? { loadClaudioConfig(from: configFile)?.masterVolume }

    init(composition: PanelAppComposition, root: URL) {
        configFile = root.appendingPathComponent("config.json")
        let file = configFile
        let records = records
        let panel = PanelView(
            audioEnvironment: composition.audioEnvironment, configFile: configFile,
            panelModel: composition.eventSettingsModel,
            soundScopeSelection: composition.soundScopeSelection,
            focusCoordinator: focus, hostIntegrations: composition.hostIntegrations,
            languageStore: composition.preferences,
            activityDiagnostics: composition.activityDiagnostics,
            eventNoticeModel: EventNoticeModel(receiverEpoch: UUID()),
            onAudibilityInputsChanged: {
                records.volumes.append(loadClaudioConfig(from: file)!.masterVolume)
            },
            onOpenSettings: {}, onOpenRecentNotices: {}, onOpenIntegration: { _ in },
            onQuit: {}, onRevealConfig: { _ in }, onAnnounce: { _ in })
        SharedVolumeMountRecorder.reset()
        host = NSHostingView(rootView: panel)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 312, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        settle()
    }
    func settle() {
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
    }
    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        SharedVolumeMountRecorder.stopRecording()
    }
}
