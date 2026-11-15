import ClaudioCore
import Foundation

// MARK: - 新建组的事件默认开关（2026-11-15 拍板）
//
// 新建组只开 `stop` / `stop_failure` / `notification`；`task_start` 与 `subagent_stop` 默认关，
// 由用户自己打开。三条边界各由下面的 suite 钉住：
//   1. 只在「组刚被创建」时套用（首次装机写出的 config.json；新建工作区规则）；
//   2. 切换 / 启用声音包不得重置既有开关；
//   3. 存量文件不迁移——`events` 缺键仍读作「开」，也不被回填成完整五键。

/// 建一个能被 `selectPack` / `mutateWorkspaceSound` 认出的最小包目录。
@MainActor
private func makeDefaultSwitchPack(at url: URL, id: String) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let manifest = #"{"id":"\#(id)","name":"\#(id)","events":{}}"#
    writeFixture(manifest, to: url.appendingPathComponent("manifest.json"))
}

/// 新建组默认开关的**期望字面量**。刻意不引用 `Event.newGroupDefaultSwitches`：
/// 拿同一份实现去断言它自己等于自我循环，常量被改坏也全绿。
private let expectedNewGroupSwitches: [String: Bool] = [
    "task_start": false, "stop": true, "stop_failure": true,
    "notification": true, "subagent_stop": false,
]

@MainActor
func runNewGroupEventDefaultsSuites() {
    suite("new group defaults: the switch table is five keys, three on, two off") {
        let switches = Event.newGroupDefaultSwitches
        expect(
            switches.keys.sorted() == Event.allCases.map(\.cliName).sorted(),
            "默认表必须是完整五键，got \(switches.keys.sorted())")
        expect(switches == expectedNewGroupSwitches, "默认表三开两关，got \(switches)")
        expect(
            Event.allCases.filter(\.isOnInNewGroupByDefault).map(\.cliName).sorted()
                == ["notification", "stop", "stop_failure"],
            "默认打开的事件必须恰好是 stop/stop_failure/notification")
    }

    suite("new group defaults: a fresh config.json persists them and reads back") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            makeDefaultSwitchPack(
                at: packs.appendingPathComponent("pika", isDirectory: true), id: "pika")

            let result = selectPack(
                "pika", configFile: configFile, userPacksDirectory: packs,
                lockFile: root.appendingPathComponent("config.lock"))
            expect(result == .success(.selected(packID: "pika")), "got \(result)")

            let config = loadClaudioConfig(from: configFile)
            expect(
                config?.eventsEnabled == expectedNewGroupSwitches,
                "全新 config.json 必须落盘三开两关，got"
                    + " \(String(describing: config?.eventsEnabled))")
            expect(
                Event.allCases.filter { config?.isEnabled($0) == true }.map(\.cliName).sorted()
                    == ["notification", "stop", "stop_failure"],
                "读回后开启的仍恰好是三个默认事件")
            expect(
                config?.isEnabled(.taskStart) == false && config?.isEnabled(.subagentStop) == false,
                "task_start / subagent_stop 默认不发声")
        }
    }

    suite("new group defaults: a newly added workspace starts from the same five keys") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            for id in ["pika", "other", "third"] {
                makeDefaultSwitchPack(
                    at: packs.appendingPathComponent(id, isDirectory: true), id: id)
            }
            expect(
                selectPack(
                    "pika", configFile: configFile, userPacksDirectory: packs, lockFile: lockFile)
                    == .success(.selected(packID: "pika")),
                "fixture: fresh config")

            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.resolvingSymlinksInPath().path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "pika", volume: 0.6))
            let added = mutateWorkspaceSound(
                .add(rule), configFile: configFile, lockFile: lockFile,
                userPacksDirectory: packs)
            expect((try? added.get()) != nil, "新建工作区必须成功，got \(added)")

            expect(
                rule.profile?.events == expectedNewGroupSwitches && rule.profile?.isValid == true,
                "新建工作区的 profile 必须五键齐全且有效，got"
                    + " \(String(describing: rule.profile?.events))")
            let resolved = try! loadClaudioConfig(from: configFile)!
                .resolveWorkspaceProfile(id: rule.id).get()
            expect(
                resolved.eventsEnabled == expectedNewGroupSwitches,
                "从磁盘读回的工作区开关必须同值，got \(resolved.eventsEnabled)")
            expect(
                resolved.isEnabled(.taskStart) == false
                    && resolved.isEnabled(.subagentStop) == false
                    && resolved.isEnabled(.stop) == true,
                "工作区默认只播三个事件")
        }
    }

    suite("new group defaults: switching a pack never rewrites existing switches") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            for id in ["pika", "other"] {
                makeDefaultSwitchPack(
                    at: packs.appendingPathComponent(id, isDirectory: true), id: id)
            }
            expect(
                selectPack(
                    "pika", configFile: configFile, userPacksDirectory: packs, lockFile: lockFile)
                    == .success(.selected(packID: "pika")),
                "fixture: fresh config")

            // 默认组：用户打开了 task_start，切包必须保留这次打开。
            expect(
                setEventEnabled(
                    .taskStart, enabled: true, configFile: configFile, lockFile: lockFile)
                    == .success(.updated(event: .taskStart, enabled: true)),
                "fixture: user turns task_start on")
            let switched = selectPack(
                "other", configFile: configFile, userPacksDirectory: packs, lockFile: lockFile)
            expect(switched == .success(.selected(packID: "other")), "got \(switched)")
            expect(
                loadClaudioConfig(from: configFile)?.eventsEnabled == [
                    "task_start": true, "stop": true, "stop_failure": true,
                    "notification": true, "subagent_stop": false,
                ],
                "默认组切包后开关逐键不变，got"
                    + " \(String(describing: loadClaudioConfig(from: configFile)?.eventsEnabled))")

            // 工作区：切包同样只写 selectedPack。
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.resolvingSymlinksInPath().path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "pika", volume: 0.4))
            expect(
                (try? mutateWorkspaceSound(
                    .add(rule), configFile: configFile, lockFile: lockFile,
                    userPacksDirectory: packs
                ).get()) != nil,
                "fixture: workspace rule")
            expect(
                (try? mutateWorkspaceSound(
                    .pack(WorkspaceSoundWriteTarget(rule: rule), "other"),
                    configFile: configFile, lockFile: lockFile, userPacksDirectory: packs
                ).get()) != nil,
                "workspace pack switch succeeds")
            let repacked = loadClaudioConfig(from: configFile)?
                .workspaceRules.first?.profile
            expect(
                repacked?.events == expectedNewGroupSwitches,
                "工作区切包后开关逐键不变，got"
                    + " \(String(describing: repacked?.events))")
        }
    }

    suite("new group defaults: existing config.json files are never backfilled") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            for id in ["pika", "other"] {
                makeDefaultSwitchPack(
                    at: packs.appendingPathComponent(id, isDirectory: true), id: id)
            }
            let lockFile = root.appendingPathComponent("config.lock")

            // ① 空表必须保持空表：缺键 = 开，这条读语义不因新建默认而改变。
            let emptyFile = root.appendingPathComponent("empty/config.json")
            try! FileManager.default.createDirectory(
                at: emptyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            writeFixture(#"{"selected_pack":"pika","events":{}}"#, to: emptyFile)
            expect(
                selectPack(
                    "other", configFile: emptyFile, userPacksDirectory: packs, lockFile: lockFile)
                    == .success(.selected(packID: "other")),
                "fixture: switch pack on a legacy empty table")
            let emptyRaw =
                try! JSONSerialization.jsonObject(with: Data(contentsOf: emptyFile))
                as! [String: Any]
            expect(
                (emptyRaw["events"] as? [String: Bool])?.isEmpty == true,
                "空 events 不得被回填成五键，got"
                    + " \(String(describing: emptyRaw["events"]))")
            expect(
                loadClaudioConfig(from: emptyFile)?.isEnabled(.taskStart) == true,
                "存量缺键仍读作启用")

            // ② 稀疏表只保留用户自己动过的那一位。
            let sparseFile = root.appendingPathComponent("sparse/config.json")
            try! FileManager.default.createDirectory(
                at: sparseFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            writeFixture(
                #"{"selected_pack":"pika","events":{"stop":false}}"#, to: sparseFile)
            expect(
                setEventEnabled(
                    .notification, enabled: false, configFile: sparseFile, lockFile: lockFile)
                    == .success(.updated(event: .notification, enabled: false)),
                "fixture: mute notification on a legacy sparse table")
            let sparseRaw =
                try! JSONSerialization.jsonObject(with: Data(contentsOf: sparseFile))
                as! [String: Any]
            expect(
                (sparseRaw["events"] as? [String: Bool])
                    == ["notification": false, "stop": false],
                "稀疏表只多出用户刚动的那一位，got"
                    + " \(String(describing: sparseRaw["events"]))")
        }
    }
}
