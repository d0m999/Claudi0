import Darwin
import Foundation

public enum HostIntegrationActionError: Error, Sendable, Equatable, CustomStringConvertible {
    case runtimeUnavailable(reason: String)
    case hostUnavailable(reason: String)
    case configuration(reason: String)
    case transaction(ConfigFileTransactionError)
    case migrationConflict(reason: String)

    public var description: String {
        switch self {
        case .runtimeUnavailable(let reason): "claudi0 共享 runtime 不可用：\(reason)"
        case .hostUnavailable(let reason): reason
        case .configuration(let reason): reason
        case .transaction(let error): error.description
        case .migrationConflict(let reason): reason
        }
    }
}

/// UI、CLI、doctor 面向宿主配置的唯一 seam。adapter 自己拥有原生事件与 schema；调用方只看快照。
public protocol HostIntegrationAdapter: Sendable {
    var host: HostID { get }
    var descriptor: HostIntegrationDescriptor { get }
    var capabilities: [HostCapabilityBinding] { get }

    func inspect(runtime: SharedRuntimeHealth) async -> HostIntegrationSnapshot
    func connect(
        runtime: SharedRuntimeHealth
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError>
    func disconnect(
        runtime: SharedRuntimeHealth
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError>
}

extension HostIntegrationAdapter {
    public var descriptor: HostIntegrationDescriptor { host.descriptor }
}

public protocol SharedRuntimeBootstrapping: Sendable {
    func inspect() -> SharedRuntimeHealth
    func bootstrap() -> Result<SharedRuntimeBootstrapOutcome, SetupError>
    func bootstrapExecution() -> SharedRuntimeBootstrapExecution
}

extension SharedRuntimeBootstrapping {
    public func bootstrapExecution() -> SharedRuntimeBootstrapExecution {
        switch bootstrap() {
        case .success(let outcome): .completed(outcome)
        case .failure(let error):
            .failed(error: error, progress: SharedRuntimeBootstrapProgress())
        }
    }
}

/// 固定 helper 的共享事实：manager 与 doctor 都必须拒绝 symlink、目录、空存根、
/// 丢失执行位和 quarantine，避免同一路径在两个入口得到相反结论。
func inspectSharedRuntimeHelper(at helper: URL) -> SharedRuntimeHealth {
    var helperStatus = stat()
    var inspectionErrno: Int32 = 0
    let inspected = helper.withUnsafeFileSystemRepresentation { path -> Bool in
        guard let path else {
            inspectionErrno = EINVAL
            return false
        }
        guard Darwin.lstat(path, &helperStatus) == 0 else {
            inspectionErrno = errno
            return false
        }
        return true
    }
    guard inspected else {
        if inspectionErrno == ENOENT || inspectionErrno == ENOTDIR {
            return .unavailable(reason: "helper 尚未发布")
        }
        return .damaged(
            reason: "无法检查 helper：\(String(cString: strerror(inspectionErrno)))")
    }
    guard (helperStatus.st_mode & S_IFMT) == S_IFREG else {
        return .damaged(reason: "helper 不是普通文件：\(helper.path)")
    }
    guard helperStatus.st_size > 0 else {
        return .damaged(reason: "helper 是空文件：\(helper.path)")
    }
    guard FileManager.default.isExecutableFile(atPath: helper.path) else {
        return .damaged(reason: "helper 不可执行：\(helper.path)")
    }
    guard !hasQuarantineAttribute(at: helper) else {
        return .damaged(reason: "helper 被 macOS 隔离：\(helper.path)")
    }
    return .ready
}

/// A system-sound selection is understood only by the helper bundled with this app version.
/// The UI calls this immediately before a new selection so an older installed helper cannot
/// silently play the selected pack sound for that event instead.
public func installedHelperMatchesBundledRuntime(
    bundledHelper: URL?, installedHelper: URL = ClaudioPaths.claudioBinary
) -> Bool {
    guard let bundledHelper, inspectSharedRuntimeHelper(at: installedHelper) == .ready else {
        return false
    }
    return identicalRunnableHelperFiles(from: bundledHelper, to: installedHelper)
}

public struct SystemSharedRuntimeBootstrapper: SharedRuntimeBootstrapping {
    public let environment: SetupEnvironment

    public init(environment: SetupEnvironment) {
        self.environment = environment
    }

    public func inspect() -> SharedRuntimeHealth {
        let helper = environment.claudioBinaryDestination
        let helperHealth = inspectSharedRuntimeHelper(at: helper)
        guard helperHealth == .ready else { return helperHealth }
        if environment.executablePath.standardizedFileURL.path
            != helper.standardizedFileURL.path,
            !identicalRunnableHelperFiles(from: environment.executablePath, to: helper)
        {
            return .damaged(reason: "已安装 helper 与当前应用版本不一致，请修复连接")
        }
        switch checkPackIntegrity(
            configFile: environment.configFile,
            userPacksDirectory: environment.userPacksDirectory,
            bundledPacksDirectory: nil)
        {
        case .complete:
            return .ready
        case .noConfig:
            return .unavailable(reason: "尚未选择声音包")
        case .configUnreadable(let reason):
            return .damaged(reason: reason)
        case .packNotFound(let packID):
            return .damaged(reason: "当前声音包不存在：\(packID)")
        case .manifestUnreadable(let packID, let reason):
            return .damaged(reason: "声音包 \(packID) 的 manifest 无法读取：\(reason)")
        case .incomplete, .noSupportedEvents:
            // partial 声音包不是整个共享 runtime 损坏：其他事件仍可播放。
            // HostIntegrationManagerBridge 会把同一份 manifest 的逐事件 coverage
            // 交给 AudibilityMatrix，只让真正缺音的格子显示 missingSound。
            return .ready
        }
    }

    public func bootstrap() -> Result<SharedRuntimeBootstrapOutcome, SetupError> {
        performSharedRuntimeBootstrap(environment: environment)
    }

    public func bootstrapExecution() -> SharedRuntimeBootstrapExecution {
        performSharedRuntimeBootstrapExecution(environment: environment)
    }
}

/// 已发布 adapter 的唯一协调者。刷新始终返回产品可见 registry，单侧失败不会短路其他来源；
/// bootstrap 只运行共享层。
public actor HostIntegrationManager {
    private struct InFlightOperation {
        let revision: UInt64
        let state: HostOperationState
    }

    private let adapters: [HostID: any HostIntegrationAdapter]
    private let bootstrapper: any SharedRuntimeBootstrapping
    private let authorization: HostEventAuthorization?
    private let maintenanceDelay: @Sendable (TimeInterval) async -> Void
    private var runIdentity: HostGUIRunIdentity?
    private var startupInProgress = false
    private var startupFailed = false
    private var lifecycleRevision: UInt64 = 0
    private var maintenanceTasks: [HostID: Task<Void, Never>] = [:]
    private var maintenanceDirty: Set<HostID> = []
    private var failures: [HostID: HostIntegrationActionError] = [:]
    private var observers: [UUID: AsyncStream<[HostIntegrationSnapshot]>.Continuation] = [:]
    public static let automaticHosts: [HostID] = [.claudeCode, .codex, .workBuddy]

    private var runtime: SharedRuntimeHealth
    private var cachedSnapshots: [HostID: HostIntegrationSnapshot]
    private var nextOperationRevision: UInt64
    private var latestOperationRevisions: [HostID: UInt64]
    private var inFlightOperations: [HostID: InFlightOperation]
    private var latestBootstrapExecution: SharedRuntimeBootstrapExecution?

    public init(
        adapters: [any HostIntegrationAdapter],
        bootstrapper: any SharedRuntimeBootstrapping,
        authorization: HostEventAuthorization? = nil,
        maintenanceDelay: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.host, $0) })
        self.bootstrapper = bootstrapper
        self.authorization = authorization
        self.maintenanceDelay = maintenanceDelay
        self.runtime = bootstrapper.inspect()
        self.cachedSnapshots = [:]
        self.nextOperationRevision = 0
        self.latestOperationRevisions = [:]
        self.inFlightOperations = [:]
        self.latestBootstrapExecution = nil
    }

    public func capabilities() -> [HostID: [HostCapabilityBinding]] {
        Dictionary(
            uniqueKeysWithValues: HostID.productVisibleCases.map { host in
                (host, adapters[host]?.capabilities ?? HostCapabilityCatalog.bindings(for: host))
            })
    }

    public func descriptors() -> [HostIntegrationDescriptor] {
        HostID.productVisibleCases.map { adapters[$0]?.descriptor ?? $0.descriptor }
    }

    /// GUI 首启入口：只自举共享 runtime，不连接或改写任何宿主配置，然后刷新全部来源事实。
    @discardableResult
    public func bootstrapSharedRuntime() async -> [HostIntegrationSnapshot] {
        prepareSharedRuntime()
        return await refresh(usingCurrentRuntime: true)
    }

    private func prepareSharedRuntime() {
        let execution = bootstrapper.bootstrapExecution()
        latestBootstrapExecution = execution
        switch execution {
        case .completed:
            runtime = bootstrapper.inspect()
        case .failed(let error, _):
            runtime = .damaged(reason: error.description)
        }
    }

    public func refresh() async -> [HostIntegrationSnapshot] {
        runtime = bootstrapper.inspect()
        return await refresh(usingCurrentRuntime: true)
    }

    public func lastBootstrapExecution() -> SharedRuntimeBootstrapExecution? {
        latestBootstrapExecution
    }

    public func snapshots() -> [HostIntegrationSnapshot] {
        HostID.productVisibleCases.map { host in
            projected(
                cachedSnapshots[host]
                    ?? HostIntegrationSnapshot(
                        host: host,
                        runtime: runtime,
                        availability: .unavailable(reason: "尚未检测"),
                        configuration: .notConfigured,
                        writability: .unknown,
                        activation: .none,
                        operation: inFlightOperations[host]?.state ?? .idle))
        }
    }

    public func connect(
        _ host: HostID
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        if authorization != nil {
            if runtime != .ready { prepareSharedRuntime() }
            guard runtime == .ready else {
                return .failure(.runtimeUnavailable(reason: runtimeReason(runtime)))
            }
            guard
                case .success = await setEnabled(
                    surface: host.surfaceID, enabled: true, schedule: false)
            else {
                return .failure(.configuration(reason: "接入启用意愿保存失败"))
            }
            return await maintainOnce(host)
        }
        return await connect(host, repairingSharedRuntime: false)
    }

    /// An explicit repair checks the bundled helper even when the installed copy still runs.
    /// Host hooks are changed only after shared runtime repair completes successfully.
    public func repair(
        _ host: HostID
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        if let authorization {
            guard authorization.intents.intent(for: host.surfaceID)?.enabled == true else {
                return .failure(.configuration(reason: "来源已关闭；重新配置不会开启来源"))
            }
            prepareSharedRuntime()
            failures[host] = nil
            return await maintainOnce(host, force: true)
        }
        return await connect(host, repairingSharedRuntime: true)
    }

    private func connect(
        _ host: HostID,
        repairingSharedRuntime: Bool
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        if let error = productActionError(for: host) { return .failure(error) }
        let operationRevision = beginOperation(.connecting, host: host)
        if repairingSharedRuntime || runtime != .ready {
            let execution = bootstrapper.bootstrapExecution()
            latestBootstrapExecution = execution
            switch execution {
            case .completed:
                runtime = bootstrapper.inspect()
            case .failed(let error, _):
                runtime = .damaged(reason: error.description)
            }
            if runtime != .ready {
                _ = await refresh(usingCurrentRuntime: true)
                let error = HostIntegrationActionError.runtimeUnavailable(
                    reason: runtimeReason(runtime))
                recordFailure(error, host: host, revision: operationRevision)
                return .failure(error)
            }
        }
        guard let adapter = adapters[host] else {
            let error = HostIntegrationActionError.hostUnavailable(
                reason: "没有 \(host.displayName) adapter")
            recordFailure(error, host: host, revision: operationRevision)
            return .failure(error)
        }
        let operationRuntime = runtime
        let result = await adapter.connect(runtime: operationRuntime)
        switch result {
        case .success(let snapshot):
            let completed = snapshotWithOperation(snapshot, operation: .idle)
            if latestOperationRevisions[host] == operationRevision {
                inFlightOperations.removeValue(forKey: host)
                cachedSnapshots[host] = completed
            }
            return .success(completed)
        case .failure(let error):
            recordFailure(error, host: host, revision: operationRevision)
            let inspected = await adapter.inspect(runtime: runtime)
            if latestOperationRevisions[host] == operationRevision {
                cachedSnapshots[host] = snapshotWithOperation(
                    inspected, operation: .failed(reason: error.description))
            }
            return .failure(error)
        }
    }

    public func disconnect(
        _ host: HostID
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        if let error = productActionError(for: host) { return .failure(error) }
        if authorization != nil {
            guard
                case .success = await setEnabled(
                    surface: host.surfaceID, enabled: false, schedule: false)
            else {
                return .failure(.configuration(reason: "关闭意愿保存失败；来源未关闭"))
            }
            return await maintainOnce(host)
        }
        let operationRevision = beginOperation(.disconnecting, host: host)
        guard let adapter = adapters[host] else {
            let error = HostIntegrationActionError.hostUnavailable(
                reason: "没有 \(host.displayName) adapter")
            recordFailure(error, host: host, revision: operationRevision)
            return .failure(error)
        }
        let operationRuntime = runtime
        let result = await adapter.disconnect(runtime: operationRuntime)
        switch result {
        case .success(let snapshot):
            let completed = snapshotWithOperation(snapshot, operation: .idle)
            if latestOperationRevisions[host] == operationRevision {
                inFlightOperations.removeValue(forKey: host)
                cachedSnapshots[host] = completed
            }
            return .success(completed)
        case .failure(let error):
            recordFailure(error, host: host, revision: operationRevision)
            let inspected = await adapter.inspect(runtime: runtime)
            if latestOperationRevisions[host] == operationRevision {
                cachedSnapshots[host] = snapshotWithOperation(
                    inspected, operation: .failed(reason: error.description))
            }
            return .failure(error)
        }
    }

    public func snapshotStream() -> AsyncStream<[HostIntegrationSnapshot]> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.yield(snapshots())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish() { for observer in observers.values { observer.yield(snapshots()) } }

    private func projected(_ snapshot: HostIntegrationSnapshot) -> HostIntegrationSnapshot {
        guard let authorization else { return snapshot }
        var result = snapshotWithOperation(
            snapshot, operation: snapshot.operation, runtime: runtime
        )
        .projectingAuthorization(authorization)
        if let failure = failures[snapshot.host], inFlightOperations[snapshot.host] == nil {
            result = snapshotWithOperation(result, operation: .failed(reason: failure.description))
        }
        return result
    }

    /// The app, rather than a destination/window, owns this coordination lifecycle.
    public func startAutomaticMaintenance(trigger: HostMaintenanceTrigger = .startup) async
        -> [HostIntegrationSnapshot]
    {
        guard !startupInProgress else { return snapshots() }
        if runIdentity != nil { return snapshots() }
        if startupFailed, trigger == .discoveryFallback { return snapshots() }
        startupInProgress = true
        startupFailed = true
        let revision = lifecycleRevision
        defer { startupInProgress = false }
        _ = await bootstrapSharedRuntime()
        guard revision == lifecycleRevision else { return snapshots() }
        guard runtime == .ready, let authorization else { return snapshots() }
        let installed = Set(
            snapshots().filter {
                Self.automaticHosts.contains($0.host) && $0.availability == .available
            }.map { $0.host.surfaceID })
        var migration = authorization.intents.migrate(installedSurfaces: installed)
        for delay in [1.0, 3.0, 10.0] {
            guard case .failure(.transaction(.lockBusy)) = migration else { break }
            await maintenanceDelay(delay)
            guard revision == lifecycleRevision else { return snapshots() }
            migration = authorization.intents.migrate(installedSurfaces: installed)
        }
        guard case .success = migration else {
            publish()
            return snapshots()
        }
        var registration = authorization.runs.register()
        for delay in [1.0, 3.0, 10.0] {
            guard case .failure(.lockBusy) = registration else { break }
            await maintenanceDelay(delay)
            guard revision == lifecycleRevision else { return snapshots() }
            registration = authorization.runs.register()
        }
        guard case .success(let run) = registration else {
            runtime = .damaged(reason: "GUI 运行资格注册失败")
            for host in Self.automaticHosts {
                failures[host] = .runtimeUnavailable(reason: "GUI 运行资格注册失败")
            }
            publish()
            return snapshots()
        }
        runIdentity = run
        startupFailed = false
        requestMaintenance(trigger: .startup)
        publish()
        return snapshots()
    }

    public func stopAutomaticMaintenance() {
        lifecycleRevision &+= 1
        for task in maintenanceTasks.values { task.cancel() }
        maintenanceTasks.removeAll()
        maintenanceDirty.removeAll()
        if let runIdentity { _ = authorization?.runs.revoke(runID: runIdentity.runID) }
        runIdentity = nil
    }

    public func setEnabled(surface: HostSurfaceID, enabled: Bool)
        async -> Result<HostIntegrationSnapshot, HostIntegrationActionError>
    {
        if authorization == nil, let host = HostID(rawValue: surface.rawValue) {
            return enabled ? await connect(host) : await disconnect(host)
        }
        return await setEnabled(surface: surface, enabled: enabled, schedule: true)
    }

    private func setEnabled(surface: HostSurfaceID, enabled: Bool, schedule: Bool)
        async -> Result<HostIntegrationSnapshot, HostIntegrationActionError>
    {
        guard let host = HostID(rawValue: surface.rawValue),
            productActionError(for: host) == nil, let authorization, let adapter = adapters[host]
        else { return .failure(.hostUnavailable(reason: "来源不可用")) }
        if enabled {
            let fact = await adapter.inspect(runtime: runtime)
            guard fact.availability == .available else {
                return .failure(.hostUnavailable(reason: "来源未安装或版本不可用"))
            }
        }
        switch authorization.intents.setEnabled(surface: surface, enabled: enabled) {
        case .failure(let error):
            return .failure(.configuration(reason: "启用意愿保存失败：\(error)"))
        case .success:
            failures[host] = nil
            publish()
            if schedule { requestMaintenance(trigger: .intentChanged, surface: surface) }
            return .success(snapshots().first { $0.host == host }!)
        }
    }

    public func retryMaintenance(surface: HostSurfaceID) async {
        if runIdentity == nil { _ = await startAutomaticMaintenance(trigger: .userRetry) }
        if let host = HostID(rawValue: surface.rawValue) { failures[host] = nil }
        requestMaintenance(trigger: .userRetry, surface: surface)
    }

    public func requestMaintenance(trigger: HostMaintenanceTrigger, surface: HostSurfaceID? = nil) {
        guard authorization != nil, runIdentity != nil else { return }
        let hosts =
            surface.flatMap { HostID(rawValue: $0.rawValue) }.map { [$0] }
            ?? Self.automaticHosts
        for host in hosts {
            // Discovery fallback must not repeatedly retry a permanent failure. File/wake/user
            // triggers represent changed facts and may re-evaluate it.
            if trigger == .discoveryFallback, failures[host] != nil { continue }
            if trigger != .discoveryFallback { failures[host] = nil }
            maintenanceDirty.insert(host)
            guard maintenanceTasks[host] == nil else { continue }
            let delay = maintenanceDelay
            maintenanceTasks[host] = Task { [weak self] in
                await delay(0.25)
                guard !Task.isCancelled else { return }
                await self?.drainMaintenance(host)
            }
        }
    }

    public func waitForMaintenance() async {
        let pending = Array(maintenanceTasks.values)
        for task in pending { await task.value }
    }

    private func drainMaintenance(_ host: HostID) async {
        defer { maintenanceTasks[host] = nil; publish() }
        while maintenanceDirty.remove(host) != nil, !Task.isCancelled {
            runtime = bootstrapper.inspect()
            if runtime != .ready { prepareSharedRuntime() }
            guard !Task.isCancelled, authorization != nil, runIdentity != nil, runtime == .ready
            else { return }
            var result = await maintainOnce(host)
            for delay in [1, 3, 10] {
                guard case .failure(.transaction(.lockBusy)) = result else { break }
                await maintenanceDelay(TimeInterval(delay))
                guard !Task.isCancelled else { return }
                result = await maintainOnce(host)
            }
        }
    }

    private func maintainOnce(_ host: HostID, force: Bool = false)
        async -> Result<HostIntegrationSnapshot, HostIntegrationActionError>
    {
        guard let authorization, let adapter = adapters[host] else {
            return .failure(.configuration(reason: "接入意愿不可读取"))
        }
        let operationRun = runIdentity
        let capturedBeforeInspection = authorization.capture(
            surface: host.surfaceID, requiresGUI: false)
        let revisionAtStart = latestOperationRevisions[host]
        let activeAtStart = inFlightOperations[host] != nil
        // Discovery and intent migration depend only on this source, never on a full refresh.
        let inspected = await adapter.inspect(runtime: runtime)
        if !activeAtStart, latestOperationRevisions[host] == revisionAtStart {
            cachedSnapshots[host] = snapshotWithOperation(inspected, operation: .idle)
            publish()
        }
        if runtime == .ready, Self.automaticHosts.contains(host),
            inspected.availability == .available,
            authorization.intents.intent(for: host.surfaceID) == nil,
            case .failure(let error) = authorization.intents.migrate(
                installedSurfaces: [host.surfaceID])
        {
            let failure: HostIntegrationActionError
            switch error {
            case .transaction(let error): failure = .transaction(error)
            case .damaged: failure = .configuration(reason: "接入启用意愿损坏，未自动改写")
            }
            failures[host] = failure
            publish()
            return .failure(failure)
        }
        guard
            let captured = capturedBeforeInspection
                ?? authorization.capture(surface: host.surfaceID, requiresGUI: false)
        else { return .failure(.configuration(reason: "接入意愿不可读取")) }
        let token = HostEventAuthorizationToken(
            surface: captured.surface, intent: captured.intent, run: operationRun)
        if token.intent.enabled {
            guard runtime == .ready else {
                return .failure(.runtimeUnavailable(reason: runtimeReason(runtime)))
            }
            guard inspected.availability == .available else {
                cachedSnapshots[host] = inspected
                publish()
                return .success(projected(inspected))
            }
            if inspected.configuration == .configured, !force {
                cachedSnapshots[host] = inspected
                publish()
                return .success(projected(inspected))
            }
        }
        // Configuration absence does not prove that the receipt installation marker was revoked.
        // Let the adapter confirm and clear its own marker even when the host removed its hooks.
        let revision = beginOperation(
            token.intent.enabled ? .connecting : .disconnecting, host: host)
        let boundary = HostPublicationContext(authorization: authorization, token: token)
        let result = await HostPublicationContext.$current.withValue(boundary) {
            token.intent.enabled
                ? await adapter.connect(runtime: runtime)
                : await adapter.disconnect(runtime: runtime)
        }
        boundary.release()
        if latestOperationRevisions[host] == revision {
            inFlightOperations[host] = nil
            switch result {
            case .success(let snapshot): cachedSnapshots[host] = snapshot; failures[host] = nil
            case .failure(let error): failures[host] = error
            }
        }
        publish()
        return result.map(projected)
    }

    private func productActionError(for host: HostID) -> HostIntegrationActionError? {
        guard !HostID.productVisibleCases.contains(host) else { return nil }
        return .hostUnavailable(
            reason: "\(host.displayName) 仅供兼容解码和隔离诊断，不能执行产品集成动作")
    }

    private func refresh(usingCurrentRuntime: Bool) async -> [HostIntegrationSnapshot] {
        _ = usingCurrentRuntime  // 明确：调用方已经决定是否重探 runtime。
        let currentRuntime = runtime
        // Actor 在 adapter await 期间可重入。刷新若跨过一次 connect/disconnect 的开始或完成，
        // 它手里的 inspect 结果就可能比 operation cache 更旧；逐宿主 revision 防止旧刷新把
        // connecting/disconnecting/failed 或刚完成的新事实覆盖回 idle。
        let operationRevisionsAtStart = latestOperationRevisions
        let activeHostsAtStart = Set(inFlightOperations.keys)
        let availableAdapters = HostID.productVisibleCases.compactMap { adapters[$0] }
        var inspected: [HostID: HostIntegrationSnapshot] = [:]
        await withTaskGroup(of: HostIntegrationSnapshot.self) { group in
            for adapter in availableAdapters {
                group.addTask { await adapter.inspect(runtime: currentRuntime) }
            }
            for await snapshot in group { inspected[snapshot.host] = snapshot }
        }
        var refreshed: [HostID: HostIntegrationSnapshot] = [:]
        for host in HostID.productVisibleCases {
            let operationChangedWhileRefreshing =
                latestOperationRevisions[host] != operationRevisionsAtStart[host]
            if activeHostsAtStart.contains(host) || operationChangedWhileRefreshing,
                let cached = cachedSnapshots[host]
            {
                refreshed[host] = cached
                continue
            }
            let snapshot =
                inspected[host]
                ?? HostIntegrationSnapshot(
                    host: host,
                    runtime: currentRuntime,
                    availability: .unavailable(reason: "adapter 不可用"),
                    configuration: .notConfigured,
                    writability: .unknown,
                    activation: .none)
            refreshed[host] = snapshotWithOperation(snapshot, operation: .idle)
        }
        cachedSnapshots = refreshed
        publish()
        return snapshots()
    }

    private func beginOperation(
        _ operation: HostOperationState,
        host: HostID
    ) -> UInt64 {
        nextOperationRevision &+= 1
        let revision = nextOperationRevision
        latestOperationRevisions[host] = revision
        inFlightOperations[host] = InFlightOperation(revision: revision, state: operation)
        let base =
            cachedSnapshots[host]
            ?? HostIntegrationSnapshot(
                host: host,
                runtime: runtime,
                availability: .unavailable(reason: "尚未检测"),
                configuration: .notConfigured,
                writability: .unknown,
                activation: .none)
        cachedSnapshots[host] = snapshotWithOperation(base, operation: operation)
        publish()
        return revision
    }

    private func recordFailure(
        _ error: HostIntegrationActionError,
        host: HostID,
        revision: UInt64
    ) {
        guard latestOperationRevisions[host] == revision else { return }
        inFlightOperations.removeValue(forKey: host)
        let base =
            cachedSnapshots[host]
            ?? HostIntegrationSnapshot(
                host: host,
                runtime: runtime,
                availability: .unavailable(reason: "尚未检测"),
                configuration: .notConfigured,
                writability: .unknown,
                activation: .none)
        cachedSnapshots[host] = snapshotWithOperation(
            base, operation: .failed(reason: error.description))
    }
}

private func snapshotWithOperation(
    _ snapshot: HostIntegrationSnapshot,
    operation: HostOperationState,
    runtime: SharedRuntimeHealth? = nil
) -> HostIntegrationSnapshot {
    var result = HostIntegrationSnapshot(
        host: snapshot.host,
        runtime: runtime ?? snapshot.runtime,
        availability: snapshot.availability,
        configuration: snapshot.configuration,
        writability: snapshot.writability,
        authorization: snapshot.authorization,
        activation: snapshot.activation,
        bindingActivations: snapshot.bindingActivations,
        latestReceipt: snapshot.latestReceipt,
        operation: operation,
        installationID: snapshot.installationID)
    result.intent = snapshot.intent
    result.intentUnavailable = snapshot.intentUnavailable
    result.eventReceptionEligible = snapshot.eventReceptionEligible
    return result
}

private func runtimeReason(_ health: SharedRuntimeHealth) -> String {
    switch health {
    case .ready: "已就绪"
    case .unavailable(let reason), .damaged(let reason): reason
    }
}
