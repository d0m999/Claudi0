import ClaudioCore
import ClaudioGUICore
import Foundation

/// C1：`SoundScopeSelection` 是声音作用域选择的**单一 app 生命周期事实**。这些编译型断言钉死：
/// 首次解析不持久化、显式选择持久化并钉定写目标、规则删除保留 typed identity 且失败关闭、
/// 目录换绑表现为 staleRule（config 重读绝不自动重钉）、显式重选重钉、profile 损坏表现为
/// invalidRule、快捷键路由的 stale / 未知 / 未选择三分支、Surface 选择不持久化，以及注入
/// `PanelConfigController` 后两个读取面看到同一份投影。
@MainActor
func runSoundScopeSelectionSuites() {
    func makeRule(
        id: UUID,
        path: String,
        profile: WorkspaceSoundProfile? = WorkspaceSoundProfile(
            selectedPack: "pack-a", volume: 0.7)
    ) -> WorkspaceSoundRule {
        var rule = WorkspaceSoundRule(
            id: id,
            directory: WorkspaceDirectory(kind: .directory, path: path),
            surfaces: [.claudeCode],
            profile: profile ?? WorkspaceSoundProfile(selectedPack: "pack-a", volume: 0.7))
        if profile == nil { rule.profile = nil }
        return rule
    }

    func makeConfig(rules: [WorkspaceSoundRule]) -> ClaudioConfig {
        var config = ClaudioConfig(
            selectedPack: "pack-a",
            masterVolume: 0.8,
            eventsEnabled: Dictionary(
                uniqueKeysWithValues: Event.allCases.map { ($0.cliName, true) }))
        config.workspaceRules = rules
        return config
    }

    suite("C1 选择 owner：首启动显示默认组且绝不落盘，垃圾值规范化回 global") {
        let defaults = SoundScopeSelectionFixtureDefaults()
        let workspaceID = UUID()
        let selection = SoundScopeSelection(defaults: defaults)
        selection.applyConfig(makeConfig(rules: [makeRule(id: workspaceID, path: "/tmp/c1-a")]))
        expect(
            selection.projection.scope == .global
                && defaults.string(forKey: panelSoundScopeDefaultsKey) == nil,
            "nil 持久值必须解析为默认组，且 pending 首择绝不写盘")
        expect(
            selection.projection.staleness == .current && selection.projection.isAvailable,
            "默认组投影必须 current 且可用")

        let unselectedDefaults = SoundScopeSelectionFixtureDefaults()
        unselectedDefaults.set("unselected", forKey: panelSoundScopeDefaultsKey)
        let unselected = SoundScopeSelection(defaults: unselectedDefaults)
        unselected.applyConfig(makeConfig(rules: []))
        expect(
            unselected.projection.scope == .global
                && unselectedDefaults.string(forKey: panelSoundScopeDefaultsKey) == "unselected",
            "`unselected` 同样只显示默认组；它不是选择事实，owner 不得改写也不得删除它")

        let garbageDefaults = SoundScopeSelectionFixtureDefaults()
        garbageDefaults.set("sounds", forKey: panelSoundScopeDefaultsKey)
        let garbage = SoundScopeSelection(defaults: garbageDefaults)
        garbage.applyConfig(makeConfig(rules: []))
        expect(
            garbage.projection.scope == .global
                && garbageDefaults.string(forKey: panelSoundScopeDefaultsKey) == "global",
            "无法解析的垃圾持久值必须在 applyConfig 时规范化回 global")
    }

    suite("C1 选择 owner：显式选择持久化并钉定写目标，失效形态逐个失败关闭") {
        let defaults = SoundScopeSelectionFixtureDefaults()
        let workspaceID = UUID()
        let selection = SoundScopeSelection(defaults: defaults)
        selection.applyConfig(makeConfig(rules: [makeRule(id: workspaceID, path: "/tmp/c1-pin")]))

        selection.select(.workspace(workspaceID))
        expect(
            defaults.string(forKey: panelSoundScopeDefaultsKey)
                == "workspace:\(workspaceID.uuidString)",
            "显式选择可用工作区必须持久化 typed stored value")
        expect(
            selection.projection.writeTarget
                == WorkspaceSoundWriteTarget(
                    id: workspaceID,
                    directory: WorkspaceDirectory(kind: .directory, path: "/tmp/c1-pin"))
                && selection.projection.staleness == .current
                && selection.projection.isAvailable,
            "选择必须钉定当时的写目标并投影为 current")

        // 规则删除：typed identity 保留、持久字节保留、staleness 翻转 —— 绝不回落默认组。
        selection.applyConfig(makeConfig(rules: []))
        expect(
            selection.projection.scope == .workspace(workspaceID)
                && defaults.string(forKey: panelSoundScopeDefaultsKey)
                    == "workspace:\(workspaceID.uuidString)",
            "规则删除后 typed identity 与持久字节都必须原样保留")
        expect(
            selection.projection.staleness == .staleRule && !selection.projection.isAvailable
                && selection.projection.writeTarget != nil,
            "规则删除必须失败关闭为 staleRule，且已钉目标不得被悄悄抹掉")

        // 目录换绑：规则以同一 UUID 指向新目录 —— config 重读不得自动重钉。
        selection.applyConfig(
            makeConfig(rules: [makeRule(id: workspaceID, path: "/tmp/c1-rebound")]))
        expect(
            selection.projection.staleness == .staleRule
                && selection.projection.writeTarget?.directory
                    == WorkspaceDirectory(kind: .directory, path: "/tmp/c1-pin"),
            "目录换绑必须保持旧钉定目标并停在校验失败，绝不经 reload 静默跟随")

        // 显式重选是唯一的重钉通道。
        selection.select(.workspace(workspaceID))
        expect(
            selection.projection.staleness == .current
                && selection.projection.writeTarget?.directory
                    == WorkspaceDirectory(kind: .directory, path: "/tmp/c1-rebound"),
            "显式重选必须重钉到当前目录并恢复 current")

        // profile 损坏：规则还在、目录一致，但 profile 无效。
        let brokenID = UUID()
        let brokenDefaults = SoundScopeSelectionFixtureDefaults()
        let broken = SoundScopeSelection(defaults: brokenDefaults)
        broken.applyConfig(
            makeConfig(rules: [makeRule(id: brokenID, path: "/tmp/c1-broken", profile: nil)]))
        broken.select(.workspace(brokenID))
        expect(
            broken.projection.staleness == .invalidRule,
            "profile 损坏的工作区必须投影为 invalidRule（与 controller 的判定顺序一致）")

        // 未知工作区：不持久化，但投影照移并失败关闭。
        let unknownID = UUID()
        selection.select(.workspace(unknownID))
        expect(
            selection.projection.scope == .workspace(unknownID)
                && selection.projection.staleness == .staleRule
                && selection.projection.writeTarget == nil
                && defaults.string(forKey: panelSoundScopeDefaultsKey)
                    == "workspace:\(workspaceID.uuidString)",
            "未知工作区不得持久化；投影照移并以 staleRule 失败关闭")

        // 显式选回默认组必须持久化 global。
        selection.select(.global)
        expect(
            defaults.string(forKey: panelSoundScopeDefaultsKey) == "global"
                && selection.projection.writeTarget == nil,
            "显式选择默认组必须持久化 global 并清空写目标")
    }

    suite("C1 选择 owner：Surface 选择不持久化，快捷键路由三分支保留失败原因") {
        let defaults = SoundScopeSelectionFixtureDefaults()
        let workspaceID = UUID()
        let selection = SoundScopeSelection(defaults: defaults)
        selection.applyConfig(makeConfig(rules: [makeRule(id: workspaceID, path: "/tmp/c1-route")]))

        selection.select(.surface(.workBuddy))
        expect(
            selection.projection.scope == .surface(.workBuddy)
                && defaults.string(forKey: panelSoundScopeDefaultsKey) == nil,
            "Surface 选择只移投影，绝不写持久字节")

        let fresh = SoundScopeSelection(defaults: defaults)
        fresh.applyConfig(makeConfig(rules: [makeRule(id: workspaceID, path: "/tmp/c1-route")]))
        expect(
            fresh.shortcutRoute() == EventSettingsWindowRoute(scope: .global),
            "未选择时快捷键必须路由到默认组，且不挂恢复原因")

        defaults.set("workspace:\(workspaceID.uuidString)", forKey: panelSoundScopeDefaultsKey)
        expect(
            fresh.shortcutRoute() == EventSettingsWindowRoute(scope: .workspace(workspaceID)),
            "可用工作区的持久字节必须路由 typed scope，不挂恢复原因")

        let staleDefaults = SoundScopeSelectionFixtureDefaults()
        staleDefaults.set("workspace:\(workspaceID.uuidString)", forKey: panelSoundScopeDefaultsKey)
        let stale = SoundScopeSelection(defaults: staleDefaults)
        stale.applyConfig(makeConfig(rules: []))
        expect(
            stale.shortcutRoute()
                == EventSettingsWindowRoute(
                    scope: .workspace(workspaceID),
                    unavailableRequestedScopeStoredValue: "workspace:\(workspaceID.uuidString)"),
            "stale 的已知工作区必须原样保留 typed route 与恢复原因，不得静默猜另一个目标")

        let unknownDefaults = SoundScopeSelectionFixtureDefaults()
        unknownDefaults.set("sounds", forKey: panelSoundScopeDefaultsKey)
        let unknown = SoundScopeSelection(defaults: unknownDefaults)
        expect(
            unknown.shortcutRoute()
                == EventSettingsWindowRoute(
                    scope: .global, unavailableRequestedScopeStoredValue: "sounds"),
            "无法 typed 化的未知持久值必须把原始字节挂在一个不可写的 Global 路由旁")
        unknown.applyConfig(makeConfig(rules: []))
        expect(
            unknownDefaults.string(forKey: panelSoundScopeDefaultsKey) == "global"
                && unknown.shortcutRoute() == EventSettingsWindowRoute(scope: .global),
            "applyConfig 把垃圾字节规范化回 global 之后，快捷键路由不再携带已消灭的恢复原因")

        let surfaceDefaults = SoundScopeSelectionFixtureDefaults()
        surfaceDefaults.set(
            HostSurfaceID.workBuddy.rawValue, forKey: panelSoundScopeDefaultsKey)
        let surface = SoundScopeSelection(defaults: surfaceDefaults)
        expect(
            surface.shortcutRoute()
                == EventSettingsWindowRoute(
                    scope: .surface(.workBuddy),
                    unavailableRequestedScopeStoredValue: HostSurfaceID.workBuddy.rawValue),
            "已知 Surface 身份即使不可用也必须保留 typed route 与恢复原因")
    }

    suite("C1 选择 owner：fixture defaults 结构隔离，默认 owner 绝不碰 .standard") {
        let first = SoundScopeSelectionFixtureDefaults()
        let second = SoundScopeSelectionFixtureDefaults()
        first.set("global", forKey: panelSoundScopeDefaultsKey)
        expect(
            second.string(forKey: panelSoundScopeDefaultsKey) == nil,
            "两个 fixture defaults 必须互不共享（测试之间不能经持久域串扰）")

        let before = UserDefaults.standard.string(forKey: panelSoundScopeDefaultsKey)
        let isolated = SoundScopeSelection(defaults: first)
        isolated.applyConfig(makeConfig(rules: [makeRule(id: UUID(), path: "/tmp/c1-isolated")]))
        isolated.select(.workspace(UUID()))
        isolated.select(.global)
        expect(
            UserDefaults.standard.string(forKey: panelSoundScopeDefaultsKey) == before,
            "fixture owner 的任何选择都不得写入真实用户面板选择")
    }

    suite("C1 注入：controller 与 owner 是同一份投影，目录换绑失败关闭后显式重钉恢复") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let configLock = root.appendingPathComponent("config.lock")
            let workspaceID = UUID()
            try! JSONEncoder().encode(makeConfig(rules: [
                makeRule(id: workspaceID, path: "/tmp/c1-injected")
            ])).write(to: configFile)
            let defaults = SoundScopeSelectionFixtureDefaults()
            let owner = SoundScopeSelection(defaults: defaults)
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let controller = PanelConfigController(
                configFile: configFile,
                lockFile: configLock,
                environment: environment,
                soundScopeSelection: owner)

            expect(
                controller.soundScopeSelection === owner
                    && controller.selectedSoundScope == owner.projection.scope,
                "controller 必须持有注入的同一个 owner，selectedSoundScope 只是它的派生读取")

            controller.selectSoundScope(.workspace(workspaceID))
            expect(
                defaults.string(forKey: panelSoundScopeDefaultsKey)
                    == "workspace:\(workspaceID.uuidString)"
                    && controller.selectedWorkspaceTarget?.directory
                        == WorkspaceDirectory(kind: .directory, path: "/tmp/c1-injected"),
                "经 controller 的显式选择必须委托 owner 持久化并钉定写目标")

            // 目录换绑：重读不得自动重钉，工作区写入失败关闭。
            try! JSONEncoder().encode(makeConfig(rules: [
                makeRule(id: workspaceID, path: "/tmp/c1-injected-elsewhere")
            ])).write(to: configFile)
            controller.reloadConfigOnly()
            expect(
                controller.workspaceError == .staleRule
                    && controller.selectedWorkspaceTarget?.directory
                        == WorkspaceDirectory(kind: .directory, path: "/tmp/c1-injected")
                    && owner.projection.staleness == .staleRule,
                "目录换绑后 reload 必须保持旧钉定目标并 staleRule 失败关闭")

            // 承重墙：同一 scope 的非 rebind 选择是 no-op，不得趁机重钉。
            controller.selectSoundScope(.workspace(workspaceID))
            expect(
                controller.workspaceError == .staleRule
                    && controller.selectedWorkspaceTarget?.directory
                        == WorkspaceDirectory(kind: .directory, path: "/tmp/c1-injected"),
                "no-op 守卫必须挡住「同一 scope 的普通选择」，防止延迟动作静默改写目标")

            controller.selectSoundScope(.workspace(workspaceID), rebindSelectedWorkspace: true)
            expect(
                controller.workspaceError == nil
                    && controller.selectedWorkspaceTarget?.directory
                        == WorkspaceDirectory(kind: .directory, path: "/tmp/c1-injected-elsewhere")
                    && owner.projection.staleness == .current,
                "显式 rebind 必须重读、重钉到当前目录并恢复可写")
        }
    }
}
