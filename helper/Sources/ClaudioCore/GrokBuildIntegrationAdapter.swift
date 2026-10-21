import Foundation

public struct GrokBuildIntegrationAdapter: HostIntegrationAdapter {
    public let environment: AdditionalHostIntegrationEnvironment
    public var host: HostID { .grokBuild }
    public var capabilities: [HostCapabilityBinding] { HostCapabilityCatalog.bindings(for: host) }

    public init(environment: AdditionalHostIntegrationEnvironment = .init(host: .grokBuild)) {
        precondition(environment.host == .grokBuild)
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
