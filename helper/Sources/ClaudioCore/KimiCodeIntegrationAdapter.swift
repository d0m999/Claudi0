import Foundation

public struct KimiCodeIntegrationAdapter: HostIntegrationAdapter {
    public let environment: AdditionalHostIntegrationEnvironment
    public var host: HostID { .kimiCode }
    public var capabilities: [HostCapabilityBinding] { HostCapabilityCatalog.bindings(for: host) }

    public init(environment: AdditionalHostIntegrationEnvironment = .init(host: .kimiCode)) {
        precondition(environment.host == .kimiCode)
        self.environment = environment
    }

    public func inspect(runtime: SharedRuntimeHealth) async -> HostIntegrationSnapshot {
        inspectAdditionalHostSnapshot(environment: environment, runtime: runtime)
    }

    public func connect(runtime: SharedRuntimeHealth)
        async -> Result<HostIntegrationSnapshot, HostIntegrationActionError>
    {
        await AdditionalHostIntegrationAdapter(environment: environment).connect(runtime: runtime)
    }

    public func disconnect(runtime: SharedRuntimeHealth)
        async -> Result<HostIntegrationSnapshot, HostIntegrationActionError>
    {
        await AdditionalHostIntegrationAdapter(environment: environment).disconnect(
            runtime: runtime)
    }
}
