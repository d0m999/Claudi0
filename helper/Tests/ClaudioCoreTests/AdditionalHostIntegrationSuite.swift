import ClaudioCore
import Foundation

@MainActor
func runAdditionalHostIntegrationSuites() async {
    suite("新增来源：独立身份、桥接事件与首版支持边界") {
        expect(HostID(rawValue: "opencode") == .opencode, "OpenCode 使用独立 HostID")
        expect(HostSurfaceID(rawValue: "kimi-code") == .kimiCode, "Kimi Code 使用独立 Surface")
        expect(HostID.opencode.descriptor.mechanism == .pluginBridge, "OpenCode 必须展示插件桥接")
        expect(AdditionalHostReleasePolicy.verifiedBindings.isEmpty, "没有真实验收证据不能进入正式启用集")
        expect(AdditionalHostReleasePolicy.isAcceptanceBuild, "harness 是隔离验收候选")
        expect(
            HostCapabilityCatalog.semanticEvent(host: .opencode, nativeEvent: "session.idle")
                == nil,
            "上游 idle 不得直接映射成完成")
        expect(
            HostCapabilityCatalog.semanticEvent(host: .opencode, nativeEvent: "ResponseCompleted")
                == .stop,
            "Claudio 桥接终态才能映射公共事件")
        for native in ["Stop", "StopFailure", "Notification", "UserPromptSubmit"] {
            expect(
                HostCapabilityCatalog.semanticEvent(host: .kimiCode, nativeEvent: native) == nil,
                "Kimi Code 未启用 \(native)")
        }
        expect(
            Set(
                HostCapabilityCatalog.bindings(for: .opencode).filter(\.isAudibleCapability)
                    .map(\.event)
            ).count == 5, "OpenCode 候选覆盖五类公共事件")
        expect(
            Set(
                HostCapabilityCatalog.bindings(for: .kimiCode).filter(\.isAudibleCapability)
                    .map(\.event)
            ).count == 3, "Kimi Code 候选只覆盖三类公共事件")
    }

    suite("新增来源：配置根与新版 kimi 安装发现") {
        withTempDirectory { root in
            let home = root.appendingPathComponent("home")
            expect(
                AdditionalHostPaths.configurationRoot(
                    host: .opencode, environment: [:],
                    homeDirectory: home)?.path
                    == home.appendingPathComponent(".config/opencode").path,
                "OpenCode 默认配置根")
            expect(
                AdditionalHostPaths.configurationRoot(
                    host: .opencode,
                    environment: ["XDG_CONFIG_HOME": root.path], homeDirectory: home)?.path
                    == root.appendingPathComponent("opencode").path, "OpenCode 尊重 XDG 配置根")
            expect(
                AdditionalHostPaths.configurationRoot(
                    host: .opencode,
                    environment: ["OPENCODE_CONFIG_DIR": root.path, "XDG_CONFIG_HOME": "/other"],
                    homeDirectory: home)?.path == root.path, "显式配置根优先")
            expect(
                AdditionalHostPaths.configurationRoot(
                    host: .kimiCode,
                    environment: ["KIMI_CODE_HOME": root.path], homeDirectory: home)?.path
                    == root.path,
                "Kimi Code 尊重独立 home")
            expect(
                AdditionalHostPaths.configurationRoot(
                    host: .kimiCode, environment: [:],
                    homeDirectory: home)?.path == home.appendingPathComponent(".kimi-code").path,
                "不得把旧 ~/.kimi 当作新版配置根")
            for host in [HostID.opencode, .kimiCode] {
                let key = host == .opencode ? "OPENCODE_CONFIG_DIR" : "KIMI_CODE_HOME"
                for path in ["relative", "", "/unsafe\nroot"] {
                    expect(
                        AdditionalHostPaths.configurationRoot(
                            host: host, environment: [key: path],
                            homeDirectory: home) == nil, "非法 override 不能静默写默认目录")
                }
            }
            let binary = home.appendingPathComponent(".kimi-code/bin/kimi")
            writeFixture("#!/bin/sh\nprintf '2.1.1\\n'\n", to: binary)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: binary.path)
            let locator = HostExecutableLocator.standard(
                environmentPath: "", environment: [:],
                homeDirectory: home)
            expect(
                locator.executablePath(command: "kimi") == binary.path,
                "Finder 启动 GUI 也能发现新版 kimi")
            let scope = HostActivationScope.additionalHost(
                .kimiCode, configurationRoot: root,
                executableLocator: locator)
            expect(
                scope?.contains("host=2.1.1") == true && scope?.contains("config=") == true,
                "作用域包含版本和配置根摘要")
            expect(scope?.contains(root.path) == false, "作用域不能保存原始配置路径")
            expect(
                scope
                    != HostActivationScope.additionalHost(
                        .kimiCode,
                        configurationRoot: home, executableLocator: locator), "配置根改变必须使旧证据失效")
            let oldBinary = home.appendingPathComponent(".local/bin/kimi")
            writeFixture("#!/bin/sh\nprintf '1.9.0\\n'\n", to: oldBinary)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: oldBinary.path)
            let coexist = HostExecutableLocator.standard(
                environmentPath: "", environment: [:], homeDirectory: home)
            expect(
                HostActivationScope.additionalHost(
                    .kimiCode, configurationRoot: root,
                    executableLocator: coexist) == scope, "旧 Kimi shim 不得遮蔽已安装的新版 CLI")
            let runtimeDirectory = root.appendingPathComponent("runtime-bin")
            let runtime = runtimeDirectory.appendingPathComponent("claudio-fixture-runtime")
            writeFixture("#!/bin/sh\nprintf '2.1.1\\n'\n", to: runtime)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: runtime.path)
            writeFixture("#!/usr/bin/env claudio-fixture-runtime\n", to: binary)
            let separateRuntime = HostExecutableLocator(
                searchDirectories: [
                    oldBinary.deletingLastPathComponent(),
                    binary.deletingLastPathComponent(), runtimeDirectory,
                ])
            expect(
                HostActivationScope.additionalHost(
                    .kimiCode, configurationRoot: root,
                    executableLocator: separateRuntime) == scope,
                "逐个探测新版 shim 时仍须保留完整运行时搜索路径")
            writeFixture("#!/bin/sh\nprintf '1.9.0\\n'\n", to: binary)
            expect(
                HostActivationScope.additionalHost(
                    .kimiCode, configurationRoot: root,
                    executableLocator: locator) == nil, "旧 Python CLI 不能冒充新版")
        }
    }

    for host in [HostID.opencode, .kimiCode] {
        await asyncSuite("\(host.displayName)：连接、重复连接、修复、断开保留第三方原字节") {
            await withAdditionalHostTempDirectory { root in
                let f = AdditionalIntegrationFixture(root: root, host: host)
                let empty = await f.adapter.inspect(runtime: .ready)
                expect(
                    empty.configuration == .notConfigured && empty.writability == .writable,
                    "可创建的配置目录属于正常未连接空态")
                expect(
                    !FileManager.default.fileExists(atPath: f.configurationRoot.path),
                    "inspect 不创建宿主配置目录")
                let original = additionalOriginal(host: host)
                let protected = f.configurationRoot.appendingPathComponent(
                    host == .opencode
                        ? "opencode.jsonc" : "config.toml")
                writeFixture(String(decoding: original, as: UTF8.self), to: protected)
                let vibe = f.configurationRoot.appendingPathComponent("plugins/vibe-island.js")
                if host == .opencode {
                    writeFixture(
                        "// Vibe Island bytes\nexport const Vibe = async () => ({});", to: vibe)
                }
                let first = try! await f.adapter.connect(runtime: .ready).get()
                expect(first.configuration == .configured, "首次连接应完整配置")
                expect(first.installationID != nil, "必须发布安装代次")
                if case .awaitingReceipt = first.activation {} else { expect(false, "配置不是激活证据") }
                let installed = try! Data(contentsOf: f.file)
                let repeated = try! await f.adapter.connect(runtime: .ready).get()
                expect(repeated.installationID == first.installationID, "重复连接复用同作用域代次")
                expect(try! Data(contentsOf: f.file) == installed, "重复连接零字节变化")
                if host == .kimiCode {
                    expect(
                        try! Data(contentsOf: f.file.appendingPathExtension("claudio.bak"))
                            == original,
                        "TOML 一次备份必须字节一致")
                    expect(
                        String(decoding: installed, as: UTF8.self).contains("timeout = 2"),
                        "自有 timeout=2")
                    expect(
                        !String(decoding: installed, as: UTF8.self).contains("event = \"Stop\""),
                        "不得安装未启用的主响应终态")
                } else {
                    expect(try! Data(contentsOf: protected) == original, "不得改写现有 JSONC")
                    expect(
                        try! String(contentsOf: vibe, encoding: .utf8)
                            == "// Vibe Island bytes\nexport const Vibe = async () => ({});",
                        "Vibe 插件原样保留")
                }
                f.scope.value = "additional-scope-v2"
                let stale = await f.adapter.inspect(runtime: .ready)
                if case .conflict = stale.configuration {} else { expect(false, "版本／配置作用域变化应失效") }
                let repaired = try! await f.adapter.connect(runtime: .ready).get()
                expect(repaired.installationID != first.installationID, "修复后必须换安装代次")
                expect(repaired.configuration == .configured, "同一写入路径完成修复")
                let disconnected = try! await f.adapter.disconnect(runtime: .ready).get()
                expect(disconnected.configuration == .notConfigured, "断开后移除自有配置")
                expect(f.receipts.currentInstallationID(host: host) == nil, "断开先撤销当前代次")
                if host == .kimiCode {
                    expect(try! Data(contentsOf: protected) == original, "断开逐字节恢复原 TOML")
                } else {
                    expect(!FileManager.default.fileExists(atPath: f.file.path), "仅删除自有插件文件")
                    expect(try! Data(contentsOf: protected) == original, "断开保持 JSONC")
                    expect(FileManager.default.fileExists(atPath: vibe.path), "断开保留 Vibe 插件")
                }
                let again = try! await f.adapter.disconnect(runtime: .ready).get()
                expect(again.configuration == .notConfigured, "重复断开幂等")
            }
        }

        await asyncSuite("\(host.displayName)：并发编辑不被覆盖，不发布新代次") {
            await withAdditionalHostTempDirectory { root in
                let f = AdditionalIntegrationFixture(root: root, host: host)
                let original = host == .kimiCode ? Data("# original\n".utf8) : nil
                if let original {
                    writeFixture(String(decoding: original, as: UTF8.self), to: f.file)
                }
                let external = host == .opencode ? "// external plugin" : "# external\n"
                let environment = f.environment(beforeFinalPublish: {
                    try! Data(external.utf8).write(to: f.file, options: .atomic)
                })
                let adapter: any HostIntegrationAdapter =
                    host == .opencode
                    ? OpenCodeIntegrationAdapter(environment: environment)
                    : KimiCodeIntegrationAdapter(environment: environment)
                if case .failure(.transaction(.concurrentModification)) = await adapter.connect(
                    runtime: .ready)
                {
                } else {
                    expect(false, "外部并发编辑应成为 CAS conflict")
                }
                expect(
                    try! String(contentsOf: f.file, encoding: .utf8) == external,
                    "必须保留外部编辑版本")
                expect(f.receipts.currentInstallationID(host: host) == nil, "冲突不得发布安装代次")
            }
        }

        await asyncSuite("\(host.displayName)：自有代码被修改时拒绝覆盖和删除") {
            await withAdditionalHostTempDirectory { root in
                let f = AdditionalIntegrationFixture(root: root, host: host)
                _ = try! await f.adapter.connect(runtime: .ready).get()
                var tampered = try! Data(contentsOf: f.file)
                tampered.append(
                    Data((host == .opencode ? "// user edit\n" : "# user edit inside block\n").utf8)
                )
                if host == .kimiCode {
                    let text = String(decoding: tampered, as: UTF8.self).replacingOccurrences(
                        of: "timeout = 2", with: "timeout = 30")
                    tampered = Data(text.utf8)
                }
                try! tampered.write(to: f.file)
                if case .failure = await f.adapter.connect(runtime: .ready) {
                } else {
                    expect(false, "修改后 connect 拒绝覆盖")
                }
                if case .failure = await f.adapter.disconnect(runtime: .ready) {
                } else {
                    expect(false, "修改后 disconnect 拒绝删除")
                }
                expect(try! Data(contentsOf: f.file) == tampered, "用户编辑保持原字节")
                expect(f.receipts.currentInstallationID(host: host) == nil, "拒绝删配置也应撤销旧回调")
            }
        }

        await asyncSuite("\(host.displayName)：断开时的并发外部编辑必须保留") {
            await withAdditionalHostTempDirectory { root in
                let f = AdditionalIntegrationFixture(root: root, host: host)
                _ = try! await f.adapter.connect(runtime: .ready).get()
                let external =
                    host == .opencode
                    ? "// external plugin survives\n" : "# external config survives\n"
                let environment = f.environment(beforeFinalPublish: {
                    try! Data(external.utf8).write(to: f.file, options: .atomic)
                })
                let adapter: any HostIntegrationAdapter =
                    host == .opencode
                    ? OpenCodeIntegrationAdapter(environment: environment)
                    : KimiCodeIntegrationAdapter(environment: environment)
                if case .failure(.transaction(.concurrentModification)) = await adapter.disconnect(
                    runtime: .ready)
                {
                } else {
                    expect(false, "断开竞争必须返回明确 conflict")
                }
                expect(
                    try! String(contentsOf: f.file, encoding: .utf8) == external,
                    "断开不得删除或覆盖新外部版本")
                expect(
                    f.receipts.currentInstallationID(host: host) == nil,
                    "竞争失败仍撤销旧回调授权")
            }
        }
    }

    await asyncSuite("Kimi Code：托管标记外的字段不能改变自有或第三方 hook") {
        await withAdditionalHostTempDirectory { root in
            for (index, suffix) in [
                "matcher = '^child$'\n",
                "# trailing edit\nmatcher = '^child$'\n[future]\nenabled = true\n",
            ].enumerated() {
                let f = AdditionalIntegrationFixture(
                    root: root.appendingPathComponent("boundary\(index)"), host: .kimiCode)
                let original = Data(
                    ("[[hooks]]\r\nevent = 'PermissionRequest'\r\n"
                        + "command = 'third-party-hook'\r\ntimeout = 30\r\n").utf8)
                writeFixture(String(decoding: original, as: UTF8.self), to: f.file)
                _ = try! await f.adapter.connect(runtime: .ready).get()
                var edited = try! Data(contentsOf: f.file)
                edited.append(Data(suffix.utf8))
                try! edited.write(to: f.file)
                let snapshot = await f.adapter.inspect(runtime: .ready)
                if case .conflict = snapshot.configuration {
                } else {
                    expect(false, "结束注释不结束 TOML 表，越界 matcher 应报告配置冲突")
                }
                f.scope.value = "additional-scope-v2"
                if case .failure(.transaction(.mutationRejected)) = await f.adapter.connect(
                    runtime: .ready)
                {
                } else {
                    expect(false, "修复必须拒绝迁移越界 matcher 到前面的第三方 hook")
                }
                expect(try! Data(contentsOf: f.file) == edited, "拒绝修复后保留配置原字节")
                if case .failure(.transaction(.mutationRejected)) = await f.adapter.disconnect(
                    runtime: .ready)
                {
                } else {
                    expect(false, "断开必须拒绝把越界 matcher 转交给第三方 hook")
                }
                expect(try! Data(contentsOf: f.file) == edited, "拒绝断开后保留配置原字节")
                expect(
                    try! Data(contentsOf: f.file.appendingPathExtension("claudio.bak"))
                        == original, "拒绝操作不改变原始第三方配置备份")
                expect(
                    f.receipts.currentInstallationID(host: .kimiCode) == nil,
                    "拒绝删除越界配置仍须撤销旧回调")
            }
        }
    }

    await asyncSuite("Kimi Code：托管块后的注释和独立表可安全修复与断开") {
        await withAdditionalHostTempDirectory { root in
            for (index, suffix) in [
                "\n# matcher = '^child$' is only a comment\n",
                "\n# separate settings\n[future]\nmatcher = '^child$'\n",
                "\n[[hooks]]\nevent = 'PermissionRequest'\n"
                    + "command = 'later-third-party-hook'\nmatcher = '^child$'\n",
            ].enumerated() {
                let f = AdditionalIntegrationFixture(
                    root: root.appendingPathComponent("safe-boundary\(index)"), host: .kimiCode)
                let original = Data(
                    ("[[hooks]]\nevent = 'PermissionRequest'\n"
                        + "command = 'first-third-party-hook'\n").utf8)
                writeFixture(String(decoding: original, as: UTF8.self), to: f.file)
                let first = try! await f.adapter.connect(runtime: .ready).get()
                var edited = try! Data(contentsOf: f.file)
                edited.append(Data(suffix.utf8))
                try! edited.write(to: f.file)
                let snapshot = await f.adapter.inspect(runtime: .ready)
                expect(snapshot.configuration == .configured, "注释或新表不扩展 Claudio hook 字段")
                f.scope.value = "additional-scope-v2"
                let repaired = try! await f.adapter.connect(runtime: .ready).get()
                expect(repaired.configuration == .configured, "独立的外部表不阻止修复")
                expect(repaired.installationID != first.installationID, "安全修复更换安装代次")
                let disconnected = try! await f.adapter.disconnect(runtime: .ready).get()
                expect(disconnected.configuration == .notConfigured, "安全断开只移除托管块")
                var retained = original
                retained.append(Data(suffix.utf8))
                expect(try! Data(contentsOf: f.file) == retained, "第三方表和注释保持全部原字节")
            }
        }
    }

    await asyncSuite("新增来源：操作锁只阻塞本来源，另一来源仍能连接") {
        await withAdditionalHostTempDirectory { root in
            let open = AdditionalIntegrationFixture(root: root, host: .opencode)
            let kimi = AdditionalIntegrationFixture(root: root, host: .kimiCode)
            let lock = FileLock(path: open.environment().operationLockFile.path)
            expect(lock.attemptLock() == .acquired, "fixture 占用 OpenCode 操作锁")
            defer { lock.unlock() }
            if case .failure(.transaction(.lockBusy)) = await open.adapter.connect(runtime: .ready)
            {
            } else {
                expect(false, "同来源竞争不等待")
            }
            let connected = try! await kimi.adapter.connect(runtime: .ready).get()
            expect(connected.configuration == .configured, "OpenCode 故障不能阻塞 Kimi")
            expect(open.receipts.currentInstallationID(host: .opencode) == nil, "锁忙不发布新代次")
        }
    }

    await asyncSuite("Kimi Code：损坏或不支持的 TOML 零写入，旧 Kimi 配置不受影响") {
        await withAdditionalHostTempDirectory { root in
            let broken = [
                "model =", "x = 1\nx = 2", "x = \"unclosed", "x = '''unclosed",
                "x = 01", "x = [1, 2", "x = { a = 1, a = 2 }", "[hooks]\nevent = 'Stop'",
                "[[hooks]]\nevent = 'Stop'\ncommand = 'other'\nasync = true",
                "[[hooks]]\nevent = 'Stop'\ncommand = 'other'\ntimeout = 0",
                "hooks = []", "[x]\na = 1\n[x]\nb = 2", "x = 2026-10-04",
                "x = 1\n[x.y]\na = 2", "a.b = 1\n[a]\nc = 2",
                "[[hooks]]\nevent = 'InventedEvent'\ncommand = 'other'",
                "# bad\u{0001}comment\nx = 1",
            ]
            for (index, text) in broken.enumerated() {
                let f = AdditionalIntegrationFixture(
                    root: root.appendingPathComponent("f\(index)"), host: .kimiCode)
                writeFixture(text, to: f.file)
                if case .failure = await f.adapter.connect(runtime: .ready) {
                } else {
                    expect(false, "损坏 TOML \(index) 应拒绝")
                }
                expect(try! String(contentsOf: f.file, encoding: .utf8) == text, "损坏 TOML 原字节保留")
                expect(f.receipts.currentInstallationID(host: .kimiCode) == nil, "损坏 TOML 不发布代次")
            }
            let f = AdditionalIntegrationFixture(
                root: root.appendingPathComponent("new"), host: .kimiCode)
            let legacy = root.appendingPathComponent(".kimi/config.toml")
            writeFixture("# legacy Kimi and Vibe Island\n", to: legacy)
            _ = try! await f.adapter.connect(runtime: .ready).get()
            _ = try! await f.adapter.disconnect(runtime: .ready).get()
            expect(
                try! String(contentsOf: legacy, encoding: .utf8)
                    == "# legacy Kimi and Vibe Island\n",
                "新版 connect/disconnect 不得触碰旧 ~/.kimi")
        }
    }

    await asyncSuite("OpenCode：外来文件、重复注册、损坏 JSONC 和符号链接均拒绝安装") {
        await withAdditionalHostTempDirectory { root in
            for (index, config) in [
                "{", "{\"plugin\":[\"./plugins/claudio.js\"]}",
                "{\"plugin\":[],\"plugin\":[]}",
            ].enumerated() {
                let f = AdditionalIntegrationFixture(
                    root: root.appendingPathComponent("json\(index)"), host: .opencode)
                let json = f.configurationRoot.appendingPathComponent("opencode.jsonc")
                writeFixture(config, to: json)
                if case .failure = await f.adapter.connect(runtime: .ready) {
                } else {
                    expect(false, "不安全 JSONC 应拒绝")
                }
                expect(try! String(contentsOf: json, encoding: .utf8) == config, "拒绝时也不改 JSONC")
                expect(!FileManager.default.fileExists(atPath: f.file.path), "拒绝时不写插件")
            }
            let f = AdditionalIntegrationFixture(
                root: root.appendingPathComponent("duplicate"), host: .opencode)
            let duplicate = f.configurationRoot.appendingPathComponent("plugins/other.js")
            writeFixture("export const id = 'claudio.opencode.v1';", to: duplicate)
            if case .failure = await f.adapter.connect(runtime: .ready) {
            } else {
                expect(false, "重复自有插件应拒绝")
            }
            let linked = AdditionalIntegrationFixture(
                root: root.appendingPathComponent("linked"), host: .opencode)
            let external = root.appendingPathComponent("foreign.js")
            writeFixture("// foreign", to: external)
            try! FileManager.default.createDirectory(
                at: linked.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! FileManager.default.createSymbolicLink(
                at: linked.file, withDestinationURL: external)
            if case .failure = await linked.adapter.connect(runtime: .ready) {
            } else {
                expect(false, "插件链接应拒绝")
            }
            expect(try! String(contentsOf: external, encoding: .utf8) == "// foreign", "不改链接目标")
        }
    }

    await asyncSuite("Kimi Code：dotfiles 符号链接保持，断开恢复目标字节") {
        await withAdditionalHostTempDirectory { root in
            let f = AdditionalIntegrationFixture(root: root, host: .kimiCode)
            let target = root.appendingPathComponent("dotfiles/kimi.toml")
            writeFixture("# dotfiles\nx = [1, {a = 'value'}]\n", to: target)
            try! FileManager.default.createDirectory(
                at: f.configurationRoot, withIntermediateDirectories: true)
            try! FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: target)
            _ = try! await f.adapter.connect(runtime: .ready).get()
            _ = try! await f.adapter.disconnect(runtime: .ready).get()
            expect(
                try! FileManager.default.destinationOfSymbolicLink(atPath: f.file.path)
                    == target.path,
                "保留 dotfiles 链接")
            expect(
                try! String(contentsOf: target, encoding: .utf8)
                    == "# dotfiles\nx = [1, {a = 'value'}]\n",
                "目标逐字节恢复")
        }
    }
}

private func additionalOriginal(host: HostID) -> Data {
    if host == .opencode {
        return Data(
            "{ // retain comment\n \"future\": {\"anything\":true},\n \"plugin\": [\"vibe-island\",],\n}\n"
                .utf8)
    }
    return Data(
        ("# 中文与未知设置\r\n[[hooks]]\r\nevent = 'PermissionRequest'\r\n"
            + "command = 'vibe-island-bridge --source kimicode'\r\ntimeout = 30\r\n"
            + "[future]\r\nextra = [1, {name = 'keep'}]\r\ntext = '''\r\n"
            + "# >>> Claudio Kimi Code hooks v1\r\nnot a real marker\r\n'''\r\nunknown = true").utf8
    )
}

private final class AdditionalScopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = "additional-scope-v1"
    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private struct AdditionalIntegrationFixture: Sendable {
    let host: HostID
    let configurationRoot: URL
    let file: URL
    let claudioRoot: URL
    let binary: URL
    let receipts: HostHookReceiptStore
    let scope = AdditionalScopeBox()

    init(root: URL, host: HostID) {
        self.host = host
        configurationRoot = root.appendingPathComponent(host.rawValue)
        file = AdditionalHostPaths.file(host: host, root: configurationRoot)
        claudioRoot = root.appendingPathComponent(".claudio")
        binary = claudioRoot.appendingPathComponent("bin/claudio")
        receipts = HostHookReceiptStore(
            receiptsRoot: claudioRoot.appendingPathComponent("receipts"),
            locksRoot: claudioRoot.appendingPathComponent("receipt-locks"),
            installationsRoot: claudioRoot.appendingPathComponent("installations"),
            installationLocksRoot: claudioRoot.appendingPathComponent("installation-locks"))
    }

    func environment(beforeFinalPublish: @escaping @Sendable () -> Void = {})
        -> AdditionalHostIntegrationEnvironment
    {
        AdditionalHostIntegrationEnvironment(
            host: host, configurationRoot: configurationRoot,
            claudioBinaryPath: binary.path, claudioRoot: claudioRoot.path, receiptStore: receipts,
            scopeFingerprint: { [scope] in scope.value }, availability: { .available },
            beforeFinalPublish: beforeFinalPublish)
    }

    var adapter: any HostIntegrationAdapter {
        host == .opencode
            ? OpenCodeIntegrationAdapter(environment: environment())
            : KimiCodeIntegrationAdapter(environment: environment())
    }
}

@MainActor
private func withAdditionalHostTempDirectory(_ body: (URL) async -> Void) async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("claudio-additional-host-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    await body(directory)
}
