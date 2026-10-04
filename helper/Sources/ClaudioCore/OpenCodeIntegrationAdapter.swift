import Foundation

public struct OpenCodeIntegrationAdapter: HostIntegrationAdapter {
    public let environment: AdditionalHostIntegrationEnvironment
    public var host: HostID { .opencode }
    public var capabilities: [HostCapabilityBinding] { HostCapabilityCatalog.bindings(for: host) }

    public init(environment: AdditionalHostIntegrationEnvironment = .init(host: .opencode)) {
        precondition(environment.host == .opencode)
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
