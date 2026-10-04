import Foundation

/// No fixture, build, configuration or synthetic receipt can qualify a new binding for release.
/// Keep this list empty until real-host, native notice and listening evidence is reviewed.
public enum AdditionalHostReleasePolicy {
    public static let verifiedBindings: Set<HostEventBindingID> = []

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
