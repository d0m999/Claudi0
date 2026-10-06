import Foundation

/// No fixture, build, configuration or synthetic receipt can qualify a new binding for release.
/// Each entry requires reviewed real-host, native notice and listening evidence.
/// Evidence: docs/validation/opencode-kimi-code-2026-10-06.md.
public enum AdditionalHostReleasePolicy {
    public static let verifiedBindings: Set<HostEventBindingID> = [
        HostEventBindingID(
            rawValue: "opencode:UserTurnStarted:task_start:bridge_execution_evidence_only:v1"),
        HostEventBindingID(
            rawValue: "opencode:ResponseCompleted:stop:bridge_terminal_evidence_only:v1"),
        HostEventBindingID(rawValue: "kimi-code:TurnStarted:task_start:user_origin_only:v1"),
    ]

    public static var isAcceptanceBuild: Bool {
        #if DEBUG || CLAUDIO_ADDITIONAL_HOST_ACCEPTANCE
        true
        #else
        false
        #endif
    }

    public static var visibleHosts: [HostID] {
        [.opencode, .kimiCode].filter { host in
            isAcceptanceBuild
                || HostCapabilityCatalog.bindings(for: host).contains {
                    verifiedBindings.contains($0.id)
                }
        }
    }

    public static func permits(_ binding: HostCapabilityBinding) -> Bool {
        guard binding.host == .opencode || binding.host == .kimiCode else { return true }
        return isAcceptanceBuild || verifiedBindings.contains(binding.id)
    }
}
