import Foundation

/// Storage capability is independent of provider production admission.
package struct AICueCredentialAccessPolicy: Sendable {
    package let permitsDataProtectionKeychain: Bool

    package init(permitsDataProtectionKeychain: Bool) {
        self.permitsDataProtectionKeychain = permitsDataProtectionKeychain
    }

    package static var currentBuild: Self {
        #if CLAUDIO_PUBLIC_PREVIEW
        Self(permitsDataProtectionKeychain: false)
        #else
        Self(permitsDataProtectionKeychain: true)
        #endif
    }

    package func permits(_ profileID: AICueProviderProfileID) -> Bool {
        permitsDataProtectionKeychain || profileID == .senseAudioChina
            || profileID == .bailianBeijing
    }

    package func permits(_ slotID: AICueCredentialSlotID) -> Bool {
        permitsDataProtectionKeychain || slotID == .senseAudioChina || slotID == .bailianBeijing
    }
}
