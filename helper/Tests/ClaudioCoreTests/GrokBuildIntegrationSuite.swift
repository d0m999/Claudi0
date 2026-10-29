import ClaudioCore
import Foundation

@MainActor
func runGrokBuildIntegrationSuites() async {
    suite("Grok Build：独立身份、五条绑定、四类公共事件和发布门槛") {
        expect(HostID(rawValue: "grok-build") == .grokBuild, "稳定 CLI HostID")
        expect(HostSurfaceID.grokBuild.rawValue == HostProductID.grokBuild.rawValue, "独立产品与来源")
        expect(HostID.grokBuild.descriptor.mechanism == .nativeHooks, "仅原生 hooks")
        let bindings = HostCapabilityCatalog.bindings(for: .grokBuild)
        expect(bindings.count == 6, "五类事件与独立提问绑定")
        let enabled = bindings.filter(\.isAudibleCapability)
        expect(enabled.count == (AdditionalHostReleasePolicy.isAcceptanceBuild ? 5 : 0), "逐绑定准入")
        expect(Set(enabled.map(\.event)).count == (enabled.isEmpty ? 0 : 4), "覆盖只按公共 Event 计数")
        expect(
            AdditionalHostReleasePolicy.verifiedBindings.isDisjoint(with: Set(bindings.map(\.id))),
            "自动证据不得开放普通 Release")
        expect(
            HostID.productVisibleCases.contains(.grokBuild)
                == AdditionalHostReleasePolicy.isAcceptanceBuild,
            "没有合格绑定时隐藏入口")
        expect(WorkspaceSurfaceEligibility.verified.contains(.grokBuild), "目录通道已验收")
        expect(
            WorkspaceSurfaceEligibility.candidates.contains(.grokBuild)
                == AdditionalHostReleasePolicy.visibleHosts.contains(.grokBuild),
            "设置页只展示当前可见来源")
        for (native, event) in [("UserPromptSubmit", Event.taskStart), ("Stop", .stop)] {
            expect(
                HostCapabilityCatalog.semanticEvent(host: .grokBuild, nativeEvent: native)
                    == (AdditionalHostReleasePolicy.isAcceptanceBuild ? event : nil),
                "开始／结束受发布准入约束：\(native)")
        }
        for native in [
            "SubagentStop", "StopCancelled", "PermissionDenied", "PostToolUseFailure",
        ] {
            expect(
                HostCapabilityCatalog.semanticEvent(host: .grokBuild, nativeEvent: native) == nil,
                "拒收 \(native)")
        }
    }

    suite("Grok Build：GROK_HOME 和 Finder 可执行发现、版本／根／绑定 scope") {
        let f = GrokBuildIntegrationFixture()
        defer { f.cleanup() }
        for value in ["", "relative", "/unsafe\nroot"] {
            expect(
                AdditionalHostPaths.configurationRoot(
                    host: .grokBuild, environment: ["GROK_HOME": value], homeDirectory: f.root
                )
                .map(\.path) == f.root.appendingPathComponent(".grok").path, "无有效绝对路径时使用默认根")
        }
        expect(
            AdditionalHostPaths.configurationRoot(
                host: .grokBuild, environment: ["GROK_HOME": f.root.path])?.path == f.root.path,
            "显式绝对根")
        let binary = f.root.appendingPathComponent(".grok/bin/grok")
        f.write(Data("#!/bin/sh\nprintf 'grok 1.0.62 (fixture)\\n'\n".utf8), to: binary)
        try! FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let locator = HostExecutableLocator.standard(
            environmentPath: "", environment: [:], homeDirectory: f.root)
        expect(locator.executablePath(command: "grok") == binary.path, "Finder 无 shell PATH 仍可发现")
        let scope = HostActivationScope.additionalHost(
            .grokBuild, configurationRoot: f.configurationRoot, executableLocator: locator)
        if AdditionalHostReleasePolicy.isAcceptanceBuild {
            expect(
                scope?.contains("grok 1.0.62") == true && scope?.contains("binding") == true,
                "版本和绑定进入 scope")
            expect(
                scope
                    != HostActivationScope.additionalHost(
                        .grokBuild, configurationRoot: f.root, executableLocator: locator),
                "配置根变化重新准备")
        } else {
            expect(scope == nil, "没有准入绑定就没有可激活 scope")
        }
        f.write(Data("#!/bin/sh\nprintf 'grok 1.0.61\\n'\n".utf8), to: binary)
        expect(
            HostActivationScope.additionalHost(
                .grokBuild, configurationRoot: f.configurationRoot, executableLocator: locator)
                == nil, "低于首个验收基线不准备")
    }

    await asyncSuite("Grok Build：普通 Release 仍能精准卸载旧候选模板") {
        for authorized in [true, false] {
            let f = GrokBuildIntegrationFixture()
            defer { f.cleanup() }
            let id = UUID()
            f.write(f.acceptanceConfiguration(id: id))
            _ = f.receipts.activate(
                host: .grokBuild, installationID: id, scopeFingerprint: f.scope.value)
            let other = f.configurationRoot.appendingPathComponent("hooks/third-party.json")
            f.write(Data("{\"hooks\":{}}\n".utf8), to: other)
            let backup = f.backupFile
            f.write(Data("retained backup".utf8), to: backup)
            let intents = HostIntegrationIntentStore(
                configFile: f.runtime.appendingPathComponent("config.json"),
                lockFile: f.runtime.appendingPathComponent("config.lock"))
            f.write(Data("{}".utf8), to: intents.configFile)
            _ = try! intents.setEnabled(surface: .grokBuild, enabled: true).get()
            let authorization = HostEventAuthorization(
                intents: intents,
                runs: HostGUIRunRegistry(
                    file: f.runtime.appendingPathComponent("gui-run.json"),
                    authorizationLockFile: intents.authorizationLockFile))
            let manager = HostIntegrationManager(
                adapters: [f.adapter], bootstrapper: GrokBuildReadyRuntime(),
                authorization: authorized ? authorization : nil)
            let result = await manager.disconnect(.grokBuild)
            expect(result.grokSucceeded, "公开 manager 卸载不受发布准入限制，authorization=\(authorized)")
            if authorized {
                expect(intents.intent(for: .grokBuild)?.enabled == false, "manager 先保存 OFF")
                expect((try? result.get())?.intent?.enabled == false, "直接返回关闭快照")
            }
            expect(!FileManager.default.fileExists(atPath: f.file.path), "只删除 exact 自有文件")
            expect(try! Data(contentsOf: other) == Data("{\"hooks\":{}}\n".utf8), "第三方文件原字节保留")
            expect(try! Data(contentsOf: backup) == Data("retained backup".utf8), "一次性备份保留")
            expect(f.receipts.currentInstallationID(host: .grokBuild) == nil, "先撤销安装代次")
            expect((await manager.disconnect(.grokBuild)).grokSucceeded, "公开卸载幂等")
            if !AdditionalHostReleasePolicy.isAcceptanceBuild {
                expect(!(await manager.connect(.grokBuild)).grokSucceeded, "Release 不安装未准入绑定")
                expect(!FileManager.default.fileExists(atPath: f.file.path), "拒收不制造空配置文件")
                expect(!(await manager.snapshots()).contains { $0.host == .grokBuild }, "卸载不暴露产品入口")
                if authorized {
                    expect(intents.intent(for: .grokBuild)?.enabled == false, "拒绝连接仍保持 OFF")
                }
            }
        }
    }

    await asyncSuite("Grok Build：宿主不可用时仍关闭，清理冲突保留原字节并撤销资格") {
        for missingConfiguration in [false, true] {
            let f = GrokBuildIntegrationFixture()
            defer { f.cleanup() }
            let id = UUID()
            let edited = f.acceptanceConfiguration(id: id) + Data(" ".utf8)
            if !missingConfiguration { f.write(edited) }
            _ = try! f.receipts.activate(
                host: .grokBuild, installationID: id, scopeFingerprint: f.scope.value
            ).get()
            let intents = HostIntegrationIntentStore(
                configFile: f.runtime.appendingPathComponent("config.json"),
                lockFile: f.runtime.appendingPathComponent("config.lock"))
            f.write(Data("{}".utf8), to: intents.configFile)
            _ = try! intents.setEnabled(surface: .grokBuild, enabled: true).get()
            let adapter = GrokBuildIntegrationAdapter(
                environment: .init(
                    host: .grokBuild, configurationRoot: f.configurationRoot,
                    claudioBinaryPath: f.helper, claudioRoot: f.runtime.path,
                    receiptStore: f.receipts, scopeFingerprint: { nil },
                    availability: { .notInstalled }))
            let manager = HostIntegrationManager(
                adapters: [adapter], bootstrapper: GrokBuildReadyRuntime(),
                authorization: .init(
                    intents: intents,
                    runs: .init(
                        file: f.runtime.appendingPathComponent("gui-run.json"),
                        authorizationLockFile: intents.authorizationLockFile)))
            let result = await manager.disconnect(.grokBuild)
            expect(intents.intent(for: .grokBuild)?.enabled == false, "宿主不可用及清理冲突不阻止 OFF")
            expect(f.receipts.currentInstallationID(host: .grokBuild) == nil, "先撤销旧代次")
            if missingConfiguration {
                expect(result.grokSucceeded, "缺失配置仍清理残留 marker")
                expect(!FileManager.default.fileExists(atPath: f.file.path), "不重建已删除配置")
            } else {
                expect(!result.grokSucceeded, "修改过的配置报告清理失败")
                expect(try! Data(contentsOf: f.file) == edited, "不删除外部修改")
            }
        }
    }

    guard AdditionalHostReleasePolicy.isAcceptanceBuild else { return }
    await asyncSuite("Grok Build：维护期间版本探测不阻塞其他来源发布或保存 OFF") {
        let f = GrokBuildIntegrationFixture()
        defer { f.cleanup() }
        let intents = HostIntegrationIntentStore(
            configFile: f.runtime.appendingPathComponent("config.json"),
            lockFile: f.runtime.appendingPathComponent("config.lock"))
        f.write(Data("{}".utf8), to: intents.configFile)
        _ = try! intents.migrate(installedSurfaces: [.codex, .opencode]).get()
        let authorization = HostEventAuthorization(
            intents: intents,
            runs: HostGUIRunRegistry(
                file: f.runtime.appendingPathComponent("gui-run.json"),
                authorizationLockFile: intents.authorizationLockFile))
        let probe = GrokBuildProbeIsolation(authorization: authorization)
        let adapter = GrokBuildIntegrationAdapter(
            environment: .init(
                host: .grokBuild, configurationRoot: f.configurationRoot,
                claudioBinaryPath: f.helper, claudioRoot: f.runtime.path,
                receiptStore: f.receipts,
                scopeFingerprint: {
                    probe.observe(); return f.scope.value
                },
                availability: {
                    probe.observe(); return .available
                }))
        let manager = HostIntegrationManager(
            adapters: [adapter], bootstrapper: GrokBuildReadyRuntime(),
            authorization: authorization, maintenanceDelay: { _ in })
        _ = await manager.startAutomaticMaintenance()
        await manager.waitForMaintenance()
        let first = f.receipts.currentInstallationID(host: .grokBuild)
        expect(first != nil, "自动准备发布安装代次")
        f.scope.value = "grok-build-upgraded-v2"
        expect((await manager.repair(.grokBuild)).grokSucceeded, "升级修复成功")
        let repaired = f.receipts.currentInstallationID(host: .grokBuild)
        expect(repaired != nil && repaired != first, "升级轮换代次")
        expect((await manager.repair(.grokBuild)).grokSucceeded, "配置未变时重复修复成功")
        expect(f.receipts.currentInstallationID(host: .grokBuild) == repaired, "重复修复保留代次")
        expect((await manager.disconnect(.grokBuild)).grokSucceeded, "关闭并清理配置")
        expect((await manager.disconnect(.grokBuild)).grokSucceeded, "缺失配置时重复关闭")
        await manager.stopAutomaticMaintenance()
        let observations = probe.observations
        expect(!observations.isEmpty, "通过实际维护路径执行版本／可用性探测")
        expect(
            observations.allSatisfy { $0.publication == .allowed },
            "每次探测期间其他来源都能发布，实际：\(observations.map(\.publication))")
        expect(observations.allSatisfy(\.savedOff), "每次探测期间其他来源都能保存 OFF")
    }

    await asyncSuite("Grok Build：最终发布前 scope 变化或保存 OFF 不激活旧安装") {
        for disable in [false, true] {
            let f = GrokBuildIntegrationFixture()
            defer { f.cleanup() }
            let intents = HostIntegrationIntentStore(
                configFile: f.runtime.appendingPathComponent("config.json"),
                lockFile: f.runtime.appendingPathComponent("config.lock"))
            f.write(Data("{}".utf8), to: intents.configFile)
            let adapter = GrokBuildIntegrationAdapter(
                environment: f.environment(beforeFinalPublish: {
                    if disable {
                        _ = intents.setEnabled(surface: .grokBuild, enabled: false)
                    } else {
                        f.scope.value = "grok-build-changed-during-publication"
                    }
                }))
            let manager = HostIntegrationManager(
                adapters: [adapter], bootstrapper: GrokBuildReadyRuntime(),
                authorization: .init(
                    intents: intents,
                    runs: .init(
                        file: f.runtime.appendingPathComponent("gui-run.json"),
                        authorizationLockFile: intents.authorizationLockFile)))
            expect(!(await manager.connect(.grokBuild)).grokSucceeded, "旧观察不能完成安装")
            expect(f.receipts.currentInstallationID(host: .grokBuild) == nil, "旧观察不发布 marker")
            if disable {
                expect(intents.intent(for: .grokBuild)?.enabled == false, "保存 OFF 优先")
                expect(!FileManager.default.fileExists(atPath: f.file.path), "旧操作不能覆盖 OFF")
            }
        }
    }

    await asyncSuite("Grok Build：当前真实回执提升来源摘要，未观察绑定仍待验证") {
        let f = GrokBuildIntegrationFixture()
        defer { f.cleanup() }
        let first = try! await f.adapter.connect(runtime: .ready).get()
        let id = first.installationID!
        let receipt = HostHookReceipt(
            installationID: id, host: .grokBuild, nativeEvent: "Notification",
            semanticEvent: .notification, timestamp: Date(), playbackResult: .muted)
        expect(
            f.receipts.store(
                receipt, expectedScopeFingerprint: f.scope.value,
                scopeFingerprint: { f.scope.value }) == .success(.written), "合法回调回执前提")
        let snapshot = await f.adapter.inspect(runtime: .ready)
        if case .observed(let evidence) = snapshot.activation {
            expect(evidence.nativeEvent == "Notification", "摘要来自已实现绑定的真实回执")
        } else {
            expect(false, "不得等待一个尚未实现的 task_start 回执")
        }
        let question = HostQuestionTrigger.grokBuild.capability
        expect(
            snapshot.activation(for: question) == .awaitingReceipt(installationID: id),
            "授权回执不能点亮提问意图")
        expect(snapshot.latestReceipt?.nativeEvent == "Notification", "脱敏最新回执单独保留")
    }
    await asyncSuite("Grok Build：发现后自动准备，关闭清理冲突仍优先 OFF，退出撤销运行资格") {
        let f = GrokBuildIntegrationFixture()
        defer { f.cleanup() }
        let intents = HostIntegrationIntentStore(
            configFile: f.runtime.appendingPathComponent("config.json"),
            lockFile: f.runtime.appendingPathComponent("config.lock"))
        f.write(Data("{}".utf8), to: intents.configFile)
        let runs = HostGUIRunRegistry(
            file: f.runtime.appendingPathComponent("gui-run.json"),
            authorizationLockFile: intents.authorizationLockFile)
        let manager = HostIntegrationManager(
            adapters: [f.adapter], bootstrapper: GrokBuildReadyRuntime(),
            authorization: .init(intents: intents, runs: runs), maintenanceDelay: { _ in })
        _ = await manager.startAutomaticMaintenance()
        await manager.waitForMaintenance()
        expect(intents.intent(for: .grokBuild)?.enabled == true, "发现后迁移为开启")
        expect(f.receipts.currentInstallationID(host: .grokBuild) != nil, "自动准备独立安装代次")
        expect(FileManager.default.fileExists(atPath: f.file.path), "自动安装原生 hooks")
        let original = try! Data(contentsOf: f.file)
        let attributes = try! FileManager.default.attributesOfItem(
            atPath: f.file.deletingLastPathComponent().path)
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "新建配置目录私有")
        let edited = original + Data(" ".utf8)
        f.write(edited)
        _ = await manager.setEnabled(surface: .grokBuild, enabled: false)
        await manager.waitForMaintenance()
        expect(intents.intent(for: .grokBuild)?.enabled == false, "清理冲突不撤回已保存 OFF")
        expect(f.receipts.currentInstallationID(host: .grokBuild) == nil, "清理冲突仍先撤销接收资格")
        expect(try! Data(contentsOf: f.file) == edited, "精确保留外部修改")
        await manager.requestMaintenance(trigger: .wake)
        await manager.waitForMaintenance()
        expect(intents.intent(for: .grokBuild)?.enabled == false, "重新发现／唤醒不复活")
        await manager.stopAutomaticMaintenance()
        expect(runs.current() == nil, "GUI 退出撤销独立运行资格")
    }
    await asyncSuite("Grok Build：安装／修复／卸载幂等及一次备份") {
        let f = GrokBuildIntegrationFixture()
        defer { f.cleanup() }
        let before = await f.adapter.inspect(runtime: .ready)
        expect(before.configuration == .notConfigured, "inspect 只读")
        expect(!FileManager.default.fileExists(atPath: f.configurationRoot.path), "inspect 不建目录")
        let first = try! await f.adapter.connect(runtime: .ready).get()
        let original = try! Data(contentsOf: f.file)
        expect(
            original == f.acceptanceConfiguration(id: first.installationID!), "五条候选绑定和 timeout=2")
        expect(first.configuration == .configured, "接入已准备")
        if case .awaitingReceipt = first.activation {} else { expect(false, "配置不制造激活") }
        let again = try! await f.adapter.connect(runtime: .ready).get()
        expect(
            again.installationID == first.installationID
                && (try! Data(contentsOf: f.file)) == original, "重复安装不变")
        f.scope.value = "grok-build-upgraded-v2"
        let repaired = try! await f.adapter.connect(runtime: .ready).get()
        expect(repaired.installationID != first.installationID, "scope 变化轮换安装代次")
        let backup = f.backupFile
        expect(try! Data(contentsOf: backup) == original, "一次备份保留准确旧配置")
        expect(
            !FileManager.default.fileExists(atPath: f.legacyBackupFile.path),
            "备份不得留在 Grok 会扫描的 hooks 目录")
        f.scope.value = "grok-build-upgraded-v3"
        _ = try! await f.adapter.connect(runtime: .ready).get()
        expect(try! Data(contentsOf: backup) == original, "再次修复不覆盖备份")
        expect((await f.adapter.disconnect(runtime: .ready)).grokSucceeded, "卸载成功")
        expect((await f.adapter.disconnect(runtime: .ready)).grokSucceeded, "重复卸载幂等")
        expect(try! Data(contentsOf: backup) == original, "运行备份属于宿主恢复合同")
    }

    await asyncSuite("Grok Build：外来、空白、修改与重复 binding 文件拒绝覆盖和删除") {
        for data in [Data(), Data("{}".utf8), Data("{\"hooks\":{\"Stop\":[]}}".utf8)] {
            let f = GrokBuildIntegrationFixture()
            defer { f.cleanup() }
            f.write(data)
            expect(!(await f.adapter.connect(runtime: .ready)).grokSucceeded, "外来同名文件拒绝覆盖")
            expect(!(await f.adapter.disconnect(runtime: .ready)).grokSucceeded, "外来同名文件拒绝删除")
            expect(try! Data(contentsOf: f.file) == data, "外来原字节保留")
        }
        for change in ["append", "remove", "duplicate"] {
            let f = GrokBuildIntegrationFixture()
            defer { f.cleanup() }
            _ = try! await f.adapter.connect(runtime: .ready).get()
            var object =
                try! JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as! [String: Any]
            var hooks = object["hooks"] as! [String: Any]
            if change == "remove" { hooks["PreToolUse"] = nil }
            if change == "duplicate", let groups = hooks["Notification"] as? [Any] {
                hooks["Notification"] = groups + groups
            }
            object["hooks"] = hooks
            var data = try! JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(contentsOf: change == "append" ? [10, 32] : [10])
            f.write(data)
            expect(!(await f.adapter.connect(runtime: .ready)).grokSucceeded, "修改后拒绝修复 \(change)")
            expect(
                !(await f.adapter.disconnect(runtime: .ready)).grokSucceeded, "修改后拒绝删除 \(change)")
            expect(f.receipts.currentInstallationID(host: .grokBuild) == nil, "清理失败也撤销资格")
            expect(try! Data(contentsOf: f.file) == data, "保留修改字节")
        }
    }

    await asyncSuite("Grok Build：符号链接与最终发布并发编辑失败关闭") {
        let f = GrokBuildIntegrationFixture()
        defer { f.cleanup() }
        let target = f.root.appendingPathComponent("foreign.json")
        f.write(Data("protected".utf8), to: target)
        try! FileManager.default.createDirectory(
            at: f.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: target)
        expect(!(await f.adapter.connect(runtime: .ready)).grokSucceeded, "符号链接不能安装")
        expect(!(await f.adapter.disconnect(runtime: .ready)).grokSucceeded, "符号链接不能卸载")
        expect(try! Data(contentsOf: target) == Data("protected".utf8), "链接目标原样保留")
        try! FileManager.default.removeItem(at: f.file)
        let environment = f.environment(beforeFinalPublish: { f.write(Data("external edit".utf8)) })
        let result = await GrokBuildIntegrationAdapter(environment: environment).connect(
            runtime: .ready)
        if case .failure(.transaction(.concurrentModification)) = result {
        } else {
            expect(false, "最终 CAS 拒绝外部修改")
        }
        expect(try! Data(contentsOf: f.file) == Data("external edit".utf8), "外部编辑优先")
        expect(f.receipts.currentInstallationID(host: .grokBuild) == nil, "冲突不发布代次")
        try! FileManager.default.removeItem(at: f.file.deletingLastPathComponent())
        let foreignDirectory = f.root.appendingPathComponent("foreign-hooks")
        f.write(
            Data("external hooks".utf8), to: foreignDirectory.appendingPathComponent("claudio.json")
        )
        try! FileManager.default.createSymbolicLink(
            at: f.file.deletingLastPathComponent(), withDestinationURL: foreignDirectory)
        expect(!(await f.adapter.connect(runtime: .ready)).grokSucceeded, "hooks 目录链接也拒绝安装")
        expect(!(await f.adapter.disconnect(runtime: .ready)).grokSucceeded, "hooks 目录链接也拒绝删除")
        expect(
            try! Data(contentsOf: foreignDirectory.appendingPathComponent("claudio.json"))
                == Data("external hooks".utf8), "不触碰目录链接目标")
    }
}

extension Result where Success == HostIntegrationSnapshot, Failure == HostIntegrationActionError {
    fileprivate var grokSucceeded: Bool { if case .success = self { return true }; return false }
}

private struct GrokBuildReadyRuntime: SharedRuntimeBootstrapping {
    func inspect() -> SharedRuntimeHealth { .ready }
    func bootstrap() -> Result<SharedRuntimeBootstrapOutcome, SetupError> {
        .success(
            .init(copiedBinary: false, copiedPacks: [], salvaged: [], packSelection: .untouched))
    }
}

private final class GrokBuildProbeIsolation: @unchecked Sendable {
    struct Observation {
        let publication: HostPublicationDecision
        let savedOff: Bool
    }
    let authorization: HostEventAuthorization
    private let lock = NSLock()
    private var recorded: [Observation] = []

    init(authorization: HostEventAuthorization) { self.authorization = authorization }

    var observations: [Observation] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func observe() {
        let token = authorization.capture(surface: .codex, requiresGUI: false)!
        let publication = HostPublicationContext(authorization: authorization, token: token)
        let decision = publication.acquire()
        publication.release()
        let on = try? authorization.intents.setEnabled(surface: .opencode, enabled: true).get()
        let off = try? authorization.intents.setEnabled(surface: .opencode, enabled: false).get()
        lock.lock(); defer { lock.unlock() }
        recorded.append(.init(publication: decision, savedOff: on != nil && off?.enabled == false))
    }
}
