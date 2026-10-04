import Foundation

public struct AdditionalHostIntegrationEnvironment: Sendable {
    public let host: HostID
    public let configurationRoot: URL?
    public let claudioBinaryPath: String
    public let claudioRoot: String
    public let receiptStore: HostHookReceiptStore
    public let lockFile: URL
    public let operationLockFile: URL
    public let availability: @Sendable () -> HostAvailability
    public let scopeFingerprint: @Sendable () -> String?
    public let beforeFinalPublish: @Sendable () -> Void

    public init(
        host: HostID, configurationRoot: URL? = nil,
        claudioBinaryPath: String = ClaudioPaths.claudioBinary.path,
        claudioRoot: String = ClaudioPaths.root.path,
        receiptStore: HostHookReceiptStore = HostHookReceiptStore(
            receiptsRoot: ClaudioPaths.receiptsDirectory,
            locksRoot: ClaudioPaths.receiptLocksDirectory,
            installationsRoot: ClaudioPaths.activeInstallationsDirectory,
            installationLocksRoot: ClaudioPaths.activeInstallationLocksDirectory),
        scopeFingerprint: (@Sendable () -> String?)? = nil,
        availability: (@Sendable () -> HostAvailability)? = nil,
        beforeFinalPublish: @escaping @Sendable () -> Void = {}
    ) {
        self.host = host
        let root = configurationRoot ?? AdditionalHostPaths.currentRoot(host: host)
        self.configurationRoot = root
        self.claudioBinaryPath = claudioBinaryPath
        self.claudioRoot = claudioRoot
        self.receiptStore = receiptStore
        let locks = URL(fileURLWithPath: claudioRoot).appendingPathComponent("integrations")
        lockFile = locks.appendingPathComponent("\(host.rawValue)-config.lock")
        operationLockFile = locks.appendingPathComponent("\(host.rawValue)-operation.lock")
        let scope: @Sendable () -> String? =
            scopeFingerprint ?? {
                HostActivationScope.additionalHost(host, configurationRoot: root)
            }
        self.scopeFingerprint = scope
        self.availability =
            availability ?? {
                guard root != nil else { return .unavailable(reason: "配置根必须是有效绝对路径") }
                return scope() == nil
                    ? .unavailable(reason: "未检测到兼容的 \(host.displayName) CLI")
                    : .available
            }
        self.beforeFinalPublish = beforeFinalPublish
    }

    public var file: URL? {
        configurationRoot.map { AdditionalHostPaths.file(host: host, root: $0) }
    }
}

struct AdditionalHostIntegrationAdapter: HostIntegrationAdapter {
    let environment: AdditionalHostIntegrationEnvironment
    var host: HostID { environment.host }
    var capabilities: [HostCapabilityBinding] { HostCapabilityCatalog.bindings(for: host) }

    func inspect(runtime: SharedRuntimeHealth) async -> HostIntegrationSnapshot {
        inspectAdditionalHostSnapshot(environment: environment, runtime: runtime)
    }

    func connect(runtime: SharedRuntimeHealth)
        async -> Result<HostIntegrationSnapshot, HostIntegrationActionError>
    {
        withHostIntegrationOperationLock(path: environment.operationLockFile) {
            guard runtime == .ready else {
                return .failure(.runtimeUnavailable(reason: "共享 helper 未就绪"))
            }
            if case .unavailable(let reason) = environment.availability() {
                return .failure(.hostUnavailable(reason: reason))
            }
            guard let file = environment.file, let scope = environment.scopeFingerprint(),
                capabilities.contains(where: \.isAudibleCapability)
            else {
                return .failure(.configuration(reason: "来源尚未取得首版启用证据，或无法读取版本／配置作用域"))
            }
            do { try additionalHostPreflight(environment: environment) } catch {
                return .failure(.configuration(reason: additionalHostErrorReason(error)))
            }
            do {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
            } catch {
                return .failure(.configuration(reason: "无法创建来源配置目录，未修改配置"))
            }
            let reusable =
                environment.receiptStore.currentInstallationScopeFingerprint(host: host)
                    == scope ? environment.receiptStore.currentInstallationID(host: host) : nil
            let transaction = ConfigFileTransaction(
                file: file, lockFile: environment.lockFile,
                backupFile: file.appendingPathExtension("claudio.bak"),
                symlinkPolicy: host == .opencode ? .reject : .preserveTarget)
            let requested = UUID()
            let result = transaction.updateBytes(
                { bytes in
                    try AdditionalHostConfiguration.connect(
                        host: host, data: bytes,
                        helperPath: environment.claudioBinaryPath,
                        claudioRoot: environment.claudioRoot,
                        requestedID: requested, reusableID: reusable)
                }, beforeFinalPublish: environment.beforeFinalPublish)
            switch result {
            case .failure(let error): return .failure(.transaction(error))
            case .success(let report):
                guard environment.scopeFingerprint() == scope else {
                    return .failure(.configuration(reason: "写入期间版本／配置作用域变化，请重新检测并修复"))
                }
                if case .failure(let error) = environment.receiptStore.activate(
                    host: host,
                    installationID: report.value, scopeFingerprint: scope)
                {
                    return .failure(.configuration(reason: "当前安装代次发布失败：\(error.description)"))
                }
                return .success(
                    inspectAdditionalHostSnapshot(environment: environment, runtime: runtime))
            }
        }
    }

    func disconnect(runtime: SharedRuntimeHealth)
        async -> Result<HostIntegrationSnapshot, HostIntegrationActionError>
    {
        withHostIntegrationOperationLock(path: environment.operationLockFile) {
            // Revoke before touching native files. Edited configuration cannot keep late callbacks live.
            if let current = environment.receiptStore.currentInstallationID(host: host),
                case .failure(let error) = environment.receiptStore.deactivate(
                    host: host,
                    installationID: current)
            {
                return .failure(.configuration(reason: "安装代次撤销失败：\(error.description)"))
            }
            guard let file = environment.file,
                FileManager.default.fileExists(atPath: file.path)
                    || leafNodeIsSymbolicLink(at: file)
            else {
                return .success(
                    inspectAdditionalHostSnapshot(environment: environment, runtime: runtime))
            }
            let transaction = ConfigFileTransaction(
                file: file, lockFile: environment.lockFile,
                symlinkPolicy: host == .opencode ? .reject : .preserveTarget)
            let result = transaction.updateBytes(
                { bytes in
                    try AdditionalHostConfiguration.disconnect(
                        host: host, data: bytes,
                        helperPath: environment.claudioBinaryPath,
                        claudioRoot: environment.claudioRoot)
                }, beforeFinalPublish: environment.beforeFinalPublish)
            if case .failure(let error) = result { return .failure(.transaction(error)) }
            return .success(
                inspectAdditionalHostSnapshot(environment: environment, runtime: runtime))
        }
    }
}

public func inspectAdditionalHostSnapshot(
    environment: AdditionalHostIntegrationEnvironment,
    runtime: SharedRuntimeHealth
) -> HostIntegrationSnapshot {
    let host = environment.host
    let currentScope = environment.scopeFingerprint()
    guard let file = environment.file else {
        return HostIntegrationSnapshot(
            host: host, runtime: runtime,
            availability: .unavailable(reason: "配置根必须是有效绝对路径"),
            configuration: .unreadable(reason: "配置根无效"), writability: .unknown, activation: .none)
    }
    var configuration: HostConfigurationState = .notConfigured
    var installationID: UUID?
    do {
        try additionalHostPreflight(environment: environment)
        let data: Data?
        if leafNodeIsSymbolicLink(at: file) && host == .opencode {
            throw ConfigFileTransactionError.symlinkRejected(path: file.path)
        }
        if FileManager.default.fileExists(atPath: file.path) || leafNodeIsSymbolicLink(at: file) {
            guard
                case .success(let bytes) = readRegularFileBounded(
                    at: file, maxBytes: 1 << 20,
                    followSymlink: host == .kimiCode)
            else {
                throw ConfigFileTransactionError.readFailure(path: file.path)
            }
            data = bytes
        } else {
            data = nil
        }
        let inspection = try AdditionalHostConfiguration.inspect(
            host: host, data: data,
            helperPath: environment.claudioBinaryPath, claudioRoot: environment.claudioRoot)
        configuration = inspection.state
        installationID = inspection.installationID
    } catch { configuration = .conflict(reason: additionalHostErrorReason(error)) }
    configuration = validatedActivationConfiguration(
        host: host, configuration: configuration,
        installationID: installationID, currentScope: currentScope,
        receiptStore: environment.receiptStore)
    return makeIntegrationSnapshot(
        host: host, runtime: runtime,
        availability: environment.availability(), configuration: configuration,
        installationID: installationID, file: file, receiptStore: environment.receiptStore,
        scopeFingerprint: currentScope, writabilityOverride: additionalHostWritability(file: file))
}

private func additionalHostWritability(file: URL) -> HostConfigWritability? {
    guard !FileManager.default.fileExists(atPath: file.path), !leafNodeIsSymbolicLink(at: file)
    else { return nil }
    var parent = file.deletingLastPathComponent()
    guard !FileManager.default.fileExists(atPath: parent.path) else { return nil }
    while parent.path != "/", !FileManager.default.fileExists(atPath: parent.path) {
        parent = parent.deletingLastPathComponent()
    }
    switch probeSettingsWritable(settingsFile: parent.appendingPathComponent(".claudio-probe")) {
    case .writable: return .writable
    case .notWritable(let reason): return .notWritable(reason: reason)
    }
}

private func additionalHostErrorReason(_ error: any Error) -> String {
    (error as? ConfigFileTransactionError)?.description ?? "来源配置无法安全读取，已停止写入"
}

private func additionalHostPreflight(environment: AdditionalHostIntegrationEnvironment) throws {
    guard environment.host == .opencode, let root = environment.configurationRoot else { return }
    try OpenCodePluginRegistrationPolicy.validate(
        configurationRoot: root,
        pluginFile: AdditionalHostPaths.file(host: .opencode, root: root))
}
