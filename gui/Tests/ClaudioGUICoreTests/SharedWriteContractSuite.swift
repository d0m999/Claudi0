import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runSharedWriteContractSuites() async {
    await suite("Shared writes：组合根的静音、切包、音量与编辑器竞争同一把 config.lock") {
        await withTempDirectory { root in
            let builder = sharedWriteFixture(root: root)
            defer { builder.cleanup() }
            let composition = try! builder.build()
            let model = composition.eventSettingsModel
            let owner = composition.soundPacksEditorOwner
            _ = owner.send(
                .activate(
                    .events(route: EventSettingsWindowRoute(scope: .global), requestRevision: 1)))
            await waitForSoundEditorReady(owner, library: composition.soundPackLibrary)
            guard case .events(let sounds) = owner.presentation.mode,
                let use = sounds.packs.first(where: { $0.id == "pack-b" })?.useAction
            else { expect(false, "真实共享库必须签发 pack-b 使用动作"); return }
            let configFile = root.appendingPathComponent("config.json")
            let before = try! Data(contentsOf: configFile)
            let volume = model.config.masterVolume
            let holder = FileLock(path: root.appendingPathComponent("config.lock").path)
            guard holder.tryLock() else { expect(false, "前提：竞争写者取得 config.lock"); return }
            defer { holder.unlock() }
            model.toggleMute(.stop)
            expect(model.muteError == .lockBusy, "静音必须竞争 Environment 指定的锁")
            expect(model.switchPack(to: "pack-b") == .failed(.lockBusy), "切包必须竞争同一把锁")
            expect(
                model.setMasterVolume(0.2) == nil && model.masterVolumeError == .lockBusy,
                "音量不得另走无锁写入")
            guard case .accepted(let operation) = owner.send(.invoke(use)) else {
                expect(false, "编辑器必须从真实 presentation 接受动作"); return
            }
            await owner.waitForScheduledOperationExitForTesting(operation)
            expect(
                owner.presentation.activities.contains {
                    if $0.operationID == operation, case .failed = $0.phase { return true }
                    return false
                }, "编辑器使用包也必须因同一锁竞争失败")
            expect(
                try! Data(contentsOf: configFile) == before && model.config.masterVolume == volume,
                "四条拒写路径必须逐字保留配置和已发布原值")
            holder.unlock()
            expect(model.setMasterVolume(0.35) == 0.35, "释放同一锁后音量写入可落地")
            model.toggleMute(.stop)
            expect(model.muteError == nil && !model.config.isEnabled(.stop), "静音成功翻转真实文件")
            expect(model.switchPack(to: "pack-b") == .succeeded, "释放后切包写入可落地")
            let object =
                try! JSONSerialization.jsonObject(with: Data(contentsOf: configFile))
                as! [String: Any]
            expect(
                object["selected_pack"] as? String == "pack-b"
                    && (object["future"] as? [String: Bool])?["keep"] == true,
                "成功与竞争失败都保留未知配置字段")
        }
    }

    await suite("Shared writes：同 UUID 换绑目录使旧目标拒写，显式重选只授权当前目标") {
        await withTempDirectory { root in
            let id = UUID()
            let old = WorkspaceSoundRule(
                id: id,
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.appendingPathComponent("old").path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "pack-a", volume: 0.6))
            let builder = sharedWriteFixture(root: root, workspaceRules: [old])
            defer { builder.cleanup() }
            let composition = try! builder.build()
            let model = composition.eventSettingsModel
            let scope = PanelSoundScopeID.workspace(id)
            model.selectSoundScope(scope)
            let target = WorkspaceSoundWriteTarget(rule: old)
            let replacement = WorkspaceSoundRule(
                id: id,
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.appendingPathComponent("new").path),
                surfaces: old.surfaces, profile: old.profile!)
            var config = ClaudioConfig(selectedPack: "pack-a", masterVolume: 0.7)
            config.workspaceRules = [replacement]
            let file = root.appendingPathComponent("config.json")
            sharedWriteConfig(config, file: file)
            let before = try! Data(contentsOf: file)
            expect(
                model.setMasterVolume(0.1) == nil && model.workspaceError == .staleRule,
                "磁盘换绑后旧面板写目标必须拒绝")
            model.toggleMute(.stop)
            _ = model.switchPack(to: "pack-b")
            expect(try! Data(contentsOf: file) == before, "旧目标不能写新目录或默认组")
            model.reloadConfigOnly()
            model.selectSoundScope(scope, rebindSelectedWorkspace: true)
            expect(
                model.setVolume(0.15, for: scope, workspaceTarget: target) == nil,
                "重选也不能复活已经捕获的旧目录能力")
            expect(try! Data(contentsOf: file) == before, "迟到旧目标拒写逐字保持配置")
            expect(model.setMasterVolume(0.4) == 0.4, "显式重选后当前工作区可写")
            let landed = loadClaudioConfig(from: file)!
            expect(
                landed.masterVolume == 0.7 && landed.workspaceRules.first?.profile?.volume == 0.4,
                "当前工作区写入不能投到默认组")
        }
    }
}

@MainActor
private func sharedWriteFixture(root: URL, workspaceRules: [WorkspaceSoundRule] = [])
    -> CompositionFixture
{
    for id in ["pack-a", "pack-b"] {
        writeFixture(
            "{\"id\":\"\(id)\",\"name\":\"\(id)\",\"events\":{\"stop\":\"stop.mp3\"}}",
            to: root.appendingPathComponent("packs/\(id)/manifest.json"))
        writeFixture("audio", to: root.appendingPathComponent("packs/\(id)/stop.mp3"))
    }
    var config = ClaudioConfig(selectedPack: "pack-a", masterVolume: 0.7)
    config.workspaceRules = workspaceRules
    sharedWriteConfig(config, file: root.appendingPathComponent("config.json"))
    return CompositionFixture(root: root)
}

private func sharedWriteConfig(_ config: ClaudioConfig, file: URL) {
    var object =
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
    object["future"] = ["keep": true]
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
}
