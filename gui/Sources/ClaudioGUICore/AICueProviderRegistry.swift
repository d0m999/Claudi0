import ClaudioLocalization
import Foundation

public enum AICueProviderRegistryError: Error, Sendable, Equatable {
    case unknownProfile
    case invalidProfileSet
    case invalidProfileContract
}

/// The application-owned profile allowlist. A selected raw ID is only trusted after a lookup;
/// endpoint, model, voice, region, authentication and credential-slot values never come from it.
public struct AICueProviderRegistry: Sendable {
    private struct BuiltInContract {
        let profiles: [AICueProviderProfile]
        let assetPoliciesByProfileID: [AICueProviderProfileID: AICueAssetPolicy]
    }

    private let orderedProfiles: [AICueProviderProfile]
    private let profilesByID: [AICueProviderProfileID: AICueProviderProfile]
    private let assetPoliciesByProfileID: [AICueProviderProfileID: AICueAssetPolicy]

    public init() {
        self.init(
            evidenceGatedSenseAudioAssetPolicy: Self.productionSenseAudioAssetPolicy)
    }

    package init(validating profiles: [AICueProviderProfile]) throws {
        let contract = Self.builtInContract(
            senseAudioAssetPolicy: Self.productionSenseAudioAssetPolicy)
        try self.init(
            validating: profiles,
            expectedProfiles: contract.profiles,
            assetPoliciesByProfileID: contract.assetPoliciesByProfileID)
    }

    /// Explicit nil omits SenseAudio without changing the other admitted profiles. Deterministic fixtures can supply
    /// an independent asset policy without changing the default production contract.
    package init(evidenceGatedSenseAudioAssetPolicy assetPolicy: AICueAssetPolicy?) {
        let contract = Self.builtInContract(senseAudioAssetPolicy: assetPolicy)
        do {
            try self.init(
                validating: contract.profiles,
                expectedProfiles: contract.profiles,
                assetPoliciesByProfileID: contract.assetPoliciesByProfileID)
        } catch {
            preconditionFailure("Built-in AI cue provider profiles are invalid")
        }
    }

    /// Package tests can mutate the compiled contract and policy map independently. Production
    /// construction always uses ``builtInContract(senseAudioAssetPolicy:)`` for both values.
    package init(
        validating profiles: [AICueProviderProfile],
        evidenceGatedSenseAudioAssetPolicy assetPolicy: AICueAssetPolicy?,
        assetPoliciesByProfileID: [AICueProviderProfileID: AICueAssetPolicy]
    ) throws {
        let contract = Self.builtInContract(senseAudioAssetPolicy: assetPolicy)
        guard assetPoliciesByProfileID == contract.assetPoliciesByProfileID else {
            throw AICueProviderRegistryError.invalidProfileContract
        }
        try self.init(
            validating: profiles,
            expectedProfiles: contract.profiles,
            assetPoliciesByProfileID: assetPoliciesByProfileID)
    }

    private init(
        validating profiles: [AICueProviderProfile],
        expectedProfiles expected: [AICueProviderProfile],
        assetPoliciesByProfileID: [AICueProviderProfileID: AICueAssetPolicy]
    ) throws {
        let expectedIDs = Set(expected.map(\.id))
        let actualIDs = Set(profiles.map(\.id))
        guard
            profiles.count == expected.count,
            actualIDs.count == profiles.count,
            actualIDs == expectedIDs
        else {
            throw AICueProviderRegistryError.invalidProfileSet
        }

        let expectedByID = Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) })
        for profile in profiles {
            guard
                profile.routes.allSatisfy({ $0.key == $0.value.modality }),
                profile.supportedModalities == Set(profile.routes.keys),
                profile.routes.values.allSatisfy({ !$0.supportedLanguageTags.isEmpty }),
                profile.routes.values.allSatisfy({ $0.candidateSetPolicy.isValid }),
                expectedByID[profile.id] == profile
            else {
                throw AICueProviderRegistryError.invalidProfileContract
            }
        }
        let remoteAssetProfileIDs = Set(
            profiles.compactMap { profile in
                profile.routes.values.contains(where: { $0.transport == .remoteAssets })
                    ? profile.id
                    : nil
            })
        guard Set(assetPoliciesByProfileID.keys) == remoteAssetProfileIDs else {
            throw AICueProviderRegistryError.invalidProfileContract
        }

        orderedProfiles = expected.map { expectedProfile in
            profiles.first(where: { $0.id == expectedProfile.id })!
        }
        profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        self.assetPoliciesByProfileID = assetPoliciesByProfileID
    }

    public func profiles() -> [AICueProviderProfile] {
        orderedProfiles
    }

    public func profile(for profileID: AICueProviderProfileID) throws -> AICueProviderProfile {
        if profileID == .bailianBeijing { return Self.bailianBeijing }
        guard let profile = profilesByID[profileID] else {
            throw AICueProviderRegistryError.unknownProfile
        }
        return profile
    }

    package func assetPolicy(for profileID: AICueProviderProfileID) -> AICueAssetPolicy? {
        assetPoliciesByProfileID[profileID]
    }

    private static let allowlistedProfiles: [AICueProviderProfile] = {
        var profiles = [elevenLabsGlobal, miniMaxGlobal]
        #if CLAUDIO_BAILIAN_ACCEPTANCE
        profiles.append(bailianBeijing)
        #endif
        return profiles
    }()

    /// Owner-accepted observed contract (ADR 0014). T9 enables the complete profile locally;
    /// distribution and final native/provider evidence remain separate acceptance gates.
    package static let productionSenseAudioAssetPolicy: AICueAssetPolicy? = try! AICueAssetPolicy(
        allowedOrigins: [try! AICueAssetOrigin("https://dynamic.senseaudio.cn:443")],
        acceptedMediaTypes: ["audio/mpeg"])

    private static func builtInContract(
        senseAudioAssetPolicy: AICueAssetPolicy?
    ) -> BuiltInContract {
        var profiles = allowlistedProfiles
        var policies: [AICueProviderProfileID: AICueAssetPolicy] = [:]
        #if CLAUDIO_BAILIAN_ACCEPTANCE
        policies[.bailianBeijing] = BailianAssetContract.downloadPolicy
        #endif
        if let senseAudioAssetPolicy {
            profiles.append(senseAudioChina)
            policies[.senseAudioChina] = senseAudioAssetPolicy
        }
        return BuiltInContract(profiles: profiles, assetPoliciesByProfileID: policies)
    }

    private static let styledComplete = AICueCandidateSetPolicy(
        semantics: .styled,
        requestedCount: 3,
        minimumAcceptedCount: 3)
    private static let numberedComplete = AICueCandidateSetPolicy(
        semantics: .numbered,
        requestedCount: 3,
        minimumAcceptedCount: 3)
    private static let numberedPartial = AICueCandidateSetPolicy(
        semantics: .numbered,
        requestedCount: 3,
        minimumAcceptedCount: 1)

    private static let elevenLabsGlobal: AICueProviderProfile = {
        let speechEndpoint = fixedURL(
            "https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb")
        let effectsEndpoint = fixedURL("https://api.elevenlabs.io/v1/sound-generation")
        let languages: Set<String> = ["zh", "zh-Hans", "en"]
        let speech = AICueProviderRoute(
            modality: .speech,
            endpoint: speechEndpoint,
            modelID: "eleven_v3",
            voiceID: "JBFqnCBsd6RMkjVDRZzb",
            supportedLanguageTags: languages,
            authentication: .elevenLabsAPIKeyHeader,
            transport: .directContainer,
            candidateSetPolicy: styledComplete)
        let mixed = AICueProviderRoute(
            modality: .mixed,
            endpoint: speechEndpoint,
            modelID: "eleven_v3",
            voiceID: "JBFqnCBsd6RMkjVDRZzb",
            supportedLanguageTags: languages,
            authentication: .elevenLabsAPIKeyHeader,
            transport: .directContainer,
            candidateSetPolicy: styledComplete)
        let animal = AICueProviderRoute(
            modality: .animal,
            endpoint: effectsEndpoint,
            modelID: "eleven_text_to_sound_v2",
            voiceID: nil,
            supportedLanguageTags: languages,
            authentication: .elevenLabsAPIKeyHeader,
            transport: .directContainer,
            candidateSetPolicy: styledComplete)
        let soundEffect = AICueProviderRoute(
            modality: .soundEffect,
            endpoint: effectsEndpoint,
            modelID: "eleven_text_to_sound_v2",
            voiceID: nil,
            supportedLanguageTags: languages,
            authentication: .elevenLabsAPIKeyHeader,
            transport: .directContainer,
            candidateSetPolicy: styledComplete)
        return AICueProviderProfile(
            id: .elevenLabsGlobal,
            providerID: .elevenLabs,
            credentialSlotID: .legacyElevenLabs,
            credentialValidationPolicy: .readOnlyProbe,
            regionID: nil,
            displayNameKey: .aiCueProviderProfileElevenLabsGlobal,
            privacyDisclosureKey: .aiCueCredentialPrivacy,
            routes: [
                .speech: speech,
                .mixed: mixed,
                .animal: animal,
                .soundEffect: soundEffect,
            ],
            constraints: AICueProviderConstraints(maximumDurationMilliseconds: 3_000))
    }()

    private static let miniMaxGlobal = AICueProviderProfile(
        id: .miniMaxGlobal,
        providerID: .miniMax,
        credentialSlotID: .miniMaxGlobal,
        credentialValidationPolicy: .readOnlyProbe,
        regionID: nil,
        displayNameKey: .aiCueProviderProfileMiniMaxGlobal,
        privacyDisclosureKey: .aiCueCredentialPrivacyMiniMax,
        routes: [
            .speech: AICueProviderRoute(
                modality: .speech,
                endpoint: fixedURL("https://api.minimax.io/v1/t2a_v2"),
                modelID: "speech-2.8-hd",
                voiceID: "Chinese (Mandarin)_Reliable_Executive",
                supportedLanguageTags: ["zh", "zh-Hans"],
                authentication: .bearerAPIKey,
                transport: .hexEncodedContainer,
                candidateSetPolicy: numberedComplete)
        ],
        constraints: AICueProviderConstraints(maximumDurationMilliseconds: 3_000))

    package static let bailianBeijing: AICueProviderProfile = {
        let routes = Dictionary(
            uniqueKeysWithValues: AICueModality.allCases.map { modality in
                let speech = modality == .speech
                return (
                    modality,
                    AICueProviderRoute(
                        modality: modality,
                        endpoint: URL(
                            string:
                                "https://cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer"
                        )!,
                        modelID: speech ? "qwen-audio-3.1-tts-flash" : "qwen-audio-3.1-tts-next",
                        voiceID: nil,
                        supportedLanguageTags: ["zh*", "en*"],
                        authentication: .bearerAPIKey,
                        transport: speech
                            ? .ssePCM(
                                AICuePCMFormat(
                                    sampleRate: 24_000, bitsPerSample: 16, channels: 1,
                                    isLittleEndian: true)) : .remoteAssets,
                        candidateSetPolicy: styledComplete,
                        generationBudget: speech ? .standard : .longRunningSFX,
                        endpointScope: .bailianWorkspace,
                        allowsGenerationRetry: false)
                )
            })
        return AICueProviderProfile(
            id: .bailianBeijing, providerID: .bailianBeijing,
            credentialSlotID: .bailianBeijing, credentialValidationPolicy: .readOnlyProbe,
            regionID: "beijing", displayNameKey: .aiCueProviderProfileBailianBeijing,
            privacyDisclosureKey: .aiCueCredentialPrivacyBailianBeijing,
            routes: routes,
            constraints: AICueProviderConstraints(maximumDurationMilliseconds: 3_000))
    }()

    private static let senseAudioChina: AICueProviderProfile = {
        let speech = AICueProviderRoute(
            modality: .speech,
            endpoint: fixedURL("https://api.senseaudio.cn/v1/t2a_v2"),
            modelID: "sensenova-tts-2.0",
            voiceID: "female_0033_b",
            supportedLanguageTags: ["zh*"],
            authentication: .bearerAPIKey,
            transport: .hexEncodedContainer,
            candidateSetPolicy: numberedComplete)
        let sfxEndpoint = fixedURL("https://api.senseaudio.cn/v1/sound-effects/generations")
        let animal = AICueProviderRoute(
            modality: .animal,
            endpoint: sfxEndpoint,
            modelID: "senseaudio-sfx-1.0-260626",
            voiceID: nil,
            supportedLanguageTags: ["zh*"],
            authentication: .bearerAPIKey,
            transport: .remoteAssets,
            candidateSetPolicy: numberedPartial,
            generationBudget: .longRunningSFX)
        let soundEffect = AICueProviderRoute(
            modality: .soundEffect,
            endpoint: sfxEndpoint,
            modelID: "senseaudio-sfx-1.0-260626",
            voiceID: nil,
            supportedLanguageTags: ["zh*"],
            authentication: .bearerAPIKey,
            transport: .remoteAssets,
            candidateSetPolicy: numberedPartial,
            generationBudget: .longRunningSFX)
        return AICueProviderProfile(
            id: .senseAudioChina,
            providerID: .senseAudio,
            credentialSlotID: .senseAudioChina,
            credentialValidationPolicy: .readOnlyProbe,
            regionID: "china",
            displayNameKey: .aiCueProviderProfileSenseAudioChina,
            privacyDisclosureKey: .aiCueCredentialPrivacySenseAudioChina,
            routes: [.speech: speech, .animal: animal, .soundEffect: soundEffect],
            constraints: AICueProviderConstraints(maximumDurationMilliseconds: 3_000))
    }()

    private static func fixedURL(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid built-in AI cue provider URL")
        }
        return url
    }

}
